+++
title = "Use it with agents"
template = "page.html"
+++

# 🤖 Use it with agents

Micelio has a [Model Context Protocol](https://modelcontextprotocol.io/)
endpoint at `POST /mcp`. An agent can read a file at a revision, search a
repository, inspect history, or create a commit without cloning a working tree.

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

The everyday tools are `list_repositories`, `read_file`, `search`, `log`,
`create_repository`, and `commit`. A commit takes an expected branch head, so
an agent cannot quietly overwrite a concurrent change.

The full list of tools and the protocol details live in the
[agent-facing reference](https://github.com/tuist/micelio/blob/main/docs/mcp.md).
