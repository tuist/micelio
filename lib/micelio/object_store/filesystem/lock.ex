defmodule Micelio.ObjectStore.Filesystem.Lock do
  @moduledoc """
  Serializes compare-and-swap writes for the filesystem object store.

  S3 gives us conditional writes for free; a plain filesystem does not, so this
  process stands in for that guarantee on a single node.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Run `fun` with no other filesystem-store write in flight."
  @spec transaction((-> result)) :: result when result: term()
  def transaction(fun) do
    case Process.whereis(__MODULE__) do
      nil -> fun.()
      _pid -> GenServer.call(__MODULE__, {:run, fun}, :timer.seconds(30))
    end
  end

  @impl true
  def init(:ok), do: {:ok, :ok}

  @impl true
  def handle_call({:run, fun}, _from, state), do: {:reply, fun.(), state}
end
