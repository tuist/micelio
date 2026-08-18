# Operations

## Configuration

Everything is read from the environment so one image can be rolled out
unchanged to every node. The only per-node value is `MICELIO_NODE_ID`.

### Required

| Variable | Meaning |
|---|---|
| `MICELIO_S3_BUCKET` | Bucket holding the write-ahead log |
| `MICELIO_S3_ENDPOINT` | Object store endpoint |
| `MICELIO_S3_ACCESS_KEY_ID` | |
| `MICELIO_S3_SECRET_ACCESS_KEY` | |
| `MICELIO_ADMIN_TOKEN` | Bearer token for the admin API |

### Object storage

| Variable | Default | Notes |
|---|---|---|
| `MICELIO_S3_REGION` | `auto` | |
| `MICELIO_S3_PREFIX` | | Key prefix, for sharing a bucket |
| `MICELIO_S3_PATH_STYLE` | `true` | `false` for virtual-hosted AWS buckets |

The store **must** support conditional writes (`If-Match`, `If-None-Match`) and
conditional reads (`If-None-Match`). AWS S3, MinIO, Tigris, Cloudflare R2 and
Ceph all do. Without them the compare-and-swap that orders pushes does not
exist, and Micelio will not be safe.

### Behaviour

| Variable | Default | Notes |
|---|---|---|
| `MICELIO_DEFAULT_REPLICAS` | `3` | Per-repository, overridable |
| `MICELIO_STALENESS_BUDGET_MS` | `0` | See below |
| `MICELIO_COMPACTION_ENTRY_THRESHOLD` | `250` | |
| `MICELIO_COMPACTION_BYTES_THRESHOLD` | `268435456` | |
| `MICELIO_IDLE_EVICTION_MS` | `3600000` | Drop untouched repositories from disk |
| `MICELIO_DATA_DIR` | `/var/lib/micelio/repositories` | Put this on fast local NVMe |

**`MICELIO_STALENESS_BUDGET_MS` deserves a moment.** At `0`, every read
re-validates against object storage before serving, which is what makes a client
able to talk to any replica and get an answer consistent with every other. The
check is a conditional GET returning `304` — a metadata operation, typically a
few milliseconds.

Raising it lets a replica serve from its cached view for that long without
checking. This is a real trade, not a tuning knob: a client that pushes to node
A and immediately fetches from node B may not see its own write. Only raise it
if you know the workload tolerates that.

### Clustering

| Variable | Default | Notes |
|---|---|---|
| `MICELIO_CLUSTER_STRATEGY` | `none` | `kubernetes`, `dns`, `epmd` |
| `MICELIO_HEADLESS_SERVICE` | `micelio-headless` | For the Kubernetes strategy |
| `MICELIO_NAMESPACE` | `default` | |
| `RELEASE_COOKIE` | | **Required for clustering.** Distributed Erlang's shared secret |

A single node works with no clustering at all. Clustering buys read scaling and
replication hints, not correctness.

### Authentication

See [kubernetes.md](kubernetes.md) for the full picture.

| Variable | Notes |
|---|---|
| `MICELIO_AUTH_BACKEND` | `webhook` (default), `oidc`, `static`, `none` |
| `MICELIO_OIDC_ISSUER` | Token issuer, used to discover the JWKS |
| `MICELIO_OIDC_AUDIENCE` | **Set this.** Binds tokens to this deployment |
| `MICELIO_AUTH_ENDPOINT` | For the webhook backend |

### Observability

| Variable | Notes |
|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Setting it enables tracing |
| `MICELIO_PUBLIC_URL` | Overrides the URL advertised to clients |

## Ports

| Port | Surface | Exposure |
|---|---|---|
| 4000 | Git smart HTTP, MCP, OAuth discovery | Public |
| 4001 | `pre-receive` hook callback | **Loopback only.** Can commit a push |
| 4002 | Health, readiness, metrics, admin API | Internal |

Port 4001 binds to `127.0.0.1` and requires a secret generated at boot and never
written to disk. It must never be exposed.

## Metrics

`GET :4002/metrics`, Prometheus format.

### The one to watch

**`micelio_wal_read_duration_seconds{outcome}`.** A healthy node's reads are
overwhelmingly `not_modified`: replicas confirm they are current with a
metadata-only round trip and serve immediately. If `modified` starts dominating,
replicas are doing real catch-up work on the read path, and latency will follow.

### The rest

