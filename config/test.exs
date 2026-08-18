import Config

config :logger, level: :warning

config :micelio,
  # Ports are bound lazily by the tests that need them; the supervision tree
  # starts without listeners so the suite can run several isolated clusters.
  start_listeners: false,
  start_gossip: false,
  data_dir: {:system_tmp, "micelio-test-repositories"},
  object_store: {Micelio.ObjectStore.Filesystem, root: {:system_tmp, "micelio-test-object-store"}},
  auth: {Micelio.Auth.Static, tokens: %{"test-token" => %{account: "test", scopes: [:read, :write]}}},
  node_id: "test-1",
  peers: []

config :micelio, Micelio.PromEx, disabled: true
