defmodule Micelio.Git.Hooks do
  @moduledoc """
  The `pre-receive` hook, which is where a push becomes durable.

  Git runs `pre-receive` after it has received and validated the objects but
  before it applies any reference update, with the new objects held in a
  quarantine directory that is discarded if the hook fails. That is precisely
  the point at which Micelio needs to act:

    * the objects exist and have been checked for connectivity, so we know the
      push is coherent,
    * nothing is visible yet, so refusing costs nothing, and
    * Git will apply the refs atomically if and only if we exit zero.

  So the hook calls back into the node, which uploads the quarantined packs to
  object storage and appends the entry to the write-ahead log. If the
  compare-and-swap wins, the hook exits zero and Git makes the push visible. If
  it loses — because another node's push landed first and the client's
  proposed `old` values are now stale — the hook exits non-zero, Git discards
  the quarantine, and the client is told to fetch and retry.

  Nothing is acknowledged to a client before it is in the log, so a client is
  never told "yes" for something the log does not have.

  The converse can happen and is worth stating plainly: a push may be reported
  as rejected and still be committed, either because the compare-and-swap
  succeeded and its response was lost, or because this node failed to install
  the refs after the log accepted them. `Micelio.WAL` closes the first window
  by recognising its own entry on retry; the second leaves this node behind
  until its next read, while other replicas serve the push normally. The
  contract is log-first: a hook failure means this node did not commit it, not
  that it never happened.

  The hook is a shell script rather than anything cleverer because it runs in
  Git's process, not ours, and the only contract that matters is its exit code.
  """

  alias Micelio.Config

  @hook "pre-receive"

  @doc """
  Install the hook into a repository, overwriting any previous version.

  Called on every materialization rather than only at creation, so a node
  running new code cannot end up driving a repository through an old hook.
  """
  @spec install(Path.t(), String.t()) :: :ok
  def install(repo_path, repo_id) do
    dir = Path.join(repo_path, "hooks")
    File.mkdir_p!(dir)
    path = Path.join(dir, @hook)
    File.write!(path, script(repo_id))
    File.chmod!(path, 0o755)
    :ok
  end

  @doc "The callback URL the hook posts to. Loopback only; never routed."
  @spec callback_url() :: String.t()
  def callback_url, do: "http://127.0.0.1:#{Config.hook_port()}/pre-receive"

  defp script(repo_id) do
    """
    #!/bin/sh
    # Managed by Micelio. Regenerated on every materialization; do not edit.
    #
    # Reads the proposed reference updates on stdin as "<old> <new> <ref>" lines
    # and asks the node whether they may be committed to the write-ahead log.
    # Exiting non-zero makes Git discard the quarantined objects, so a rejection
    # here leaves no trace.
    set -eu

    payload=$(cat)

    response=$(printf '%s' "$payload" | curl \\
      --silent --show-error \\
      --max-time "${MICELIO_HOOK_TIMEOUT:-600}" \\
      --request POST \\
      --header "Content-Type: text/plain" \\
      --header "X-Micelio-Token: ${MICELIO_HOOK_TOKEN:-}" \\
      --header "X-Micelio-Repository: #{repo_id}" \\
      --header "X-Micelio-Quarantine: ${GIT_QUARANTINE_PATH:-}" \\
      --header "X-Micelio-Git-Dir: $(pwd)" \\
      --header "X-Micelio-Push: ${MICELIO_PUSH_ID:-}" \\
      --header "X-Micelio-Actor: ${MICELIO_ACTOR:-}" \\
      --data-binary @- \\
      --write-out '\\n%{http_code}' \\
      "${MICELIO_HOOK_URL:-#{callback_url()}}" 2>&1) || {
      echo "micelio: could not reach the local node to commit this push" >&2
      exit 1
    }

    status=$(printf '%s' "$response" | tail -n 1)
    body=$(printf '%s' "$response" | sed '$d')

    if [ "$status" != "200" ]; then
      # The body is the reason, written for whoever ran `git push`.
      [ -n "$body" ] && printf '%s\\n' "$body" >&2
      exit 1
    fi

    exit 0
    """
  end
end
