defmodule Micelio.ObjectStoreTest do
  @moduledoc """
  The filesystem backend stands in for S3 in development and tests, so the
  conditional-read and compare-and-swap semantics it implements have to match.
  If they diverge, every WAL test is testing something production never does.
  """

  use Micelio.Case, async: true

  alias Micelio.ObjectStore

  test "reads and writes round trip" do
    assert {:ok, etag} = ObjectStore.put("a/b.bin", "hello")
    assert {:ok, "hello", ^etag} = ObjectStore.get("a/b.bin")
  end

  test "a missing object is not found" do
    assert {:error, :not_found} = ObjectStore.get("nope")
  end

  describe "conditional reads" do
    test "an unchanged object reports not_modified" do
      {:ok, etag} = ObjectStore.put("k", "v1")
      assert {:ok, :not_modified} = ObjectStore.get("k", etag: etag)
    end

    test "a changed object returns the new body and a new etag" do
      {:ok, etag} = ObjectStore.put("k", "v1")
      {:ok, _} = ObjectStore.put("k", "v2")

      assert {:ok, "v2", new_etag} = ObjectStore.get("k", etag: etag)
      assert new_etag != etag
    end
  end

  describe "compare-and-swap" do
    test "if_none_match creates exactly once" do
      assert {:ok, _} = ObjectStore.put("once", "first", if_none_match: "*")
      assert {:error, :precondition_failed} = ObjectStore.put("once", "second", if_none_match: "*")
      assert {:ok, "first", _} = ObjectStore.get("once")
    end

    test "if_match only replaces the version it was given" do
      {:ok, etag} = ObjectStore.put("k", "v1")

      assert {:ok, new_etag} = ObjectStore.put("k", "v2", if_match: etag)
      assert {:error, :precondition_failed} = ObjectStore.put("k", "v3", if_match: etag)
      assert {:ok, "v2", ^new_etag} = ObjectStore.get("k")
    end

    test "if_match on a missing object fails rather than creating it" do
      assert {:error, :precondition_failed} = ObjectStore.put("ghost", "v", if_match: ~s("abc"))
      assert {:error, :not_found} = ObjectStore.get("ghost")
    end

    test "only one of many concurrent writers wins" do
      {:ok, etag} = ObjectStore.put("contended", "base")

      results =
        1..20
        |> Task.async_stream(fn n -> ObjectStore.put("contended", "w#{n}", if_match: etag) end,
          max_concurrency: 20
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &(&1 == {:error, :precondition_failed})) == 19
    end
  end

  test "list/1 returns keys under a prefix" do
    ObjectStore.put("repos/a/index.pb", "1")
    ObjectStore.put("repos/b/index.pb", "2")
    ObjectStore.put("other/c", "3")

    assert {:ok, entries} = ObjectStore.list("repos/")
    keys = Enum.map(entries, & &1.key)

    assert "repos/a/index.pb" in keys
    assert "repos/b/index.pb" in keys
    refute "other/c" in keys
  end

  describe "streaming" do
    @tag :tmp_dir
    test "a file round trips without being read into a binary", %{tmp_dir: tmp} do
      source = Path.join(tmp, "source.bin")
      bytes = :crypto.strong_rand_bytes(1024 * 1024 + 13)
      File.write!(source, bytes)

      assert {:ok, _etag} = ObjectStore.put_file("big/object", source)
      assert {:ok, ^bytes, _etag} = ObjectStore.get("big/object")

      destination = Path.join(tmp, "nested/destination.bin")
      assert {:ok, size} = ObjectStore.get_file("big/object", destination)
      assert size == byte_size(bytes)
      assert File.read!(destination) == bytes
    end

    @tag :tmp_dir
    test "put_file honours if_none_match, so a re-upload cannot overwrite", %{tmp_dir: tmp} do
      first = Path.join(tmp, "first.bin")
      second = Path.join(tmp, "second.bin")
      File.write!(first, "original")
      File.write!(second, "replacement")

      assert {:ok, _} = ObjectStore.put_file("immutable", first, if_none_match: "*")
      assert {:error, :precondition_failed} = ObjectStore.put_file("immutable", second, if_none_match: "*")
      assert {:ok, "original", _} = ObjectStore.get("immutable")
    end

    @tag :tmp_dir
    test "a failed put_file leaves nothing behind", %{tmp_dir: tmp} do
      assert {:error, :enoent} = ObjectStore.put_file("absent", Path.join(tmp, "missing.bin"))
      assert {:error, :not_found} = ObjectStore.get("absent")
    end

    test "get_file reports a missing object rather than creating an empty one" do
      destination = Path.join(System.tmp_dir!(), "micelio-absent-#{:erlang.unique_integer([:positive])}")
      assert {:error, :not_found} = ObjectStore.get_file("no/such/key", destination)
      refute File.exists?(destination)
    end

    @tag :tmp_dir
    test "digest_file agrees with hashing the whole body", %{tmp_dir: tmp} do
      path = Path.join(tmp, "hash.bin")
      bytes = :crypto.strong_rand_bytes(700 * 1024)
      File.write!(path, bytes)

      expected = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
      assert {:ok, ^expected, size} = ObjectStore.digest_file(path)
      assert size == byte_size(bytes)
    end
  end

  test "delete/1 is idempotent" do
    ObjectStore.put("gone", "x")
    assert :ok = ObjectStore.delete("gone")
    assert :ok = ObjectStore.delete("gone")
    assert {:error, :not_found} = ObjectStore.get("gone")
  end
end
