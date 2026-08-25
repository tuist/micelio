import Config

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :repo_id,
    :node_id,
    :seq,
    :epoch,
    :reason,
    :operation,
    :service,
    :status,
    :listener,
    :method,
    :duration_ms,
    :duration_us,
    :packs,
    :bytes,
    :otel_trace_id,
    :otel_span_id
  ]

import_config "#{config_env()}.exs"
