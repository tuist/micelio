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
