defmodule Micelio.PromEx.Plugin do
  @moduledoc """
  Micelio's own metrics.

  Grouped by the question each one answers:

  **Is the cluster healthy?** `micelio_wal_read_duration_seconds` bucketed by
  outcome. A healthy node's reads are overwhelmingly `not_modified`, because
  that is a metadata-only round trip against object storage. If `modified`
  starts dominating, replicas are doing catch-up work on the read path.

  **Is there write contention?** Read `micelio_wal_append_batch_size` first: it
  is how many pushes each compare-and-swap absorbed, so rising with load is
  group commit doing its job. `micelio_wal_cas_retry_count` is the contention
  that got past it — a few are normal, but many mean pushes are arriving at
  several nodes at once and the preferred-writer routing is not taking effect.

  **How far behind is this node?** `micelio_replica_entries_behind` on each
  sync. Persistent non-zero values mean hints are not arriving, or object
  storage is slow.

  **Should we scale?** `micelio_git_requests_in_flight` is the honest measure
  of a Git server's load: a clone occupies a connection and a process for its
  entire duration, so concurrency saturates long before CPU does.
  """

  use PromEx.Plugin

  @impl true
  def event_metrics(_opts) do
    [
      http_metrics(),
      object_store_metrics(),
      wal_metrics(),
      replica_metrics(),
      push_metrics(),
      git_metrics(),
      mcp_metrics(),
      factory_metrics(),
      auth_metrics()
    ]
  end

  defp http_metrics do
    Event.build(:micelio_http_event_metrics, [
      distribution(
        [:micelio, :http, :request, :duration_seconds],
        event_name: [:micelio, :http, :request],
        measurement: :duration_us,
        description: "End-to-end HTTP request duration, by listener, method and response status class.",
        unit: {:microsecond, :second},
        tags: [:listener, :method, :status],
        reporter_options: [buckets: [0.001, 0.005, 0.025, 0.1, 0.5, 1, 5, 30, 300, 1800]]
      ),
      counter(
        [:micelio, :http, :request, :count],
        event_name: [:micelio, :http, :request],
        description: "Completed HTTP requests.",
        tags: [:listener, :method, :status]
      ),
      sum(
        [:micelio, :http, :request, :bytes],
        event_name: [:micelio, :http, :request],
        measurement: :response_bytes,
        unit: :byte,
        description: "Bytes sent in HTTP responses.",
        tags: [:listener]
      ),
      counter(
        [:micelio, :http, :exception, :count],
        event_name: [:micelio, :http, :exception],
        description: "Unhandled HTTP request exceptions.",
        tags: [:listener]
      )
    ])
  end

  defp object_store_metrics do
    Event.build(:micelio_object_store_event_metrics, [
      distribution(
        [:micelio, :object_store, :request, :duration_seconds],
        event_name: [:micelio, :object_store, :request],
        measurement: :duration_us,
        description: "Object-store request duration. The object store is the source of truth.",
        unit: {:microsecond, :second},
        tags: [:operation, :outcome],
        reporter_options: [buckets: [0.001, 0.005, 0.025, 0.1, 0.5, 1, 5, 30, 300]]
      ),
      counter(
        [:micelio, :object_store, :request, :count],
        event_name: [:micelio, :object_store, :request],
        description: "Object-store requests, by operation and bounded outcome.",
        tags: [:operation, :outcome]
      )
    ])
  end

  defp wal_metrics do
    Event.build(:micelio_wal_event_metrics, [
      distribution(
        [:micelio, :wal, :read, :duration],
        event_name: [:micelio, :wal, :read],
        measurement: :duration_us,
        description: "Time to validate a replica's cached view of the log; not_modified is the fast path.",
        unit: {:microsecond, :second},
        tags: [:outcome],
        reporter_options: [buckets: [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5]]
      ),
      counter(
        [:micelio, :wal, :read, :count],
        event_name: [:micelio, :wal, :read],
        description: "Write-ahead log index reads.",
        tags: [:outcome]
      ),
      counter(
        [:micelio, :wal, :append, :count],
        event_name: [:micelio, :wal, :append],
        description: "Entries appended to the log."
      ),
      distribution(
        [:micelio, :wal, :append, :attempts],
        event_name: [:micelio, :wal, :append],
        measurement: :attempts,
        description: "Compare-and-swap attempts needed to commit an entry.",
        reporter_options: [buckets: [1, 2, 3, 5, 8, 12]]
      ),
      distribution(
        [:micelio, :wal, :append_batch, :size],
        event_name: [:micelio, :wal, :append_batch],
        measurement: :size,
        description:
          "Entries committed per compare-and-swap. This is group commit working: " <>
            "rising with load is the system absorbing contention rather than retrying through it.",
        reporter_options: [buckets: [1, 2, 4, 8, 16, 32, 64]]
      ),
      counter(
        [:micelio, :wal, :cas_retry, :count],
        event_name: [:micelio, :wal, :cas_retry],
        description: "Pushes that lost a compare-and-swap and retried against newer state."
      ),
      counter(
        [:micelio, :wal, :compact, :count],
        event_name: [:micelio, :wal, :compact],
        description: "Compactions performed by this node."
      ),
      sum(
        [:micelio, :wal, :pack_upload, :bytes],
        event_name: [:micelio, :wal, :pack_upload],
        measurement: :bytes,
        unit: :byte,
        description: "Packfile bytes streamed into the log. Object-store egress starts here."
      ),
      sum(
        [:micelio, :wal, :pack_download, :bytes],
        event_name: [:micelio, :wal, :pack_download],
        measurement: :bytes,
        unit: :byte,
        description:
          "Packfile bytes streamed out of the log to warm a replica. Sustained growth " <>
            "means caches are being rebuilt more often than they are being used."
      )
    ])
  end

  defp replica_metrics do
    Event.build(:micelio_replica_event_metrics, [
      distribution(
        [:micelio, :replica, :sync, :duration],
        event_name: [:micelio, :replica, :sync],
        measurement: :duration_ms,
        description: "Time to bring a replica into agreement with the log.",
        unit: {:millisecond, :second},
        reporter_options: [buckets: [0.005, 0.025, 0.1, 0.5, 1, 5, 15, 60, 300]]
      ),
      distribution(
        [:micelio, :replica, :sync, :entries_behind],
        event_name: [:micelio, :replica, :sync],
        measurement: :entries_behind,
        description: "How many log entries a replica was behind when it synced.",
        reporter_options: [buckets: [0, 1, 5, 25, 100, 500, 2500]]
      ),
      sum(
        [:micelio, :replica, :sync, :packs_downloaded],
        event_name: [:micelio, :replica, :sync],
        measurement: :packs_downloaded,
        description: "Packfiles downloaded from object storage."
      ),
      counter(
        [:micelio, :replica, :evict, :count],
        event_name: [:micelio, :replica, :evict],
        description: "Repositories evicted from local disk."
      )
    ])
  end

  defp push_metrics do
    Event.build(:micelio_push_event_metrics, [
      distribution(
        [:micelio, :push, :committed, :duration],
        event_name: [:micelio, :push, :committed],
        measurement: :duration_ms,
        description: "Time from receiving a push to it being durable in the log.",
        unit: {:millisecond, :second},
        reporter_options: [buckets: [0.01, 0.05, 0.1, 0.5, 1, 5, 15, 60]]
      ),
      counter(
        [:micelio, :push, :committed, :count],
        event_name: [:micelio, :push, :committed],
        description: "Pushes committed to the log."
      ),
      counter(
        [:micelio, :push, :rejected, :count],
        event_name: [:micelio, :push, :rejected],
        description: "Pushes rejected, by reason.",
        tags: [:reason]
      )
    ])
  end

  defp git_metrics do
    Event.build(:micelio_git_event_metrics, [
      distribution(
        [:micelio, :git, :command, :duration],
        event_name: [:micelio, :git, :command],
        measurement: :duration_us,
        description: "Duration of git plumbing invocations.",
        unit: {:microsecond, :second},
        tags: [:subcommand],
        reporter_options: [buckets: [0.001, 0.01, 0.05, 0.25, 1, 5, 30, 300]]
      ),
      distribution(
        [:micelio, :git, :served, :duration],
        event_name: [:micelio, :git, :served],
        measurement: :duration_ms,
        description: "Duration of a served Git protocol request.",
        unit: {:millisecond, :second},
        tags: [:service],
        reporter_options: [buckets: [0.01, 0.1, 1, 5, 30, 120, 600]]
      ),
      sum(
        [:micelio, :git, :served, :bytes],
        event_name: [:micelio, :git, :served],
        measurement: :bytes,
        description: "Bytes served over the Git protocol.",
        tags: [:service]
      ),
      counter(
        [:micelio, :git, :aborted, :count],
        event_name: [:micelio, :git, :aborted],
        description: "Git streams that ended before completing.",
        tags: [:service]
      )
    ])
  end

  defp mcp_metrics do
    Event.build(:micelio_mcp_event_metrics, [
      distribution(
        [:micelio, :mcp, :request, :duration],
        event_name: [:micelio, :mcp, :request],
        measurement: :duration_us,
        description: "Duration of an MCP request, by method.",
        unit: {:microsecond, :second},
        tags: [:method],
        reporter_options: [buckets: [0.001, 0.01, 0.05, 0.25, 1, 5, 30]]
      ),
      counter(
        [:micelio, :mcp, :request, :count],
        event_name: [:micelio, :mcp, :request],
        description: "MCP requests handled.",
        tags: [:method, :outcome]
      )
    ])
  end

  defp factory_metrics do
    Event.build(:micelio_factory_event_metrics, [
      distribution(
        [:micelio, :factory, :operation, :duration],
        event_name: [:micelio, :factory, :operation],
        measurement: :duration_us,
        description:
          "Duration of durable graph-run and account-configuration operations, by bounded operation and outcome.",
        unit: {:microsecond, :second},
        tags: [:operation, :outcome],
        reporter_options: [buckets: [0.001, 0.005, 0.025, 0.1, 0.5, 1, 5, 30]]
      ),
      counter(
        [:micelio, :factory, :operation, :count],
        event_name: [:micelio, :factory, :operation],
        description:
          "Durable graph-run and account-configuration operations, by bounded operation and outcome.",
        tags: [:operation, :outcome]
      )
    ])
  end

  defp auth_metrics do
    Event.build(:micelio_auth_event_metrics, [
      counter(
        [:micelio, :auth, :denied, :count],
        event_name: [:micelio, :auth, :denied],
        description: "Authorization denials, by permission.",
        tags: [:permission]
      )
    ])
  end

  @impl true
  def polling_metrics(opts) do
    interval = Keyword.get(opts, :poll_rate, 10_000)

    [
      Polling.build(
        :micelio_cluster_polling_metrics,
        interval,
        {__MODULE__, :observe, []},
        [
          last_value(
            [:micelio, :cluster, :observed, :size],
            event_name: [:micelio, :cluster, :observed],
            measurement: :size,
            description: "Nodes currently in the cluster."
          ),
          last_value(
            [:micelio, :cluster, :observed, :resident],
            event_name: [:micelio, :cluster, :observed],
            measurement: :resident,
            description: "Repositories materialized on this node."
          ),
          last_value(
            [:micelio, :cluster, :observed, :in_flight],
            event_name: [:micelio, :cluster, :observed],
            measurement: :in_flight,
            description:
              "Git protocol requests currently being served. The right signal to autoscale on: " <>
                "a clone holds a connection for its whole duration, so concurrency saturates before CPU."
          ),
          last_value(
            [:micelio, :cluster, :observed, :disk_used_bytes],
            event_name: [:micelio, :cluster, :observed],
            measurement: :disk_used_bytes,
            description: "Bytes the local repository cache is occupying."
          )
        ]
      )
    ]
  end

  @doc false
  def observe do
    :telemetry.execute(
      [:micelio, :cluster, :observed],
      %{
        size: length(Micelio.Cluster.members()),
        resident: length(Micelio.Replica.resident()),
        in_flight: in_flight(),
        disk_used_bytes: disk_used()
      },
      %{}
    )
  end

  defp in_flight, do: Micelio.Telemetry.InFlight.count()

  defp disk_used do
    Micelio.Config.data_dir()
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.reduce(0, fn path, acc ->
      case File.stat(path) do
        {:ok, %{type: :regular, size: size}} -> acc + size
        _ -> acc
      end
    end)
  rescue
    _ -> 0
  end
end
