defmodule Micelio.WALFailureTest do
  @moduledoc """
  What happens when object storage misbehaves.

  These are the only tests in the suite that stub the object store, because
  they are the only ones that cannot be provoked with a real one: sustained
  compare-and-swap contention, a mid-write failure, corruption on the wire.

  The property under test throughout is that a failure produces an error, never
  a silent partial write. The log is the source of truth for every replica, so
  a push that half-happened is worse than one that did not happen at all.
  """

  use Micelio.Case, async: true
  use Mimic

  alias Micelio.ObjectStore
  alias Micelio.WAL
  alias Micelio.WAL.Entry

  # Private mode, not global: these run async, and a global stub would replace
  # the object store for every other test running at the same time. Everything
  # stubbed here is called from the test process, so per-process stubs reach it.
  setup :set_mimic_private
  setup :verify_on_exit!

  defp push_entry do
    Entry.new(
      type: :ENTRY_TYPE_PUSH,
      commands: [Entry.command("refs/heads/main", Entry.zero_oid(), String.duplicate("a", 40))]
    )
  end

  describe "compare-and-swap contention" do
    test "gives up rather than looping forever when it can never win", %{repo: repo} do
      {:ok, _} = WAL.create(repo)

      # Every index write loses. A real cluster cannot do this indefinitely, but
      # a pathological hotspot can do it for long enough that an unbounded
      # retry loop would pin a scheduler and never answer the client.
      stub(ObjectStore, :put, fn key, body, opts ->
        if String.ends_with?(key, "index.pb") and Keyword.has_key?(opts, :if_match) do
          {:error, :precondition_failed}
        else
          Mimic.call_original(ObjectStore, :put, [key, body, opts])
        end
      end)

      assert {:error, :cas_exhausted} = WAL.append(repo, fn _ -> {:ok, push_entry()} end)
    end

    test "succeeds once contention clears", %{repo: repo} do
      {:ok, _} = WAL.create(repo)
      counter = :counters.new(1, [])

      stub(ObjectStore, :put, fn key, body, opts ->
        cas? = String.ends_with?(key, "index.pb") and Keyword.has_key?(opts, :if_match)
        :counters.add(counter, 1, 1)

        # Lose the first two attempts, then behave.
        if cas? and :counters.get(counter, 1) <= 2 do
          {:error, :precondition_failed}
        else
          Mimic.call_original(ObjectStore, :put, [key, body, opts])
        end
      end)

      assert {:ok, result} = WAL.append(repo, fn _ -> {:ok, push_entry()} end)
      assert result.seq == 1
    end
  end

  describe "an ambiguous compare-and-swap" do
    test "a commit whose response was lost is reported as committed, not rejected", %{repo: repo} do
      {:ok, _} = WAL.create(repo)

      # The exact shape of a lost response: the store commits the write and
      # then answers the *retry* with a precondition failure, which is
      # indistinguishable from losing the race to another writer. Reporting
      # that as a rejection tells a client its push failed while the log has
      # already accepted it — the one outcome a write-ahead log must not have.
      committed = :counters.new(1, [])

      stub(ObjectStore, :put, fn key, body, opts ->
        cas? = String.ends_with?(key, "index.pb") and Keyword.has_key?(opts, :if_match)

        if cas? and :counters.get(committed, 1) == 0 do
          :counters.add(committed, 1, 1)
          # Apply the write, then claim it failed.
          Mimic.call_original(ObjectStore, :put, [key, body, Keyword.delete(opts, :if_match)])
          {:error, :precondition_failed}
        else
          Mimic.call_original(ObjectStore, :put, [key, body, opts])
        end
      end)

      assert {:ok, result} = WAL.append(repo, fn _index -> {:ok, push_entry()} end)

      assert result.seq == 1

      {:ok, index, _etag} = WAL.fetch(repo)
      assert index.seq == 1, "the entry must be installed exactly once"
      assert length(index.entries) == 1
    end
  end

  describe "storage failures" do
    test "a failed index write is reported, not swallowed", %{repo: repo} do
      {:ok, _} = WAL.create(repo)

      stub(ObjectStore, :put, fn key, body, opts ->
        if String.ends_with?(key, "index.pb") do
          {:error, {:unexpected_status, 500, "internal error"}}
        else
          Mimic.call_original(ObjectStore, :put, [key, body, opts])
        end
      end)

      assert {:error, {:unexpected_status, 500, _}} = WAL.append(repo, fn _ -> {:ok, push_entry()} end)

      # And the log is untouched: nothing was made visible.
      assert {:ok, index, _} = WAL.fetch(repo)
      assert index.seq == 0
    end

    test "a failed entry write stops before the index is touched", %{repo: repo} do
      {:ok, _} = WAL.create(repo)

      stub(ObjectStore, :put, fn key, body, opts ->
        if String.contains?(key, "/wal/") do
          {:error, :storage_unavailable}
        else
          Mimic.call_original(ObjectStore, :put, [key, body, opts])
        end
      end)

      assert {:error, :storage_unavailable} = WAL.append(repo, fn _ -> {:ok, push_entry()} end)

      assert {:ok, index, _} = WAL.fetch(repo)
      assert index.seq == 0
    end

    test "an unreadable index is an error rather than an empty repository", %{repo: repo} do
      {:ok, _} = WAL.create(repo)

      stub(ObjectStore, :get, fn _key, _opts -> {:error, :timeout} end)

      # Treating this as "no repository" would let a transient storage blip
      # look like a deletion.
      assert {:error, :timeout} = WAL.fetch(repo)
    end
  end

  describe "integrity" do
    test "a corrupted entry is rejected rather than decoded", %{repo: repo} do
      {:ok, _} = WAL.create(repo)
      {:ok, _} = WAL.append(repo, fn _ -> {:ok, push_entry()} end)
      {:ok, index, _} = WAL.fetch(repo)
      [pointer] = index.entries

      stub(ObjectStore, :get, fn key -> ObjectStore.get(key, []) end)

      stub(ObjectStore, :get, fn key, opts ->
        if key == pointer.key do
          {:ok, "corrupted bytes", ~s("etag")}
        else
          Mimic.call_original(ObjectStore, :get, [key, opts])
        end
      end)

      assert {:error, {:entry_digest_mismatch, _}} = WAL.read_entry(repo, pointer)
    end

    test "a corrupted pack is rejected before git ever sees it", %{repo: repo} do
      {:ok, _} = WAL.create(repo)
      dir = Path.join(System.tmp_dir!(), "micelio-corrupt-#{:erlang.unique_integer([:positive])}")

      pack = %V1.Pack{
        key: WAL.pack_key(repo, "pack-abc.pack"),
        size: 4,
        digest: WAL.digest("good")
      }

      stub(ObjectStore, :get, fn key -> ObjectStore.get(key, []) end)
      stub(ObjectStore, :get, fn _key, _opts -> {:ok, "evil", ~s("etag")} end)

      assert {:error, {:pack_digest_mismatch, _}} = WAL.get_pack(repo, pack, dir)
      refute File.exists?(Path.join(dir, "pack-abc.pack"))

      File.rm_rf(dir)
    end

    test "a malformed index is reported rather than treated as empty", %{repo: repo} do
      {:ok, _} = WAL.create(repo)

      stub(ObjectStore, :get, fn _key, _opts -> {:ok, <<255, 255, 255, 255>>, ~s("etag")} end)

      assert {:error, {:malformed_index, _}} = WAL.fetch(repo)
    end
  end

  describe "immutable writes" do
    test "an object that already exists is success, not failure", %{repo: repo} do
      {:ok, _} = WAL.create(repo)

      # Packs and entries are content-addressed, so a precondition failure on
      # them means the identical bytes are already stored. Treating that as an
      # error would make every compare-and-swap retry fail.
      stub(ObjectStore, :put, fn key, body, opts ->
        if String.contains?(key, "/wal/") do
          {:error, :precondition_failed}
        else
          Mimic.call_original(ObjectStore, :put, [key, body, opts])
        end
      end)

      assert {:ok, result} = WAL.append(repo, fn _ -> {:ok, push_entry()} end)
      assert result.seq == 1
    end
  end
end
