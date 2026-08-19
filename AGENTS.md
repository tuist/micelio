# Working on Micelio

Instructions for coding agents working *on this repository*. Micelio is also a
Git forge *for* agents, so both readings of the filename exist here; if you are
looking for the tools an agent calls over MCP, that is [`docs/mcp.md`](docs/mcp.md).

## The one invariant

The write-ahead log in object storage is the source of truth. Everything on a
node's disk — the Git repository, the packfiles, the refs, the cached index — is
a warm cache that can be deleted at any moment and rebuilt from the log.

Nearly every design question resolves against that sentence. If a change makes a
node's local disk authoritative for anything, it is wrong, however convenient.
Read [`docs/architecture.md`](docs/architecture.md) before changing anything
under `lib/micelio/wal/`, `lib/micelio/replica/` or `lib/micelio/ingest/`.

## Commands

```sh
mise run setup     # deps, first time
mise run test      # unit tests
mise run e2e       # end-to-end against a real server and real S3; needs Docker
mise run lint      # mix format --check-formatted, then Credo --strict
mise run proto     # regenerate schemas after editing priv/proto
mise run server    # a single node, locally
```

`mise run lint` and `mise run test` both have to pass before you commit. The e2e
suite is slower and needs Docker, but run it for anything touching the Git
protocol, the object store, replication or auth — it is the only place the real
S3 semantics and the real `git` client are exercised.

## Tests

**Every test is `async: true`, and it has to stay that way.** This is not
incidental: the interesting behaviour here is what happens when two writers race,
and a suite that cannot run in parallel accumulates shared state that hides
exactly those bugs.

What makes it safe, and what you must preserve:

- Configuration is **process-local**. `Micelio.Config.put_overrides/1` gives each
  test its own object store, data directory and node id. Never read configuration
  through a global that a test cannot override.
- Repository ids are **unique per test** (`Micelio.Case` provides `repo/1`). The
  replica registry is global, so two tests sharing an id share a process.
- Cleanup is **scoped** to the replicas a test started, never all of them.

Use `Mimic` for stubbing, always in private mode (`setup :set_mimic_private`) —
a global stub would replace the object store for every other test running
concurrently. Stub as little as possible: today only the object store is stubbed,
and only for failures that cannot be provoked with a real one, such as sustained
compare-and-swap contention or corruption on the wire.

Prefer a test that asserts a **property** over one that measures a symptom. There
is a worked example of why in `test/micelio/wal_test.exs`: an attempt to catch
pack buffering by measuring memory passed against the buggy implementation,
because refc binaries are freed before they can be sampled. The test that works
asserts the pack path never calls the buffering API at all.

## Landmines

These are all things that have already cost someone a day.

- **Never hold a packfile in memory.** A pack is as large as a customer's
  history, so buffering one makes this node's memory ceiling somebody else's
  decision. Use `ObjectStore.put_file/3`, `get_file/3` and `digest_file/1`. A
  test enforces this.
- **MuonTrap only for output-free commands.** Capturing output through MuonTrap
  kills the calling process with `:epipe` on Linux, reproducibly. `Micelio.Git`
  uses it for `repack` and nothing else; everything that reads output goes
  through `System.cmd` inside `isolated/2`, and streaming goes through a raw Port.
- **Never hand-edit `*.pb.ex`.** Edit `priv/proto/**` and run `mise run proto`.
- **Helm values that are numbers need `int64`.** A bare large integer renders as
  `2.68435456e+08` in the manifest and Kubernetes rejects it.
- **`enableServiceLinks: false` must stay set.** Otherwise Kubernetes injects
  `MICELIO_ADMIN_PORT=tcp://10.x.x.x:9000` and clobbers our own configuration
  environment variables.
- **Modules are `Micelio.*`, never `Tuist.*`.** The project carries its own name;
  the organisation does not prefix it.

## Auth

Authentication and authorization both happen **in-process, on every node**, with
no control plane. A node answers from a cached JWKS and from per-account policy
it reads out of the same object store as the log. Anything that introduces a
service which must be reachable for a clone to succeed is a departure from the
design and needs to be argued for, not assumed.

`Micelio.Auth.Webhook` is the one existing exception, and it is opt-in.

## Docs

`docs/` describes what the code does, not what we would like it to do. A claim in
there is a promise someone will rely on when operating a cluster. If you document
behaviour that is not implemented, mark it explicitly as not implemented — there
has already been one commit whose entire purpose was removing three claims about
multi-tenancy that were not true.

## Commits

Conventional commits, and they are load-bearing: merging to `main` publishes a
release automatically. `feat:` cuts a minor version, `fix:` cuts a patch, and
git-cliff turns the subject line into the public release notes. So write the
subject for someone reading a changelog, and do not use `feat:` for a refactor.

Commit bodies are the right place for the reasoning: what was tried, what was
rejected, and how the change was verified.
