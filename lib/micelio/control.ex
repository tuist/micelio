defmodule Micelio.Control do
  @moduledoc """
  Repository lifecycle and cluster introspection.

  This is the "control plane", and the point of the architecture is that it is
  not a separate system. Creating a repository is a conditional write to object
  storage. Deciding where it lives is a hash. Finding out how a replica is
  doing is asking that node. There is no scheduler, no placement database, no
  membership table and nothing to keep consistent, so every node can answer
  every question and any node can be asked.

  That is what makes autoscaling work without an operator. Adding a pod changes
  the membership that rendezvous hashing reads, which silently reassigns a
  fraction of the repositories; the new pod materializes them on first request
  and the old ones evict them once idle. No rebalancing job runs, because there
  is no balance to restore — placement was never recorded, only computed.
  """

  require Logger

  alias Micelio.Cluster
  alias Micelio.Git
  alias Micelio.Replica
  alias Micelio.WAL
  alias Micelio.WAL.Index

  @doc """
  Create a repository.

  The conditional write is what makes this safe to call concurrently from
  anywhere: two nodes racing produce one repository and one `:already_exists`.
  """
  @spec create_repository(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_repository(repo_id, opts \\ []) do
    case WAL.create(repo_id, opts) do
      {:ok, index} ->
        Logger.info("created repository", repo_id: repo_id)
        :telemetry.execute([:micelio, :repository, :created], %{}, %{repo_id: repo_id})
        {:ok, summarize(index)}

      {:error, :already_exists} ->
        {:error, :already_exists}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Delete a repository and everything belonging to it. Irreversible."
  @spec delete_repository(String.t()) :: :ok | {:error, term()}
  def delete_repository(repo_id) do
    with :ok <- WAL.destroy(repo_id) do
      # Evict everywhere rather than waiting for the reaper, so the bytes stop
      # existing when the caller was told they would.
      Cluster.members()
      |> Enum.each(fn node ->
        :erpc.cast(node, Replica, :evict, [repo_id])
      end)

      Logger.info("deleted repository", repo_id: repo_id)
      :ok
    end
  end

  @doc "Every repository in the object store."
  @spec list_repositories() :: {:ok, [String.t()]} | {:error, term()}
  def list_repositories, do: WAL.list_repositories()

  @doc """
  Everything known about a repository: log state, placement and replica health.

  Placement is computed, not looked up. Replica health is gathered by asking
  each node that should hold it, in parallel, and a node that does not answer
  is reported as unreachable rather than treated as an error — a replica being
  down is a normal condition, not a fault, because the log is unaffected.
  """
  @spec describe_repository(String.t()) :: {:ok, map()} | {:error, term()}
  def describe_repository(repo_id) do
    with {:ok, index, _etag} <- WAL.fetch(repo_id) do
      placement = Cluster.replicas_for(repo_id, index.replicas)

      {:ok,
       summarize(index)
       |> Map.put(:placement, %{
         primary: List.first(placement),
         replicas: placement,
         desired: index.replicas,
         cluster_size: length(Cluster.members())
       })
       |> Map.put(:replicas, gather_replica_state(repo_id, placement))}
    end
  end

  defp gather_replica_state(repo_id, nodes) do
    nodes
    |> Task.async_stream(
      fn node ->
        case safe_rpc(node, Replica, :info, [repo_id]) do
          {:ok, {:ok, info}} -> Map.put(info, :reachable, true)
          {:ok, {:error, :not_resident}} -> %{node: node, reachable: true, resident: false}
          {:error, reason} -> %{node: node, reachable: false, error: inspect(reason)}
        end
      end,
      timeout: :timer.seconds(10),
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(nodes)
    |> Enum.map(fn
      {{:ok, state}, _node} -> state
      {{:exit, _}, node} -> %{node: node, reachable: false, error: "timeout"}
    end)
  end

  defp safe_rpc(node, mod, fun, args) when node == node() do
    {:ok, apply(mod, fun, args)}
  end

  defp safe_rpc(node, mod, fun, args) do
    {:ok, :erpc.call(node, mod, fun, args, :timer.seconds(8))}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc "Set the repository's default branch. Recorded in the log like any change."
  @spec set_default_branch(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def set_default_branch(repo_id, branch) do
    ref = if String.starts_with?(branch, "refs/"), do: branch, else: "refs/heads/#{branch}"
    Micelio.Ingest.set_head(repo_id, ref)
  end

  @doc "Change how many replicas a repository should have."
  @spec set_replica_count(String.t(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def set_replica_count(repo_id, count) when count > 0 do
    with {:ok, index, etag} <- WAL.fetch(repo_id),
         {:ok, _} <-
           Micelio.ObjectStore.put(WAL.index_key(repo_id), Index.encode(%{index | replicas: count}),
             if_match: etag,
             content_type: "application/vnd.micelio.wal.v1+protobuf"
           ) do
      {:ok, %{repo_id: repo_id, replicas: count}}
    end
  end

  @doc "This node's view of the cluster."
  @spec cluster_status() :: map()
  def cluster_status do
    members = Cluster.members()

    %{
      node: node(),
      node_id: Micelio.Config.node_id(),
      members: members,
      size: length(members),
      resident_repositories: length(Replica.resident()),
      version: Micelio.version(),
      git_version:
        case Git.version() do
          {:ok, version} -> version
          _ -> nil
        end,
      object_store: Micelio.ObjectStore.backend() |> elem(0) |> inspect(),
      uptime_ms: uptime_ms()
    }
  end

  defp uptime_ms do
    {total, _since_last} = :erlang.statistics(:wall_clock)
    total
  end

  @doc """
  Which nodes would hold `repo_id`, without touching object storage.

  Useful for confirming that a scaling event moved what you expected: the
  answer is a pure function of the id and the live membership.
  """
  @spec placement(String.t(), pos_integer() | nil) :: map()
  def placement(repo_id, count \\ nil) do
    nodes = Cluster.replicas_for(repo_id, count)
    %{repo_id: repo_id, primary: List.first(nodes), replicas: nodes, cluster_size: length(Cluster.members())}
  end

  defp summarize(index) do
    %{
      repo_id: index.repo_id,
      epoch: index.epoch,
      seq: index.seq,
      refs: map_size(index.refs),
      default_branch: Index.default_branch(index),
      head: Index.head(index),
      packs: length(Index.required_packs(index)),
      bytes: Index.bytes(index),
      pending_entries: length(index.entries),
      created_at: to_iso(index.created_at_ms),
      updated_at: to_iso(index.updated_at_ms),
      updated_by: index.updated_by,
      desired_replicas: index.replicas
    }
  end

  defp to_iso(0), do: nil
  defp to_iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
