# MCP: a headless Git forge for agents

Every Micelio node serves the Model Context Protocol at `POST /mcp`, alongside
the Git protocol on the same port.

The premise is that an agent usually does not want a working tree. It wants to
read a file at a revision, search for a symbol, look at history, and commit a
change. Each of those is a Git plumbing command against a repository the node
can materialize on demand, so exposing them costs almost nothing and removes the
clone entirely.

## Connecting

```json
{
  "mcpServers": {
    "micelio": {
      "url": "https://micelio.example.com/mcp",
      "headers": { "Authorization": "Bearer ${MICELIO_TOKEN}" }
    }
  }
}
```

Transport is Streamable HTTP. `GET /mcp` returns `405`: Micelio never initiates
messages, so there is nothing a server-to-client stream would carry.

## No sessions, and why that matters

Micelio keeps no session state. `Mcp-Session-Id` is echoed if a client sends one
so client-side correlation works, but nothing on the server depends on it.

This is deliberate. A session store would be the one piece of cluster-wide
mutable state the architecture has otherwise avoided, and it would need
replicating, expiring and reconciling. Without it, an agent can be
load-balanced across pods mid-conversation and nothing breaks — a plain
round-robin Service is enough, with no affinity rules and no sidecar router.

## Every call routes itself

Tool calls go through rendezvous hashing to whichever node already holds the
repository, over `:erpc`. So an agent talks to *any* pod, and the work happens
where the data already is. If that node is unreachable the call falls through to
the next candidate; if none are, it is served locally, because correctness comes
from the log rather than from placement.

Concretely: a hundred agents hitting a hundred pods for the same monorepo do not
cause a hundred materializations.

## Tools

### Reading

| Tool | |
|---|---|
| `list_repositories` | What the caller may read |
| `describe_repository` | Log state, default branch, size, replica placement |
| `list_refs` | Branches and tags with their object ids |
| `read_file` | A file's contents at a revision |
| `list_tree` | Directory entries at a revision, optionally recursive |
| `search` | `git grep` server-side, at a revision |
| `log` | Commit history, optionally for one path |
| `diff` | Unified diff between two revisions |
| `history` | The write-ahead log itself: who pushed what, when |
| `clone_url` | For when the agent genuinely does want a working tree |

Everything takes an optional `ref` and defaults to the repository's default
branch.

### Writing

| Tool | |
|---|---|
| `create_repository` | Cheap: a repository is one object until something is pushed |
| `commit` | Write files and commit them, without a working tree |
| `create_branch` | Point a branch at a commit |
| `delete_branch` | |

`commit` is the interesting one:

```json
{
  "name": "commit",
  "arguments": {
    "repository": "acme/ios-app",
    "branch": "agent/fix-crash",
    "message": "fix: guard against nil user",
    "changes": [
      { "path": "Sources/App/User.swift", "content": "..." },
      { "path": "Sources/App/Old.swift" }
    ],
    "expected_head": "a1b2c3..."
  }
}
```

A change with no `content` deletes the file. `encoding: "base64"` carries binary
content. `expected_head` makes the write conditional, so a concurrent change
fails the call rather than being clobbered.

**Writes take the same road as `git push`.** The tool builds a tree and a commit
with plumbing, then goes through the same ingest path: the same
compare-and-swap, the same non-fast-forward checks, the same durability
guarantee. There is no side door that bypasses the log. When the call returns,
the commit is durable and ordered.

## Errors

An ordinary failure — a branch moved, a file is missing — comes back as a tool
result with `isError: true`, not a JSON-RPC error. The model needs to see it and
react; aborting the conversation over a missing file would be wrong.

JSON-RPC errors are reserved for protocol problems: unknown methods, malformed
requests, unsupported protocol versions.

## Authorization

Grants are patterns, and a repository the caller may not read is reported as
**not found** rather than forbidden. Distinguishing the two would let an agent
enumerate which repositories exist, which on a multi-tenant host leaks the shape
of every customer's estate. `list_repositories` filters to what the principal can
actually read, for the same reason.

Discovery follows OAuth 2.1: a `401` carries

```
WWW-Authenticate: Bearer realm="micelio",
  resource_metadata="https://micelio.example.com/.well-known/oauth-protected-resource"
```

and that document names the authorization servers and this deployment's resource
identifier. An MCP client can therefore find out where to get a token instead of
being handed one out of band.

Micelio validates tokens and never issues them. See
[kubernetes.md](kubernetes.md) for how a pod authenticates with a credential it
was born with.

## Resources

Two templates, rather than an enumeration:

```
micelio://{repository}/refs
micelio://{repository}/blob/{ref}/{path}
```

Listing every repository as a resource would be a poor trade at any real scale;
the tools are the intended surface.