| Metric | Question it answers |
|---|---|
| `micelio_wal_cas_retry_count` | Is there write contention the writer could not absorb? A few are normal; many mean pushes are arriving at several nodes at once, so routing to the preferred writer is not taking effect |
| `micelio_wal_append_batch_size` | Pushes absorbed per compare-and-swap. Rising with load is group commit doing its job |
| `micelio_replica_sync_entries_behind` | How far behind is this node? Persistent non-zero means hints are not arriving, or the store is slow |
| `micelio_git_requests_in_flight` | Should we scale? See below |
| `micelio_push_rejected_count{reason}` | `non_fast_forward` is users; `storage` and `contention` are yours |
| `micelio_git_aborted_count` | Clients disconnecting mid-clone |
| `micelio_replica_evict_count` | Cache churn. High values with high sync duration means the working set does not fit |

### What to autoscale on

`micelio_git_requests_in_flight`, not CPU. A clone occupies a connection, a
process and a `git upload-pack` for its entire duration, which can be minutes,
while CPU stays unremarkable. Scaling on CPU alone reacts far too late.

Use CPU as a secondary signal for compaction load.

## Health

| Endpoint | Meaning |
|---|---|
| `GET :4002/health` | The process is up. Use as a liveness probe |
| `GET :4002/ready` | Object storage is reachable. Use as a readiness probe |

Readiness deliberately depends on the object store: a node that cannot read the
log cannot answer consistently and should leave rotation rather than serve stale
data.

## Admin API

Bearer `MICELIO_ADMIN_TOKEN`. Any node answers any question.

```sh
curl :4002/status                            # this node
curl :4002/cluster                           # membership and resident repositories
curl :4002/repositories                      # every repository in the store
curl :4002/repositories/acme/app             # log state, placement, replica health
curl :4002/placement/acme/app                # where it should live, computed
curl -XPOST :4002/repositories -d '{"repository":"acme/app"}'
curl -XPOST :4002/compact/acme/app           # forwarded to the primary
curl -XPOST :4002/evict/acme/app             # drop the local cache
curl -XPUT  :4002/replicas/acme/app -d '{"replicas":30}'
```

`GET /repositories/<id>` is the one to reach for first when something is wrong.
It reports the log's position and each replica's position, so "which nodes are
behind, and by how much" is one request.

## Failure modes

**A node dies.** Nothing to do. Rendezvous hashing has already reassigned its
repositories; the nodes that inherit them materialize on first request. There is
no repair queue because there is nothing to repair.

**Object storage is unreachable.** Reads keep working for repositories already
materialized *only if* `staleness_budget_ms > 0`; at the default of `0` they
fail, because the node cannot confirm it is current and would rather refuse than
lie. Writes fail. `/ready` goes red and the node leaves rotation. This is a hard
dependency by design.

**A git command hangs with no output on macOS.** Not Micelio. The `osxkeychain`
credential helper blocks storing a credential for a host and port it has not
seen before. Add `-c credential.helper=` to confirm, then approve it once.

**A push is rejected with "has moved since you last fetched".** Working as
intended: another push landed first, possibly on another node. The client should
fetch and retry. If it happens constantly on one repository, that repository is
a write hotspot.

**`cas_exhausted`.** Too many concurrent writers on one repository for the retry
budget. Bounded by object store latency, not by Micelio.

**A replica cannot converge.** Almost always a log entry naming an object no
pack provides, which the sync will refuse loudly rather than paper over. Check
`micelio_replica_sync_*` and the node's logs; the repository is intact in the
log, so evicting the replica and letting it rebuild is safe and usually enough.

**Disk fills.** Lower `MICELIO_IDLE_EVICTION_MS` or add nodes. The cache tracks
the working set, so this means the working set grew.

## Capacity

- **Read throughput** scales linearly with replicas. Add pods.
- **Per-repository write throughput** is one conditional GET and one
  conditional PUT *per batch*, not per push: concurrent pushes to a repository
  are grouped by its writer (see [architecture](architecture.md#write-throughput)).
  A repository under sustained write load therefore scales with batch size
  rather than degrading with concurrency. S3 Express One Zone materially
  outperforms S3 Standard here.
- **Cluster-wide write throughput** scales with the number of distinct
  repositories, since each has its own independent CAS chain.
- **Disk** should hold the working set, not the corpus.

## Backup

The object store is the repository. Back up the bucket; versioning and
cross-region replication apply as they would to any bucket. Nothing on any
node's disk needs backing up, ever.

Because every entry is retained and every pre-compaction index is snapshotted
under `history/`, point-in-time reconstruction of any repository state is
possible from the bucket alone.
