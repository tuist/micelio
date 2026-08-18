# Architecture

## The one idea

A repository is a write-ahead log in object storage. Everything else — the
files on a node's disk, the packfiles, the refs — is a cache of that log.

This is worth stating precisely because it inverts the usual arrangement. In a
conventional Git host, the repository is the directory on disk, and replication
is the problem of keeping several such directories in agreement. That is hard:
the directories are authoritative, so losing one means losing data, and
disagreement between them means someone has to adjudicate. GitHub's Spokes
solved it with three-phase commit across three replicas, which works but
constrains scaling in both directions — you cannot have fewer than three, and
each additional one costs latency on every write.

If instead the log is authoritative and the directories are caches, all of that
disappears. A cache can be wrong, because you can check it. A cache can be lost,
because you can rebuild it. And two caches never need to agree with each other,
only with the log.

## Objects

```
repos/<repo_id>/index.pb           the only mutable object, under CAS
repos/<repo_id>/wal/<digest>.pb    entries, immutable, content-addressed
repos/<repo_id>/packs/<name>.pack  packfiles, immutable
repos/<repo_id>/packs/<name>.idx
repos/<repo_id>/history/<epoch>.pb index snapshots, kept for provenance
```

Everything but the packfiles is protobuf, defined in
`priv/proto/micelio/wal/v1/wal.proto`. The log outlives any particular version
of this code — a node running next year's build will read entries written by
today's — so the encoding is a schema with compatibility rules rather than
whatever a serializer happened to emit.

### The index

One object per repository, and the only one that is ever mutated. It holds:

- `epoch` and `seq` — the repository's position,
- `base` — the packs and refs a compaction produced,
- `entries` — pointers to entries applied since that base,
- `refs` — the repository's **complete current ref state**,
- `replicas` — how many nodes should hold it.

The last two deserve explanation, because they are what make both halves of the
system cheap.

**`refs` at the top level** means a replica converges by setting refs to exactly
this map, rather than by replaying each entry's commands in order. Catching up
is therefore the same amount of work whether a replica is one push behind or ten
thousand. It also means a pusher can check a proposed update against the real
current value before winning the CAS, which is what makes "reject
non-fast-forwards" mean something across nodes rather than only locally.

**Packs repeated on each entry pointer** means a replica can compute which packs
it needs from the index alone, without fetching a single entry body. Entry
bodies then exist purely for audit — which is what they are actually for.

Together: catching up costs **one read**.

### Entries

Immutable, and keyed by the hash of their own bytes. Writing one is therefore
idempotent, which is why retrying after a lost compare-and-swap costs one small
`PUT` rather than re-uploading a packfile.

The sequence number is deliberately *not* in the entry. Order is assigned by the
index, which is the only object under CAS. Keeping it out of the body is exactly
what makes the entry content-addressable.

## How a push becomes visible

Git runs `pre-receive` after it has received and validated the objects but
before it applies any reference update, with the new objects held in a
quarantine directory that is discarded if the hook fails. That is precisely the
window Micelio needs.

```
git receive-pack
      │
      ├─ objects received, connectivity checked, held in quarantine
      │
      ├─ pre-receive hook ──► node
      │                        │
      │                        ├─ 1. upload packs      (content-addressed, idempotent)
      │                        ├─ 2. upload entry      (content-addressed, idempotent)
      │                        └─ 3. CAS the index     ◄── the push exists here
      │                              │
      │                              ├─ won  → exit 0 → git applies refs atomically
      │                              └─ lost → re-read, re-validate, retry
      │
      └─ refs applied, client acknowledged
```

Nothing is acknowledged before step 3 succeeds. The ordering is the wrong way
round to lose data: the log can briefly hold a push whose local ref update then
failed — and a replica will happily converge on it — but a client can never be
told "yes" for something the log does not have.

### Why this is linearizable without consensus

Step 3 is a single atomic operation on a single object. Whoever wins it decides
what happened first. Losing is not a failure; it means someone else's push
landed, so the builder function is re-run against the state they left behind and
the fast-forward check is re-evaluated against *their* result.

That is the whole ordering protocol. There is no quorum, no leader, and no
agreement between nodes, which is why any node can accept any push.

## How a replica converges

