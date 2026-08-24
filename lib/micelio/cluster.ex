defmodule Micelio.Cluster do
  @moduledoc """
  Cluster membership and replication hints.

  The reference design for this system broadcasts UDP gossip packets to tell
  other replicas that a repository moved forward, and carries its own notion of
  which nodes are healthy. On the BEAM both of those already exist, so this
  module is mostly a thin, well-named layer over what OTP provides:

    * **Membership** is the `:pg` group every ready node joins. A node appears
      when its replica supervisor is running and disappears when the node dies
      or is partitioned away, which distributed Erlang detects through its own
      heartbeat (`net_ticktime`). There is no membership protocol here to get
      wrong.
    * **Discovery** is `libcluster`, so a Kubernetes StatefulSet, a DNS record
      or a static list all work without changing this code.
    * **Hints** are ordinary messages to the group. Distributed Erlang delivers
      them over TCP with per-pair ordering, so unlike UDP gossip they do not
      need to be designed around loss or reordering.

  What does not change is that hints are **advisory**. A replica never trusts a
  hint as evidence of anything; it treats it as a reason to go and revalidate
  its cached WAL index against object storage. Losing every hint in the cluster
  costs latency, never correctness, because reads verify against the source of
  truth anyway. That is what lets membership be approximate: two nodes that
  disagree about who owns a repository still converge, because the object store
  arbitrates and not the cluster.
  """

  use GenServer

  require Logger

  alias Micelio.Cluster.Rendezvous
  alias Micelio.Config

  @scope Micelio.PG
  @group :replicas

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Nodes currently ready to serve repositories."
  @spec members() :: [node()]
  def members do
    case group_members() do
      [] -> if(Config.serve?(), do: [node()], else: [])
      nodes -> nodes
    end
  end

  @doc """
  Nodes that should hold `repo_id`, most-preferred first.

  `count` defaults to the repository's configured replica factor. A large
  monorepo can name a hundred nodes to absorb CI read load; a repository
  created by an agent can name one, because losing that one replica loses
  nothing that is not already in the log.
  """
  @spec replicas_for(String.t(), pos_integer() | nil) :: [node()]
  def replicas_for(repo_id, count \\ nil) do
    Rendezvous.select(members(), repo_id, count || Config.default_replicas())
  end

  @doc """
  The node that should act as primary for `repo_id`.

  Nothing depends on this for correctness: any node may accept a push, since
  the compare-and-swap in the object store is what linearizes them. It matters
  for compaction, which is expensive and should happen once rather than on
  every replica.
  """
  @spec primary_for(String.t()) :: node() | nil
  def primary_for(repo_id), do: Rendezvous.primary(members(), repo_id)

  @doc "Whether this node is the preferred primary for `repo_id`."
  @spec primary?(String.t()) :: boolean()
  def primary?(repo_id), do: primary_for(repo_id) == node()

  @doc "Whether this node is one of the nodes that should hold `repo_id`."
  @spec responsible?(String.t(), pos_integer() | nil) :: boolean()
  def responsible?(repo_id, count \\ nil), do: node() in replicas_for(repo_id, count)

  @doc """
  Tell the other replicas that `repo_id` advanced to `(epoch, seq)`.

  Fire and forget. A replica that misses this finds out on its next read, when
  the conditional GET on the index returns `200` instead of `304`.
  """
  @spec announce(String.t(), non_neg_integer(), non_neg_integer()) :: :ok
  def announce(repo_id, epoch, seq) do
    message = {:wal_advanced, repo_id, epoch, seq, node()}

    for pid <- group_pids(), node(pid) != node() do
      send(pid, message)
    end

    # Maintenance has its own capability group. A serving node must not pull a
    # CPU-heavy job onto itself merely because it accepted a push, and a
    # maintenance-only node must not pretend to serve repositories.
    Micelio.Maintenance.announce(repo_id, epoch, seq)

    :telemetry.execute([:micelio, :cluster, :announce], %{seq: seq}, %{repo_id: repo_id, epoch: epoch})
    :ok
  end

  @doc "Run `fun` on the preferred primary for `repo_id`, or locally if it is us."
  @spec on_primary(String.t(), (-> result), timeout()) :: {:ok, result} | {:error, term()}
        when result: term()
  def on_primary(repo_id, fun, timeout \\ :timer.seconds(30)) do
    case primary_for(repo_id) do
      nil -> {:error, :no_members}
      target when target == node() -> {:ok, fun.()}
      target -> safe_call(target, fun, timeout)
    end
  end

  defp safe_call(target, fun, timeout) do
    {:ok, :erpc.call(target, fun, timeout)}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @impl true
  def init(_opts) do
    if Config.serve?(), do: :pg.join(@scope, @group, self())
    :net_kernel.monitor_nodes(true, node_type: :visible)
    {:ok, %{}}
  end

  @impl true
  def handle_info({:wal_advanced, repo_id, epoch, seq, from}, state) do
    # Only act when this node is meant to hold the repository, or already does.
    # Otherwise a hint would pull repositories onto nodes that should not be
    # spending disk on them.
    if Micelio.Replica.alive?(repo_id) or responsible?(repo_id) do
      Micelio.Replica.hint(repo_id, epoch, seq)
    end

    Logger.debug("wal hint for #{repo_id} at #{epoch}/#{seq} from #{from}")
    {:noreply, state}
  end

  def handle_info({:nodeup, node, _info}, state) do
    Logger.info("node joined the cluster: #{node}")
    :telemetry.execute([:micelio, :cluster, :nodeup], %{count: length(members())}, %{node: node})
    {:noreply, state}
  end

  def handle_info({:nodedown, node, _info}, state) do
    # Nothing to repair. Repositories the departed node held are still fully
    # described by the log, and rendezvous hashing has already reassigned them.
    Logger.info("node left the cluster: #{node}")
    :telemetry.execute([:micelio, :cluster, :nodedown], %{count: length(members())}, %{node: node})
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  def scope, do: @scope

  @doc false
  def group, do: @group

  defp group_members do
    group_pids()
    |> Enum.map(&node/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # A test may deliberately run without distributed membership. The serving
  # fallback above is enough for that single-node case; an absent process group
  # must not turn a local read into an exception.
  defp group_pids do
    :pg.get_members(@scope, @group)
  rescue
    ArgumentError -> []
  catch
    :exit, _reason -> []
  end
end
