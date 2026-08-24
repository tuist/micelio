defmodule Micelio.Config do
  @moduledoc """
  Typed access to the node's configuration.

  Every value has a default that makes a single-node development cluster work,
  so tests and `iex -S mix` need no environment at all.

  ## Process-local overrides

  Configuration is normally application environment, which is global. That is
  correct for a node — every process on it serves the same cluster — but it
  makes the test suite serial: two tests cannot point at different object
  stores at the same time.

  So a process may override configuration for itself and everything it starts,
  via `put_overrides/1`. Lookups check the calling process first, then walk
  `$callers`, then fall back to application environment. `Task` propagates
  `$callers` automatically, and `Micelio.Replica` copies its starter's
  overrides at init, so a test's isolation reaches the processes it causes to
  exist without threading configuration through every function signature.

  Nothing in production sets an override, so the fallback is the only path
  taken there.
  """

  @app :micelio
  @overrides_key {__MODULE__, :overrides}

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

  @doc """
  How long a node may reuse a cached authorization policy before revalidating.

  Unlike `staleness_budget_ms`, this does not default to zero. Authorization is
  on the path of every request, so revalidating each time would double the
  round trips; and unlike serving a stale repository, which would be a
  correctness failure, a slightly old policy is a bounded window that is still
  far tighter than the token lifetime it replaces.
  """
  @spec policy_staleness_budget_ms() :: non_neg_integer()
  def policy_staleness_budget_ms, do: get(:policy_staleness_budget_ms, 5_000)

  @spec compaction_entry_threshold() :: pos_integer()
  def compaction_entry_threshold, do: get(:compaction_entry_threshold, 250)

  @spec compaction_bytes_threshold() :: pos_integer()
  def compaction_bytes_threshold, do: get(:compaction_bytes_threshold, 256 * 1024 * 1024)

  @typedoc "A capability a node advertises to the rest of the cluster."
  @type role :: :serve | :maintain | :events

  @roles [:serve, :maintain, :events]

  @doc """
  Capabilities enabled on this node.

  Roles are deliberately capabilities, not an assignment recorded anywhere:
  changing a deployment changes the members visible to rendezvous hashing, and
  the next job naturally moves to an eligible node. The write-ahead log stays
  the source of truth regardless of which capability produced a cache entry.
  """
  @spec roles() :: [role()]
  def roles do
    :roles
    |> get(@roles)
    |> normalize_roles()
  end

  @spec serve?() :: boolean()
  def serve?, do: :serve in roles()

  @spec maintain?() :: boolean()
  def maintain?, do: :maintain in roles()

  @spec events?() :: boolean()
  def events?, do: :events in roles()

  @doc "Whether this node starts the local maintenance scheduler."
  @spec maintenance?() :: boolean()
  def maintenance?, do: maintain?() or events?()

  @doc "Maximum concurrent jobs of one maintenance kind on this node."
  @spec maintenance_concurrency(:compact | :lookup | :bundle | :events) :: pos_integer()
  def maintenance_concurrency(:compact), do: get(:maintenance_compaction_concurrency, 1)
  def maintenance_concurrency(:lookup), do: get(:maintenance_lookup_concurrency, 1)
  def maintenance_concurrency(:bundle), do: get(:maintenance_bundle_concurrency, 1)
  def maintenance_concurrency(:events), do: get(:maintenance_events_concurrency, 4)

  @doc "How often the local scheduler considers already-resident repositories."
  @spec maintenance_sweep_ms() :: pos_integer()
  def maintenance_sweep_ms, do: get(:maintenance_sweep_ms, :timer.minutes(5))

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

  @doc "Public browser-login settings for Git Credential Manager, if enabled."
  @spec git_auth() ::
          %{
            issuer: String.t(),
            client_id: String.t() | nil,
            authorization_endpoint: String.t(),
            token_endpoint: String.t(),
            registration_endpoint: String.t() | nil,
            redirect_uri: String.t(),
            scopes: [String.t()],
            username: String.t()
          }
          | nil
  def git_auth, do: get(:git_auth, nil)

  @spec put(atom(), term()) :: :ok
  def put(key, value), do: Application.put_env(@app, key, value)

  @doc """
  Override configuration for this process and everything it starts.

  Intended for tests. Passing an empty map clears the override.
  """
  @spec put_overrides(map()) :: :ok
  def put_overrides(overrides) when is_map(overrides) do
    Process.put(@overrides_key, overrides)
    :ok
  end

  @doc "The overrides in effect for the calling process, if any."
  @spec overrides() :: map()
  def overrides do
    case Process.get(@overrides_key) do
      nil -> inherited_overrides()
      overrides -> overrides
    end
  end

  # `$callers` is set by Task and by anything that opts into the convention, so
  # work spawned on behalf of a test inherits its isolation.
  defp inherited_overrides do
    Enum.find_value(Process.get(:"$callers", []), %{}, &overrides_of/1)
  end

  defp overrides_of(pid) do
    with {:dictionary, dictionary} <- Process.info(pid, :dictionary),
         {_key, overrides} <- List.keyfind(dictionary, @overrides_key, 0) do
      overrides
    else
      _ -> nil
    end
  end

  defp get(key, default) do
    case Map.fetch(overrides(), key) do
      {:ok, value} -> value
      :error -> Application.get_env(@app, key, default)
    end
  end

  defp normalize_roles(roles) when is_binary(roles) do
    roles
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> normalize_roles()
  end

  defp normalize_roles(roles) when is_list(roles) do
    roles
    |> Enum.map(&normalize_role!/1)
    |> Enum.uniq()
  end

  defp normalize_roles(other) do
    raise ArgumentError, "roles must be a list or comma-separated string, got: #{inspect(other)}"
  end

  defp normalize_role!(role) when role in @roles, do: role
  defp normalize_role!("serve"), do: :serve
  defp normalize_role!("maintain"), do: :maintain
  defp normalize_role!("events"), do: :events

  defp normalize_role!(role) do
    raise ArgumentError, "unknown Micelio role: #{inspect(role)}"
  end

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
