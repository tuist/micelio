defmodule Micelio.Replica.CompactorTest do
  @moduledoc """
  Compaction is the one operation that rewrites what the log says, so the
  properties worth pinning down are that it never loses a push and that other
  replicas end up in the same place afterwards.
  """

  use Micelio.Case, async: false

  alias Micelio.Control
  alias Micelio.Git
  alias Micelio.MCP.Tools
  alias Micelio.Replica
  alias Micelio.Replica.Compactor
  alias Micelio.WAL
  alias Micelio.WAL.Entry
  alias Micelio.WAL.Index

  @repo "acme/app"

  setup do
    start_replica_runtime()
    {:ok, _} = Control.create_repository(@repo)

    principal = %Micelio.Auth.Principal{
      subject: "test",
      grants: [Micelio.Auth.Principal.grant("**", [:admin])]
    }

    {:ok, principal: principal}
  end

  defp commit(principal, name) do
    {:ok, result} =
      Tools.call(
        "commit",
        %{
          "repository" => @repo,
          "branch" => "main",
          "message" => "add #{name}",
          "changes" => [%{"path" => "#{name}.txt", "content" => "#{name}\n"}]
        },
        principal
      )

    result
  end

  test "collapses the log and preserves the ref state", %{principal: principal} do
    for n <- 1..5, do: commit(principal, "file#{n}")

    {:ok, before, _} = WAL.fetch(@repo)
    assert length(before.entries) == 5
    refs_before = Index.refs(before)

    assert {:ok, summary} = Compactor.compact(@repo)
    assert summary.epoch == before.epoch + 1

    {:ok, compacted, _} = WAL.fetch(@repo)
    assert compacted.entries == []
    assert Index.refs(compacted) == refs_before
    assert compacted.seq == before.seq, "compaction must not rewind the sequence number"
  end

  test "another replica adopts the compacted base rather than replaying", %{principal: principal} do
    for n <- 1..3, do: commit(principal, "file#{n}")

    {:ok, _} = Compactor.compact(@repo)
    {:ok, index, _} = WAL.fetch(@repo)

    # Throw the local copy away: this is what a node that was offline through
    # the compaction, or a brand new node, has to cope with.
    Replica.evict(@repo)

    assert {:ok, view} = Replica.ensure_fresh(@repo)
    assert view.epoch == index.epoch
    assert {:ok, refs} = Git.refs(view.path)
    assert refs == Index.refs(index)

    # And the history is genuinely there, not just the tip.
    assert {:ok, log} = Git.log(view.path, "refs/heads/main", limit: 10)
    assert length(log) == 3
  end

  test "the compacted base is self-sufficient", %{principal: principal} do
    for n <- 1..3, do: commit(principal, "file#{n}")
    {:ok, _} = Compactor.compact(@repo)

    {:ok, index, _} = WAL.fetch(@repo)

    # After compaction every required pack must come from the base, since the
    # entries that referenced the others are gone.
    assert index.entries == []
    assert Index.required_packs(index) == index.base.packs
    assert index.base.packs != []
  end

  test "pushes continue to work after compaction", %{principal: principal} do
    commit(principal, "before")
    {:ok, _} = Compactor.compact(@repo)

    result = commit(principal, "after")
    refute result[:isError], inspect(result)

    {:ok, view} = Replica.ensure_fresh(@repo)
    assert {:ok, log} = Git.log(view.path, "refs/heads/main", limit: 10)
    assert length(log) == 2
  end

  test "compacting twice in a row is harmless", %{principal: principal} do
    commit(principal, "one")

    assert {:ok, first} = Compactor.compact(@repo)
    assert {:ok, second} = Compactor.compact(@repo)
    assert second.epoch == first.epoch + 1

    {:ok, view} = Replica.ensure_fresh(@repo)
    assert {:ok, refs} = Git.refs(view.path)
    assert map_size(refs) == 1
  end

  describe "thresholds" do
    test "does nothing until the log is long enough", %{principal: principal} do
      commit(principal, "one")

      previous = Application.get_env(:micelio, :compaction_entry_threshold)
      Application.put_env(:micelio, :compaction_entry_threshold, 100)
      on_exit(fn -> Application.put_env(:micelio, :compaction_entry_threshold, previous) end)

      assert :not_due = Compactor.maybe_compact(@repo)
    end

    test "runs once the threshold is crossed", %{principal: principal} do
      for n <- 1..3, do: commit(principal, "file#{n}")

      previous = Application.get_env(:micelio, :compaction_entry_threshold)
      Application.put_env(:micelio, :compaction_entry_threshold, 2)
      on_exit(fn -> Application.put_env(:micelio, :compaction_entry_threshold, previous) end)

      assert {:ok, _} = Compactor.maybe_compact(@repo)
    end
  end

  test "refuses to compact from a stale replica" do
    # A repack of a repository that is behind would publish a base missing the
    # newest pushes, so this has to fail rather than proceed.
    {:ok, _} = Replica.ensure_fresh(@repo)

    {:ok, _} =
      WAL.append(@repo, fn _ ->
        {:ok,
         Entry.new(
           type: :ENTRY_TYPE_PUSH,
           commands: [
             Entry.command(
               "refs/heads/x",
               Entry.zero_oid(),
               String.duplicate("a", 40)
             )
           ]
         )}
      end)

    # The replica cannot converge on an entry whose object does not exist, so
    # it stays behind, and compaction must notice.
    assert {:error, _} = Compactor.compact(@repo)
  end
end
