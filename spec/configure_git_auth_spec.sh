# shellcheck shell=bash

configure_git_auth() {
  metadata=$1
  root=$(mktemp -d)
  bin="$root/bin"
  log="$root/git-config.log"
  metadata_file="$root/metadata.json"
  mkdir "$bin"
  printf '%s' "$metadata" >"$metadata_file"

  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ "$1 $2" = "credential-manager version" ]; then exit 0; fi' \
    'printf "%s\\n" "$*" >>"$MICELIO_TEST_GIT_LOG"' >"$bin/git"
  chmod +x "$bin/git"

  printf '%s\n' '#!/usr/bin/env bash' \
    'cat "$MICELIO_TEST_METADATA"' >"$bin/curl"
  chmod +x "$bin/curl"

  PATH="$bin:$PATH" \
    MICELIO_TEST_GIT_LOG="$log" \
    MICELIO_TEST_METADATA="$metadata_file" \
    "${SHELLSPEC_PROJECT_ROOT}/scripts/configure-micelio-git" --url https://git.example.com
  status=$?

  if [ -f "$log" ]; then
    grep -F 'credential.https://git.example.com.helper ' "$log"
    grep -F 'credential.https://git.example.com.helper manager' "$log"
    grep -F 'credential.https://git.example.com.oauthRedirectUri http://127.0.0.1' "$log"
    grep -F 'credential.https://git.example.com.oauthUseClientAuthHeader false' "$log"
  fi

  rm -rf "$root"
  return "$status"
}

Describe 'Git Credential Manager setup script'
  It 'configures a public client with a loopback redirect'
    metadata='version=1
issuer=https://identity.example.com
client_id=micelio-developers
authorization_endpoint=https://identity.example.com/authorize
token_endpoint=https://identity.example.com/token
redirect_uri=http://127.0.0.1
scopes=openid profile
username=oauth2'

    When call configure_git_auth "$metadata"
    The status should equal 0
    The output should include 'credential.https://git.example.com.helper manager'
    The output should include 'credential.https://git.example.com.oauthRedirectUri http://127.0.0.1'
    The output should include 'credential.https://git.example.com.oauthUseClientAuthHeader false'
  End

  It 'rejects a redirect outside the loopback listener before changing Git'
    metadata='version=1
issuer=https://identity.example.com
client_id=micelio-developers
authorization_endpoint=https://identity.example.com/authorize
token_endpoint=https://identity.example.com/token
redirect_uri=https://attacker.example.com/callback
scopes=openid
username=oauth2'

    When call configure_git_auth "$metadata"
    The status should not equal 0
    The stderr should include 'redirect_uri must be an HTTP 127.0.0.1 origin'
    The output should not include 'credential.https://git.example.com'
  End
End
