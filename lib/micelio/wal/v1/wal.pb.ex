defmodule Micelio.Wal.V1.EntryType do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "micelio.wal.v1.EntryType",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:ENTRY_TYPE_UNSPECIFIED, 0)
  field(:ENTRY_TYPE_PUSH, 1)
  field(:ENTRY_TYPE_SYMREF, 2)
  field(:ENTRY_TYPE_CREATE, 3)
end

defmodule Micelio.Wal.V1.Pack do
  @moduledoc false

  use Protobuf,
    full_name: "micelio.wal.v1.Pack",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:key, 1, type: :string)
  field(:size, 2, type: :uint64)
  field(:digest, 3, type: :string)
end

defmodule Micelio.Wal.V1.RefCommand do
  @moduledoc false

  use Protobuf,
    full_name: "micelio.wal.v1.RefCommand",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:ref, 1, type: :string)
  field(:old_oid, 2, type: :string, json_name: "oldOid")
  field(:new_oid, 3, type: :string, json_name: "newOid")
end

defmodule Micelio.Wal.V1.Actor do
  @moduledoc false

  use Protobuf,
    full_name: "micelio.wal.v1.Actor",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:account, 1, type: :string)
  field(:subject, 2, type: :string)
  field(:node, 3, type: :string)
  field(:remote_addr, 4, type: :string, json_name: "remoteAddr")
end

defmodule Micelio.Wal.V1.Entry.SymrefsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "micelio.wal.v1.Entry.SymrefsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule Micelio.Wal.V1.Entry do
  @moduledoc false

  use Protobuf,
    full_name: "micelio.wal.v1.Entry",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:type, 1, type: Micelio.Wal.V1.EntryType, enum: true)
  field(:commands, 2, repeated: true, type: Micelio.Wal.V1.RefCommand)
  field(:packs, 3, repeated: true, type: Micelio.Wal.V1.Pack)
  field(:symrefs, 4, repeated: true, type: Micelio.Wal.V1.Entry.SymrefsEntry, map: true)
  field(:actor, 5, type: Micelio.Wal.V1.Actor)
  field(:at_ms, 6, type: :int64, json_name: "atMs")
end

defmodule Micelio.Wal.V1.EntryPointer do
  @moduledoc false

  use Protobuf,
    full_name: "micelio.wal.v1.EntryPointer",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:seq, 1, type: :uint64)
  field(:key, 2, type: :string)
  field(:type, 3, type: Micelio.Wal.V1.EntryType, enum: true)
  field(:digest, 4, type: :string)
  field(:size, 5, type: :uint64)
  field(:at_ms, 6, type: :int64, json_name: "atMs")
  field(:packs, 7, repeated: true, type: Micelio.Wal.V1.Pack)
end

defmodule Micelio.Wal.V1.Base.RefsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "micelio.wal.v1.Base.RefsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule Micelio.Wal.V1.Base.SymrefsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "micelio.wal.v1.Base.SymrefsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule Micelio.Wal.V1.Base do
  @moduledoc false

  use Protobuf,
    full_name: "micelio.wal.v1.Base",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:packs, 1, repeated: true, type: Micelio.Wal.V1.Pack)
  field(:refs, 2, repeated: true, type: Micelio.Wal.V1.Base.RefsEntry, map: true)
  field(:symrefs, 3, repeated: true, type: Micelio.Wal.V1.Base.SymrefsEntry, map: true)
  field(:seq, 4, type: :uint64)
  field(:at_ms, 5, type: :int64, json_name: "atMs")
end

defmodule Micelio.Wal.V1.Index.RefsEntry do
  @moduledoc false

  use Protobuf,
    full_name: "micelio.wal.v1.Index.RefsEntry",
    map: true,
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:key, 1, type: :string)
  field(:value, 2, type: :string)
end

defmodule Micelio.Wal.V1.Index do
  @moduledoc false

  use Protobuf,
    full_name: "micelio.wal.v1.Index",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:repo_id, 1, type: :string, json_name: "repoId")
  field(:epoch, 2, type: :uint64)
  field(:seq, 3, type: :uint64)
  field(:base, 4, type: Micelio.Wal.V1.Base)
  field(:entries, 5, repeated: true, type: Micelio.Wal.V1.EntryPointer)
  field(:replicas, 6, type: :uint32)
  field(:created_at_ms, 7, type: :int64, json_name: "createdAtMs")
  field(:updated_at_ms, 8, type: :int64, json_name: "updatedAtMs")
  field(:updated_by, 9, type: :string, json_name: "updatedBy")
  field(:default_branch, 10, type: :string, json_name: "defaultBranch")
  field(:refs, 11, repeated: true, type: Micelio.Wal.V1.Index.RefsEntry, map: true)
end
