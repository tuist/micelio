import Config

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:repo_id, :node_id, :seq, :epoch]

import_config "#{config_env()}.exs"
