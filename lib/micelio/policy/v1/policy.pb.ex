defmodule Micelio.Policy.V1.Binding do
  @moduledoc false

  use Protobuf,
    full_name: "micelio.policy.v1.Binding",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:subject, 1, type: :string)
  field(:repositories, 2, repeated: true, type: :string)
  field(:permissions, 3, repeated: true, type: :string)
  field(:note, 4, type: :string)
  field(:created_at_ms, 5, type: :int64, json_name: "createdAtMs")
  field(:expires_at_ms, 6, type: :int64, json_name: "expiresAtMs")
end

defmodule Micelio.Policy.V1.Policy do
  @moduledoc false

  use Protobuf,
    full_name: "micelio.policy.v1.Policy",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:account, 1, type: :string)
  field(:bindings, 2, repeated: true, type: Micelio.Policy.V1.Binding)
  field(:version, 3, type: :uint64)
  field(:created_at_ms, 4, type: :int64, json_name: "createdAtMs")
  field(:updated_at_ms, 5, type: :int64, json_name: "updatedAtMs")
  field(:updated_by, 6, type: :string, json_name: "updatedBy")
end
