defmodule Micelio.WAL.Index do
  @moduledoc """
  The single mutable object per repository, and the only thing under
  compare-and-swap.

  It holds two parts:

    * a **base**, produced by compaction: the packfiles and the exact ref state
      a replica reaches by downloading them, and
    * an ordered list of **entry pointers** applied on top of that base.

  It also carries the repository's complete current ref state and, on each
  entry pointer, the packs that entry introduced. That is what makes catching
  up cost a single read: everything a replica needs — which packs to fetch,
  which refs to end up at — is derivable from this one object, so a replica
  that is a thousand pushes behind does the same amount of work as one that is
  a single push behind.

  A replica is up to date when its `{epoch, seq}` matches the index. Reading it
  conditionally is the entire consistency protocol: a `304` means keep serving,
  a `200` means catch up first.

  `epoch` changes only on compaction. A replica that sees a higher epoch throws
  away its pack set and adopts the new base rather than replaying history,
  which is why replicas never repack: they download the primary's result and
  trade bandwidth for CPU.
  """

  alias Micelio.WAL.Entry
  alias Micelio.Wal.V1

  @type t :: V1.Index.t()
  @type pointer :: V1.EntryPointer.t()

  @spec new(String.t(), keyword()) :: t()
  def new(repo_id, opts \\ []) do
    now = System.system_time(:millisecond)
    branch = Keyword.get(opts, :default_branch, "refs/heads/main")

    %V1.Index{
      repo_id: repo_id,
      epoch: 1,
      seq: 0,
      base: %V1.Base{packs: [], refs: %{}, symrefs: %{"HEAD" => branch}, seq: 0, at_ms: now},
      entries: [],
      refs: %{},
      replicas: Keyword.get(opts, :replicas, 3),
      created_at_ms: now,
      updated_at_ms: now,
      updated_by: Keyword.get(opts, :node_id, ""),
      default_branch: branch
    }
  end

  @doc """
  Append an entry pointer and return the updated index.

  The sequence number is assigned here and nowhere else. That is what makes the
  log a total order: whoever wins the compare-and-swap on this object decides
  what happened first, and no other agreement is needed.
  """
  @spec append(t(), Entry.t(), String.t(), non_neg_integer(), String.t(), String.t()) :: t()
  def append(%V1.Index{} = index, %V1.Entry{} = entry, key, size, digest, node_id) do
    seq = index.seq + 1

    pointer = %V1.EntryPointer{
      seq: seq,
      key: key,
      type: entry.type,
      digest: digest,
      size: size,
      at_ms: entry.at_ms,
      packs: entry.packs
    }

    %{
      index
      | seq: seq,
        entries: index.entries ++ [pointer],
        refs: apply_commands(index.refs, entry.commands),
        base: apply_entry_symrefs(index.base, entry),
        updated_at_ms: System.system_time(:millisecond),
        updated_by: node_id
    }
  end

  @doc """
  Apply ref commands to a ref map.

  A command whose `new_oid` is the zero id deletes; anything else sets. This is
  the only place ref state advances, which keeps "what does this repository
  currently point at" answerable from the index alone.
  """
  @spec apply_commands(%{optional(String.t()) => String.t()}, [V1.RefCommand.t()]) ::
          %{optional(String.t()) => String.t()}
  def apply_commands(refs, commands) do
    zero = Entry.zero_oid()

    Enum.reduce(commands, refs, fn %V1.RefCommand{ref: ref, new_oid: new}, acc ->
      if new == zero, do: Map.delete(acc, ref), else: Map.put(acc, ref, new)
    end)
  end

  defp apply_entry_symrefs(base, %V1.Entry{symrefs: symrefs}) when map_size(symrefs) == 0, do: base

  defp apply_entry_symrefs(base, %V1.Entry{symrefs: symrefs}),
    do: %{base | symrefs: Map.merge(base.symrefs, symrefs)}

  @doc """
  Replace the base with a compaction result and drop the replayed entries.

  Bumping the epoch is the signal replicas use to rebuild their pack set from
  the new base instead of continuing to replay entries that no longer exist in
  the active index.
  """
  @spec rebase(t(), [Entry.pack()], map(), map(), String.t()) :: t()
  def rebase(%V1.Index{} = index, packs, refs, symrefs, node_id) do
    now = System.system_time(:millisecond)

    %{
      index
      | epoch: index.epoch + 1,
        base: %V1.Base{packs: packs, refs: refs, symrefs: symrefs, seq: index.seq, at_ms: now},
        entries: [],
        refs: refs,
        updated_at_ms: now,
        updated_by: node_id
    }
  end

  @doc "Record a symbolic ref change, such as moving the default branch."
  @spec put_symref(t(), String.t(), String.t()) :: t()
  def put_symref(%V1.Index{} = index, name, target) do
    base = %{index.base | symrefs: Map.put(index.base.symrefs, name, target)}
    default = if name == "HEAD", do: target, else: index.default_branch

    %{index | base: base, default_branch: default, updated_at_ms: System.system_time(:millisecond)}
  end

  @doc "Entry pointers a replica sitting at `seq` still has to apply."
  @spec entries_after(t(), non_neg_integer()) :: [pointer()]
  def entries_after(%V1.Index{entries: entries}, seq), do: Enum.filter(entries, &(&1.seq > seq))

  @doc "Bytes referenced by the base packs plus the entries not yet compacted."
  @spec bytes(t()) :: non_neg_integer()
  def bytes(%V1.Index{} = index) do
    packs = index.base.packs |> Enum.map(& &1.size) |> Enum.sum()
    packs + (index.entries |> Enum.map(& &1.size) |> Enum.sum())
  end

  @doc """
  Whether the log has grown enough that compaction is worth its cost.

  Compaction is the one genuinely expensive operation in the system, so it is
  driven by thresholds rather than by a timer: a repository nobody pushes to
  should never pay for it.
  """
  @spec compaction_due?(t(), keyword()) :: boolean()
  def compaction_due?(%V1.Index{} = index, opts) do
    length(index.entries) >= Keyword.fetch!(opts, :entries) or bytes(index) >= Keyword.fetch!(opts, :bytes)
  end

  @doc """
  Every pack a replica needs in order to hold the repository's current state.

  The base's packs plus everything the un-compacted entries introduced. Packs
  are content-addressed, so a replica may skip any it already has by name.
  """
  @spec required_packs(t()) :: [Entry.pack()]
  def required_packs(%V1.Index{} = index) do
    (index.base.packs ++ Enum.flat_map(index.entries, & &1.packs))
    |> Enum.uniq_by(& &1.key)
  end

  @doc "The repository's complete current ref state."
  @spec refs(t()) :: %{optional(String.t()) => String.t()}
  def refs(%V1.Index{refs: refs}), do: refs

  @doc "The object id a ref currently points at, or the zero id if absent."
  @spec ref(t(), String.t()) :: String.t()
  def ref(%V1.Index{refs: refs}, name), do: Map.get(refs, name, Entry.zero_oid())

  @doc "Where HEAD should point."
  @spec head(t()) :: String.t()
  def head(%V1.Index{} = index) do
    Map.get(index.base.symrefs, "HEAD") || default_branch(index)
  end

  @spec default_branch(t()) :: String.t()
  def default_branch(%V1.Index{default_branch: ""}), do: "refs/heads/main"
  def default_branch(%V1.Index{default_branch: branch}), do: branch

  @spec encode(t()) :: binary()
  def encode(%V1.Index{} = index), do: V1.Index.encode(index)

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary) do
    {:ok, V1.Index.decode(binary)}
  rescue
    error -> {:error, {:malformed_index, error}}
  end
end
