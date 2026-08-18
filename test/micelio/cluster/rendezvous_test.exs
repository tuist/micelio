defmodule Micelio.Cluster.RendezvousTest do
  use ExUnit.Case, async: true

  alias Micelio.Cluster.Rendezvous

  @nodes Enum.map(1..12, &:"micelio#{&1}@10.0.0.#{&1}")

  describe "select/3" do
    test "is deterministic for the same inputs" do
      assert Rendezvous.select(@nodes, "acme/app", 3) == Rendezvous.select(@nodes, "acme/app", 3)
    end

    test "does not depend on the order members are given in" do
      shuffled = Enum.shuffle(@nodes)
      assert Rendezvous.select(@nodes, "acme/app", 3) == Rendezvous.select(shuffled, "acme/app", 3)
    end

    test "returns fewer members than asked for when the cluster is small" do
      assert length(Rendezvous.select(Enum.take(@nodes, 2), "acme/app", 5)) == 2
      assert Rendezvous.select([], "acme/app", 3) == []
    end

    test "distributes repositories across the cluster" do
      counts =
        1..2000
        |> Enum.map(&Rendezvous.primary(@nodes, "acme/repo-#{&1}"))
        |> Enum.frequencies()

      assert map_size(counts) == length(@nodes)

      expected = div(2000, length(@nodes))
      # Rendezvous hashing is not a perfectly even split; assert it is within a
      # band rather than pinning it, so this does not become a hash-stability
      # test in disguise.
      for {_node, count} <- counts do
        assert count > expected * 0.6
        assert count < expected * 1.4
      end
    end
  end

  describe "membership changes" do
    test "removing a node only moves the repositories that named it" do
      departing = List.first(@nodes)
      remaining = List.delete(@nodes, departing)
      repos = Enum.map(1..1000, &"acme/repo-#{&1}")

      moved =
        Enum.count(repos, fn repo ->
          Rendezvous.primary(@nodes, repo) != Rendezvous.primary(remaining, repo)
        end)

      # Only repositories whose primary was the departing node should move.
      expected = Enum.count(repos, &(Rendezvous.primary(@nodes, &1) == departing))
      assert moved == expected
    end

    test "adding a node steals only its fair share" do
      arriving = :"micelio99@10.0.0.99"
      grown = [arriving | @nodes]
      repos = Enum.map(1..1000, &"acme/repo-#{&1}")

      moved =
        Enum.count(repos, fn repo ->
          Rendezvous.primary(@nodes, repo) != Rendezvous.primary(grown, repo)
        end)

      # Everything that moved must have moved *to* the new node; nothing should
      # be reshuffled between pre-existing nodes.
      for repo <- repos, Rendezvous.primary(@nodes, repo) != Rendezvous.primary(grown, repo) do
        assert Rendezvous.primary(grown, repo) == arriving
      end

      assert moved < div(1000, length(@nodes)) * 2
    end
  end

  test "member?/4 agrees with select/3" do
    [first | _] = selected = Rendezvous.select(@nodes, "acme/app", 3)
    assert Rendezvous.member?(@nodes, "acme/app", 3, first)
    refute Rendezvous.member?(@nodes, "acme/app", 3, Enum.find(@nodes, &(&1 not in selected)))
  end
end
