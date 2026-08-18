import Config

# Development runs a single node against a filesystem-backed object store, so
# there is no dependency on MinIO or S3 to get a working push/fetch loop.
config :micelio,
  data_dir: "priv/data/repositories",
  object_store: {Micelio.ObjectStore.Filesystem, root: "priv/data/object-store"},
  # Deliberately unscoped: a token with no account grants everything, which is
  # what a single-developer machine wants. A token *with* an account is scoped
  # to it and nothing else — see Micelio.Auth.Static.
  auth: {Micelio.Auth.Static, tokens: %{"dev-token" => %{subject: "dev", scopes: [:admin]}}},
  git_port: 4000,
  hook_port: 4001,
  admin_port: 4002,
  gossip_port: 4010,
  node_id: "dev-1",
  peers: []

config :micelio, Micelio.PromEx,
  disabled: false,
  manual_metrics_start_delay: :no_delay,
  grafana: :disabled,
  metrics_server: :disabled
