defmodule Micelio.WAL.Entry do
  @moduledoc """
  One immutable record in a repository's write-ahead log.

  The struct is the generated protobuf message itself (`Micelio.Wal.V1.Entry`)
  rather than a parallel Elixir type, so there is exactly one definition of
  what an entry is and no mapping layer to drift.

  An entry is written to object storage before anything references it, and is
  never mutated afterwards. Its key is derived from the hash of its own encoded
  bytes, which makes writing idempotent: retrying after a lost compare-and-swap
  reuses the object already stored instead of leaving a new orphan behind.
  """

  alias Micelio.Wal.V1

  @type t :: V1.Entry.t()
  @type command :: V1.RefCommand.t()
  @type pack :: V1.Pack.t()

  @zero String.duplicate("0", 40)

  @doc """
  The all-zero object id Git uses for "this ref does not exist".

  Git uses it on both sides of a command: as `old_oid` it means create, as
  `new_oid` it means delete.
  """
  @spec zero_oid() :: String.t()
  def zero_oid, do: @zero

  @doc "Build an entry, defaulting the timestamp to now."
  @spec new(keyword()) :: t()
  def new(fields) do
    fields =
      fields
      |> Keyword.put_new(:at_ms, System.system_time(:millisecond))
      |> Keyword.put_new(:type, :ENTRY_TYPE_PUSH)

    struct!(V1.Entry, fields)
  end

  @doc "Build a ref command from string object ids."
  @spec command(String.t(), String.t(), String.t()) :: command()
  def command(ref, old_oid, new_oid) do
    %V1.RefCommand{ref: ref, old_oid: old_oid, new_oid: new_oid}
  end

  @doc "Whether the command creates a ref that did not previously exist."
  @spec create?(command()) :: boolean()
  def create?(%V1.RefCommand{old_oid: old}), do: old == @zero

  @doc "Whether the command deletes a ref."
  @spec delete?(command()) :: boolean()
  def delete?(%V1.RefCommand{new_oid: new}), do: new == @zero

  @spec encode(t()) :: binary()
  def encode(%V1.Entry{} = entry), do: V1.Entry.encode(entry)

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary) do
    {:ok, V1.Entry.decode(binary)}
  rescue
    error -> {:error, {:malformed_entry, error}}
  end

  @doc "Human-readable one-liner for logs, traces and the admin API."
  @spec describe(t()) :: String.t()
  def describe(%V1.Entry{type: :ENTRY_TYPE_PUSH} = entry) do
    refs = Enum.map_join(entry.commands, ", ", & &1.ref)
    "push #{length(entry.commands)} ref(s) [#{refs}] in #{length(entry.packs)} pack(s)"
  end

  def describe(%V1.Entry{type: :ENTRY_TYPE_SYMREF} = entry) do
    "symref " <> Enum.map_join(entry.symrefs, ", ", fn {name, target} -> "#{name} -> #{target}" end)
  end

  def describe(%V1.Entry{type: type}), do: type |> Atom.to_string() |> String.downcase()
end
