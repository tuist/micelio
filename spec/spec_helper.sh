# shellcheck shell=bash
# End-to-end suite.
#
# These tests drive a real server with the real `git` client over the real
# smart-HTTP protocol, against real S3-compatible object storage. That is the
# point: the unit tests can prove the write-ahead log is correct, but only this
# can prove that `git push` and `git clone` actually work, which is the product.
#
# The stack itself is brought up by `mise run e2e` rather than by a hook here,
# so that a failing run can be inspected while it is still standing.

# shellcheck source=support/stack.sh
. "${SHELLSPEC_PROJECT_ROOT}/spec/support/stack.sh"

spec_helper_precheck() {
  minimum_version "0.28.0"

  command -v git >/dev/null 2>&1 || abort "git is required"

  # Set by support/stack.sh. Without it, git commands in this suite can pick up
  # the developer's credential helper and block indefinitely.
  [ -f "${E2E_GITCONFIG:-}" ] || abort "hermetic gitconfig missing. Start the stack with: mise run e2e:up"
  if ! curl -fsS "${NODE1_ADMIN_URL}/health" >/dev/null 2>&1; then
    abort "micelio is not running. Start the stack with: mise run e2e:up"
  fi

  if ! curl -fsS "${NODE2_ADMIN_URL}/health" >/dev/null 2>&1; then
    abort "the second node is not running. Start the stack with: mise run e2e:up"
  fi
}

spec_helper_configure() {
  :
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# A URL with credentials embedded, which is how a Git client authenticates.
git_url() {
  echo "${1%/}/${2}.git" | sed "s#http://#http://x-access-token:${E2E_TOKEN}@#"
}

admin() {
  base=$1 method=$2 path=$3
  shift 3
  curl -sS -X "$method" \
    -H "Authorization: Bearer ${E2E_ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    "$@" "${base}${path}"
}

mcp() {
  curl -sS -X POST \
    -H "Authorization: Bearer ${E2E_TOKEN}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d "$2" \
    "${1}/mcp"
}

# Every example gets a fresh repository id, so the suite has no ordering
# dependencies and can be run repeatedly against the same bucket.
new_repo() {
  echo "acme/e2e-$(date +%s)-${RANDOM}"
}

# A scratch working copy with one commit.
make_source() {
  dir=$(mktemp -d)
  (
    cd "$dir" || exit 1
    git init -q -b main
    echo "# e2e" > README.md
    git add .
    git commit -qm "feat: initial"
  ) >/dev/null
  echo "$dir"
}

# Specs frequently need a multi-step shell sequence, which means a nested
# `bash -c`. Functions are not inherited by a child shell unless exported, so
# export them explicitly rather than making every spec re-implement curl.
if [ -n "${BASH_VERSION:-}" ]; then
  export -f git_url admin mcp new_repo make_source
fi
