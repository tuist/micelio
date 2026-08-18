defmodule Micelio.ClusterTest do
  @moduledoc """
  Cluster behaviour on a single node.

  A one-node cluster is not a degenerate case to be tolerated: it is the
  default deployment, because a repository with one replica is still fully
  durable when the log lives in object storage. So the properties worth pinning
  here are that placement works with one member, and that nothing in the read
  or write path treats "no peers" as an error.
  """

  use ExUnit.Case, async: true

  alias Micelio.Cluster

  describe "membership" do
    test "always includes this node" do
      assert node() in Cluster.members()
    end

    test "never reports an empty cluster" do
      # An empty membership would make rendezvous hashing return no placement
      # at all, and every caller would have to special-case it.
      refute Cluster.members() == []
    end
  end

  describe "placement" do
    test "a single node holds everything" do
      assert Cluster.replicas_for("acme/app") == [node()]
      assert Cluster.primary_for("acme/app") == node()
      assert Cluster.primary?("acme/app")
      assert Cluster.responsible?("acme/app")
    end

    test "is stable for the same repository" do
      assert Cluster.replicas_for("acme/app") == Cluster.replicas_for("acme/app")
    end

    test "asking for more replicas than there are nodes is not an error" do
      # A repository can ask for thirty replicas in a three-node cluster; it
      # gets three, and that is a correct answer rather than a failure.
      assert Cluster.replicas_for("acme/app", 30) == [node()]
    end
  end

  describe "announce/3" do
    test "is a no-op with no peers, not an error" do
      # Hints are advisory. Having nobody to tell is the normal case for a
      # single node and must cost nothing.
      assert :ok = Cluster.announce("acme/app", 1, 1)
    end
  end

  describe "on_primary/3" do
    test "runs locally when this node is the primary" do
      assert {:ok, :ran_here} = Cluster.on_primary("acme/app", fn -> :ran_here end)
    end

    test "propagates the function's return value" do
      assert {:ok, 42} = Cluster.on_primary("acme/app", fn -> 42 end)
    end
  end

  test "the process group scope and group are stable names" do
    # These are part of how nodes find each other; renaming one silently would
    # partition a rolling deployment.
    assert Cluster.scope() == Micelio.PG
    assert Cluster.group() == :replicas
  end
end
