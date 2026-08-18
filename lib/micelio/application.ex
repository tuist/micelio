defmodule Micelio.Application do
  @moduledoc """
  The supervision tree.

  Ordering matters in one place only: the cluster process joins the process
  group that makes this node visible to the others, so it starts *after* the
  replica machinery is ready. A node that advertised itself before it could
  serve would receive hints and route decisions it was not yet able to honour.

  Everything else is independent, which is a consequence of the architecture
  rather than an accident: no component owns state another one needs, so
  nothing has to be started in a particular order to be correct.
  """

  use Application

  require Logger

  alias Micelio.Config

  @impl true
  def start(_type, _args) do
    Micelio.Telemetry.attach()
    Micelio.Telemetry.setup_opentelemetry()
    log_boot()

    children =
      [
        {Task.Supervisor, name: Micelio.TaskSupervisor},
        object_store_children(),
        {Registry, keys: :unique, name: Micelio.ReplicaRegistry},
        {DynamicSupervisor, strategy: :one_for_one, name: Micelio.ReplicaSupervisor},
        # One writer per repository, batching its index updates.
        {Registry, keys: :unique, name: Micelio.WriterRegistry},
        {DynamicSupervisor, strategy: :one_for_one, name: Micelio.WriterSupervisor},
        auth_children(),
        {Micelio.Auth.JWKS, []},
        # Authorization policy lives in object storage like everything else;
        # this is only its per-node cache.
        {Micelio.Policy, []},
        maintenance_children(),
        listener_children(),
        prom_ex_children(),
        # Last: joining the cluster is what tells other nodes this one can
        # serve, so nothing should be advertised until it can.
        cluster_children()
      ]
      |> List.flatten()

    opts = [strategy: :one_for_one, name: Micelio.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("micelio #{Micelio.version()} ready on #{Config.node_id()} (#{node()})")
        {:ok, pid}

      error ->
        error
    end
  end

  # The filesystem object store needs a process to serialize compare-and-swap
  # writes; S3 gets that from the service itself and needs nothing.
  defp object_store_children do
    case Config.object_store() do
      {Micelio.ObjectStore.Filesystem, _opts} -> [{Micelio.ObjectStore.Filesystem.Lock, []}]
      _ -> []
    end
  end

  defp auth_children do
    case Config.auth() do
      {Micelio.Auth.Webhook, opts} -> [{Micelio.Auth.Webhook, opts}]
      _ -> []
    end
  end

  defp maintenance_children do
    if Config.start_listeners?() do
      [
        {Micelio.Replica.Compactor, []},
        {Micelio.Replica.Reaper, []}
      ]
    else
      []
    end
  end

  defp listener_children do
    if Config.start_listeners?() do
      [
        # Public: Git smart HTTP, MCP, OAuth discovery.
        #
        # A clone can run for many minutes and a push can be gigabytes, so the
        # read timeout is raised well above what an ordinary web listener would
        # want. Named so the metrics plugin can count live connections, which
        # is the signal an autoscaler should use.
        listener(Micelio.HTTP.Public,
          plug: Micelio.HTTP.Router,
          port: Config.git_port(),
          thousand_island_options: [
            num_acceptors: 100,
            read_timeout: :timer.minutes(30),
            transport_options: [backlog: 1024]
          ],
          # Compression is off deliberately. Bandit will gzip a response when the
          # client offers to accept it, and every git client does — but the Git
          # protocol carries packfiles, which are already compressed, so this
          # spends CPU to make responses slightly larger. Worse, git parses the
          # reference advertisement itself and stalls when it arrives encoded,
          # which presents as a push that hangs rather than an error.
          http_options: [log_protocol_errors: false, compress: false]
        ),

        # Loopback only: the pre-receive hook's callback. This endpoint can
        # commit a push, so it must not be reachable from outside the node.
        listener(Micelio.HTTP.Hook,
          plug: Micelio.HTTP.HookRouter,
          port: Config.hook_port(),
          ip: {127, 0, 0, 1}
        ),

        # Operations: health, readiness, metrics, repository administration.
        listener(Micelio.HTTP.Admin, plug: Micelio.HTTP.AdminRouter, port: Config.admin_port())
      ]
    else
      []
    end
  end

  # Bandit owns its listener's registered name, so the supervisor id is the only
  # thing we set. Live connections are counted from Bandit's telemetry instead
  # of by inspecting the listener; see `Micelio.Telemetry.InFlight`.
  defp listener(name, opts) do
    opts =
      opts
      |> Keyword.put(:scheme, :http)
      |> Keyword.put(:startup_log, false)

    Supervisor.child_spec({Bandit, opts}, id: name)
  end

  defp prom_ex_children do
    if Config.start_listeners?(), do: [Micelio.PromEx], else: []
  end

  defp cluster_children do
    if Config.start_gossip?() do
      [
        # `:pg` is the membership and broadcast primitive. Distributed Erlang
        # already knows which nodes are alive and delivers messages reliably
        # between them, so there is no gossip protocol here to write or debug.
        %{id: Micelio.PG, start: {:pg, :start_link, [Micelio.Cluster.scope()]}},
        libcluster_child(),
        {Micelio.Cluster, []}
      ]
      |> List.flatten()
    else
      []
    end
  end

  # Discovery only. libcluster's job ends once nodes can see each other;
  # membership, failure detection and message delivery are the BEAM's.
  defp libcluster_child do
    case Application.get_env(:libcluster, :topologies) do
      nil -> []
      topologies -> [{Cluster.Supervisor, [topologies, [name: Micelio.ClusterSupervisor]]}]
    end
  end

  defp log_boot do
    Logger.info("""
    micelio #{Micelio.version()} starting
      node:         #{Config.node_id()} (#{node()})
      data dir:     #{Config.data_dir()}
      object store: #{Config.object_store() |> elem(0) |> inspect()}
      auth:         #{Config.auth() |> elem(0) |> inspect()}
    """)
  end
end
