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
    * `[:micelio, :wal, :pack_upload]` / `[:micelio, :wal, :pack_download]` —
      `bytes`, meta `repo_id`. Packs stream to and from the store, so these
      count bytes moved, not memory held.
    * `[:micelio, :replica, :sync]` — `duration_ms`, `packs_downloaded`,
      `entries_behind`
    * `[:micelio, :replica, :evict]`
    * `[:micelio, :object_store, :request]` — `duration_us`, meta `operation`,
      `outcome`; every access to the source of truth
    * `[:micelio, :http, :request]` — `duration_us`, request and response
      bytes, meta listener, method and status class
    * `[:micelio, :http, :exception]` — an unhandled request exception
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
  alias OpenTelemetry.Ctx
  alias OpenTelemetry.Span
  require OpenTelemetry.Tracer

  @doc """
  Attach the log handlers.

  Deliberately sparse: a Git server under load produces enormous numbers of
  events, and logging each one turns observability into the bottleneck.
  Metrics carry the volume; logs carry the exceptions.
  """
  @spec attach() :: :ok
  def attach do
    logging_events = [
      [:micelio, :push, :rejected],
      [:micelio, :git, :aborted],
      [:micelio, :wal, :compact]
    ]

    :telemetry.detach("micelio-logging")
    :telemetry.detach("micelio-http")
    :telemetry.attach_many("micelio-logging", logging_events, &__MODULE__.handle_event/4, nil)

    :telemetry.attach_many(
      "micelio-http",
      [[:bandit, :request, :stop], [:bandit, :request, :exception]],
      &__MODULE__.handle_http_event/4,
      nil
    )

    Micelio.Telemetry.InFlight.attach()
    :ok
  end

  @doc false
  def handle_event([:micelio, :push, :rejected], _measurements, meta, _config) do
    Logger.info("push rejected", repo_id: meta.repo_id, reason: meta.reason)
  end

  def handle_event([:micelio, :git, :aborted], measurements, meta, _config) do
    Logger.debug(
      "Git stream aborted",
      repo_id: meta[:repo_id],
      service: meta[:service],
      duration_ms: measurements.duration_ms,
      reason: meta[:reason]
    )
  end

  def handle_event([:micelio, :wal, :compact], measurements, meta, _config) do
    Logger.info("compacted write-ahead log",
      repo_id: meta.repo_id,
      epoch: measurements.epoch,
      packs: measurements.packs
    )
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  @doc false
  def handle_http_event([:bandit, :request, :stop], measurements, %{conn: conn, plug: plug}, _config) do
    case listener(plug) do
      nil ->
        :ok

      listener ->
        :telemetry.execute(
          [:micelio, :http, :request],
          %{
            duration_us: System.convert_time_unit(measurements.duration, :native, :microsecond),
            request_bytes: Map.get(measurements, :req_body_bytes, 0),
            response_bytes: Map.get(measurements, :resp_body_bytes, 0)
          },
          %{listener: listener, method: http_method(conn.method), status: status_class(conn.status)}
        )
    end
  end

  def handle_http_event([:bandit, :request, :exception], _measurements, %{conn: conn, plug: plug}, _config) do
    case listener(plug) do
      nil ->
        :ok

      listener ->
        :telemetry.execute([:micelio, :http, :exception], %{}, %{listener: listener})
        Logger.error("unhandled HTTP request exception", listener: listener, method: conn.method)
    end
  end

  def handle_http_event(_event, _measurements, _meta, _config), do: :ok

  @doc """
  Add attributes to the current OpenTelemetry span, if tracing is running.

  Silently does nothing when the OpenTelemetry application is not started, so tests and
  a bare `iex -S mix` need no tracing configuration.
  """
  @spec put_span_attributes(conn, map()) :: conn when conn: term()
  def put_span_attributes(conn, attributes) do
    put_span_attributes(attributes)
    conn
  end

  @doc "Add attributes to the current OpenTelemetry span."
  @spec put_span_attributes(map()) :: :ok
  def put_span_attributes(attributes) do
    if tracing?() do
      OpenTelemetry.Tracer.set_attributes(attributes)
    end

    :ok
  end

  @doc "Return the current tracing context, or nil when tracing is disabled."
  @spec context() :: Ctx.t() | nil
  def context do
    if tracing?(), do: Ctx.get_current()
  end

  @doc "Run `fun` with a tracing context received from another process."
  @spec with_context(Ctx.t() | nil, (-> result)) :: result when result: term()
  def with_context(nil, fun), do: fun.()

  def with_context(context, fun) do
    if tracing?() do
      token = Ctx.attach(context)

      try do
        fun.()
      after
        Ctx.detach(token)
      end
    else
      fun.()
    end
  end

  @doc "Add a bounded outcome attribute to the active span."
  @spec put_span_outcome(term()) :: term()
  def put_span_outcome(result) do
    outcome = outcome(result)

    if tracing?() do
      OpenTelemetry.Tracer.set_attribute("micelio.outcome", Atom.to_string(outcome))

      if outcome == :error do
        OpenTelemetry.Tracer.set_status(:error, "operation failed")
      end
    end

    result
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
        log_metadata = Logger.metadata()
        Logger.metadata(Span.hex_span_ctx(OpenTelemetry.Tracer.current_span_ctx()))

        try do
          fun.()
        after
          Logger.reset_metadata(log_metadata)
        end
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
      # Public clients can send arbitrary trace headers. Link their context for
      # correlation, but do not let it become the parent of this service's work.
      :ok = OpentelemetryBandit.setup(public_endpoint: true)
      Logger.info("OpenTelemetry tracing enabled")
    end

    :ok
  rescue
    error ->
      Logger.warning("could not start OpenTelemetry instrumentation", reason: error)
      :ok
  end

  defp listener({Micelio.HTTP.Router, _opts}), do: :public
  defp listener({Micelio.HTTP.AdminRouter, _opts}), do: :admin
  defp listener({Micelio.HTTP.HookRouter, _opts}), do: :hook
  defp listener(_plug), do: nil

  defp http_method("GET"), do: :get
  defp http_method("POST"), do: :post
  defp http_method("PUT"), do: :put
  defp http_method("PATCH"), do: :patch
  defp http_method("DELETE"), do: :delete
  defp http_method("HEAD"), do: :head
  defp http_method("OPTIONS"), do: :options
  defp http_method(_method), do: :other

  defp status_class(status) when status in 100..199, do: :"1xx"
  defp status_class(status) when status in 200..299, do: :"2xx"
  defp status_class(status) when status in 300..399, do: :"3xx"
  defp status_class(status) when status in 400..499, do: :"4xx"
  defp status_class(status) when status in 500..599, do: :"5xx"
  defp status_class(_status), do: :unknown

  defp outcome(:ok), do: :ok
  defp outcome({:ok, _}), do: :ok
  defp outcome({:ok, _, _}), do: :ok
  defp outcome({:error, :not_found}), do: :not_found
  defp outcome({:error, :precondition_failed}), do: :precondition_failed
  defp outcome({:error, _}), do: :error
  defp outcome(_), do: :ok
end
