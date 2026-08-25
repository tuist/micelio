+++
title = "A clearer view of a running node"
description = "Micelio now connects traces, metrics, and logs across its request, replication, and object-store work."
template = "page.html"
+++

# 👀 A clearer view of a running node

When a Git request is slow or a replica needs to catch up, operators need to
see the work as one connected story. Micelio now records that story across
requests, background work, and the object store.

## What changed

Public requests, Git pushes, replica refreshes, synchronization, and
object-store operations now emit [OpenTelemetry](https://opentelemetry.io/docs/)
spans. Prometheus metrics now cover request latency, counts, byte sizes,
exceptions, and object-store calls. Their labels are deliberately bounded, so a
repository identifier or request path cannot turn the metrics endpoint into an
unbounded data store.

Logs for the same work are structured and include trace and span identifiers
when a trace is active. This makes a failed request or a slow replication run
easier to follow from a metric to the relevant log records.

## Why

Micelio is designed to serve Git traffic while rebuilding its local state from
the write-ahead log. That makes visibility into both serving and recovery work
part of operating the system safely, especially when a problem crosses a
request, a replica, and object storage.
