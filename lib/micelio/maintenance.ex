defmodule Micelio.Maintenance do
  @moduledoc """
  Capability-aware, bounded maintenance work.

  This process deliberately does not elect a leader or persist a queue. A
  maintenance job is derived from a write-ahead-log snapshot, and its
  publication is conditional on that exact snapshot still being current.
  Therefore process-group membership is only a placement hint: a split view
  can duplicate compute, but cannot make a stale result visible.

  The scheduler is local to one node. It uses a Registry and DynamicSupervisor
  to keep one expensive job per {repository, kind} on that node, while
  rendezvous hashing spreads repositories across nodes with the relevant
  capability.
  """

  use GenServer

  alias Micelio.Cluster.Rendezvous
  alias Micelio.Config
  alias Micelio.Replica

  @scope Micelio.PG
  @maintainers :maintainers
  @event_consumers :event_consumers
  @registry Micelio.MaintenanceRegistry
  @supervisor Micelio.MaintenanceSupervisor

  @type kind :: :compact | :lookup | :bundle | :events
  @type mode :: :force | :if_due

  @known_kinds [:compact, :lookup, :bundle, :events]
  @maintenance_kinds [:compact, :lookup, :bundle]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Nodes currently advertising the capability required by kind."
  @spec members(kind()) :: [node()]
  def members(kind) when kind in @known_kinds do
    members =
      kind
      |> member_group()
      |> group_pids()
      |> Enum.map(&node/1)
      |> Enum.uniq()
      |> Enum.sort()

    if members == [] and capable?(kind), do: [node()], else: members
  end

  @doc """
  Preferred node for a repository and job kind.

  The job kind is part of the hash input so a node can spread compaction and
  cache lookup work independently. The member list is the only changing input:
  adding a capable node moves only the jobs that select it.
  """
  @spec owner_for(String.t(), kind()) :: node() | nil
  def owner_for(repo_id, kind) when kind in @known_kinds do
    Rendezvous.primary(members(kind), "#{kind}:#{repo_id}")
  end

  @doc """
  Run maintenance and wait for its result.

  Work is forwarded to the currently preferred capable node. If membership is
  stale or that node disappears, a local capable scheduler may perform the
  same snapshot job instead. The object store conditional write remains the
  authority, so this fallback trades duplicate work for availability rather
  than changing correctness.
  """
  @spec run(String.t(), kind(), keyword()) :: {:ok, map()} | {:error, term()} | :not_due
  def run(repo_id, kind, opts \\ [])

  def run(repo_id, kind, opts) when kind in @known_kinds do
    timeout = Keyword.get(opts, :timeout, :timer.hours(3))

    case owner_for(repo_id, kind) do
      nil ->
        if capable?(kind), do: local_run(repo_id, kind, opts), else: {:error, :no_maintenance_members}

      target when target == node() ->
        local_run(repo_id, kind, opts)

      target when is_atom(target) ->
        remote_run(target, repo_id, kind, opts, timeout)
    end
  end

  def run(_repo_id, kind, _opts), do: {:error, {:unknown_maintenance_kind, kind}}

  @doc false
  @spec local_run(String.t(), kind(), keyword()) :: {:ok, map()} | {:error, term()} | :not_due
  def local_run(repo_id, kind, opts \\ [])

  def local_run(repo_id, kind, opts) when kind in @known_kinds do
    timeout = Keyword.get(opts, :timeout, :timer.hours(3))
    scheduler = Keyword.get(opts, :scheduler, __MODULE__)

    if GenServer.whereis(scheduler) && capable?(kind) do
      GenServer.call(scheduler, {:run, repo_id, kind, Keyword.get(opts, :mode, :force)}, timeout)
    else
      {:error, :maintenance_unavailable}
    end
  catch
    :exit, {:noproc, _details} -> {:error, :maintenance_unavailable}
    :exit, reason -> {:error, {:maintenance_call_failed, reason}}
  end

  def local_run(_repo_id, kind, _opts), do: {:error, {:unknown_maintenance_kind, kind}}

  @doc """
  Broadcast a write-ahead-log advance to maintenance nodes.

  Like replica announcements, these are advisory. The receiver fetches the
  index itself before doing anything, so a dropped, duplicated or stale hint
  can affect only how soon work starts.
  """
  @spec announce(String.t(), non_neg_integer(), non_neg_integer()) :: :ok
  def announce(repo_id, epoch, seq) do
    message = {:wal_advanced, repo_id, epoch, seq, node()}

    for pid <- group_pids(@maintainers), node(pid) != node() do
      send(pid, message)
    end

    hint(repo_id, epoch, seq)
    :ok
  end

  @doc "Schedule threshold-driven compaction locally when this node owns it."
  @spec hint(String.t(), non_neg_integer(), non_neg_integer()) :: :ok
  def hint(repo_id, epoch, seq) do
    if pid = Process.whereis(__MODULE__) do
      GenServer.cast(pid, {:wal_advanced, repo_id, epoch, seq, node()})
    end

    :ok
  end

  @doc "A local diagnostic snapshot. It contains no durable job state."
  @spec status() :: map()
  def status do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :status)
    else
      %{running: [], pending: [], members: %{maintain: members(:compact), events: members(:events)}}
    end
  end

  @impl true
  def init(opts) do
    overrides = Keyword.get(opts, :overrides, Config.overrides())
    if map_size(overrides) > 0, do: Config.put_overrides(overrides)

    if Config.maintain?(), do: join_group(@maintainers)
    if Config.events?(), do: join_group(@event_consumers)

    interval = Keyword.get(opts, :interval, Config.maintenance_sweep_ms())
    schedule(interval)

    {:ok,
     %{
       interval: interval,
       overrides: overrides,
       jobs: %{},
       pending: [],
       running: %{}
     }}
  end

  @impl true
  def handle_call({:run, repo_id, kind, mode}, from, state) do
    if valid_mode?(mode) and capable?(kind) do
      {:noreply, enqueue(state, repo_id, kind, mode, from)}
    else
      {:reply, {:error, :maintenance_unavailable}, state}
    end
  end

  def handle_call(:status, _from, state) do
    running =
      Enum.map(state.running, fn {_ref, %{key: {repo_id, kind}, pid: pid}} ->
        %{repository: repo_id, kind: kind, pid: pid}
      end)

    {:reply,
     %{
       running: running,
       pending: state.pending,
       members: %{maintain: members(:compact), events: members(:events)}
     }, state}
  end

  @impl true
  def handle_cast({:wal_advanced, repo_id, _epoch, _seq, _from}, state) do
    state =
      if Config.maintain?() and owner_for(repo_id, :compact) == node() do
        enqueue(state, repo_id, :compact, :if_due)
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:wal_advanced, repo_id, _epoch, _seq, _from}, state) do
    handle_cast({:wal_advanced, repo_id, 0, 0, node()}, state)
  end

  def handle_info(:sweep, state) do
    state =
      if Config.maintain?() do
        Enum.reduce(Replica.resident(), state, fn repo_id, acc ->
          if owner_for(repo_id, :compact) == node() do
            enqueue(acc, repo_id, :compact, :if_due)
          else
            acc
          end
        end)
      else
        state
      end

    schedule(state.interval)
    {:noreply, state}
  end

  def handle_info({:maintenance_job_finished, pid, key, result}, state) do
    case running_ref(state.running, pid, key) do
      nil ->
        {:noreply, state}

      ref ->
        Process.demonitor(ref, [:flush])
        state = state |> remove_running(ref) |> finish(key, result) |> start_runnable()
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.fetch(state.running, ref) do
      :error ->
        {:noreply, state}

      {:ok, %{key: key}} ->
        state =
          state
          |> remove_running(ref)
          |> finish(key, {:error, {:maintenance_job_crashed, reason}})
          |> start_runnable()

        {:noreply, state}
    end
  end

  def handle_info(:start_pending, state), do: {:noreply, start_runnable(state)}
  def handle_info(_message, state), do: {:noreply, state}

  defp remote_run(target, repo_id, kind, opts, timeout) do
    :erpc.call(target, __MODULE__, :local_run, [repo_id, kind, opts], timeout + 5_000)
  rescue
    error -> fallback_local(repo_id, kind, opts, error)
  catch
    :exit, reason -> fallback_local(repo_id, kind, opts, {:exit, reason})
  end

  defp fallback_local(repo_id, kind, opts, reason) do
    case local_run(repo_id, kind, opts) do
      {:error, :maintenance_unavailable} -> {:error, {:maintenance_owner_unreachable, reason}}
      result -> result
    end
  end

  defp enqueue(state, repo_id, kind, mode, waiter \\ nil) do
    key = {repo_id, kind}

    state =
      case Map.get(state.jobs, key) do
        nil ->
          job = %{mode: mode, waiters: if(waiter, do: [waiter], else: [])}
          %{state | jobs: Map.put(state.jobs, key, job), pending: state.pending ++ [key]}

        job ->
          job = %{
            job
            | mode: strongest_mode(job.mode, mode),
              waiters: if(waiter, do: [waiter | job.waiters], else: job.waiters)
          }

          %{state | jobs: Map.put(state.jobs, key, job)}
      end

    start_runnable(state)
  end

  defp start_runnable(state) do
    case take_runnable(state.pending, state) do
      nil ->
        state

      {key, pending} ->
        job = Map.fetch!(state.jobs, key)

        case start_job(key, job, state.overrides) do
          {:ok, pid} ->
            ref = Process.monitor(pid)
            send(pid, :run)

            state
            |> Map.put(:pending, pending)
            |> Map.put(:running, Map.put(state.running, ref, %{key: key, pid: pid}))
            |> start_runnable()

          {:error, {:already_started, _pid}} ->
            # The completed job tells us its result just before it terminates.
            # Registry cleanup follows the process exit, so a new job for the
            # same key can briefly see the old registration. Keep it pending
            # and retry after that local lifecycle edge has passed.
            Process.send_after(self(), :start_pending, 10)
            %{state | pending: [key | pending]}

          {:error, reason} ->
            state
            |> Map.put(:pending, pending)
            |> finish(key, {:error, {:maintenance_job_start_failed, reason}})
            |> start_runnable()
        end
    end
  end

  defp start_job(key, job, overrides) do
    DynamicSupervisor.start_child(
      @supervisor,
      {Micelio.Maintenance.Job, {self(), key, job.mode, overrides}}
    )
  end

  defp take_runnable([], _state), do: nil

  defp take_runnable([key | rest], state) do
    case Map.get(state.jobs, key) do
      %{mode: _mode} ->
        if can_start?(key, state) do
          {key, rest}
        else
          take_later(key, rest, state)
        end

      _ ->
        take_later(key, rest, state)
    end
  end

  defp take_later(key, rest, state) do
    case take_runnable(rest, state) do
      nil -> nil
      {next, pending} -> {next, [key | pending]}
    end
  end

  defp can_start?({_repo_id, kind}, state) do
    capable?(kind) and running_count(state, kind) < Config.maintenance_concurrency(kind)
  end

  defp running_count(state, kind) do
    Enum.count(state.running, fn {_ref, %{key: {_repo_id, running_kind}}} -> running_kind == kind end)
  end

  defp running_ref(running, pid, key) do
    Enum.find_value(running, fn
      {ref, %{pid: ^pid, key: ^key}} -> ref
      _ -> nil
    end)
  end

  defp remove_running(state, ref), do: %{state | running: Map.delete(state.running, ref)}

  defp finish(state, key, result) do
    case Map.pop(state.jobs, key) do
      {nil, jobs} ->
        %{state | jobs: jobs}

      {%{waiters: waiters}, jobs} ->
        Enum.each(waiters, &GenServer.reply(&1, result))
        %{state | jobs: jobs}
    end
  end

  defp strongest_mode(:force, _mode), do: :force
  defp strongest_mode(_mode, :force), do: :force
  defp strongest_mode(_mode, _other), do: :if_due

  defp valid_mode?(mode), do: mode in [:force, :if_due]
  defp capable?(kind) when kind in @maintenance_kinds, do: Config.maintain?()
  defp capable?(:events), do: Config.events?()

  defp member_group(kind) when kind in @maintenance_kinds, do: @maintainers
  defp member_group(:events), do: @event_consumers

  defp group_pids(group) do
    :pg.get_members(@scope, group)
  rescue
    ArgumentError -> []
  catch
    :exit, _reason -> []
  end

  defp join_group(group) do
    :pg.join(@scope, group, self())
  rescue
    ArgumentError -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp schedule(interval) do
    # Jitter avoids every node scanning its cache at the same time after a
    # rolling restart. Threshold checks, not the clock, still decide whether
    # any expensive work runs.
    Process.send_after(self(), :sweep, interval + :rand.uniform(max(div(interval, 4), 1)))
  end

  @doc false
  def registry, do: @registry

  @doc false
  def supervisor, do: @supervisor
