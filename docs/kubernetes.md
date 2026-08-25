# Kubernetes

## Why this is a Deployment, not a StatefulSet

A Git host is usually a StatefulSet: stable identities, stable volumes, careful
ordering, because the disk *is* the repository.

Here the disk is a cache. Nothing on it is authoritative, nothing needs to
survive a restart, and no pod needs a stable identity for correctness. So it is
an ordinary Deployment with `emptyDir` on local NVMe, and it scales like any
stateless workload.

That is not a packaging convenience. It follows from the log being the source of
truth, and it is what makes autoscaling work without an operator: adding a pod
changes the membership that rendezvous hashing reads, which reassigns a fraction
of the repositories. The new pod materializes them on first request; the old ones
evict them once idle. No rebalancing job runs, because placement was never
recorded — only computed.

## Install

```sh
helm install micelio oci://ghcr.io/tuist/charts/micelio \
  --set objectStore.bucket=micelio \
  --set objectStore.endpoint=https://s3.eu-west-1.amazonaws.com \
  --set objectStore.existingSecret=micelio-s3 \
  --set auth.oidc.kubernetes=true \
  --set auth.oidc.audience=micelio
```

See [`charts/micelio/values.yaml`](../charts/micelio/values.yaml).

## Clustering

Nodes find each other through a headless Service; `libcluster` reads its
endpoints and connects them with distributed Erlang. From there, membership,
failure detection and message delivery are the BEAM's, and placement is
rendezvous hashing over the live set.

`RELEASE_COOKIE` is the shared secret for distributed Erlang. The chart
generates one and stores it in a Secret if you do not supply one. Nodes with
different cookies silently fail to cluster.

Clustering is not required for correctness. A single replica is fully durable,
because the log is in object storage. Clustering buys read scaling.

## Autoscaling

```yaml
autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 50

  # Needs prometheus-adapter or KEDA. Off by default, and deliberately so: an
  # HPA that names a metric nobody serves does not fall back to CPU, it stops
  # scaling entirely — while still looking healthy until you read its
  # conditions.
  inFlightMetric:
    enabled: true
    target: 40
```

**Scale on in-flight requests, not CPU.** A clone holds a connection, a process
and a `git upload-pack` for its whole duration — minutes for a large monorepo —
while CPU stays unremarkable. By the time CPU is a useful signal the node has
already run out of capacity to accept work.

This needs `prometheus-adapter` or KEDA to expose the metric. The chart ships a
`ServiceMonitor` and an example adapter rule. CPU is worth keeping as a secondary
trigger for compaction load.

Scale-down is safe at any moment: a terminating pod's repositories are already
in the log, so the only cost is that whoever inherits them materializes on first
request. Set a `terminationGracePeriodSeconds` long enough for in-flight clones
to finish (the chart defaults to 120s).

## Authentication without secrets

This is the part that makes "no control plane" hold up in practice.

Every pod already has a projected service account token, which is an OIDC JWT
the cluster's own issuer will vouch for. Micelio validates it against the
cluster's JWKS. Nothing has to be created, distributed, rotated or revoked,
because the kubelet already rotates it.

Set `auth.oidc.kubernetes=true` and leave `auth.oidc.issuer` empty. Two details
matter, and both are handled by the chart:

  * **The cluster's discovery endpoint is not public.** It is served with the
    cluster CA and requires authentication, so Micelio uses its own service
    account token and the mounted CA to read it. That is the one API
    permission Micelio ever needs — the read-only
    `system:service-account-issuer-discovery` role — and the chart grants it
    only when this backend is configured. Everything else, clustering
    included, needs no API access at all.

  * **Do not configure the issuer by hand.** Kubernetes is *reached* at
    `https://kubernetes.default.svc` but *issues* tokens naming
    `https://kubernetes.default.svc.cluster.local`. Configuring the address you
    connect to rejects every token with an issuer mismatch, so Micelio asks the
    cluster instead of guessing.

```yaml
volumes:
  - name: micelio-token
    projected:
      sources:
        - serviceAccountToken:
            audience: micelio      # must match auth.oidc.audience
            expirationSeconds: 3600
            path: token
```

```sh
git -c http.extraHeader="Authorization: Bearer $(cat /var/run/secrets/micelio/token)" \
    clone https://micelio.internal/acme/ios-app.git
```

The subject arrives as `system:serviceaccount:<namespace>:<name>`. With
`namespace_grants` (on by default) that becomes read and write on
`<namespace>/**` — so a pod in `team-ios` can use `team-ios`'s repositories and
nothing else, with no per-team configuration at all.

That default deliberately does not grant `execute`. A sandbox that must claim
work needs an explicit `execute` grant through the account policy or the
token's grants claim. A claim returns only the inference profile name, version,
endpoint, and model. Its credential binding is read by the trusted provisioner
and egress proxy, not by the sandbox or repository-command environment.

For finer control, put explicit grants in a claim:

```json
{ "micelio_grants": ["acme/**:read", "acme/sandbox-*:read,write,execute"] }
```

### Audience binding is not optional

`aud` is verified against this deployment's resource identifier. Without it, a
token minted for any other service sharing the issuer would be replayable here —
the confused-deputy problem the MCP authorization spec exists to prevent. Micelio
logs a warning if you run without an audience configured.

## Storage

```yaml
persistence:
  enabled: false        # emptyDir; the cache is disposable
  sizeLimit: 100Gi
```

Put it on local NVMe. If your nodes have local SSD, use it:

```yaml
persistence:
  enabled: true
  storageClass: local-nvme
```

Either works. Each pod gets its own volume — a generic ephemeral claim, created
and deleted with the pod — because the cache is per-pod: replicas sharing one
set of Git directories would have several nodes repacking and updating the same
refs at once. A single ReadWriteOnce claim would also pin every replica to one
node, quietly undoing the spread constraint above.

A claim survives a container restart and saves re-materialization; an
`emptyDir` is simpler and rebuilds in seconds for anything but a large monorepo.
Size it for the working set, not the corpus — the reaper evicts what nobody
touches.

## Probes

```yaml
livenessProbe:
  httpGet: { path: /health, port: admin }
readinessProbe:
  httpGet: { path: /ready, port: admin }
```

`/ready` checks that object storage is reachable. A node that cannot read the log
cannot answer consistently and should leave rotation rather than serve stale
data.

## Exposure

Only port 4000 should be public. Port 4002 (admin, metrics) belongs on an
internal Service; port 4001 binds to loopback and is never a Service at all — it
can commit a push, and it is reachable only from inside the pod.

## Multi-region

Nodes in different regions can share one bucket and one cluster, but each push
pays cross-region latency to the object store, and distributed Erlang across
regions is not something to do casually.

The better arrangement is one Micelio cluster per region against a regional
bucket, with replication handled at the bucket level if you need it. The
architecture does not require a single global cluster, and rendezvous hashing
makes each regional cluster self-sufficient.
