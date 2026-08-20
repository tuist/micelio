+++
template = "index.html"
+++

# Micelio

Git hosting with no disk to trust.

Micelio speaks ordinary Git: clone, fetch, push, and every tool built on them
works as usual. The difference is where the authoritative copy lives. It is a
headless forge whose source of truth is a write-ahead log in object storage, so
each node's local repository is only a cache.

Micelio starts with Cursor's
[Git at any scale](https://cursor.com/blog/git-at-any-scale), then adapts that
idea to the Erlang runtime.

Start with the guide that matches what you need to do. The detailed design notes
remain in the repository for when you need them.
