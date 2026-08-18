defmodule Micelio.Ingest do
  @moduledoc """
  Committing a push to the write-ahead log.

  This runs inside Git's `pre-receive` window: the objects have been received
  and checked but nothing is visible yet, and Git will apply the reference
  updates if and only if this returns success.

  Three things happen, in an order chosen so that a failure at any point leaves
  nothing half-done:

    1. **Upload the packs.** They are content-addressed and nothing references
       them yet, so this is idempotent and a crash here leaks at most an
       unreferenced object.
    2. **Write the entry.** Also content-addressed, also unreferenced.
    3. **Compare-and-swap the index.** This is the moment the push exists.
       Before it, nothing has happened; after it, the push is durable, ordered,
       and visible to every replica.

  ## Rejecting stale pushes across nodes

  Git gives the hook the `old` value each ref had *on this node*. That is not
  enough on its own: another node may have accepted a push in between, and this
  node's local view could be behind. So every command is checked against the
  index's ref map — the authoritative current state — inside the CAS retry
  loop, where it is re-read on each attempt.

  The result is that a non-fast-forward is rejected cluster-wide with the same
  certainty a single-server Git gets from its ref lock, without any node having
  to know what the others are doing.
  """

  require Logger

  alias Micelio.Cluster
  alias Micelio.Git
  alias Micelio.Replica
  alias Micelio.WAL
  alias Micelio.WAL.Entry
  alias Micelio.WAL.Index
  alias Micelio.Wal.V1

  @type command :: V1.RefCommand.t()

  @doc """
  Commit a push. Returns `{:ok, result}` when Git may apply the refs.

  The error tuple's second element is a message written for whoever ran
  `git push`, not for a log.
  """
  @spec commit(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def commit(repo_id, opts) do
    commands = Keyword.fetch!(opts, :commands)
    quarantine = Keyword.get(opts, :quarantine)
    actor = Keyword.get(opts, :actor, %V1.Actor{})
    started = System.monotonic_time(:millisecond)

    with {:ok, packs} <- collect_packs(repo_id, quarantine),
         {:ok, result} <- append(repo_id, commands, packs, actor) do
      Replica.record_local_push(repo_id, result.epoch, result.seq)
      Cluster.announce(repo_id, result.epoch, result.seq)

      duration = System.monotonic_time(:millisecond) - started

      :telemetry.execute(
        [:micelio, :push, :committed],
        %{duration_ms: duration, refs: length(commands), packs: length(packs)},
        %{repo_id: repo_id, seq: result.seq}
      )

      Logger.info("push committed to #{repo_id} at seq #{result.seq} (#{duration}ms)")
      {:ok, result}
    else
      {:error, reason} ->
        :telemetry.execute([:micelio, :push, :rejected], %{}, %{repo_id: repo_id, reason: classify(reason)})
        {:error, message(reason)}
    end
  end

  # Objects arrive in a quarantine directory that Git discards if we fail.
  # With `receive.unpackLimit = 1` they are always a packfile, so the artefact
  # on disk and the artefact in the log are the same bytes and no repacking or
  # re-encoding stands between the client's push and what gets stored.
  defp collect_packs(_repo_id, nil), do: {:ok, []}

  defp collect_packs(repo_id, quarantine) do
    quarantine
    |> Path.join("pack/*.pack")
    |> Path.wildcard()
    |> Enum.reduce_while({:ok, []}, fn pack, {:ok, acc} ->
      case WAL.put_pack(repo_id, pack) do
        {:ok, descriptor} -> {:cont, {:ok, [descriptor | acc]}}
        {:error, reason} -> {:halt, {:error, {:pack_upload_failed, reason}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp append(repo_id, commands, packs, actor) do
    WAL.append(repo_id, fn index ->
      # Re-checked on every compare-and-swap attempt, against the index we just
      # read. A push that races another one is validated against the winner's
      # result rather than against whatever was true when we started.
      with :ok <- check_fast_forward(index, commands) do
        {:ok,
         Entry.new(
           type: :ENTRY_TYPE_PUSH,
           commands: commands,
           packs: packs,
           actor: %{actor | node: Micelio.Config.node_id()}
         )}
      end
    end)
  end

  defp check_fast_forward(index, commands) do
    Enum.reduce_while(commands, :ok, fn %V1.RefCommand{} = command, _acc ->
      current = Index.ref(index, command.ref)

      if current == command.old_oid do
        {:cont, :ok}
      else
        {:halt, {:error, {:stale, command.ref, command.old_oid, current}}}
      end
    end)
  end

  @doc """
  Parse the `<old> <new> <ref>` lines Git writes to the hook's stdin.
  """
  @spec parse_commands(String.t()) :: {:ok, [command()]} | {:error, String.t()}
  def parse_commands(body) do
    commands =
      body
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split(String.trim(&1), " ", parts: 3))
      |> Enum.map(fn
        [old, new, ref] -> %V1.RefCommand{ref: ref, old_oid: old, new_oid: new}
        _ -> nil
      end)

    if Enum.any?(commands, &is_nil/1) do
      {:error, "malformed reference update"}
    else
      {:ok, commands}
    end
  end

  @doc """
  Resolve the quarantine directory Git handed the hook.

  `GIT_QUARANTINE_PATH` is usually relative to the repository, so it is
  resolved against the hook's working directory rather than ours.
  """
  @spec resolve_quarantine(String.t() | nil, String.t() | nil) :: Path.t() | nil
  def resolve_quarantine(nil, _git_dir), do: nil
  def resolve_quarantine("", _git_dir), do: nil

  def resolve_quarantine(quarantine, git_dir) do
    if Path.type(quarantine) == :absolute do
      quarantine
    else
      Path.expand(quarantine, git_dir || File.cwd!())
    end
  end

  @doc """
  Record a symbolic ref change, such as moving the default branch.

  It goes through the log like everything else, so replicas pick it up by the
  same mechanism and there is no second channel for "metadata" to get out of
  step with the repository itself.
  """
  @spec set_head(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def set_head(repo_id, target) do
    with {:ok, result} <-
           WAL.append(repo_id, fn _index ->
             {:ok, Entry.new(type: :ENTRY_TYPE_SYMREF, symrefs: %{"HEAD" => target})}
           end) do
      Replica.record_local_push(repo_id, result.epoch, result.seq)
      Cluster.announce(repo_id, result.epoch, result.seq)
      {:ok, result}
    end
  end

  @doc """
  Apply ref updates directly, without a Git client.

  This is the write path for the agent-facing API: an agent that has just
  written a tree and a commit needs the same durability and the same
  non-fast-forward checks as `git push`, so it takes the same road.
  """
  @spec update_refs(String.t(), [command()], keyword()) :: {:ok, map()} | {:error, String.t()}
  def update_refs(repo_id, commands, opts \\ []) do
    with {:ok, view} <- Replica.ensure_fresh(repo_id),
         {:ok, index, _etag} <- WAL.fetch(repo_id),
         {:ok, packs} <- pack_new_objects(repo_id, view.path, commands, index),
         {:ok, result} <- append(repo_id, commands, packs, Keyword.get(opts, :actor, %V1.Actor{})) do
      Git.update_refs(view.path, commands)
      Replica.record_local_push(repo_id, result.epoch, result.seq)
      Cluster.announce(repo_id, result.epoch, result.seq)
      {:ok, result}
    else
      {:error, reason} -> {:error, message(reason)}
    end
  end

  # Objects written by the agent API land loose in the local repository and have
  # to become a packfile before they can be logged, because a pack is the only
  # unit the log carries.
  #
  # The pack holds exactly what this change introduced: everything reachable
  # from the proposed new values, minus everything already reachable from the
  # repository's current refs.
  #
  # `git repack` is the wrong tool here, and getting this wrong is silent. It
  # only packs objects reachable from a ref, and on this path the new commit
  # has no ref yet — the ref is precisely what we are proposing — so a repack
  # produces an empty pack and the log ends up naming an object no pack
  # provides. Every replica then fails to converge, while the node that wrote
  # it carries on happily, because it still has the objects loose on disk.
  # It would also rewrite and re-upload the entire repository on every commit.
  defp pack_new_objects(repo_id, path, commands, index) do
    zero = Entry.zero_oid()
    include = commands |> Enum.map(& &1.new_oid) |> Enum.reject(&(&1 == zero)) |> Enum.uniq()

    if include == [] do
      # A pure deletion introduces no objects.
      {:ok, []}
    else
      exclude = index.refs |> Map.values() |> Enum.uniq()

      scratch =
        Path.join(
          System.tmp_dir!(),
          "micelio-pack-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
        )

      try do
        case Git.pack_objects(path, include, exclude, scratch) do
          {:ok, pack} -> upload_new_pack(repo_id, path, pack)
          {:error, reason} -> {:error, {:pack_failed, reason}}
        end
      after
        File.rm_rf(scratch)
      end
    end
  end

  defp upload_new_pack(_repo_id, _path, nil), do: {:ok, []}

  defp upload_new_pack(repo_id, path, pack) do
    with {:ok, descriptor} <- WAL.put_pack(repo_id, pack),
         # Install it locally too, so this node holds the same artefact every
         # other replica will download rather than a pile of loose objects.
         {:ok, _installed} <- Git.install_pack(path, pack) do
      {:ok, [descriptor]}
    else
      {:error, reason} -> {:error, {:pack_upload_failed, reason}}
    end
  end

  defp classify({:pack_failed, _}), do: :storage
  defp classify({:stale, _, _, _}), do: :non_fast_forward
  defp classify({:pack_upload_failed, _}), do: :storage
  defp classify(:cas_exhausted), do: :contention
  defp classify(_), do: :other

  defp message({:stale, ref, proposed, actual}) do
    """
    micelio: #{ref} has moved since you last fetched.
      you expected: #{short(proposed)}
      it is now:    #{short(actual)}
    Fetch and rebase, then push again.
    """
    |> String.trim()
  end

  defp message(:cas_exhausted) do
    "micelio: too much concurrent write activity on this repository; please retry"
  end

  defp message({:pack_upload_failed, reason}) do
    "micelio: could not durably store the pushed objects (#{inspect(reason)}); nothing was applied"
  end

  defp message(reason), do: "micelio: push rejected (#{inspect(reason)})"

  defp short(oid) do
    zero = Entry.zero_oid()
    if oid == zero, do: "(absent)", else: String.slice(oid, 0, 12)
  end
end
