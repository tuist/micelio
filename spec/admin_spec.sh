# shellcheck shell=bash
Describe 'Admin API'
  It 'answers health without a credential'
    # A probe that needs a credential is a probe that fails for the wrong
    # reasons, and health reveals nothing.
    When run curl -sS "${NODE1_ADMIN_URL}/health"
    The status should equal 0
    The output should include "ok"
  End

  It 'reports readiness only when object storage is reachable'
    When run curl -sS "${NODE1_ADMIN_URL}/ready"
    The status should equal 0
    The output should include "ready"
  End

  It 'requires a token for everything else'
    When run curl -sS -o /dev/null -w '%{http_code}' "${NODE1_ADMIN_URL}/repositories"
    The status should equal 0
    The output should equal "401"
  End

  It 'exposes prometheus metrics'
    # Two things have to be true, and they fail differently: the endpoint must
    # serve Prometheus format at all, and Micelio's own metrics must appear
    # once there is something to report.
    #
    # A metric with no observations is not emitted, so the log has to be read
    # first. Creating a repository is not enough: that only writes. Describing
    # it performs the conditional read whose outcome micelio_wal_read reports,
    # which is the metric that actually matters.
    When run bash -c '
      repo=$(new_repo)
      admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null
      admin "$NODE1_ADMIN_URL" GET "/repositories/$repo" >/dev/null

      for _ in $(seq 1 20); do
        body=$(curl -sS "${NODE1_ADMIN_URL}/metrics")
        if printf "%s" "$body" | grep -q "micelio_wal_"; then
          printf "%s" "$body" | grep -q "micelio_prom_ex_beam" && echo "metrics ok"
          exit 0
        fi
        sleep 1
      done
      echo "micelio metrics never appeared"
      exit 1
    '
    The status should equal 0
    The output should include "metrics ok"
  End

  It 'reports cluster membership'
    When run bash -c "admin '$NODE1_ADMIN_URL' GET /cluster"
    The status should equal 0
    The output should include "micelio-e2e-1@127.0.0.1"
  End

  It 'creates and describes a repository'
    repo=$(new_repo)

    When run bash -c "
      set -e
      admin '$NODE1_ADMIN_URL' POST /repositories -d '{\"repository\":\"$repo\"}' >/dev/null
      admin '$NODE1_ADMIN_URL' GET '/repositories/$repo'
    "
    The status should equal 0
    The output should include "\"epoch\""
    The output should include "placement"
  End

  It 'refuses to create the same repository twice'
    repo=$(new_repo)
    admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null

    When run bash -c "
      curl -sS -o /dev/null -w '%{http_code}' -X POST \
        -H 'Authorization: Bearer ${E2E_ADMIN_TOKEN}' \
        -H 'Content-Type: application/json' \
        -d '{\"repository\":\"$repo\"}' \
        '${NODE1_ADMIN_URL}/repositories'
    "
    The status should equal 0
    The output should equal "409"
  End

  It 'rejects a repository id that could escape its prefix'
    When run bash -c "
      curl -sS -o /dev/null -w '%{http_code}' -X POST \
        -H 'Authorization: Bearer ${E2E_ADMIN_TOKEN}' \
        -H 'Content-Type: application/json' \
        -d '{\"repository\":\"../../etc/passwd\"}' \
        '${NODE1_ADMIN_URL}/repositories'
    "
    The status should equal 0
    The output should equal "422"
  End

  It 'deletes a repository'
    repo=$(new_repo)
    admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null

    When run bash -c "
      curl -sS -o /dev/null -w '%{http_code}' -X DELETE \
        -H 'Authorization: Bearer ${E2E_ADMIN_TOKEN}' \
        '${NODE1_ADMIN_URL}/repositories/${repo}'
    "
    The status should equal 0
    The output should equal "204"
  End
End
