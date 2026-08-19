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

Nothing is acknowledged before step 3 succeeds, so a client is never told "yes"
for something the log does not have. The converse is not true, and it is worth
being precise about rather than glossing:

**A push can be reported as rejected and still be committed.** Two windows
produce it. If the store commits the index write and the response is lost, the
node cannot tell that from losing the race — so the entry's content address is
checked on retry, and an entry already installed is reported as the success it
was. If the hook returns success but `receive-pack` then fails to install refs
locally, the log has the push and this node does not; every other replica makes
it visible, and this one converges on its next read.

So the honest statement of the contract is *log-first*: the log decides, and a
hook failure means "this node did not commit it", not "it never happened". No
sequence loses a push or produces a ref value neither client asked for, but a
client can see a failure for a push that landed. Recovering is a fetch.

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

### Why not Horde, Swarm, syn or libring

The ecosystem's clustering libraries are good, and none of them fit, for one
reason: they all solve *global process uniqueness*, and Micelio does not want
it.

[Horde](https://github.com/elixir-horde/horde), [Swarm](https://github.com/bitwalker/swarm)
and [syn](https://github.com/ostinelli/syn) exist to guarantee that a given key
maps to exactly one process somewhere in the cluster, and to keep a replicated
registry saying where. Horde does it with a δ-CRDT; on netsplit heal it picks a
winner for each contested name and sends the loser an exit signal. syn does it
with its own replication and conflict resolution. That machinery is the whole
value proposition, and it is precisely what we would have to fight.

Two nodes serving the same repository at the same time is not a conflict here.
It is the steady state — that is what a replica *is*. Two nodes accepting
pushes for the same repository at the same time is also fine, because ordering
is decided by a compare-and-swap in object storage rather than by which process
holds a name. Adopting a distributed registry would mean installing an
invariant we do not want, paying for the replicated state that maintains it,
and then explaining why its netsplit resolution keeps killing healthy replicas.

`:pg` is the right level. It answers "which nodes are ready to serve", which is
all placement needs, and it is in OTP rather than a dependency. Its documented
weakness — membership views are strongly eventually consistent and not
transitive during a partition — is harmless here, because a wrong membership
view produces a suboptimal *placement*, never an incorrect *result*: whoever
ends up serving still verifies against the log.

[libring](https://github.com/bitwalker/libring) is the closest thing to a
drop-in for the placement half, but it implements consistent hashing (ketama)
rather than rendezvous. Consistent hashing needs virtual nodes to balance
acceptably and does not naturally yield an ordered top-N, which is exactly what
a replica list is. Rendezvous gives that ordering for free, has better balance
without tuning, and fits in about fifteen lines — see
`Micelio.Cluster.Rendezvous`.

### The known ceiling

Distributed Erlang is a full mesh: every node connects to every other, so
connections grow with the square of the cluster and the failure detector gets
chattier as it grows. In practice this is comfortable into the low hundreds of
nodes and stops being comfortable somewhere after that.

If a single cluster ever needs to exceed that, the answer is
[Partisan](https://github.com/lasp-lang/partisan) — an alternative distribution
layer with non-mesh topologies — and not a registry library, which would not
address the constraint at all. Nothing in this design assumes a single global
cluster, though: rendezvous hashing makes each cluster self-sufficient, so one
cluster per region against a regional bucket is the simpler answer to the same
problem.

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

## Write throughput

A push costs one conditional read and one conditional write of the index. Left
alone, concurrent pushes to one repository contend for the same
compare-and-swap: most lose, re-read and retry, so adding writers makes each
one slower without making the repository faster.

The instinct is to elect a writer so that everyone agrees who may commit. That
is the expensive answer. An election has to conclude before anything can be
written, and a partition stalls writes until it does — trading away exactly the
availability the rest of the design works to keep.

What is needed is weaker than agreement. Rendezvous hashing already names a
*preferred* writer, computed identically on every node from the live
membership, with no agreement round at all. Routing writes there concentrates
them on one process, and that process can then batch:

```
    push A ─┐
    push B ─┼─► writer ──► one read, one compare-and-swap ──► seqs 7, 8, 9
    push C ─┘
```

Each push still uploads its own packs and its own entry object first — those
are content-addressed, so they never contend and they happen wherever the push
arrived. Only installing the pointers is serialized, and that costs the same
one round trip whether the batch holds one push or fifty.

The batching is implicit rather than timed: the writer commits whatever has
arrived, and anything that arrives during that round trip forms the next batch.
Under light load nothing waits; under heavy load batches grow exactly as fast
as contention would otherwise have grown. There is no timer to tune.

Crucially the routing is a **hint, not a rule**. Being wrong about who the
writer is costs nothing, because the batch still lands through the same
compare-and-swap that already handles two nodes writing at once. When the
preferred node is unreachable, the receiving node simply commits for itself.
That is the difference between this and an election: there is no state to be
inconsistent about, so there is nothing to repair when the answer changes.

Entries within a batch are validated in order against the index as it evolves,
so the result is identical to having processed them one at a time — including
rejecting a push that a peer in the same batch just invalidated.

See `Micelio.Ingest.Writer`.

## Where the limits are

- **A single repository's writes are still bounded by object store latency**,
  now per batch rather than per push. Group commit raises the ceiling by the
  batch size; it does not remove it.
- **Read throughput scales linearly with replicas** and is bounded by nothing in
  particular, which is the point.
- **Compaction is the one expensive operation** and is why the primary concept
  exists at all.
