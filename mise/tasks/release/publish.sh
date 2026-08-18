#!/usr/bin/env bash
#MISE description="Publish the GitHub release"
#USAGE flag "--version <version>" help="Version being released"
#USAGE flag "--notes <notes>" help="Path to the rendered release notes file"
#USAGE flag "--dist <dist>" help="Directory containing release artifacts"
set -euo pipefail

version=""
notes=""
dist=""
while (($# > 0)); do
  case "$1" in
    --version) version="${2}"; shift 2 ;;
    --notes) notes="${2}"; shift 2 ;;
    --dist) dist="${2}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "${version}" ]] || { echo "--version is required" >&2; exit 1; }
[[ -n "${notes}" ]] || { echo "--notes is required" >&2; exit 1; }

target="$(git rev-parse HEAD)"

artifacts=()
if [[ -n "${dist}" && -d "${dist}" ]]; then
  while IFS= read -r line; do artifacts+=("$line"); done < <(find "${dist}" -type f -print)
fi

gh release create "${version}" \
  --title "${version}" \
  --notes-file "${notes}" \
  --target "${target}" \
  "${artifacts[@]}"