```elixir
case ObjectStore.get(index_key, etag: cached_etag) do
  {:ok, :not_modified} -> serve                        # metadata-only round trip
  {:ok, index, etag}   -> download packs, set refs, serve
end
```

Then:

1. download the packs the index names that we do not already hold,
2. install them (`git index-pack` verifies them),
3. set refs to exactly `index.refs`,
4. drop any pack the index no longer names, if the epoch changed.

Every step is idempotent, and there is only one of them — no separate "repair",
"clone from peer" or "resync" mode to get wrong. Materializing a repository from
nothing and catching one up by one push are the same code path.

Ref updates are applied without checking previous values. That is not laxness:
the log already decided the order when a CAS was won, and a replica's job is to
converge on that decision, not to re-adjudicate it.

## Compaction

A log that only grows makes materialization slower forever. Compaction collapses
history into a new base: one `git repack`, a full ref snapshot, and an epoch
bump. A replica seeing a higher epoch adopts the base rather than replaying.

Only the preferred primary runs it, because repacking is CPU-bound and produces
a deterministic artefact. Paying for it once and letting every replica download
the result is strictly better than every replica recomputing the same packs.
Replicas trade bandwidth for CPU, which is the right trade when bandwidth is
elastic and CPU is the thing you are scaling reads with.

"Primary" is just the head of the rendezvous order. If two nodes both believe
they are it, nothing breaks: compaction lands through the same CAS as everything
else, so the loser is told `:raced` and does nothing. No lock, no election.

It is threshold-driven rather than scheduled. A repository nobody pushes to
should never pay for maintenance.

## Placement

Rendezvous (highest-random-weight) hashing over the live node set. Placement is
a pure function of the repository id and that set, so:

- there is no routing table to replicate or repair,
- two nodes seeing the same membership always agree,
- when a node leaves, only the repositories that named it move — every other
  assignment is untouched,
- when a node joins, it steals its share and nothing is reshuffled between
  existing nodes.

That last pair is what makes autoscaling free. Adding a pod changes the
membership, which silently reassigns a fraction of repositories; the new pod
materializes them on first request and the old ones evict them once idle. No
rebalancing job runs, because there is no balance to restore — placement was
never recorded, only computed.

Disagreement during a membership change is safe rather than merely tolerable.
Two nodes that both think they own a repository can both serve it and both
accept pushes, because the object store arbitrates.

## What the BEAM replaces

The reference design hand-rolls a fair amount of distributed-systems plumbing.
On the BEAM most of it already exists:

| Reference design | Micelio |
|---|---|
| UDP gossip packets for replication hints | `:pg` broadcast over distributed Erlang: TCP, ordered per pair, no loss handling needed |
| A health table and heartbeat protocol | `:net_kernel.monitor_nodes/2` and `net_ticktime` |
| Topology configuration | `libcluster` (Kubernetes, DNS, epmd) |
| Ad-hoc "which node is primary" | rendezvous hashing over live `:pg` membership |
| Retry and backoff plumbing for lost packets | supervision and monitors |
| Per-repository single-flight coordination | `Registry` + `DynamicSupervisor` + a GenServer mailbox |
| Cross-node introspection RPC | `:erpc.call/4` |

Hints stay **advisory** regardless. A replica never treats a hint as evidence of
anything; it treats it as a reason to go and re-validate against object storage.
Losing every hint in the cluster costs latency, never correctness. That is what
lets membership be approximate.

The genuinely novel part — the log, the compare-and-swap, the convergence rule —
is the part that had to be written.

## Consistency summary

- **Pushes are linearizable.** One CAS on one object decides the order.
- **Reads are consistent.** Every read re-validates against the source of truth
  before serving. `staleness_budget_ms` can relax this, and defaults to zero.
- **Durability is object storage's.** A push is acknowledged only once it is in
  the log; replica loss is not data loss.
- **Provenance is complete.** Every entry is retained, and every pre-compaction
  index is snapshotted, so every state a repository has ever been in is
  reconstructible.

## Where the limits are

- **Per-repository write throughput is bounded by object store latency.** Each
  push is at least one conditional GET and one conditional PUT. A single hot
  repository will not scale past what one CAS chain can sustain, which is why
  the CAS retry count is a metric worth watching.
- **Read throughput scales linearly with replicas** and is bounded by nothing in
  particular, which is the point.
- **Compaction is the one expensive operation** and is why the primary concept
  exists at all.
