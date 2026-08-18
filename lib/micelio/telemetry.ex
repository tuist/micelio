defmodule Micelio.Telemetry do
  @moduledoc """
  Instrumentation.

  A replica's whole job is to be consistent with something it cannot see, so
  the questions an operator actually asks are unusual ones: how often does a
  read find the log unchanged, how far behind is this node, how much of a push
  is contention rather than work. Those are the things measured here.

  The most important single metric is the outcome of the conditional read on
  the WAL index. A healthy cluster is almost all `not_modified`: replicas
  confirm they are current with a metadata round trip and serve immediately. A
  rising `modified` rate means replicas are doing real catch-up work on the
  read path, which is the first thing to look at when latency climbs.

  ## Events

    * `[:micelio, :wal, :read]` — `duration_us`, meta `outcome`, `repo_id`
    * `[:micelio, :wal, :append]` — `seq`, `attempts`, meta `repo_id`
    * `[:micelio, :wal, :cas_retry]` — a push lost a compare-and-swap
    * `[:micelio, :wal, :compact]` — `epoch`, `packs`
    * `[:micelio, :replica, :sync]` — `duration_ms`, `packs_downloaded`,
      `entries_behind`
    * `[:micelio, :replica, :evict]`
    * `[:micelio, :push, :committed]` — `duration_ms`, `refs`, `packs`
    * `[:micelio, :push, :rejected]` — meta `reason`
    * `[:micelio, :git, :command]` — `duration_us`, meta `subcommand`, `status`
    * `[:micelio, :git, :served]` — `duration_ms`, `bytes`, meta `service`
    * `[:micelio, :git, :aborted]` — client vanished or stream failed
    * `[:micelio, :mcp, :request]` — `duration_us`, meta `method`, `outcome`
    * `[:micelio, :auth, :authorized]` / `[:micelio, :auth, :denied]`
    * `[:micelio, :cluster, :nodeup]` / `[:micelio, :cluster, :nodedown]`
    * `[:micelio, :repository, :created]`
  """

  require Logger
  require OpenTelemetry.Tracer

  @doc """
  Attach the log handlers.

  Deliberately sparse: a Git server under load produces enormous numbers of
  events, and logging each one turns observability into the bottleneck.
  Metrics carry the volume; logs carry the exceptions.
  """
  @spec attach() :: :ok
  def attach do
    events = [
      [:micelio, :push, :rejected],
      [:micelio, :git, :aborted],
      [:micelio, :wal, :compact]
    ]

    :telemetry.attach_many("micelio-logging", events, &__MODULE__.handle_event/4, nil)
    Micelio.Telemetry.InFlight.attach()
    :ok
  end

  @doc false
  def handle_event([:micelio, :push, :rejected], _measurements, meta, _config) do
    Logger.info("push rejected for #{meta.repo_id}: #{meta.reason}")
  end

  def handle_event([:micelio, :git, :aborted], measurements, meta, _config) do
    Logger.debug(
      "git #{meta[:service]} aborted for #{meta[:repo_id]} after #{measurements.duration_ms}ms: #{inspect(meta[:reason])}"
    )
  end

  def handle_event([:micelio, :wal, :compact], measurements, meta, _config) do
    Logger.info("#{meta.repo_id} compacted to epoch #{measurements.epoch} (#{measurements.packs} pack(s))")
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  @doc """
  Add attributes to the current OpenTelemetry span, if tracing is running.

  Silently does nothing when the OTel application is not started, so tests and
  a bare `iex -S mix` need no tracing configuration.
  """
  @spec put_span_attributes(conn, map()) :: conn when conn: term()
  def put_span_attributes(conn, attributes) do
    if tracing?() do
      OpenTelemetry.Tracer.set_attributes(attributes)
    end

    conn
  end

  @doc """
  Run `fun` inside a span named `name`.

  Used on the paths where the interesting latency is: catching a replica up,
  and committing a push.
  """
  @spec span(String.t(), map(), (-> result)) :: result when result: term()
  def span(name, attributes, fun) do
    if tracing?() do
      OpenTelemetry.Tracer.with_span name, %{attributes: attributes} do
        fun.()
      end
    else
      fun.()
    end
  end

  defp tracing?, do: Application.get_env(:micelio, :tracing_enabled, false)

  @doc """
  Configure OpenTelemetry instrumentation.

  Bandit's instrumentation is attached here rather than in configuration so
  that a node with no OTel exporter configured simply does not trace, instead
  of failing to boot.
  """
  @spec setup_opentelemetry() :: :ok
  def setup_opentelemetry do
    if Application.get_env(:micelio, :tracing_enabled, false) do
      :ok = OpentelemetryBandit.setup()
      Logger.info("opentelemetry tracing enabled")
    end

    :ok
  rescue
    error ->
      Logger.warning("could not start opentelemetry instrumentation: #{inspect(error)}")
      :ok
  end
end
