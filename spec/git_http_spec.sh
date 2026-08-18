# shellcheck shell=bash
Describe 'Git smart HTTP'
  Describe 'authentication'
    It 'refuses an unauthenticated clone'
      repo=$(new_repo)
      admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null

      # credential.helper is emptied deliberately. Without it, a developer's
      # keychain will happily supply credentials cached by an earlier passing
      # test, and this assertion silently stops testing anything.
      When run env GIT_TERMINAL_PROMPT=0 git -c credential.helper= \
        clone -q "${NODE1_URL}/${repo}.git" "$(mktemp -d)/clone"
      The status should not equal 0
      The stderr should match pattern "*Username*"
    End

    It 'offers a Basic challenge so git knows to send credentials'
      repo=$(new_repo)
      admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null

      When run curl -sS -i "${NODE1_URL}/${repo}/info/refs?service=git-upload-pack"
      The status should equal 0
      The output should include "401"
      # Without this header git fails outright instead of prompting.
      The output should include 'Basic realm="micelio"'
      # And this is what lets an MCP client discover where to get a token.
      The output should include "resource_metadata"
    End

    It 'does not reveal whether an unauthorized repository exists'
      # A 403 here would let anyone enumerate the estate.
      When run curl -sS -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${E2E_TOKEN}" \
        "${NODE1_URL}/someone-else/private/info/refs?service=git-upload-pack"
      The status should equal 0
      The output should equal "404"
    End
  End

  Describe 'clone and push'
    It 'round trips a repository'
      repo=$(new_repo)
      source=$(make_source)
      clone=$(mktemp -d)/clone

      admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null

      When run bash -c "
        set -e
        cd '$source'
        git push -q '$(git_url "$NODE1_URL" "$repo")' main
        git clone -q '$(git_url "$NODE1_URL" "$repo")' '$clone'
        cat '$clone/README.md'
      "
      The status should equal 0
      The output should include "# e2e"
    End

    It 'serves an incremental fetch after a second push'
      repo=$(new_repo)
      source=$(make_source)
      clone=$(mktemp -d)/clone
      url=$(git_url "$NODE1_URL" "$repo")

      admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null

      When run bash -c "
        set -e
        cd '$source'
        git push -q '$url' main
        git clone -q '$url' '$clone'
        echo second > second.txt
        git add . && git commit -qm 'feat: second'
        git push -q '$url' main
        cd '$clone' && git pull -q
        cat second.txt
      "
      The status should equal 0
      The output should include "second"
    End

    It 'rejects a non-fast-forward push'
      repo=$(new_repo)
      a=$(make_source)
      b=$(mktemp -d)/b
      url=$(git_url "$NODE1_URL" "$repo")

      admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null

      When run bash -c "
        cd '$a'
        git push -q '$url' main
        git clone -q '$url' '$b'

        # Diverge: two different commits claiming the same parent.
        echo one > f.txt && git add . && git commit -qm one && git push -q '$url' main

        cd '$b'
        git config user.email e2e@example.com && git config user.name E2E
        echo two > f.txt && git add . && git commit -qm two
        git push '$url' main 2>&1
      "
      The status should not equal 0
      The stdout should include "rejected"
    End

    It 'supports protocol v2'
      repo=$(new_repo)
      source=$(make_source)
      admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null
      url=$(git_url "$NODE1_URL" "$repo")

      When run bash -c "
        set -e
        cd '$source' && git push -q '$url' main
        git -c protocol.version=2 ls-remote '$url' 2>&1
      "
      The status should equal 0
      The output should include "refs/heads/main"
    End

    It 'supports a partial clone'
      repo=$(new_repo)
      source=$(make_source)
      clone=$(mktemp -d)/clone
      admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null
      url=$(git_url "$NODE1_URL" "$repo")

      When run bash -c "
        set -e
        cd '$source' && git push -q '$url' main
        git clone -q --filter=blob:none '$url' '$clone'
        cat '$clone/README.md'
      "
      The status should equal 0
      The output should include "# e2e"
    End
  End

  Describe 'unknown repositories'
    It 'reports a repository that does not exist as not found'
      When run curl -sS -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${E2E_TOKEN}" \
        "${NODE1_URL}/acme/does-not-exist/info/refs?service=git-upload-pack"
      The status should equal 0
      The output should equal "404"
    End
  End
End
