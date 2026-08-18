#!/usr/bin/env bash
#MISE description="Package the Helm chart and push it to the registry as an OCI artifact"
#USAGE flag "--version <version>" help="Version to stamp into the chart"
#USAGE flag "--registry <registry>" help="OCI registry, e.g. oci://ghcr.io/tuist/charts"
#USAGE flag "--dist <dist>" help="Directory to write the packaged chart into"
#USAGE flag "--push" help="Push the packaged chart to the registry"
set -euo pipefail

version=""
registry="oci://ghcr.io/tuist/charts"
dist="dist"
push=false

while (($# > 0)); do
  case "$1" in
    --version) version="${2}"; shift 2 ;;
    --registry) registry="${2}"; shift 2 ;;
    --dist) dist="${2}"; shift 2 ;;
    --push) push=true; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "${version}" ]] || { echo "--version is required" >&2; exit 1; }

mkdir -p "${dist}"

# The chart version and the appVersion move together. Keeping them in step
# means "which Micelio does this chart deploy" never needs looking up.
helm package charts/micelio \
  --version "${version}" \
  --app-version "${version}" \
  --destination "${dist}"

if [[ "${push}" == true ]]; then
  helm push "${dist}/micelio-${version}.tgz" "${registry}"
fi
