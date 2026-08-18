#!/usr/bin/env bash
# Regenerate the write-ahead log schema from priv/proto.
#
# The generated modules are committed, so neither a build nor a deploy needs
# protoc present. Run this whenever priv/proto changes, and commit the result
# alongside the schema change.
set -euo pipefail

cd "$(dirname "$0")/.."

command -v protoc >/dev/null 2>&1 || { echo "protoc not found. Run 'mise install'." >&2; exit 1; }

escripts="${MIX_HOME:-$HOME/.mix}/escripts"
if [ ! -x "$escripts/protoc-gen-elixir" ]; then
  echo "Installing protoc-gen-elixir..."
  mix escript.install hex protobuf --force
fi
export PATH="$escripts:$PATH"

# protoc-gen-elixir nests output under both the proto package and the proto
# file path, which double-counts them here because the two deliberately match.
# Generate into a scratch directory and place the result ourselves.
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

protoc --proto_path=priv/proto --elixir_out="$scratch" priv/proto/micelio/wal/v1/wal.proto

mkdir -p lib/micelio/wal/v1
find "$scratch" -name '*.pb.ex' -exec cp {} lib/micelio/wal/v1/wal.pb.ex \;

mix format lib/micelio/wal/v1/wal.pb.ex

echo "Generated lib/micelio/wal/v1/wal.pb.ex:"
grep '^defmodule' lib/micelio/wal/v1/wal.pb.ex | sed 's/^/  /'
