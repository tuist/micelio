defmodule Micelio.Replica.Compactor do
  @moduledoc """
  Turns a long write-ahead log into a short one.

  A log that only ever grows makes materialization slower and slower: a replica
  coming up fresh would have to replay every push a repository has ever
  received. Compaction collapses that history into a base — one repack, a full
  ref snapshot — and the epoch bump tells every other replica to adopt the
  result rather than replay.

  ## Why only one node does this

  Repacking is the single genuinely expensive operation in the system, it is
  CPU-bound, and it produces a deterministic artefact. Running it on every
  replica would multiply the cost by the replica count for no benefit
  whatsoever, so the preferred primary runs it and everyone else downloads the
  packs. Replicas trade bandwidth for CPU, which is the right trade when
  bandwidth is a shared, elastic resource and CPU is the thing you are trying
  to scale reads with.

  "Primary" here is just the head of the rendezvous order. Nothing breaks if
  two nodes both think they are it: compaction lands through the same
  compare-and-swap as everything else, so the loser is told `:raced` and does
  nothing. That is why this needs no lock and no leader election.

  ## Why it is threshold-driven

  Compaction is triggered by log length and log size, never by a timer. A
  repository nobody pushes to should never pay for maintenance, and a
  repository under heavy write load should be compacted because of that load
  rather than because a clock ticked.
  """

  use GenServer

  require Logger

  alias Micelio.Cluster
  alias Micelio.Config
  alias Micelio.Git
  alias Micelio.Replica
  alias Micelio.WAL
  alias Micelio.WAL.Index

  @default_interval :timer.minutes(5)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Compact a repository now, regardless of thresholds.

  Exposed for the admin API and for tests. Returns `{:error, :not_primary}`
  when another node owns the work, and `{:error, :raced}` when a concurrent
  push or compaction won the compare-and-swap first; both are ordinary
  outcomes, not failures.
  """
  @spec compact(String.t()) :: {:ok, map()} | {:error, term()}
  def compact(repo_id) do
    if Cluster.primary?(repo_id) do
      run(repo_id, :force)
    else
      {:error, :not_primary}
    end
  end

  @doc "Compact `repo_id` if its log has grown past the configured thresholds."
  @spec maybe_compact(String.t()) :: {:ok, map()} | {:error, term()} | :not_due
  def maybe_compact(repo_id) do
    with true <- Cluster.primary?(repo_id) or {:error, :not_primary}, do: run(repo_id, :if_due)
  end

  @doc false
  @spec run(String.t(), :force | :if_due) :: {:ok, map()} | {:error, term()} | :not_due
  def run(repo_id, mode) do
    with {:ok, index, etag} <- WAL.fetch(repo_id),
         :ok <- due?(mode, index) do
      compact_snapshot(repo_id, index, etag)
    else
      false -> :not_due
      other -> other
    end
  end

  defp due?(:force, _index), do: :ok
  defp due?(:if_due, index), do: if(due?(index), do: :ok, else: false)

  defp due?(index) do
    Index.compaction_due?(index,
      entries: Config.compaction_entry_threshold(),
      bytes: Config.compaction_bytes_threshold()
    )
  end

  # The index and ETag are a maintenance snapshot. A push after this point is
  # not "merged" into the repack: the conditional write rejects the stale
  # snapshot, and the scheduler later plans a fresh job. That keeps a
  # partition or a duplicated job to wasted compute rather than lost history.
  defp compact_snapshot(repo_id, index, etag) do
    started = System.monotonic_time(:millisecond)

    # Compact from a repository that is already caught up, otherwise the repack
    # would produce a base missing the most recent pushes.
    with {:ok, view} <- Replica.ensure_fresh(repo_id),
         :ok <- ensure_caught_up(view, index),
         {:ok, packs} <- Git.repack(view.path),
         {:ok, refs} <- Git.refs(view.path),
         {:ok, descriptors} <- upload_packs(repo_id, packs),
         {:ok, compacted} <- WAL.compact(repo_id, descriptors, refs, index.base.symrefs, index, etag) do
      Replica.record_local_push(repo_id, compacted.epoch, compacted.seq)
      Cluster.announce(repo_id, compacted.epoch, compacted.seq)

      duration = System.monotonic_time(:millisecond) - started

      Logger.info(
        "compacted #{repo_id}: #{length(index.entries)} entries -> epoch #{compacted.epoch} " <>
          "(#{length(descriptors)} pack(s), #{duration}ms)"
      )

      {:ok, %{epoch: compacted.epoch, seq: compacted.seq, packs: length(descriptors), duration_ms: duration}}
    end
  end

  # A repack of a stale working copy would silently drop pushes that landed
  # while we were behind, so refuse rather than publish an incomplete base.
  defp ensure_caught_up(view, index) do
    if view.epoch == index.epoch and view.seq == index.seq, do: :ok, else: {:error, :stale_replica}
  end

  defp upload_packs(repo_id, packs) do
    packs
    |> Enum.reduce_while({:ok, []}, fn pack, {:ok, acc} ->
      case WAL.put_pack(repo_id, pack) do
        {:ok, descriptor} -> {:cont, {:ok, [descriptor | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # ----------------------------------------------------------------------
  # Periodic sweep
  # ----------------------------------------------------------------------

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:sweep, state) do
    # Only repositories resident here are considered: a repository nobody has
    # touched on this node is not this node's problem, and whichever node is
    # actually serving it will trip the same thresholds.
    for repo_id <- Replica.resident(), Cluster.primary?(repo_id) do
      Task.Supervisor.start_child(Micelio.TaskSupervisor, fn ->
        case maybe_compact(repo_id) do
          {:ok, _result} -> :ok
          :not_due -> :ok
          {:error, reason} -> Logger.debug("compaction skipped for #{repo_id}: #{inspect(reason)}")
        end
      end)
    end

    schedule(state.interval)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(interval) do
    # Jitter so a cluster that started together does not sweep in lockstep.
    Process.send_after(self(), :sweep, interval + :rand.uniform(div(interval, 4)))
  end
end
