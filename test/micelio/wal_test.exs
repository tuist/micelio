defmodule Micelio.WALTest do
  use Micelio.Case, async: false

  alias Micelio.WAL
  alias Micelio.WAL.Entry
  alias Micelio.WAL.Index

  @repo "acme/app"

  defp push_entry(ref, old, new) do
    Entry.new(type: :ENTRY_TYPE_PUSH, commands: [Entry.command(ref, old, new)])
  end

  defp zero, do: Entry.zero_oid()

  describe "valid_id?/1" do
    test "accepts namespaced names" do
      assert WAL.valid_id?("acme/app")
      assert WAL.valid_id?("acme/team/app")
      assert WAL.valid_id?("a")
      assert WAL.valid_id?("acme/my-app.v2_x")
    end

    test "rejects anything that could escape its prefix" do
      refute WAL.valid_id?("../etc/passwd")
      refute WAL.valid_id?("acme/../../x")
      refute WAL.valid_id?("/absolute")
      refute WAL.valid_id?("acme//app")
      refute WAL.valid_id?("")
      refute WAL.valid_id?(nil)
    end
  end

  describe "create/2" do
    test "creates the log for a new repository" do
      assert {:ok, index} = WAL.create(@repo)
      assert index.repo_id == @repo
      assert index.epoch == 1
      assert index.seq == 0
    end

    test "is exactly-once under concurrency" do
      results =
        1..10
        |> Task.async_stream(fn _ -> WAL.create(@repo) end, max_concurrency: 10)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :already_exists})) == 9
    end
  end

  describe "read/2" do
    test "a repeat read with the same etag is not_modified" do
      {:ok, _} = WAL.create(@repo)
      {:ok, _index, etag} = WAL.fetch(@repo)

      assert {:ok, :not_modified} = WAL.read(@repo, etag)
    end

    test "a read after an append returns the new state" do
      {:ok, _} = WAL.create(@repo)
      {:ok, _index, etag} = WAL.fetch(@repo)

      {:ok, _} =
        WAL.append(@repo, fn _ ->
          {:ok, push_entry("refs/heads/main", zero(), "a" <> String.duplicate("0", 39))}
        end)

      assert {:ok, index, new_etag} = WAL.read(@repo, etag)
      assert index.seq == 1
      assert new_etag != etag
    end
  end

  describe "append/2" do
    setup do
      {:ok, _} = WAL.create(@repo)
      :ok
    end

    test "assigns monotonically increasing sequence numbers" do
      for n <- 1..5 do
        oid = String.pad_leading("#{n}", 40, "0")
        {:ok, result} = WAL.append(@repo, fn _ -> {:ok, push_entry("refs/heads/b#{n}", zero(), oid)} end)
        assert result.seq == n
      end
    end

    test "tracks ref state in the index" do
      oid = String.duplicate("a", 40)
      {:ok, _} = WAL.append(@repo, fn _ -> {:ok, push_entry("refs/heads/main", zero(), oid)} end)

      {:ok, index, _} = WAL.fetch(@repo)
      assert Index.ref(index, "refs/heads/main") == oid
      assert Index.refs(index) == %{"refs/heads/main" => oid}
    end

    test "a delete removes the ref from the index" do
      oid = String.duplicate("a", 40)
      {:ok, _} = WAL.append(@repo, fn _ -> {:ok, push_entry("refs/heads/tmp", zero(), oid)} end)
      {:ok, _} = WAL.append(@repo, fn _ -> {:ok, push_entry("refs/heads/tmp", oid, zero())} end)

      {:ok, index, _} = WAL.fetch(@repo)
      assert Index.refs(index) == %{}
    end

    test "the builder sees fresh state on every attempt" do
      # Each concurrent append asserts that the ref is where it last saw it, so
      # the only way all of them can succeed is if the builder is re-run
      # against the winner's result rather than a stale read.
      results =
        1..10
        |> Task.async_stream(
          fn n ->
            WAL.append(@repo, fn index ->
              current = Index.ref(index, "refs/heads/main")
              next = String.pad_leading("#{n}", 40, "0")
              {:ok, push_entry("refs/heads/main", current, next)}
            end)
          end,
          max_concurrency: 10,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, _}, &1))

      seqs = Enum.map(results, fn {:ok, r} -> r.seq end)
      assert Enum.sort(seqs) == Enum.to_list(1..10), "sequence numbers must be a total order with no gaps"

      {:ok, index, _} = WAL.fetch(@repo)
      assert index.seq == 10
    end

    test "a builder that refuses aborts without touching the log" do
      assert {:error, :nope} = WAL.append(@repo, fn _ -> {:error, :nope} end)

      {:ok, index, _} = WAL.fetch(@repo)
      assert index.seq == 0
    end

    test "entries are content addressed, so a retry reuses the stored object" do
      entry = push_entry("refs/heads/main", zero(), String.duplicate("a", 40))
      body = Entry.encode(entry)
      digest = WAL.digest(body)
      key = WAL.entry_key(@repo, digest)

      assert key =~ digest
      assert {:ok, _} = Micelio.ObjectStore.put(key, body, if_none_match: "*")

      # A second write of identical content is refused; the WAL treats that as
      # success, which is what makes losing a compare-and-swap cheap to retry.
      assert {:error, :precondition_failed} = Micelio.ObjectStore.put(key, body, if_none_match: "*")
    end
  end

  describe "compact/6" do
    test "bumps the epoch and clears the replayed entries" do
      {:ok, _} = WAL.create(@repo)
      oid = String.duplicate("a", 40)
      {:ok, _} = WAL.append(@repo, fn _ -> {:ok, push_entry("refs/heads/main", zero(), oid)} end)

      {:ok, index, etag} = WAL.fetch(@repo)
      refs = %{"refs/heads/main" => oid}
      pack = %V1.Pack{key: WAL.pack_key(@repo, "pack-x.pack"), size: 10, digest: "d"}

      assert {:ok, compacted} = WAL.compact(@repo, [pack], refs, index.base.symrefs, index, etag)
      assert compacted.epoch == index.epoch + 1
      assert compacted.entries == []
      assert compacted.seq == index.seq, "compaction must not lose the sequence number"
      assert Index.refs(compacted) == refs
    end

    test "loses to a concurrent push rather than overwriting it" do
      {:ok, _} = WAL.create(@repo)
      {:ok, index, etag} = WAL.fetch(@repo)

      # A push lands between our read and our compaction.
      {:ok, _} =
        WAL.append(@repo, fn _ -> {:ok, push_entry("refs/heads/x", zero(), String.duplicate("b", 40))} end)

      assert {:error, :raced} = WAL.compact(@repo, [], %{}, index.base.symrefs, index, etag)

      {:ok, current, _} = WAL.fetch(@repo)
      assert current.seq == 1, "the push must survive the failed compaction"
    end

    test "snapshots the previous index for provenance" do
      {:ok, _} = WAL.create(@repo)
      {:ok, index, etag} = WAL.fetch(@repo)
      {:ok, _} = WAL.compact(@repo, [], %{}, index.base.symrefs, index, etag)

      assert {:ok, body, _} = Micelio.ObjectStore.get(WAL.history_key(@repo, index.epoch))
      assert {:ok, snapshot} = Index.decode(body)
      assert snapshot.epoch == index.epoch
    end
  end

  describe "required_packs/1" do
    test "is the base packs plus everything the entries introduced" do
      {:ok, _} = WAL.create(@repo)

      pack = %V1.Pack{key: "repos/#{@repo}/packs/p1.pack", size: 1, digest: "d1"}

      {:ok, _} =
        WAL.append(@repo, fn _ ->
          {:ok, Entry.new(type: :ENTRY_TYPE_PUSH, commands: [], packs: [pack])}
        end)

      {:ok, index, _} = WAL.fetch(@repo)
      assert Enum.map(Index.required_packs(index), & &1.key) == [pack.key]
    end
  end

  test "list_repositories/0 finds every created repository" do
    {:ok, _} = WAL.create("acme/one")
    {:ok, _} = WAL.create("acme/two")
    {:ok, _} = WAL.create("beta/three")

    assert {:ok, ids} = WAL.list_repositories()
    assert ids == ["acme/one", "acme/two", "beta/three"]
  end

  test "destroy/1 removes everything belonging to a repository" do
    {:ok, _} = WAL.create(@repo)

    {:ok, _} =
      WAL.append(@repo, fn _ -> {:ok, push_entry("refs/heads/main", zero(), String.duplicate("a", 40))} end)

    assert :ok = WAL.destroy(@repo)
    assert {:error, :not_found} = WAL.read(@repo)
    assert {:ok, []} = Micelio.ObjectStore.list("repos/#{@repo}/")
  end
end
