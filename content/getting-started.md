+++
title = "Getting started"
template = "page.html"
+++

# 🚀 Getting started

Run Micelio locally with one node and a filesystem-backed object store.

```sh
mise install
mise run setup
mise run server
```

Create a repository, then use it with the Git client you already have:

```sh
curl -X POST localhost:4002/repositories \
  -H 'content-type: application/json' \
  -d '{"repository":"acme/app"}'

git clone http://x-access-token:dev-token@localhost:4000/acme/app.git
```

When you are ready to deploy, follow the [hosting guide](/hosting/).
