# Factory work runs

Micelio can coordinate repository work as a durable directed graph. A work run
is an immutable graph specification plus a small mutable projection in object
storage. It is the coordination layer for a sandboxed worker, not a second
source of truth for Git history: the repository write-ahead log remains the
authority for source code.

This first implementation owns graph creation, claims, result acceptance,
leases, cancellation, approvals, immutable evidence, and observation. It does
not provision a sandbox, select a model, hold a model session, or run a
Kubernetes controller. A worker can therefore be a simple test double today
and a sandboxed production agent later without changing the work-run protocol.

## Graph format

The graph is stored in the run, so changing a repository template later cannot
change work already started. Each node has an id, title, kind, and dependencies.
Supported kinds are `agent`, `command`, `evaluate`, and `approval`. An approval
node waits until an authorized caller approves it. Other nodes become ready
when all their dependencies succeed.

An `agent` node may carry a [Condukt](https://github.com/tuist/condukt)
operation contract:

```json
{
  "id": "implement",
  "kind": "agent",
  "title": "Implement the issue",
  "execution": {
    "type": "condukt_operation",
    "operation": "implement_issue",
    "input": { "issue": 42 },
    "output_schema": { "type": "object" }
  }
}
```

`operation` is a name selected by the worker deployment, not an Elixir module,
provider credential, or model choice. The worker maps it to a locally allowed
Condukt operation, starts that operation in its own sandbox, and reports the
attempt outcome. This is intentionally compatible with a mocked worker: tests
can claim the node, make a deterministic code change, and report success with
no inference endpoint or session at all.

Micelio accepts a base commit only when it is the current head of a public
repository reference at creation time. When a worker claims a node, Micelio
returns that frozen repository id, commit, optional issue number, and normalized
node definition. The worker must use that exact revision. It records any durable
outputs as artifact references; Micelio does not accept pod-local files as
evidence.

## Storage and races

For a repository `acme/app` and run `r1`, the object-store layout is:

```
factory/acme/app/runs/r1/specification.json
factory/acme/app/runs/r1/state.json
factory/acme/app/runs/r1/events/<event-id>.json
factory/acme/app/runs/r1/attempts/<attempt-id>/claim.json
factory/acme/app/runs/r1/attempts/<attempt-id>/result.json
```

Specifications, claims, results, and events are immutable. `state.json` is the
only mutable object, advanced with an object-store conditional write. Multiple
workers may race to claim work. They may leave unreferenced claim or event
objects, but only the state version that wins is canonical and only its event
ids are returned to clients. A result is accepted only when its attempt id is
still the current attempt for that node. Cancelling a run prevents a running
attempt from becoming accepted, while preserving its evidence if it uploads it.

Leases are advisory. Each immutable claim records its expiry time, and an
authorized reconciler can requeue a running node after that deadline. It never
deletes the old claim or result. A worker that reports after requeue has its
immutable result retained as rejected evidence, rather than silently losing it.

If a node fails, the work run becomes failed, and nodes that have not started
are marked `skipped`. A still-running sibling may report evidence, but cannot
change the terminal outcome.

## Observation and control

The [Representational State Transfer API](https://en.wikipedia.org/wiki/REST)
is under `/api/work-runs` and is described by `/api/openapi.json`. It provides
creation, list and get, events, attempts, claim, complete, approval, expiry,
and cancellation. Existing repository read permission is required to observe a
run. Repository write permission creates, claims, and completes work; repository
administrator permission approves, expires, or cancels it. A dedicated
execution permission is not implemented yet, so a sandbox worker should use a
scoped write credential only until that policy capability exists.

The verified principal that completes an attempt must be the same principal
that claimed it. A repository administrator can cancel or approve work, but
cannot forge the claimed worker's result. A result reported after a terminal
run is retained as immutable rejected evidence and never becomes the node's
accepted result.

Completion is replay-safe: resubmitting the same attempt result returns its
original accepted or rejected disposition without adding another event.

The [Model Context Protocol](https://modelcontextprotocol.io/) exposes the same
contract through `create_work_run`, `list_work_runs`, `get_work_run`,
`work_run_events`, `claim_work_node`, `complete_work_attempt`,
`approve_work_node`, `cancel_work_run`, `expire_work_node`, and
`get_work_attempt`.

Events are revision-cursored immutable records. A client can poll events after
the most recent `next_cursor`, reconstruct the canonical graph state, and link
attempt evidence to its corresponding work. Streaming logs, sandbox telemetry,
and a worker reconciler are not implemented yet.