end

defmodule Micelio.Maintenance.Job do
  @moduledoc false

  use GenServer

  alias Micelio.Config
  alias Micelio.Maintenance.Lookup
  alias Micelio.Replica.Compactor

  @registry Micelio.MaintenanceRegistry

  @spec child_spec({pid(), {String.t(), Micelio.Maintenance.kind()}, Micelio.Maintenance.mode(), map()}) ::
          Supervisor.child_spec()
  def child_spec({scheduler, {repo_id, kind}, mode, overrides}) do
    %{
      id: {__MODULE__, repo_id, kind},
      start: {__MODULE__, :start_link, [{scheduler, {repo_id, kind}, mode, overrides}]},
      restart: :transient
    }
  end

  @spec start_link({pid(), {String.t(), Micelio.Maintenance.kind()}, Micelio.Maintenance.mode(), map()}) ::
          GenServer.on_start()
  def start_link({scheduler, {repo_id, kind}, mode, overrides}) do
    GenServer.start_link(__MODULE__, {scheduler, {repo_id, kind}, mode, overrides},
      name: {:via, Registry, {@registry, {repo_id, kind}}}
    )
  end

  @impl true
  def init({scheduler, key, mode, overrides}) do
    if map_size(overrides) > 0, do: Config.put_overrides(overrides)
    Process.monitor(scheduler)
    {:ok, %{scheduler: scheduler, key: key, mode: mode}}
  end

  @impl true
  def handle_info(:run, %{scheduler: scheduler, key: key, mode: mode} = state) do
    {repo_id, kind} = key
    result = execute(repo_id, kind, mode)
    send(scheduler, {:maintenance_job_finished, self(), key, result})
    {:stop, :normal, state}
  end

  # The scheduler is the component that knows who is awaiting the result. If
  # it restarts, abandon this cache-only attempt; it can plan the same
  # idempotent snapshot job again.
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:stop, :normal, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp execute(repo_id, :compact, mode), do: Compactor.run(repo_id, mode)
  defp execute(repo_id, :lookup, mode), do: Lookup.run(repo_id, mode)

  # Creating externally consumable bundles requires a public ref-selection and
  # discovery contract. Sending events requires subscriber, acknowledgement,
  # retry and durable cursor contracts. Keep both slots explicit so neither is
  # mistaken for a local cache optimization.
  defp execute(_repo_id, :bundle, _mode), do: {:error, :bundle_creation_not_configured}
  defp execute(_repo_id, :events, _mode), do: {:error, :event_delivery_not_configured}
