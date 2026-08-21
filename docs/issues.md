# Issues

An issue belongs to the same repository as its source code. It is not stored in
a shared service or in a database on a node's local disk.

## Storage and durability

Micelio stores issue state in the repository's private
`refs/micelio/issues` Git reference. Every create, change, comment, or delete
operation creates a Git commit in that reference and sends its objects through
the normal write-ahead log path. Object storage is therefore the source of
truth for issue history as well as source history; a node can rebuild either
after its local repository directory is lost.

Each commit contains two forms of data:

- a small current-state projection, for efficient reads;
- an immutable issue or comment event, including the verified caller identity
  and the time of the operation.

The commit's Git author is the Micelio service. The event actor is the
authenticated principal, so a client cannot forge authorship with a Git author
header.

Issue and comment deletion writes a tombstone. The item no longer appears in
current views, while the immutable history remains available to authorized
readers.

The reference is hidden from Git advertisement and fetch, cannot be updated by
Git push, and is rejected by ordinary agent source-code tools. It is reserved
for Micelio's own issue implementation.

## Concurrency

An issue mutation is conditional on the current private-reference commit. If
another mutation wins first, Micelio rereads the projection, rebuilds the
change, and retries. The repository's existing writer serializes competing
object-storage compare-and-swap operations, so this requires no separate
leader or issue database.

## Interfaces and authorization

The [Model Context Protocol](https://modelcontextprotocol.io/) exposes issue
and comment create, read, update, and delete operations, plus issue listing
and immutable history. Calls that only read require repository `read`
permission; mutations require `write` permission.

The same operations are available over the
[Hypertext Transfer Protocol](https://developer.mozilla.org/en-US/docs/Web/HTTP):

| Operation | Endpoint |
|---|---|
| List and create issues | `GET`, `POST /api/issues?repository=<id>` |
| Read, change, or delete an issue | `GET`, `PATCH`, `DELETE /api/issues/{issue}?repository=<id>` |
| List and add comments | `GET`, `POST /api/issues/{issue}/comments?repository=<id>` |
| Read, change, or delete a comment | `GET`, `PATCH`, `DELETE /api/issues/{issue}/comments/{comment}?repository=<id>` |
| Read immutable history | `GET /api/issues/{issue}/history?repository=<id>` |

The [OpenAPI](https://spec.openapis.org/oas/latest.html) description is
available at `GET /api/openapi.json`. Hypertext Transfer Protocol requests use
the same bearer-token authentication and per-repository authorization as Git
and the Model Context Protocol. A caller without read access receives `404` for
a repository, preserving the existing non-enumeration behavior.
