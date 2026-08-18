defmodule Micelio do
  @moduledoc """
  Micelio is Git hosting whose source of truth is a write-ahead log in object
  storage, not a disk.

  That single inversion is where everything else comes from:

    * A node's on-disk repository is a warm cache. It can be evicted, corrupted
      or lost with the machine, and nothing needs repairing — the next request
      rebuilds it from the log.
    * Placement is a pure function of the repository id and the live node set
      (`Micelio.Cluster.Rendezvous`). There is no routing table to replicate
      and no membership consensus to run.
    * Any node can accept a push, because ordering is decided by a
      compare-and-swap on one object rather than by a quorum.
    * Reads are consistent without coordination: a replica re-validates its
      cached view of the log before serving. A `304` costs a metadata round
      trip; a `200` means catch up first.
    * A repository can have one replica or a hundred, and the number can change
      at any moment, because losing a replica loses nothing.

  Because there is no authoritative state on any node, there is nothing for a
  control plane to control. Every node answers every question, which is what
  lets a deployment be a plain Kubernetes Deployment behind a round-robin
  Service, scaled on CPU like any stateless workload.

  ## Where to start reading

    * `Micelio.WAL` — the log format and the compare-and-swap protocol
    * `Micelio.Replica` — the per-repository state machine
    * `Micelio.Replica.Sync` — how a replica converges on the log
    * `Micelio.Cluster` — what distributed Erlang replaces
    * `Micelio.HTTP.GitRouter` — the Git smart HTTP surface
    * `Micelio.MCP.Tools` — the agent-facing surface
  """

  @doc "Version of the running node."
  @spec version() :: String.t()
  def version do
    case Application.spec(:micelio, :vsn) do
      nil -> "dev"
      vsn -> to_string(vsn)
    end
  end
end
