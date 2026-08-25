defmodule Micelio.Replica do
  @moduledoc """
  The per-repository state machine: one process per repository this node holds.

  A replica owns a bare Git repository on local disk and a cached view of the
  write-ahead log — an epoch, a sequence number and the ETag of the index
  object those came from. It is a cache in the strict sense: everything it
  holds is reconstructible from object storage, so it can be evicted, crash, or
  be lost with the node without anyone needing to repair anything.

  ## Serving a read consistently

  Before any read is served, `ensure_fresh/2` re-validates the cached ETag with
  a conditional GET. A `304` is a metadata-only round trip and means the
  replica may serve immediately; a `200` means catch up first. That is the
  entire consistency protocol, and it is why replicas need no coordination with
  each other: they are each individually consistent with the source of truth,
  so they are trivially consistent with one another.

  The check can be skipped within `staleness_budget_ms`, which defaults to
  zero. Raising it above zero is a deliberate trade of strict consistency for
  fewer round trips, and should be a decision rather than an accident.

  ## Why a process per repository

  The GenServer is not here to hold state — object storage does that. It is
  here to serialize catch-up. Ten concurrent fetches of a repository that has
  fallen behind should produce one catch-up, not ten, and a mailbox is the
  simplest correct way to say that. Streaming the actual Git protocol happens
  in the connection process, not here, so a slow clone never blocks the
  repository's other readers.
  """

  use GenServer

  require Logger

  alias Micelio.Cluster
  alias Micelio.Config
  alias Micelio.Git
  alias Micelio.Replica.Sync
  alias Micelio.WAL
  alias Micelio.WAL.Index

  @registry Micelio.ReplicaRegistry
  @supervisor Micelio.ReplicaSupervisor

  @type state :: %{
          repo_id: String.t(),
          path: Path.t(),
          epoch: non_neg_integer(),
          seq: non_neg_integer(),
          etag: String.t() | nil,
          index: Index.t() | nil,
          verified_at: integer() | nil,
          accessed_at: integer()
        }

  @typedoc "What a caller needs in order to serve a request."
  @type view :: %{
          repo_id: String.t(),
          path: Path.t(),
          epoch: non_neg_integer(),
          seq: non_neg_integer(),
          head: String.t()
        }

  # ----------------------------------------------------------------------
  # Public API
  # ----------------------------------------------------------------------

  @doc """
  Return a view of the repository that is consistent with the log.

  This is the function every read path calls first. It starts the replica
  process if needed, materializes the repository from the log if it is not on
  disk, and catches up if it is behind.
  """
  @spec ensure_fresh(String.t(), keyword()) :: {:ok, view()} | {:error, term()}
  def ensure_fresh(repo_id, opts \\ []) do
    Micelio.Telemetry.span(
      "micelio.replica.ensure_fresh",
      %{
        "micelio.repository.id" => repo_id
      },
      fn ->
        call(
          repo_id,
          {:ensure_fresh, opts, Micelio.Telemetry.context()},
          Keyword.get(opts, :timeout, :timer.minutes(10))
        )
      end
    )
  end

  # A replica can go away between being looked up and being called: the reaper
  # evicts idle repositories while requests are in flight, and an eviction is a
  # normal stop rather than a fault. Treating that as an error would turn
  # routine cache management into failed requests, so the call is simply
  # retried against a freshly started replica.
  #
  # Only the "it is not there" exits are retried. A timeout means the replica
  # is alive and busy, and retrying would make that worse.
  defp call(repo_id, message, timeout, attempt \\ 1) do
    with {:ok, pid} <- ensure_started(repo_id) do
      try do
        GenServer.call(pid, message, timeout)
      catch
        :exit, {reason, _details} when reason in [:noproc, :normal, :shutdown] ->
          if attempt < 3 do
            # Registry deregisters on process death through a monitor, which is
            # asynchronous; yield so the next lookup does not find the corpse.
            Process.sleep(5 * attempt)
            call(repo_id, message, timeout, attempt + 1)
          else
            {:error, :replica_unavailable}
          end
      end
    end
  end

  @doc """
  Record that a push was committed to the log by this node.

  Saves a round trip: the node that won the compare-and-swap already knows the
  resulting epoch and sequence number, so it has no reason to ask the object
  store what it just wrote.
  """
  @spec record_local_push(String.t(), non_neg_integer(), non_neg_integer()) :: :ok
  def record_local_push(repo_id, epoch, seq) do
    case whereis(repo_id) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:record_local_push, epoch, seq})
    end
  end

  @doc """
  Note that the log may have advanced, without asserting that it has.

  Hints are advisory. Acting on one means re-validating against object storage,
  never trusting the hint's contents, so a forged, stale, duplicated or lost
  hint cannot make a replica wrong.
  """
  @spec hint(String.t(), non_neg_integer(), non_neg_integer()) :: :ok
  def hint(repo_id, epoch, seq) do
    case whereis(repo_id) do
      nil ->
        # Not resident. Starting it here would let hint traffic pull every
        # repository onto every node, so leave it to the next real request.
        :ok

      pid ->
        GenServer.cast(pid, {:hint, epoch, seq})
    end
  end

  @doc "Whether this node currently holds the repository in memory."
  @spec alive?(String.t()) :: boolean()
  def alive?(repo_id), do: whereis(repo_id) != nil

  @doc "Diagnostic snapshot of a resident replica."
  @spec info(String.t()) :: {:ok, map()} | {:error, :not_resident}
  def info(repo_id) do
    case whereis(repo_id) do
      nil ->
        {:error, :not_resident}

      pid ->
        try do
          GenServer.call(pid, :info)
        catch
          :exit, {reason, _details} when reason in [:noproc, :normal, :shutdown] ->
            {:error, :not_resident}
        end
    end
  end

  @doc "Every repository resident on this node."
  @spec resident() :: [String.t()]
  def resident do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc """
  Drop a repository from local disk.

  Safe by construction: everything being deleted is reconstructible from the
  log, so this is a cache eviction rather than a deletion.
  """
  @spec evict(String.t()) :: :ok
  def evict(repo_id) do
    case whereis(repo_id) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.call(pid, :evict, :timer.seconds(30))
        catch
          # Already gone — because the reaper got there first, or another
          # caller did. The goal is that it is not resident, and it is not.
          :exit, {reason, _details} when reason in [:noproc, :normal, :shutdown] -> :ok
        end
    end
  end

  @doc "Local path of a repository, whether or not it is currently resident."
  @spec path(String.t()) :: Path.t()
  def path(repo_id) do
    # Repository ids may contain slashes; keep them as directories so the tree
    # on disk mirrors the namespace in object storage.
    Path.join(Config.data_dir(), repo_id)
  end

  @spec ensure_started(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(repo_id) do
    if WAL.valid_id?(repo_id) do
      case whereis(repo_id) do
        nil -> start_replica(repo_id)
        pid -> {:ok, pid}
      end
    else
      {:error, {:invalid_repo_id, repo_id}}
    end
  end

  defp start_replica(repo_id) do
    # A DynamicSupervisor child does not inherit `$callers`, so the starter's
    # configuration overrides are captured here and reinstated in `init/1`.
    # In production there are none and this is an empty map.
    child = {__MODULE__, {repo_id, Config.overrides()}}

    case DynamicSupervisor.start_child(@supervisor, child) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  defp whereis(repo_id) do
    case Registry.lookup(@registry, repo_id) do
      # A registration can outlive its process by the width of a monitor
      # message, so liveness is checked rather than assumed.
      [{pid, _}] -> if Process.alive?(pid), do: pid, else: nil
      [] -> nil
    end
  end

  @doc false
  def child_spec({repo_id, overrides}) do
    %{
      id: {__MODULE__, repo_id},
      start: {__MODULE__, :start_link, [{repo_id, overrides}]},
      restart: :transient
    }
  end

  def child_spec(repo_id), do: child_spec({repo_id, %{}})

  @doc false
  def start_link({repo_id, overrides}) do
    GenServer.start_link(__MODULE__, {repo_id, overrides}, name: {:via, Registry, {@registry, repo_id}})
  end

  def start_link(repo_id), do: start_link({repo_id, %{}})

  # ----------------------------------------------------------------------
  # Server
  # ----------------------------------------------------------------------

  @impl true
  def init({repo_id, overrides}) do
    Process.flag(:trap_exit, true)
    if map_size(overrides) > 0, do: Config.put_overrides(overrides)
    now = System.monotonic_time(:millisecond)

    {:ok,
     %{
       repo_id: repo_id,
       path: path(repo_id),
       # Epoch 0 is "we know nothing", which forces the first sync to adopt a
       # base rather than assume the on-disk state is meaningful.
       epoch: 0,
       seq: 0,
       etag: nil,
       index: nil,
       # nil rather than 0: monotonic time can be negative, so a zero here
       # would report an absurd age before the first read.
       verified_at: nil,
       accessed_at: now
     }}
  end

  @impl true
  def handle_call({:ensure_fresh, opts, context}, _from, state) do
    budget = Keyword.get(opts, :staleness_budget_ms, Config.staleness_budget_ms())
    now = System.monotonic_time(:millisecond)
    state = %{state | accessed_at: now}

    {reply, state} =
      Micelio.Telemetry.with_context(context, fn ->
        Micelio.Telemetry.span(
          "micelio.replica.refresh",
          %{
            "micelio.repository.id" => state.repo_id
          },
          fn -> ensure_state_fresh(state, budget, now) end
        )
      end)

    {:reply, reply, state}
  end

  def handle_call(:info, _from, state) do
    stats = if File.dir?(state.path), do: Git.stats(state.path), else: %{objects: 0, size_kb: 0, packs: 0}

    info = %{
      repo_id: state.repo_id,
      node: node(),
      path: state.path,
      epoch: state.epoch,
      seq: state.seq,
      log_seq: state.index && state.index.seq,
      behind: if(state.index, do: max(state.index.seq - state.seq, 0), else: nil),
      materialized: File.dir?(Path.join(state.path, "objects")),
      last_verified_ms_ago: age(state.verified_at),
      last_accessed_ms_ago: age(state.accessed_at),
      objects: stats.objects,
      size_kb: stats.size_kb,
      packs: stats.packs
    }

    {:reply, {:ok, info}, state}
  end

  def handle_call(:evict, _from, state) do
    File.rm_rf(state.path)
    :telemetry.execute([:micelio, :replica, :evict], %{}, %{repo_id: state.repo_id})
    Logger.info("evicted replica from local disk", repo_id: state.repo_id)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_cast({:record_local_push, epoch, seq}, state) do
    # The stored object changed, so the cached ETag is stale by definition.
    # Clearing it keeps the next read honest: it re-reads the index, which is
    # cheap, rather than trusting an ETag we never observed. The cached index
    # is advanced rather than dropped, because this node performed the write
    # and therefore does know the sequence number it produced.
    index = state.index && %{state.index | epoch: epoch, seq: seq}
    {:noreply, %{state | epoch: epoch, seq: seq, index: index, etag: nil, verified_at: nil}}
  end

  def handle_cast({:hint, epoch, seq}, state) do
    if epoch > state.epoch or seq > state.seq do
      case refresh(state) do
        {:ok, state} -> {:noreply, state}
        {:error, _reason} -> {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  # ----------------------------------------------------------------------
  # Internals
  # ----------------------------------------------------------------------

  defp ensure_state_fresh(state, budget, now) do
    if state.index && budget > 0 && state.verified_at && now - state.verified_at < budget do
      :telemetry.execute([:micelio, :replica, :serve], %{}, %{repo_id: state.repo_id, path: :budget})
      {{:ok, view(state)}, state}
    else
      case refresh(state) do
        {:ok, state} ->
          {{:ok, view(state)}, state}

        {:error, reason} = error ->
          Logger.warning("replica could not refresh", repo_id: state.repo_id, reason: reason)
          {error, state}
      end
    end
  end

  defp refresh(state) do
    case WAL.read(state.repo_id, state.etag) do
      {:ok, :not_modified} ->
        {:ok, %{state | verified_at: System.monotonic_time(:millisecond)}}

      {:ok, index, etag} ->
        sync(state, index, etag)

      {:error, :not_found} ->
        {:error, :no_such_repository}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sync(state, index, etag) do
    case Sync.run(state.repo_id, state.path, index, state.epoch, state.seq) do
      {:ok, %{epoch: epoch, seq: seq}} ->
        {:ok,
         %{
           state
           | epoch: epoch,
             seq: seq,
             etag: etag,
             index: index,
             verified_at: System.monotonic_time(:millisecond)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp age(nil), do: nil
  defp age(at), do: System.monotonic_time(:millisecond) - at

  defp view(state) do
    %{
      repo_id: state.repo_id,
      path: state.path,
      epoch: state.epoch,
      seq: state.seq,
      head: if(state.index, do: Index.head(state.index), else: "refs/heads/main")
    }
  end

  @doc false
  def registry, do: @registry

  @doc false
  def supervisor, do: @supervisor

  @doc """
  Run `fun` on whichever node should hold `repo_id`.

  Any node can answer any request, but answering locally means materializing
  the repository here, which costs disk and a download. Routing to the node
  rendezvous hashing already points at means a cluster of `n` nodes holds each
  repository in one place rather than `n`, without a router, a session
  affinity rule, or a lookup service to keep correct.
  """
  @spec via_owner(String.t(), (-> result), keyword()) :: {:ok, result}
        when result: term()
  def via_owner(repo_id, fun, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :timer.seconds(30))

    case Cluster.replicas_for(repo_id) do
      [] ->
        {:ok, fun.()}

      nodes ->
        if node() in nodes do
          {:ok, fun.()}
        else
          call_first_reachable(nodes, fun, timeout)
        end
    end
  end

  defp call_first_reachable([], fun, _timeout) do
    # Nobody reachable. Serving locally is always allowed: correctness comes
    # from the log, not from placement, so a degraded cluster gets slower
    # rather than wrong.
    {:ok, fun.()}
  end

  defp call_first_reachable([target | rest], fun, timeout) do
    {:ok, :erpc.call(target, fun, timeout)}
  rescue
    _ -> call_first_reachable(rest, fun, timeout)
  catch
    :exit, _ -> call_first_reachable(rest, fun, timeout)
  end
end
