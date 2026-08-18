defmodule Micelio.Cluster.Rendezvous do
  @moduledoc """
  Highest-random-weight (rendezvous) hashing.

  Placement has to be a pure function of the repository id and the set of live
  nodes, because the alternative is a routing table, and a routing table is a
  piece of distributed state that has to be kept correct, replicated and
  repaired. Rendezvous hashing removes that state entirely: any node can work
  out where a repository belongs by itself, and two nodes that see the same
  membership always agree.

  It also degrades the way we want. When a node leaves, only the repositories
  that named it move; every other assignment is untouched. That matters because
  a moved assignment costs a materialization from the write-ahead log, and we
  would rather pay for `1/n` of them than reshuffle the whole cluster.

  Disagreement during a membership change is safe rather than merely tolerable:
  two nodes that both believe they own a repository can both serve it, and both
  can accept pushes, because visibility is decided by a compare-and-swap in the
  object store and not by who thinks they are in charge.
  """

  @type member :: node()

  @doc """
  The `count` highest-weighted members for `repo_id`, in descending order.

  The head of the list is the preferred primary. Returns fewer than `count`
  members when the cluster is smaller than that, which is normal and not an
  error: a repository with one live replica is still fully durable, because the
  log lives in object storage.
  """
  @spec select([member()], String.t(), pos_integer()) :: [member()]
  def select([], _repo_id, _count), do: []

  def select(members, repo_id, count) when count > 0 do
    members
    |> Enum.map(&{weight(&1, repo_id), &1})
    # Ties break on the node name so every node computes the same order.
    |> Enum.sort(fn {w1, n1}, {w2, n2} -> {w1, n1} >= {w2, n2} end)
    |> Enum.take(count)
    |> Enum.map(&elem(&1, 1))
  end

  @doc "The preferred primary for `repo_id`, or `nil` when there are no members."
  @spec primary([member()], String.t()) :: member() | nil
  def primary(members, repo_id) do
    case select(members, repo_id, 1) do
      [primary] -> primary
      [] -> nil
    end
  end

  @doc "Whether `member` is among the `count` nodes that should hold `repo_id`."
  @spec member?([member()], String.t(), pos_integer(), member()) :: boolean()
  def member?(members, repo_id, count, member) do
    member in select(members, repo_id, count)
  end

  defp weight(member, repo_id) do
    :crypto.hash(:sha256, [to_string(member), 0, repo_id]) |> :binary.decode_unsigned()
  end
end
