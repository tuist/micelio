defmodule Micelio.Replica.Reaper do
  @moduledoc """
  Evicts idle repositories from local disk.

  This is only safe to do because a replica is a cache. A repository that has
  seen no traffic for a while costs disk and adds to the set of things a node
  has to keep current; dropping it costs nothing but the materialization the
  next request will pay for.

  It is also what makes "millions of tiny repositories" affordable. Agents
  create repositories constantly and most are never read again. Without
  eviction, every node would accumulate them forever; with it, disk tracks the
  working set rather than the total.

  Repositories this node should no longer hold at all — because the cluster
  grew or shrank and rendezvous hashing moved them elsewhere — are evicted on
  the same pass, without any rebalancing job to run.
  """

  use GenServer

  require Logger

  alias Micelio.Cluster
  alias Micelio.Config
  alias Micelio.Replica

  @default_interval :timer.minutes(5)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Run a sweep immediately. Returns the repositories evicted."
  @spec sweep() :: [String.t()]
  def sweep, do: GenServer.call(__MODULE__, :sweep, :timer.minutes(2))

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_call(:sweep, _from, state), do: {:reply, do_sweep(), state}

  @impl true
  def handle_info(:sweep, state) do
    do_sweep()
    schedule(state.interval)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp do_sweep do
    idle_after = Config.idle_eviction_ms()

    for repo_id <- Replica.resident(), evictable?(repo_id, idle_after) do
      Logger.info("reaping #{repo_id}")
      Replica.evict(repo_id)
      repo_id
    end
  end

  defp evictable?(repo_id, idle_after) do
    case Replica.info(repo_id) do
      {:ok, info} ->
        idle? = is_integer(info.last_verified_ms_ago) and info.last_verified_ms_ago > idle_after
        # A repository that moved away under rehashing is evicted regardless of
        # how recently it was touched: it now belongs somewhere else.
        misplaced? = not Cluster.responsible?(repo_id)

        idle? or misplaced?

      {:error, _} ->
        false
    end
  end

  defp schedule(interval) do
    Process.send_after(self(), :sweep, interval + :rand.uniform(div(interval, 4)))
  end
end
