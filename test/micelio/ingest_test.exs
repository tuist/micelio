defmodule Micelio.IngestTest do
  @moduledoc """
  What may enter the write-ahead log.

  The log is written before Git applies anything locally, and every replica
  converges on it afterwards, so a command the log accepts is one every replica
  must be able to apply. Anything it cannot is permanent damage.
  """

  use Micelio.Case, async: true

  alias Micelio.Auth.Principal
  alias Micelio.Control
  alias Micelio.Ingest
  alias Micelio.Issues
  alias Micelio.MCP.Tools
  alias Micelio.Replica
  alias Micelio.WAL
  alias Micelio.WAL.Entry

  setup %{repo: repo, namespace: namespace} do
    start_replica_runtime()
    {:ok, _} = Control.create_repository(repo)

    {:ok,
     principal: %Principal{subject: "tenant", grants: [Principal.grant("#{namespace}/**", [:read, :write])]}}
  end

  defp seed(repo, principal) do
    {:ok, result} =
      Tools.call(
        "commit",
        %{
          "repository" => repo,
          "branch" => "main",
          "message" => "seed",
          "changes" => [%{"path" => "a", "content" => "a"}]
        },
        principal
      )

    result
  end

  test "an unrepresentable reference name is refused rather than recorded", %{repo: repo} do
    command = %V1.RefCommand{
      ref: "refs/heads/bad..name",
      old_oid: Entry.zero_oid(),
      new_oid: String.duplicate("a", 40)
    }

    assert {:error, message} = Ingest.commit(repo, commands: [command])
    assert message =~ "not a valid reference name"

    {:ok, index, _etag} = WAL.fetch(repo)
    assert index.seq == 0, "nothing should have been written"
  end

  test "a client cannot write Micelio's private references", %{repo: repo} do
    command = %V1.RefCommand{
      ref: Issues.ref(),
      old_oid: Entry.zero_oid(),
      new_oid: Entry.zero_oid()
    }

    assert {:error, message} = Ingest.commit(repo, commands: [command])
    assert message =~ "reserved for Micelio"

    {:ok, index, _etag} = WAL.fetch(repo)
    assert index.seq == 0, "nothing should have been written"
  end

  test "a client cannot occupy the private reference namespace", %{repo: repo} do
    command = %V1.RefCommand{
      ref: "refs/micelio",
      old_oid: Entry.zero_oid(),
      new_oid: Entry.zero_oid()
    }

    assert {:error, message} = Ingest.commit(repo, commands: [command])
    assert message =~ "reserved for Micelio"
  end

  test "the default branch cannot point at a private reference", %{repo: repo} do
    assert {:error, :reserved_ref} = Ingest.set_head(repo, Issues.ref())

    {:ok, index, _etag} = WAL.fetch(repo)
    assert index.seq == 0, "nothing should have been written"
  end

  test "a tenant cannot brick a repository through the agent API", %{repo: repo, principal: principal} do
    # The regression. `create_branch` accepted any name, recorded it, and
    # ignored Git's refusal to apply it — after which no replica could converge
    # and the repository was unservable for good.
    commit = seed(repo, principal)

    assert {:error, message} =
             Tools.call(
               "create_branch",
               %{"repository" => repo, "branch" => "bad..name", "target" => commit.commit},
               principal
             )

    assert message =~ "not a valid reference name"

    # And the agent sees it as a tool error rather than a success.
    {:reply, %{result: result}} =
      Micelio.MCP.Server.handle(
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "tools/call",
          "params" => %{
            "name" => "create_branch",
            "arguments" => %{"repository" => repo, "branch" => "also..bad", "target" => commit.commit}
          }
        },
        principal: principal
      )

    assert result.isError

    # And the repository is still fully serviceable from the log alone.
    Replica.evict(repo)
    assert {:ok, view} = Replica.ensure_fresh(repo)
    assert {:ok, refs} = Micelio.Git.refs(view.path)
    assert Map.has_key?(refs, "refs/heads/main")
    refute Enum.any?(Map.keys(refs), &String.contains?(&1, ".."))
  end

  test "ordinary branch names still work", %{repo: repo, principal: principal} do
    commit = seed(repo, principal)

    {:ok, result} =
      Tools.call(
        "create_branch",
        %{"repository" => repo, "branch" => "feature/ok", "target" => commit.commit},
        principal
      )

    refute result[:isError], inspect(result)
  end
end
