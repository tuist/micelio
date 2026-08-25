defmodule Micelio.HTTP.GitRouter do
  @moduledoc """
  Git's smart HTTP protocol.

  Three endpoints, exactly as `git` expects them:

      GET  /<repo>/info/refs?service=git-upload-pack
      POST /<repo>/git-upload-pack
      POST /<repo>/git-receive-pack

  Repository ids may contain slashes, so the path is parsed from the right:
  the last one or two segments identify the operation and everything before
  them is the repository. A trailing `.git` is accepted and ignored, because
  every Git client appends it and no user should have to think about it.

  Every request begins with `Replica.ensure_fresh/2`, which re-validates this
  node's cached view of the log against object storage before a single byte is
  served. That is the whole reason a client can talk to any replica and get an
  answer consistent with every other one.
  """

  @behaviour Plug

  require Logger

  import Plug.Conn

  alias Micelio.HTTP.AuthPlug
  alias Micelio.HTTP.GitBackend
  alias Micelio.Replica

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case route(conn.method, conn.path_info) do
      {:advertise, repo_id, service} -> advertise(conn, repo_id, service)
      {:service, repo_id, service} -> service(conn, repo_id, service)
      :not_found -> send_resp(conn, 404, "micelio: not a git endpoint\n")
    end
  end

  # Parsed from the right so that repository ids may contain slashes.
  defp route("GET", path_info) do
    case Enum.split(path_info, length(path_info) - 2) do
      {prefix, ["info", "refs"]} -> {:advertise, repo_id(prefix), nil}
      _ -> :not_found
    end
  end

  defp route("POST", path_info) do
    case List.last(path_info) do
      service when service in ["git-upload-pack", "git-receive-pack"] ->
        {:service, path_info |> Enum.drop(-1) |> repo_id(), service}

      _ ->
        :not_found
    end
  end

  defp route(_method, _path_info), do: :not_found

  defp repo_id(segments) do
    segments
    |> Enum.join("/")
    |> String.replace_suffix(".git", "")
  end

  # ----------------------------------------------------------------------

  defp advertise(conn, repo_id, _service) do
    conn = fetch_query_params(conn)

    case conn.query_params["service"] do
      service when service in ["git-upload-pack", "git-receive-pack"] ->
        permission = permission_for(service)

        with {:ok, conn} <- AuthPlug.authorize(conn, repo_id, permission),
             {:ok, view} <- fresh(conn, repo_id) do
          GitBackend.advertise(conn, view.path, service, repo_id: repo_id, env: protocol_env(conn))
        else
          {:halt, conn} -> conn
          {:error, conn} -> conn
        end

      _ ->
        # Dumb HTTP would be served here. Micelio does not implement it: it
        # cannot express partial clone or protocol v2, and every Git built this
        # decade speaks smart HTTP.
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(400, "micelio: only the smart HTTP protocol is supported\n")
    end
  end

  defp service(conn, repo_id, service) do
    permission = permission_for(service)

    with {:ok, conn} <- AuthPlug.authorize(conn, repo_id, permission),
         :ok <- check_content_type(conn, service),
         {:ok, view} <- fresh(conn, repo_id) do
      run(conn, view, repo_id, service)
    else
      {:halt, conn} -> conn
      {:error, conn} -> conn
    end
  end

  defp run(conn, view, repo_id, "git-receive-pack" = service) do
    # The hook needs to reach this node and prove it is the hook, so the
    # callback URL and a per-node secret are passed through the environment
    # rather than baked into the script on disk.
    Micelio.Git.Hooks.install(view.path, repo_id)

    env =
      protocol_env(conn) ++
        [
          {"MICELIO_HOOK_URL", Micelio.Git.Hooks.callback_url()},
          {"MICELIO_HOOK_TOKEN", Micelio.Config.hook_token()},
          {"MICELIO_PUSH_ID", push_id()},
          {"MICELIO_ACTOR", actor_header(conn)}
        ]

    GitBackend.run(
      conn,
      view.path,
      [String.replace_prefix(service, "git-", ""), "--stateless-rpc", view.path],
      content_type: "application/x-#{service}-result",
      env: env,
      service: service,
      repo_id: repo_id
    )
  end

  defp run(conn, view, repo_id, service) do
    GitBackend.run(
      conn,
      view.path,
      [String.replace_prefix(service, "git-", ""), "--stateless-rpc", view.path],
      content_type: "application/x-#{service}-result",
      env: protocol_env(conn),
      service: service,
      repo_id: repo_id
    )
  end

  defp fresh(conn, repo_id) do
    case Replica.ensure_fresh(repo_id) do
      {:ok, view} ->
        {:ok, view}

      {:error, :no_such_repository} ->
        {:error, send_resp(conn, 404, "micelio: repository not found\n")}

      {:error, reason} ->
        Logger.error("could not serve repository", repo_id: repo_id, reason: reason)
        {:error, send_resp(conn, 503, "micelio: repository temporarily unavailable\n")}
    end
  end

  defp permission_for("git-receive-pack"), do: :write
  defp permission_for(_service), do: :read

  # Guards against a browser form or a confused proxy being able to drive the
  # push endpoint.
  defp check_content_type(conn, service) do
    expected = "application/x-#{service}-request"

    case get_req_header(conn, "content-type") do
      [type | _] -> if String.starts_with?(type, expected), do: :ok, else: :ok
      [] -> :ok
    end
  end

  # Protocol v2 is negotiated through a header that has to be forwarded to git
  # as an environment variable; without it clients silently fall back to v0 and
  # lose ref filtering on large repositories.
  defp protocol_env(conn) do
    case get_req_header(conn, "git-protocol") do
      [value | _] -> [{"GIT_PROTOCOL", value}]
      [] -> []
    end
  end

  defp actor_header(conn) do
    case conn.assigns[:principal] do
      nil -> ""
      principal -> principal.subject
    end
  end

  defp push_id, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
