# Multi-tenancy, authentication and authorization

The question this page answers: can a system with no control plane host
mutually distrusting tenants? Mostly yes, and the parts that do not fit are
worth naming rather than glossing over.

## Where the tenant boundary is

A repository id is `account/name`, and the account is the tenant. It is the
prefix of the object storage key, the first segment of every authorization
pattern, and the namespace of the policy object. Nothing else needs to know
about tenancy:

```
repos/acme/app/index.pb        acme's repository
accounts/acme/policy.pb        acme's authorization policy
```

Because placement is a hash of the repository id, tenants are spread across
nodes rather than pinned to them. That is deliberate: pinning would make
capacity planning per-tenant, which is a control plane by another name.

## Authentication: necessarily external

Micelio validates tokens and never issues them. This is not a simplification;
it is the only arrangement that keeps the node stateless. Minting an identity
requires a secret somebody holds, and holding it would make a node
authoritative about something.

So Micelio is an OAuth 2.1 **resource server**. It verifies a signature against
the issuer's public keys, checks that the token names *this* deployment in its
`aud`, and turns the result into a subject. Any OIDC issuer works: your own,
your customers', or the Kubernetes cluster's.

The last one is what makes the model practical for machines. A pod's projected
service account token is already an OIDC JWT the cluster will vouch for, so an
agent authenticates with a credential it was born with, and nothing has to be
created, distributed or rotated. See [kubernetes.md](kubernetes.md).

### One issuer per deployment (today)

A deployment verifies against a single issuer. That covers the common shapes —
one company's IdP, or a Kubernetes cluster vouching for its own pods — and
tenants are then separated by subject, through namespace grants or policy
bindings.

**Tenants bringing their own identity providers is not implemented.** It is not
a large change: the key id in a token already selects which signing key
verifies it, so a set of issuers could be tried by `kid` and the `iss` claim
checked against whichever one owned that key. But it does not exist, and until
it does, every tenant on a deployment must authenticate through the same
issuer.

## Authorization: data, not a service

Authentication answers *who*. Authorization answers *what*, and the usual
answers all reintroduce a control plane:

| Approach | Why it does not fit |
|---|---|
| Grants in token claims | Works, and is right for machine identities. But a claim is true until the token expires, so revocation waits out the token's lifetime |
| A permissions service | Something to deploy, keep available, and be down when it is down |
| A database per node | Authoritative state on a node, which is the thing this design refuses to have |

So policy goes where every other authoritative fact already lives: object
storage. A policy object is read with a conditional GET and updated with a
compare-and-swap — the same two operations the write-ahead log is built from.

```
PUT /policy/acme
{"subject": "alice@example.com",
 "repositories": ["acme/**"],
 "permissions": ["read", "write"]}
```

Every node can serve it, any node can change it, nothing has to be kept in
sync, and the object store arbitrates concurrent edits exactly as it does
concurrent pushes. Still no control plane.

Two properties fall out of this that a token-claims-only design does not have:

- **Revocation is immediate.** A binding removed here is gone on the next
  read, not when a token happens to expire.
- **Grants can be given to identities that cannot be reissued.** A customer's
  IdP is not going to add a `micelio_grants` claim for you.

Both sources compose: a principal may act if *either* the credential it
presented or the account's policy allows it. The policy is only consulted when
the token alone is insufficient, so the machine-identity path costs nothing.

Subjects may be patterns, so a whole class of identities can be bound in one
line — `system:serviceaccount:builders:*` covers every CI pod in a namespace
without enumerating them. Bindings may also carry an expiry, which is how you
grant an agent access for the duration of a task.

### Caching

Authorization is on the path of every request, so policies are cached per node
and revalidated with a conditional GET once `MICELIO_POLICY_STALENESS_BUDGET_MS`
elapses (five seconds by default). Unlike a repository read, where serving
stale data would be a correctness failure, this is a bounded and deliberate
window — and still far tighter than the token lifetime it replaces.

## What isolation you actually get

**Namespace isolation: yes.** Repository ids, storage keys and policy are all
account-scoped, and a repository the caller may not read is reported as *not
found* rather than *forbidden*, so the shape of one tenant's estate is not
discoverable by another. Verified on a cluster: a pod in one namespace cannot
reach another namespace's repositories, and is told they do not exist.

**Account ownership: not modelled.** There is no registry of which tenant owns
which account name. An account exists because a repository was created under
it, and whoever holds a grant matching `name/**` can do that. Within one
company that is fine — grants come from your IdP or your policy, and neither
hands out patterns carelessly. For a product where tenants sign themselves up,
it is a gap: nothing stops a tenant whose grants are broad from claiming a name
that should belong to someone else, and nothing records who claimed it.

**Credential isolation: yes.** Tokens are audience-bound to this deployment and
verified against the issuer configured for the account.

**Durability isolation: yes.** One tenant cannot affect another's data;
everything authoritative is in object storage under a distinct prefix.

**Resource isolation: partial, and this is the honest gap.** Nodes are shared,
so a tenant cloning a very large monorepo consumes connections, page cache and
disk that other tenants are also using. What exists today:

- `micelio_git_requests_in_flight` makes the load visible and autoscalable.
- Idle eviction bounds how much disk any one tenant's cold repositories hold.
- Compaction is threshold-driven, so an idle tenant never pays for it.

What does not exist: per-tenant request quotas, per-tenant bandwidth limits,
and per-tenant CPU confinement. `Micelio.Git.run_supervised/3` accepts a cgroup
to confine a command to, which is the hook a CPU limit would hang off, but
nothing passes one today.

For hostile multi-tenancy those are needed, and the natural place for them is
the same one everything else uses — a quota object per account, read the same
way. That is not implemented either.

**Storage isolation at the bucket level: not implemented.** Every tenant shares
one bucket under separate prefixes. Per-tenant buckets or per-tenant KMS keys
would need the object store configuration to be resolved per account rather
than per node. The `Micelio.ObjectStore` behaviour already takes its
configuration as an argument, so this is a small change, but it is a change.

## If tenants must not share nodes

Run a deployment per tenant. Nothing in the architecture assumes a single
cluster: placement is self-contained, the log is a bucket prefix, and a
deployment is a stateless Deployment plus a bucket. The reason to share is
efficiency, not capability — and for tenants that require hard isolation,
efficiency is the wrong thing to optimise for.
