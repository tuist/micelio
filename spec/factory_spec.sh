# shellcheck shell=bash
Describe 'Factory work runs'
  It 'runs a mocked Condukt worker without an inference endpoint or session'
    # The worker below is deliberately mundane. It pulls the operation contract,
    # makes a deterministic Git change, and reports durable evidence. That proves
    # the factory boundary independently from any model provider.
    repo=$(new_repo)
    source=$(make_source)
    admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null
    git -C "$source" remote add origin "$(git_url "$NODE1_URL" "$repo")"
    git -C "$source" push -q origin main
    base_commit=$(git -C "$source" rev-parse HEAD)

    When run bash -c "
      set -e
      created=\$(curl -fsS -X POST \\
        -H 'Authorization: Bearer \${E2E_TOKEN}' \\
        -H 'Content-Type: application/json' \\
        --data \"\$(printf '{\\\"base_commit\\\":\\\"%s\\\",\\\"graph\\\":{\\\"nodes\\\":[{\\\"id\\\":\\\"implement\\\",\\\"kind\\\":\\\"agent\\\",\\\"title\\\":\\\"Implement fixture\\\",\\\"execution\\\":{\\\"type\\\":\\\"condukt_operation\\\",\\\"operation\\\":\\\"mock_implement\\\",\\\"input\\\":{\\\"path\\\":\\\"IMPLEMENTED.md\\\"}}}]}}' '$base_commit')\" \\
        '\${NODE1_URL}/api/work-runs?repository=$repo')
      run_id=\$(printf '%s' \"\$created\" | sed -n 's/.*\"run_id\":\"\([^\"]*\)\".*/\1/p')
      test -n \"\$run_id\"

      claimed=\$(curl -fsS -X POST \\
        -H 'Authorization: Bearer \${E2E_TOKEN}' \\
        -H 'Content-Type: application/json' \\
        --data '{\"executor\":\"mock-condukt-worker\"}' \\
        \"\${NODE2_URL}/api/work-runs/\$run_id/claim?repository=$repo\")
      attempt_id=\$(printf '%s' \"\$claimed\" | sed -n 's/.*\"attempt_id\":\"\([^\"]*\)\".*/\1/p')
      test -n \"\$attempt_id\"
      printf '%s' \"\$claimed\" | grep -q 'mock_implement'

      worker=\$(mktemp -d)
      git clone -q '$(git_url "$NODE2_URL" "$repo")' \"\$worker\"
      printf 'implemented by mocked condukt worker\\n' > \"\$worker/IMPLEMENTED.md\"
      git -C \"\$worker\" add IMPLEMENTED.md
      git -C \"\$worker\" commit -qm 'feat: mocked factory work'
      git -C \"\$worker\" push -q origin main

      completed=\$(curl -fsS -X POST \\
        -H 'Authorization: Bearer \${E2E_TOKEN}' \\
        -H 'Content-Type: application/json' \\
        --data \"{\\\"attempt\\\":\\\"\$attempt_id\\\",\\\"outcome\\\":\\\"succeeded\\\",\\\"artifacts\\\":[{\\\"name\\\":\\\"mock-worker-log\\\",\\\"uri\\\":\\\"object://factory/\$run_id/log\\\"}]}\" \\
        \"\${NODE1_URL}/api/work-runs/\$run_id/nodes/implement/complete?repository=$repo\")
      printf '%s' \"\$completed\" | grep -q '\"status\":\"succeeded\"'

      events=\$(curl -fsS -H 'Authorization: Bearer \${E2E_TOKEN}' \\
        \"\${NODE1_URL}/api/work-runs/\$run_id/events?repository=$repo\")
      printf '%s' \"\$events\" | grep -q 'work_run_created'
      printf '%s' \"\$events\" | grep -q 'node_claimed'
      printf '%s' \"\$events\" | grep -q 'attempt_succeeded'

      verifier=\$(mktemp -d)
      git clone -q '$(git_url "$NODE1_URL" "$repo")' \"\$verifier\"
      cat \"\$verifier/IMPLEMENTED.md\"
    "
    The status should equal 0
    The output should include 'implemented by mocked condukt worker'
  End

  It 'accepts exactly one cross-node claim under object-store contention'
    repo=$(new_repo)
    source=$(make_source)
    admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null
    git -C "$source" remote add origin "$(git_url "$NODE1_URL" "$repo")"
    git -C "$source" push -q origin main
    base_commit=$(git -C "$source" rev-parse HEAD)

    When run bash -c "
      set -e
      created=\$(curl -fsS -X POST \\
        -H 'Authorization: Bearer \${E2E_TOKEN}' \\
        -H 'Content-Type: application/json' \\
        --data \"\$(printf '{\\\"base_commit\\\":\\\"%s\\\",\\\"graph\\\":{\\\"nodes\\\":[{\\\"id\\\":\\\"implement\\\",\\\"title\\\":\\\"Implement fixture\\\"}]}}' '$base_commit')\" \\
        '\${NODE1_URL}/api/work-runs?repository=$repo')
      run_id=\$(printf '%s' \"\$created\" | sed -n 's/.*\"run_id\":\"\([^\"]*\)\".*/\1/p')
      test -n \"\$run_id\"

      first=\$(mktemp)
      second=\$(mktemp)
      curl -sS -X POST \\
        -H 'Authorization: Bearer \${E2E_TOKEN}' \\
        -H 'Content-Type: application/json' \\
        --data '{\"executor\":\"contender-one\"}' \\
        \"\${NODE1_URL}/api/work-runs/\$run_id/claim?repository=$repo\" > \"\$first\" &
      first_pid=\$!
      curl -sS -X POST \\
        -H 'Authorization: Bearer \${E2E_TOKEN}' \\
        -H 'Content-Type: application/json' \\
        --data '{\"executor\":\"contender-two\"}' \\
        \"\${NODE2_URL}/api/work-runs/\$run_id/claim?repository=$repo\" > \"\$second\" &
      second_pid=\$!
      wait \"\$first_pid\"
      wait \"\$second_pid\"

      winners=\$(grep -h -o '\"attempt_id\"' \"\$first\" \"\$second\" | wc -l | tr -d ' ')
      test \"\$winners\" -eq 1

      events=\$(curl -fsS -H 'Authorization: Bearer \${E2E_TOKEN}' \\
        \"\${NODE1_URL}/api/work-runs/\$run_id/events?repository=$repo\")
      claims=\$(printf '%s' \"\$events\" | grep -o 'node_claimed' | wc -l | tr -d ' ')
      test \"\$claims\" -eq 1
      echo \"winners=\$winners\"
    "
    The status should equal 0
    The output should include 'winners=1'
  End
End
