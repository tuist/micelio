+++
title = "Maintenance work stays off the serving path"
description = "Micelio separates Git serving from compaction and lookup rebuilding without requiring a cluster leader."
template = "page.html"
+++

# 🧰 Maintenance work stays off the serving path

Micelio can now run Git serving and background maintenance on different nodes
without making either node authoritative.

## What changed

Nodes advertise the capabilities they perform. Serving nodes handle Git traffic;
maintenance nodes compact the write-ahead log and rebuild local multi-pack
lookup files. Rendezvous hashing chooses a preferred maintenance node for each
repository, while the object store's conditional write remains the final
authority.

## Why

Git repacking is deliberately expensive. Moving it off the clone and push path
keeps request-serving capacity predictable without introducing a cluster leader
or a separate control plane.

## Current scope

Compaction and local lookup rebuilding are active. Bundle creation and external
event delivery have reserved capabilities, but remain unavailable until their
public contracts are defined.
