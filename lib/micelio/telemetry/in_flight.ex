defmodule Micelio.Telemetry.InFlight do
  @moduledoc """
  Counts requests currently being served.

  This is the number that matters for scaling a Git server. A clone occupies a
  connection, a process and a `git upload-pack` for its whole duration, which
  can be minutes; CPU stays unremarkable while the node runs out of capacity to
  accept anything else. Scaling on CPU alone therefore reacts far too late.

  Implemented with `:counters` rather than a process, so incrementing it on
  every request costs an atomic add and can never become a bottleneck or a
  single point of failure.
  """

  @key {__MODULE__, :counter}

  @doc "Attach to Bandit's request lifecycle. Safe to call more than once."
  @spec attach() :: :ok
  def attach do
    :persistent_term.put(@key, :counters.new(1, [:write_concurrency]))

    :telemetry.detach("micelio-in-flight")

    :telemetry.attach_many(
      "micelio-in-flight",
      [
        [:bandit, :request, :start],
        [:bandit, :request, :stop],
        [:bandit, :request, :exception]
      ],
      &__MODULE__.handle_event/4,
      nil
    )

    :ok
  end

  @doc false
  def handle_event([:bandit, :request, :start], _measurements, _meta, _config), do: add(1)
  def handle_event([:bandit, :request, :stop], _measurements, _meta, _config), do: add(-1)
  def handle_event([:bandit, :request, :exception], _measurements, _meta, _config), do: add(-1)
  def handle_event(_event, _measurements, _meta, _config), do: :ok

  @doc "Requests currently in flight on this node."
  @spec count() :: non_neg_integer()
  def count do
    case :persistent_term.get(@key, nil) do
      nil -> 0
      counter -> max(:counters.get(counter, 1), 0)
    end
  end

  defp add(delta) do
    case :persistent_term.get(@key, nil) do
      nil -> :ok
      counter -> :counters.add(counter, 1, delta)
    end
  end
end
