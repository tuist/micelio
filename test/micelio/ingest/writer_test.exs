defmodule Micelio.Ingest.WriterTest do
  @moduledoc """
  Group commit has to be indistinguishable from committing one push at a time,
  or it is not an optimisation but a change of semantics. These tests pin that
  down: the ordering, the rejections and the failure isolation must all match.
  """

  use Micelio.Case, async: true

  alias Micelio.Control
  alias Micelio.Ingest.Writer
  alias Micelio.WAL
  alias Micelio.WAL.Entry
  alias Micelio.WAL.Index

  setup %{repo: repo} do
    start_replica_runtime()
    {:ok, _} = Control.create_repository(repo)
    :ok
  end

  # Distinct from Micelio.Case.oid/1, which resolves a real revision.
  defp fake_oid(n), do: String.pad_leading(Integer.to_string(n), 40, "0")

  # The calls are sent before the writer can process them, so waiting on the
  # mailbox length is what makes "they were all queued" a fact rather than a
  # race.
  defp wait_for_queue(pid, expected, attempts \\ 200) do
    {:message_queue_len, length} = Process.info(pid, :message_queue_len)

    cond do
      length >= expected -> :ok
      attempts == 0 -> flunk("only #{length} of #{expected} requests reached the writer")
      true -> Process.sleep(5) && wait_for_queue(pid, expected, attempts - 1)
    end
  end

  defp prepare(repo, ref, old, new) do
    entry = Entry.new(type: :ENTRY_TYPE_PUSH, commands: [Entry.command(ref, old, new)])

    {:ok, prepared} =
      WAL.prepare(repo, entry, fn index ->
        if Index.ref(index, ref) == old, do: :ok, else: {:error, {:stale, ref, old, Index.ref(index, ref)}}
      end)

    prepared
  end

  describe "committing" do
    test "assigns a sequence number", %{repo: repo} do
      prepared = prepare(repo, "refs/heads/main", Entry.zero_oid(), fake_oid(1))

      assert {:ok, %{seq: 1, epoch: 1}} = Writer.commit(repo, prepared)
    end

    test "rejects a stale update", %{repo: repo} do
      {:ok, _} = Writer.commit(repo, prepare(repo, "refs/heads/main", Entry.zero_oid(), fake_oid(1)))

      stale = prepare(repo, "refs/heads/main", fake_oid(9), fake_oid(2))
      assert {:error, {:stale, _, _, _}} = Writer.commit(repo, stale)
    end
  end

  describe "batching" do
    test "concurrent pushes to different refs all land, with a total order", %{repo: repo} do
      results =
        1..20
        |> Task.async_stream(
          fn n ->
            Writer.commit(repo, prepare(repo, "refs/heads/b#{n}", Entry.zero_oid(), fake_oid(n)))
          end,
          max_concurrency: 20,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, _}, &1))

      seqs = Enum.map(results, fn {:ok, %{seq: seq}} -> seq end)
      assert Enum.sort(seqs) == Enum.to_list(1..20), "sequence numbers must be a gapless total order"

      {:ok, index, _} = WAL.fetch(repo)
      assert index.seq == 20
      assert map_size(Index.refs(index)) == 20
    end

    test "actually batches rather than committing one at a time", %{repo: repo} do
      # The point of the writer: N concurrent pushes should not cost N index
      # round trips.
      #
      # Asserting that by launching tasks and hoping they overlap is a flaky
      # test — against a fast local store each commit can finish before the
      # next arrives, and the batch is legitimately one. So the overlap is
      # arranged rather than wished for: suspending the writer parks every
      # request in its mailbox, and resuming it makes the grouping observable
      # with no timing assumption at all.
      {:ok, writer} = Writer.ensure_started(repo)
      :sys.suspend(writer)

      tasks =
        for n <- 1..10 do
          Task.async(fn ->
            Writer.commit(repo, prepare(repo, "refs/heads/b#{n}", Entry.zero_oid(), fake_oid(n)))
          end)
        end

      wait_for_queue(writer, 10)
      :sys.resume(writer)

      results = Task.await_many(tasks, 30_000)
      assert Enum.all?(results, &match?({:ok, _}, &1))

      assert Writer.last_batch_size(repo) == 10,
             "expected ten queued pushes to be committed as one batch, got #{Writer.last_batch_size(repo)}"
    end

    test "a rejected push does not take its batch down with it", %{repo: repo} do
      {:ok, _} = Writer.commit(repo, prepare(repo, "refs/heads/main", Entry.zero_oid(), fake_oid(1)))

      # One valid, one hopeless, submitted together.
      good = prepare(repo, "refs/heads/other", Entry.zero_oid(), fake_oid(2))
      bad = prepare(repo, "refs/heads/main", fake_oid(99), fake_oid(3))

      tasks = [
        Task.async(fn -> Writer.commit(repo, good) end),
        Task.async(fn -> Writer.commit(repo, bad) end)
      ]

      [good_result, bad_result] = Task.await_many(tasks, 30_000)

      assert {:ok, _} = good_result
      assert {:error, {:stale, _, _, _}} = bad_result

      {:ok, index, _} = WAL.fetch(repo)
      assert Index.ref(index, "refs/heads/other") == fake_oid(2)
      assert Index.ref(index, "refs/heads/main") == fake_oid(1)
    end

    test "two pushes racing on one ref cannot both win", %{repo: repo} do
      # Both were prepared against the same starting state, so whichever is
      # ordered second in the batch must be rejected — exactly as it would be
      # if they had arrived sequentially.
      a = prepare(repo, "refs/heads/main", Entry.zero_oid(), fake_oid(1))
      b = prepare(repo, "refs/heads/main", Entry.zero_oid(), fake_oid(2))

      tasks = [Task.async(fn -> Writer.commit(repo, a) end), Task.async(fn -> Writer.commit(repo, b) end)]
      results = Task.await_many(tasks, 30_000)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, {:stale, _, _, _}}, &1)) == 1
    end

    test "batched commits are equivalent to sequential ones", %{repo: repo} do
      # Chain twenty updates to one ref, each depending on the last. If batching
      # changed the semantics at all, this could not hold.
      for n <- 1..20 do
        previous = if n == 1, do: Entry.zero_oid(), else: fake_oid(n - 1)

        assert {:ok, %{seq: ^n}} =
                 Writer.commit(repo, prepare(repo, "refs/heads/main", previous, fake_oid(n)))
      end

      {:ok, index, _} = WAL.fetch(repo)
      assert Index.ref(index, "refs/heads/main") == fake_oid(20)
    end
  end

  describe "routing" do
    test "a single-node cluster commits locally", %{repo: repo} do
      # There is no other node to prefer, and the absence of one must not be an
      # error: correctness never depended on the routing.
      assert Micelio.Cluster.primary_for(repo) == node()
      assert {:ok, _} = Writer.commit(repo, prepare(repo, "refs/heads/main", Entry.zero_oid(), fake_oid(1)))
    end
  end
end
