defmodule Micelio.Config do
  @moduledoc """
  Typed access to the node's configuration.

  Every value has a default that makes a single-node development cluster work,
  so tests and `iex -S mix` need no environment at all.
  """

  @app :micelio

  @spec node_id() :: String.t()
  def node_id, do: get(:node_id, "micelio-1")

  @spec advertise_host() :: String.t()
  def advertise_host, do: get(:advertise_host, "127.0.0.1")

  @doc """
  Directory holding materialized bare repositories.

  This is the "warm cache on disk" and is expected to sit on fast local NVMe.
  It is safe to lose: anything in here can be rebuilt from the write-ahead log.
  """
  @spec data_dir() :: Path.t()
  def data_dir, do: get(:data_dir, "priv/data/repositories") |> expand_path()

  @spec object_store() :: {module(), keyword()}
  def object_store do
    case get(:object_store, nil) do
      nil -> {Micelio.ObjectStore.Filesystem, root: expand_path("priv/data/object-store")}
      {mod, opts} -> {mod, expand_opts(opts)}
    end
  end

  # Only genuinely path-valued options are expanded. Expanding everything would
  # rewrite an S3 endpoint or a secret into an absolute filesystem path, which
  # fails in a spectacularly confusing way at request time rather than at boot.
  @path_options [:root]

  @spec auth() :: {module(), keyword()}
  def auth, do: get(:auth, {Micelio.Auth.Allow, []})

  @spec git_port() :: :inet.port_number()
  def git_port, do: get(:git_port, 4000)

  @spec hook_port() :: :inet.port_number()
  def hook_port, do: get(:hook_port, 4001)

  @spec admin_port() :: :inet.port_number()
  def admin_port, do: get(:admin_port, 4002)

  @spec gossip_port() :: :inet.port_number()
  def gossip_port, do: get(:gossip_port, 4010)

  @spec admin_token() :: String.t() | nil
  def admin_token, do: get(:admin_token, nil)

  @doc "Statically configured peers, as `host:gossip_port` strings."
  @spec peers() :: [String.t()]
  def peers, do: get(:peers, [])

  @spec default_replicas() :: pos_integer()
  def default_replicas, do: get(:default_replicas, 3)

  @doc """
  How long a replica may reuse its cached view of the WAL index before
  re-validating it against the object store.

  Zero means every read is verified against the source of truth. Raising it
  trades strict consistency for fewer metadata round trips; the only safe
  reason to do so is a workload that tolerates bounded staleness.
  """
  @spec staleness_budget_ms() :: non_neg_integer()
  def staleness_budget_ms, do: get(:staleness_budget_ms, 0)

  @spec compaction_entry_threshold() :: pos_integer()
  def compaction_entry_threshold, do: get(:compaction_entry_threshold, 250)

  @spec compaction_bytes_threshold() :: pos_integer()
  def compaction_bytes_threshold, do: get(:compaction_bytes_threshold, 256 * 1024 * 1024)

  @doc "Evict a repository from local disk after this long without traffic."
  @spec idle_eviction_ms() :: pos_integer()
  def idle_eviction_ms, do: get(:idle_eviction_ms, :timer.hours(1))

  @spec start_listeners?() :: boolean()
  def start_listeners?, do: get(:start_listeners, true)

  @spec start_gossip?() :: boolean()
  def start_gossip?, do: get(:start_gossip, true)

  @doc "Shared secret the Git hooks use to call back into this node."
  @spec hook_token() :: String.t()
  def hook_token do
    case :persistent_term.get({__MODULE__, :hook_token}, nil) do
      nil ->
        token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        :persistent_term.put({__MODULE__, :hook_token}, token)
        token

      token ->
        token
    end
  end

  @doc """
  The externally reachable base URL of this deployment.

  Behind an ingress the request's own host is what clients can actually reach,
  so it is preferred over anything configured; `MICELIO_PUBLIC_URL` exists for
  deployments where that is not true, such as a proxy that rewrites the host.
  """
  @spec public_url(Plug.Conn.t() | nil) :: String.t()
  def public_url(conn \\ nil)

  def public_url(nil), do: get(:public_url, "http://localhost:#{git_port()}")

  def public_url(conn) do
    case get(:public_url, nil) do
      nil ->
        scheme = forwarded(conn, "x-forwarded-proto") || to_string(conn.scheme)
        host = forwarded(conn, "x-forwarded-host") || conn.host
        port = conn.port

        if (scheme == "https" and port == 443) or (scheme == "http" and port == 80) do
          "#{scheme}://#{host}"
        else
          "#{scheme}://#{host}:#{port}"
        end

      configured ->
        configured
    end
  end

  defp forwarded(conn, header) do
    case Plug.Conn.get_req_header(conn, header) do
      [value | _] -> value |> String.split(",") |> List.first() |> String.trim()
      [] -> nil
    end
  end

  @doc """
  The identifier tokens must name in their `aud` claim.

  Binding tokens to this deployment is what stops a token minted for another
  service that shares an issuer from being replayed here.
  """
  @spec resource_identifier() :: String.t()
  def resource_identifier, do: get(:resource_identifier, nil) || public_url(nil)

  @doc "Authorization servers advertised to MCP clients, if any."
  @spec authorization_servers() :: [String.t()]
  def authorization_servers, do: get(:authorization_servers, [])

  @spec put(atom(), term()) :: :ok
  def put(key, value), do: Application.put_env(@app, key, value)

  defp get(key, default), do: Application.get_env(@app, key, default)

  defp expand_opts(opts) do
    Enum.map(opts, fn
      {key, value} when key in @path_options -> {key, expand_path(value)}
      other -> other
    end)
  end

  # Tests want per-run scratch directories without hardcoding a path in the
  # config file, so `{:system_tmp, name}` resolves against the OS temp dir.
  defp expand_path({:system_tmp, name}), do: Path.join(System.tmp_dir!(), name)
  defp expand_path(value) when is_binary(value), do: Path.expand(value)
  defp expand_path(other), do: other
end
