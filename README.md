# Micelio

Git hosting whose source of truth is a write-ahead log in object storage, not a
disk.

Micelio serves the ordinary Git smart-HTTP protocol, so `git clone`, `git push`
and every tool built on them work unchanged. What is different is where the
authoritative copy of a repository lives. A node's on-disk repository is a warm
cache; the log in S3 is the repository. That one inversion is where everything
else comes from.

```
                 ┌──────────────────────────────────────┐
                 │        object storage (S3)           │
                 │                                      │
                 │  repos/<id>/index.pb    ← CAS'd      │
                 │  repos/<id>/wal/*.pb    ← immutable  │
                 │  repos/<id>/packs/*     ← immutable  │
                 └───────────▲──────────────▲───────────┘
                             │              │
        conditional GET      │              │  compare-and-swap
        (304 = serve now)    │              │  (decides push order)
                             │              │
        ┌────────────────────┴──┐   ┌───────┴───────────────┐
        │  node A               │   │  node B               │
        │  warm cache on NVMe   │   │  warm cache on NVMe   │
        │  git / MCP / admin    │   │  git / MCP / admin    │
        └───────────────────────┘   └───────────────────────┘
                     └──── distributed Erlang ────┘
                        membership + replication hints
```

## Why this shape

**Replicas are disposable.** Everything a node holds can be rebuilt from the
log, so there is nothing to repair. A crashed node, an evicted repository and a
brand-new pod all take the same code path: materialize from the log.

**Placement is computed, not stored.** Rendezvous hashing maps a repository id
and the live node set to a list of nodes. No routing table, no placement
database, nothing to keep consistent. Two nodes that see the same membership
always agree, and when they briefly disagree it is harmless.

**Any node can accept a push.** Ordering is decided by one compare-and-swap on
one object, not by a quorum. There is no primary to elect and no consensus
round to wait for.

**Reads are consistent without coordination.** Before serving, a replica
re-validates its cached view of the log with a conditional GET. A `304` is a
metadata-only round trip and means serve immediately; a `200` means catch up
first. Each replica is individually consistent with the source of truth, which
makes them trivially consistent with each other.

**Replica count is a dial, not a constraint.** A monorepo absorbing CI load can
name a hundred nodes. A repository an agent created thirty seconds ago can name
one, because losing that one replica loses nothing.

**There is no control plane.** Not "the control plane is small" — there isn't
one. Every node answers every question, because no answer comes from state a
node owns. That is what lets Micelio be a plain Kubernetes Deployment behind a
round-robin Service, autoscaled like any stateless workload.

## What it gives you

- **Git smart HTTP** — clone, fetch, push, protocol v2, partial clone.
- **An MCP server** — a headless Git forge for agents: read files, search, read
  history, and commit, all without cloning. See [docs/mcp.md](docs/mcp.md).
- **OAuth 2.1 resource server** — validates tokens, never issues them. In
  Kubernetes an agent authenticates with the projected service account token it
  was born with, so no secret is ever distributed, and authorization lives in
  object storage rather than in a service. See
  [docs/kubernetes.md](docs/kubernetes.md) and
  [docs/multi-tenancy.md](docs/multi-tenancy.md).
- **Prometheus metrics and OpenTelemetry traces** — including the signals worth
  autoscaling on.

## Quick start

```sh
mise install       # Erlang, Elixir, protoc, shellspec
mise run setup     # deps and compile
mise run server    # a single node against a local filesystem object store
```

Then, in another shell:

```sh
curl -X POST localhost:4002/repositories \
  -H 'content-type: application/json' \
  -d '{"repository":"acme/app"}'

git clone http://x-access-token:dev-token@localhost:4000/acme/app.git
```

To run against real object storage, start MinIO and point at it:

```sh
mise run e2e:up    # MinIO plus two clustered nodes
mise run e2e       # the end-to-end suite, against a live server and real S3
mise run e2e:down
```

Or bring up the whole system in containers, which is the closest thing to how
it actually runs:

```sh
docker compose up --build -d
```

## Documentation

| | |
|---|---|
| [Architecture](docs/architecture.md) | How the log works, and why there is no consensus protocol |
| [Operations](docs/operations.md) | Configuration, metrics, failure modes, capacity |
| [Kubernetes](docs/kubernetes.md) | Deploying, autoscaling, and authenticating pods |
| [MCP](docs/mcp.md) | The agent-facing surface |
| [Multi-tenancy](docs/multi-tenancy.md) | Authentication, authorization, and what isolation you actually get |

## Development

```sh
mise run test      # unit tests
mise run e2e       # end-to-end, needs Docker for MinIO
mise run lint      # formatting and Credo
mise run proto     # regenerate the log schema after editing priv/proto
```

[`AGENTS.md`](AGENTS.md) covers the conventions this codebase depends on —
why every test is `async: true`, which commands are safe to run under MuonTrap,
and the handful of landmines that have already cost someone a day.

## Prior art

The architecture follows the one Cursor described in [Git at any
scale](https://cursor.com/blog/git-at-any-scale), which in turn is a reaction to
GitHub's Spokes. The substantial difference here is the runtime: on the BEAM,
cluster membership, failure detection and reliable broadcast already exist, so
Micelio uses distributed Erlang and `:pg` where the original design hand-rolls
UDP gossip and a health table. What is left is the part that genuinely needs
writing: the log, the compare-and-swap, and the convergence rule.

## License

Copyright 2026 Tuist GmbH. Mozilla Public License 2.0, see [LICENSE](LICENSE).

MPL-2.0 is file-level copyleft: changes to Micelio's own source stay open, but
it can be deployed alongside and linked from code under any license, including
proprietary. Running a modified Micelio as a service does not oblige you to
publish anything beyond the modified files themselves.
