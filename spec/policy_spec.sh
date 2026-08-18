# shellcheck shell=bash
Describe 'Authorization policy'
  # Policy is an object in the store, so these assertions are really about the
  # control-plane-less claim: any node can read it, any node can change it, and
  # a change takes effect without restarting or reissuing anything.

  It 'is empty for an account that has none'
    account="e2e-empty-${RANDOM}"

    When run bash -c "admin '$NODE1_ADMIN_URL' GET '/policy/$account'"
    The status should equal 0
    The output should include '"bindings":[]'
  End

  It 'binds a subject and reports it back'
    account="e2e-bind-${RANDOM}"

    When run bash -c "
      set -e
      admin '$NODE1_ADMIN_URL' PUT '/policy/$account' \
        -d '{\"subject\":\"alice\",\"repositories\":[\"$account/**\"],\"permissions\":[\"read\",\"write\"]}' >/dev/null
      admin '$NODE1_ADMIN_URL' GET '/policy/$account'
    "
    The status should equal 0
    The output should include "alice"
    The output should include "$account/**"
  End

  It 'is visible from a different node than the one that wrote it'
    # No replication step, no cache invalidation message: the second node reads
    # the same object.
    account="e2e-shared-${RANDOM}"

    When run bash -c "
      set -e
      admin '$NODE1_ADMIN_URL' PUT '/policy/$account' \
        -d '{\"subject\":\"bob\",\"repositories\":[\"$account/**\"],\"permissions\":[\"read\"]}' >/dev/null
      sleep 6
      admin '$NODE2_ADMIN_URL' GET '/policy/$account'
    "
    The status should equal 0
    The output should include "bob"
  End

  It 'revokes without reissuing anything'
    account="e2e-revoke-${RANDOM}"

    When run bash -c "
      set -e
      admin '$NODE1_ADMIN_URL' PUT '/policy/$account' \
        -d '{\"subject\":\"carol\",\"repositories\":[\"$account/**\"],\"permissions\":[\"write\"]}' >/dev/null
      admin '$NODE1_ADMIN_URL' DELETE '/policy/$account?subject=carol' >/dev/null
      admin '$NODE1_ADMIN_URL' GET '/policy/$account'
    "
    The status should equal 0
    The output should include '"bindings":[]'
  End

  Describe 'authorizing a real git operation'
    # The claim the whole design rests on: a credential with no grant over an
    # account can be authorised by that account's policy alone, with nothing
    # reissued and nothing restarted.

    outsider_url() {
      echo "${1%/}/${2}.git" | sed "s#http://#http://x-access-token:${E2E_OUTSIDER_TOKEN}@#"
    }

    It 'refuses a clone the token alone does not permit'
      repo=$(new_repo)
      source=$(make_source)
      admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null

      # The acme policy is shared with the other examples here, so the absence
      # of a binding is established rather than assumed.
      admin "$NODE1_ADMIN_URL" DELETE '/policy/acme?subject=outsider' >/dev/null
      sleep 1

      When run bash -c "
        set -e
        cd '$source' && git push -q '$(git_url "$NODE1_URL" "$repo")' main
        git clone -q '$(outsider_url "$NODE1_URL" "$repo")' \"\$(mktemp -d)/clone\"
      "
      The status should not equal 0
      # Not 'forbidden': a repository the caller may not read is reported as
      # missing, so the estate cannot be enumerated by probing.
      The stderr should include "not found"
    End

    It 'allows the same clone once policy grants it'
      repo=$(new_repo)
      source=$(make_source)
      clone=$(mktemp -d)/clone
      admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null

      When run bash -c "
        set -e
        cd '$source' && git push -q '$(git_url "$NODE1_URL" "$repo")' main

        admin '$NODE1_ADMIN_URL' PUT '/policy/acme' \
          -d '{\"subject\":\"outsider\",\"repositories\":[\"acme/**\"],\"permissions\":[\"read\"]}' >/dev/null
        sleep 1

        git clone -q '$(outsider_url "$NODE1_URL" "$repo")' '$clone'
        cat '$clone/README.md'
      "
      The status should equal 0
      The output should include "# e2e"
    End

    It 'still refuses a push, because the grant was read only'
      repo=$(new_repo)
      source=$(make_source)
      admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null

      When run bash -c "
        set -e
        cd '$source' && git push -q '$(git_url "$NODE1_URL" "$repo")' main
        admin '$NODE1_ADMIN_URL' PUT '/policy/acme' \
          -d '{\"subject\":\"outsider\",\"repositories\":[\"acme/**\"],\"permissions\":[\"read\"]}' >/dev/null
        sleep 1
        echo more > more.txt && git add . && git commit -qm more
        git push '$(outsider_url "$NODE1_URL" "$repo")' main
      "
      The status should not equal 0
      The stderr should include "not found"
    End

    It 'revokes access without reissuing the credential'
      repo=$(new_repo)
      source=$(make_source)
      admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null

      When run bash -c "
        set -e
        cd '$source' && git push -q '$(git_url "$NODE1_URL" "$repo")' main

        admin '$NODE1_ADMIN_URL' PUT '/policy/acme' \
          -d '{\"subject\":\"outsider\",\"repositories\":[\"acme/**\"],\"permissions\":[\"read\"]}' >/dev/null
        sleep 1
        git clone -q '$(outsider_url "$NODE1_URL" "$repo")' \"\$(mktemp -d)/a\"

        admin '$NODE1_ADMIN_URL' DELETE '/policy/acme?subject=outsider' >/dev/null
        sleep 2
        git clone -q '$(outsider_url "$NODE1_URL" "$repo")' \"\$(mktemp -d)/b\"
      "
      The status should not equal 0
      The stderr should include "not found"
    End
  End

  It 'rejects an incomplete binding'
    account="e2e-bad-${RANDOM}"

    When run bash -c "
      curl -sS -o /dev/null -w '%{http_code}' -X PUT \
        -H 'Authorization: Bearer ${E2E_ADMIN_TOKEN}' \
        -H 'Content-Type: application/json' \
        -d '{\"subject\":\"dave\"}' \
        '${NODE1_ADMIN_URL}/policy/$account'
    "
    The status should equal 0
    The output should equal "422"
  End
End
