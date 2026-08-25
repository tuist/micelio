+++
title = "Repository work can now run as a durable graph"
description = "Micelio coordinates sandboxed repository work through durable, leaderless graph runs."
date = "2026-08-25"
template = "page.html"
+++

# 🤖 Repository work can now run as a durable graph

Work should not disappear when a sandbox finishes or a worker goes away.

Micelio can now coordinate repository work as a durable graph. A work run
starts from a frozen source commit, exposes ready nodes to workers, and keeps
the claim, result, and evidence in object storage.

## What changed

Workers claim one ready node at a time. Conditional object-storage writes make
that safe without a leader, even when multiple workers race through different
nodes.

A node can name a Condukt operation and its input. An account administrator
can now also configure a named, versioned inference profile. It persists an
endpoint, model, and non-secret credential-delivery contract. Runs pin the
profile version they select, and Micelio returns it only to a worker with
execution permission after it claims work.

Micelio never stores a model credential or conversation. The worker reports
artifacts and an outcome when it is done, and Micelio retains the evidence even
when a lease expires or a run is cancelled.

The application programming interface and Model Context Protocol both expose
the same graph, event history, claims, and attempt evidence.

## Why

We want agents to work on repositories continuously without turning a running
pod into the source of truth. The graph makes the work visible and recoverable:
an operator can see what is ready, running, approved, failed, or skipped from
any node.

## Current scope

Micelio coordinates work but does not provision a sandbox, start a model
session, resolve a secret-manager credential, or select a model provider. That
boundary keeps worker credentials and sessions inside the worker environment,
while the durable coordination contract stays portable.
