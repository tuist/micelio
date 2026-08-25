# Factory work runs

Micelio can coordinate repository work as a durable directed graph. A work run
is an immutable graph specification plus a small mutable projection in object
storage. It is the coordination layer for a sandboxed worker, not a second
source of truth for Git history: the repository write-ahead log remains the
authority for source code.

This implementation owns graph creation, account inference-profile
configuration, claims, result acceptance, leases, cancellation, approvals,
immutable evidence, and observation. It does not provision a sandbox, hold a
model session, run a Kubernetes controller, or fetch a secret. A worker can
therefore be a simple test double today and a sandboxed production agent later
without changing the work-run protocol.

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

`operation` is a name selected by the worker deployment, not an Elixir module
or provider credential. The worker maps it to a locally allowed Condukt
operation, starts that operation in its own sandbox, and reports the attempt
outcome. This is intentionally compatible with a mocked worker: tests can
claim the node, make a deterministic code change, and report success with no
inference endpoint or session at all.

### Account secret backends and inference profiles

An account administrator first binds its account to the deployment-managed
[Infisical](https://infisical.com/) service. The binding is versioned and only
contains the tenant-facing project identifier:

```json
{
  "driver": "managed_infisical",
  "project": "acme-production"
}
```

The Infisical address, the workload-token audience, and the trust relationship
with the Kubernetes cluster are deployment configuration, not account input.
This prevents an account administrator from asking a sandbox to project a
workload token for an arbitrary receiver. Micelio does not create, rotate, or
delete Infisical machine identities.

An account administrator may then create a named inference profile and
reference it from an operation using `inference_profile`:

```json
{
  "execution": {
    "type": "condukt_operation",
    "operation": "implement_issue",
    "inference_profile": "coding"
  }
}
```

Micelio persists the endpoint, model, and a version-pinned, non-secret
credential binding. For example:

```json
{
  "endpoint": "https://inference.example.com/v1",
  "model": "coding-model",
  "credential_binding": {
    "backend": "production",
    "identity_id": "coding-machine-identity",
    "secret": {"reference": "/production/coding", "field": "api_key"}
  }
}
```

The binding pins the backend's immutable version with the profile. Secret
values, bearer tokens, provider endpoints, workload-token audiences, and user
information in inference endpoints are rejected.

Micelio does not resolve this binding. A work claim returns only the profile
name, version, inference endpoint, and model. It does not return the backend,
machine identity, or logical secret reference.

### Trusted runtime delivery

The Kubernetes provisioner and a Condukt egress proxy are outside Micelio and
are **not implemented by this repository**. Their required contract is:

1. The provisioner reads the immutable profile and backend configuration from
   object storage using the profile version already pinned in the work-run
   specification. It derives the Kubernetes service account from that
   configuration, not from the worker's claim payload.
2. Only the egress proxy receives that service account's projected token. The
   repository-command container and the Condukt agent process do not receive
   it.
3. The proxy exchanges the projected token directly with the managed Infisical
   service, obtains the inference credential, and injects it into the outbound
   inference request. It never exposes the credential to the model, tool
   environment, session history, or Micelio.

This arrangement means the secret manager and Kubernetes are runtime
dependencies for factory work, but not for Git clone, fetch, push, or Micelio
claim coordination. A later backend driver can extend the account backend
schema without changing the graph or storage semantics.

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
accounts/acme/factory/inference-profiles/coding/current.json
accounts/acme/factory/inference-profiles/coding/versions/<profile-version>.json
accounts/acme/factory/secret-backends/production/current.json
accounts/acme/factory/secret-backends/production/versions/<backend-version>.json
```

Specifications, claims, results, and events are immutable. `state.json` is the
only mutable object, advanced with an object-store conditional write. Multiple
workers may race to claim work. They may leave unreferenced claim or event
objects, but only the state version that wins is canonical and only its event
ids are returned to clients. A result is accepted only when its attempt id is
still the current attempt for that node. Cancelling a run prevents a running
attempt from becoming accepted, while preserving its evidence if it uploads it.

Inference-profile versions are immutable too. `current.json` is their only
mutable pointer and changes through the same conditional-write rule. A run
pins the selected version when it is created, so later profile rotation cannot
silently change work already in progress. A lost profile-update race may leave
an unreferenced immutable version, but cannot overwrite a pinned one.

Leases are advisory. Each immutable claim records its expiry time, and an
authorized reconciler can requeue a running node after that deadline. It never
deletes the old claim or result. A worker that reports after requeue has its
immutable result retained as rejected evidence, rather than silently losing it.

If a node fails, the work run becomes failed, and nodes that have not started
are marked `skipped`. A still-running sibling may report evidence, but cannot
change the terminal outcome.

## Observation and control

The [Representational State Transfer API](https://en.wikipedia.org/wiki/REST)
is under `/api/work-runs`, `/api/inference-profiles`, and
`/api/secret-backends`, and is described by `/api/openapi.json`. It provides
creation, list and get, events, attempts, claim, complete, approval, expiry,
cancellation, and account configuration. Existing repository read permission is
required to observe a run. Repository write permission creates work. Repository
`execute` permission claims and completes work, but does not reveal a profile's
credential binding. Repository administrator permission approves, expires, and
cancels work. Account configuration additionally requires an administrator
grant spanning the whole account, for example `acme/**`; an administrator grant
on one repository is insufficient.

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
`get_work_attempt`, as well as `configure_secret_backend`,
`list_secret_backends`, `get_secret_backend`,
`configure_inference_profile`, `list_inference_profiles`, and
`get_inference_profile` for account administrators.

Events are revision-cursored immutable records. A client can poll events after
the most recent `next_cursor`, reconstruct the canonical graph state, and link
attempt evidence to its corresponding work. Streaming logs, sandbox telemetry,
and a worker reconciler are not implemented yet.