end

defmodule Micelio.Maintenance.Lookup do
  @moduledoc """
  Cache-only Git lookup maintenance.

  The multi-pack index is derived exclusively from the materialized repository.
  It is never uploaded or referenced by the write-ahead log, so losing it is
  equivalent to losing any other local cache file.
  """

  alias Micelio.Git
  alias Micelio.Replica
  alias Micelio.WAL

  @spec run(String.t(), Micelio.Maintenance.mode()) :: {:ok, map()} | {:error, term()} | :not_due
  def run(repo_id, mode) do
    with {:ok, index, etag} <- WAL.fetch(repo_id),
         {:ok, view} <- Replica.ensure_fresh(repo_id),
         :ok <- ensure_snapshot(view, index),
         :ok <- due?(view.path, mode),
         :ok <- Git.rebuild_multi_pack_index(view.path),
         :ok <- still_current?(repo_id, etag) do
      packs = length(Git.packs(view.path))

      :telemetry.execute(
        [:micelio, :maintenance, :lookup],
        %{packs: packs},
        %{repo_id: repo_id, epoch: index.epoch, seq: index.seq}
      )

      {:ok, %{epoch: index.epoch, seq: index.seq, packs: packs}}
    else
      false -> :not_due
      other -> other
    end
  end

  defp ensure_snapshot(view, index) do
    if view.epoch == index.epoch and view.seq == index.seq, do: :ok, else: {:error, :snapshot_stale}
  end

  # A multi-pack index only pays for itself when there are several packs. Git
  # already has the individual .idx file for every single pack, downloaded and
  # verified beside that pack.
  # Git cannot create a multi-pack index without a pack. A force request
  # bypasses the multiple-pack threshold, but an empty repository is still a
  # no-op rather than a failed maintenance job.
  defp due?(path, :force), do: if(Git.packs(path) == [], do: false, else: :ok)

  defp due?(path, :if_due) do
    if length(Git.packs(path)) > 1, do: :ok, else: false
  end

  defp still_current?(repo_id, etag) do
    case WAL.read(repo_id, etag) do
      {:ok, :not_modified} -> :ok
      {:ok, _index, _new_etag} -> {:error, :snapshot_stale}
      {:error, reason} -> {:error, reason}
    end
  end
end
