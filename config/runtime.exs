import Config

# Everything a Micelio node needs is read from the environment, so a single
# container image can be rolled out unchanged to every replica in a cluster.
# The only genuinely per-node value is MICELIO_NODE_ID.
#
# This applies in any environment where MICELIO_S3_BUCKET is set, not only in
# production. That lets the end-to-end suite drive a node from source against
# real object storage, and lets a developer point `iex -S mix` at a real bucket
# without a separate configuration path that could drift from the real one.
if config_env() == :prod or System.get_env("MICELIO_S3_BUCKET") do
  get = fn key, default -> System.get_env(key, default) end

  require_env = fn key ->
    System.get_env(key) ||
      raise """
      environment variable #{key} is missing.

      Micelio needs an S3-compatible object store to hold the write-ahead log; it
      is the source of truth for every repository this node serves.
      """
  end

  object_store =
    {
      Micelio.ObjectStore.S3,
      # Path style is what MinIO, Tigris and Ceph expect. Set to "false" for
      # virtual-hosted-style buckets on AWS proper.
      bucket: require_env.("MICELIO_S3_BUCKET"),
      endpoint: require_env.("MICELIO_S3_ENDPOINT"),
      region: get.("MICELIO_S3_REGION", "auto"),
      access_key_id: require_env.("MICELIO_S3_ACCESS_KEY_ID"),
      secret_access_key: require_env.("MICELIO_S3_SECRET_ACCESS_KEY"),
      prefix: get.("MICELIO_S3_PREFIX", ""),
      path_style: get.("MICELIO_S3_PATH_STYLE", "true") == "true"
    }

  auth =
    case get.("MICELIO_AUTH_BACKEND", "webhook") do
      "webhook" ->
        {Micelio.Auth.Webhook,
         endpoint: require_env.("MICELIO_AUTH_ENDPOINT"),
         token: require_env.("MICELIO_AUTH_TOKEN"),
         cache_ttl_ms: String.to_integer(get.("MICELIO_AUTH_CACHE_TTL_MS", "30000"))}

      "static" ->
        {Micelio.Auth.Static, tokens: Micelio.Auth.Static.parse_tokens(get.("MICELIO_AUTH_TOKENS", ""))}

      "none" ->
        {Micelio.Auth.Allow, []}
    end

  config :micelio,
    node_id: get.("MICELIO_NODE_ID", nil) || :inet.gethostname() |> elem(1) |> to_string(),
    advertise_host: get.("MICELIO_ADVERTISE_HOST", "127.0.0.1"),
    data_dir: get.("MICELIO_DATA_DIR", "/var/lib/code/repositories"),
    object_store: object_store,
    auth: auth,
    git_port: String.to_integer(get.("MICELIO_GIT_PORT", "4000")),
    hook_port: String.to_integer(get.("MICELIO_HOOK_PORT", "4001")),
    admin_port: String.to_integer(get.("MICELIO_ADMIN_PORT", "4002")),
    gossip_port: String.to_integer(get.("MICELIO_GOSSIP_PORT", "4010")),
    admin_token: require_env.("MICELIO_ADMIN_TOKEN"),
    peers: get.("MICELIO_PEERS", "") |> String.split(",", trim: true),
    default_replicas: String.to_integer(get.("MICELIO_DEFAULT_REPLICAS", "3")),
    # How long a replica may serve a read without re-verifying the WAL index
    # against the object store. 0 means "verify every read", which is the
    # guarantee the design is built on; raise it only knowingly.
    staleness_budget_ms: String.to_integer(get.("MICELIO_STALENESS_BUDGET_MS", "0")),
    # Authorization is checked on every request, so unlike a repository read
    # this is not zero by default; see docs/multi-tenancy.md.
    policy_staleness_budget_ms: String.to_integer(get.("MICELIO_POLICY_STALENESS_BUDGET_MS", "5000")),
    compaction_entry_threshold: String.to_integer(get.("MICELIO_COMPACTION_ENTRY_THRESHOLD", "250")),
    compaction_bytes_threshold: String.to_integer(get.("MICELIO_COMPACTION_BYTES_THRESHOLD", "268435456")),
    idle_eviction_ms: String.to_integer(get.("MICELIO_IDLE_EVICTION_MS", "3600000")),
    public_url: System.get_env("MICELIO_PUBLIC_URL"),
    resource_identifier: System.get_env("MICELIO_RESOURCE_IDENTIFIER"),
    authorization_servers: get.("MICELIO_AUTHORIZATION_SERVERS", "") |> String.split(",", trim: true),
    tracing_enabled: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") != nil

  # Node discovery. libcluster's only job is to make nodes visible to each
  # other; from there distributed Erlang handles membership, failure detection
  # and message delivery, and rendezvous hashing handles placement. In
  # Kubernetes this reads the Endpoints of a headless Service, so scaling the
  # Deployment is the whole of "adding capacity".
  topologies =
    case get.("MICELIO_CLUSTER_STRATEGY", "none") do
      "kubernetes" ->
        # The headless-service DNS strategy rather than the API-based one: it
        # resolves pod addresses straight from DNS, so Micelio needs no
        # ServiceAccount permissions and no API access at all. One less thing
        # to grant, and one less thing that can break a deploy.
        [
          micelio: [
            strategy: Elixir.Cluster.Strategy.Kubernetes.DNS,
            config: [
              service: get.("MICELIO_HEADLESS_SERVICE", "micelio-headless"),
              application_name: get.("MICELIO_RELEASE_NAME", "micelio"),
              polling_interval: 5_000
            ]
          ]
        ]

      "dns" ->
        [
          micelio: [
            strategy: Elixir.Cluster.Strategy.DNSPoll,
            config: [
              query: require_env.("MICELIO_DNS_QUERY"),
              node_basename: get.("MICELIO_RELEASE_NAME", "micelio"),
              polling_interval: 5_000
            ]
          ]
        ]

      "epmd" ->
        [
          micelio: [
            strategy: Elixir.Cluster.Strategy.Epmd,
            config: [
              hosts: get.("MICELIO_PEERS", "") |> String.split(",", trim: true) |> Enum.map(&String.to_atom/1)
            ]
          ]
        ]

      _ ->
        nil
    end

  if topologies, do: config(:libcluster, topologies: topologies)

  config :micelio, Micelio.PromEx,
    disabled: false,
    manual_metrics_start_delay: :no_delay,
    drop_metrics_groups: [],
    grafana: :disabled,
    metrics_server: :disabled

  if System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") do
    config :opentelemetry,
      resource: [service: %{name: "micelio", version: Micelio.version()}],
      span_processor: :batch,
      traces_exporter: :otlp

    config :opentelemetry_exporter,
      otlp_protocol: get.("OTEL_EXPORTER_OTLP_PROTOCOL", "http_protobuf") |> String.to_atom(),
      otlp_endpoint: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")
  end
end
