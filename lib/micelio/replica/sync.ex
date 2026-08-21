defmodule Micelio.Replica.Sync do
  @moduledoc """
  Bringing a local repository into agreement with the write-ahead log.

  Because the index carries the repository's complete ref state and every entry
  pointer repeats the packs that entry introduced, catching up does not mean
  replaying history. It means:

    1. download the packs named by the index that we do not already hold,
    2. install them,
    3. set refs to exactly the index's ref map, and
    4. drop any pack the index no longer names.

  That is the same amount of work whether the replica is one push behind or ten
  thousand, and it is the same code path as materializing a repository from
  nothing. There is no separate "repair" or "clone from peer" mode to get wrong,
  because there is only ever one way a replica reaches a state: from the log.

  Ref updates are applied without checking previous values. That is not
  laxness. The log already decided the order when a compare-and-swap was won;
  a replica's job is to converge on that decision, not to re-adjudicate it.

  Packs are never rewritten locally. When a compaction produces a new base, a
  replica downloads the primary's result and deletes what the base does not
  name. Repacking is CPU-bound and deterministic, so paying for it once and
  distributing the answer is strictly better than every replica recomputing it.
  """

  require Logger

  alias Micelio.Git
  alias Micelio.WAL
  alias Micelio.WAL.Index

  @type outcome :: %{epoch: non_neg_integer(), seq: non_neg_integer(), downloaded: non_neg_integer()}

  @doc """
  Make `path` reflect `index`.

  `epoch` and `seq` are what the caller believes the local state to be; they
  are used only to skip work. Passing a state we did not actually reach can
  cost extra effort but never correctness, because every step is idempotent.
  """
  @spec run(String.t(), Path.t(), Index.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, outcome()} | {:error, term()}
  def run(repo_id, path, index, epoch, seq) do
    started = System.monotonic_time(:millisecond)
    required = Index.required_packs(index)

    with :ok <- ensure_repository(path, index),
         {:ok, downloaded} <- install_packs(repo_id, path, required),
         :ok <- maybe_prune(path, index, epoch),
         :ok <- Git.reset_refs(path, Index.refs(index)),
         :ok <- apply_symrefs(path, index) do
      duration = System.monotonic_time(:millisecond) - started

      if index.seq != seq or index.epoch != epoch do
        Logger.info(
          "synced #{repo_id}: #{epoch}/#{seq} -> #{index.epoch}/#{index.seq} " <>
            "(#{downloaded} pack(s), #{duration}ms)"
        )
      end

      :telemetry.execute(
        [:micelio, :replica, :sync],
        %{duration_ms: duration, packs_downloaded: downloaded, entries_behind: index.seq - seq},
        %{repo_id: repo_id, epoch: index.epoch}
      )

      {:ok, %{epoch: index.epoch, seq: index.seq, downloaded: downloaded}}
    end
  end

  # Nothing on disk is not an error and not a repair: a replica is a cache, and
  # materializing one from the log is the ordinary way it comes into existence.
  defp ensure_repository(path, index) do
    if File.dir?(Path.join(path, "objects")) do
      # A repository can outlive the Micelio release that materialized it. In
      # particular, existing caches must gain the private-reference transport
      # settings before this release writes issue state into them.
      Git.configure_bare(path)
    else
      Git.init_bare(path, head: Index.head(index))
    end
  end

  # Only on an epoch change, because that is the only time packs stop being
  # needed. Pruning on every sync would delete packs belonging to entries that
  # a concurrent push added between our read and our write.
  defp maybe_prune(_path, %{epoch: epoch}, epoch), do: :ok

  defp maybe_prune(path, index, _epoch) do
    keep = index |> Index.required_packs() |> Enum.map(&Path.basename(&1.key))
    Git.prune_packs(path, keep)
  end

  defp apply_symrefs(path, index) do
    Enum.reduce_while(index.base.symrefs, :ok, fn {name, target}, _acc ->
      case set_symref(path, name, target) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp set_symref(path, "HEAD", target), do: Git.set_head(path, target)

  defp set_symref(path, name, target) do
    with {:ok, _} <- Git.run(path, ["symbolic-ref", name, target]), do: :ok
  end

  # Packs already present are skipped by name. They are content-addressed, so a
  # matching name means matching contents; re-downloading one would be pure
  # waste on a repository under active use.
  defp install_packs(_repo_id, _path, []), do: {:ok, 0}

  defp install_packs(repo_id, path, packs) do
    present = path |> Git.packs() |> MapSet.new(&Path.basename/1)
    missing = Enum.reject(packs, &MapSet.member?(present, Path.basename(&1.key)))

    if missing == [] do
      {:ok, 0}
    else
      scratch =
        Path.join(
          System.tmp_dir!(),
          "micelio-packs-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
        )

      File.mkdir_p!(scratch)

      try do
        missing
        |> Task.async_stream(&fetch_and_install(repo_id, path, &1, scratch),
          max_concurrency: 4,
          timeout: :timer.minutes(30),
          ordered: false
        )
        |> Enum.reduce_while({:ok, 0}, fn
          {:ok, :ok}, {:ok, count} -> {:cont, {:ok, count + 1}}
          {:ok, {:error, reason}}, _acc -> {:halt, {:error, reason}}
          {:exit, reason}, _acc -> {:halt, {:error, {:pack_download_crashed, reason}}}
        end)
      after
        File.rm_rf(scratch)
      end
    end
  end

  defp fetch_and_install(repo_id, path, pack, scratch) do
    with {:ok, file} <- WAL.get_pack(repo_id, pack, scratch),
         {:ok, _installed} <- Git.install_pack(path, file) do
      :ok
    end
  end
end
