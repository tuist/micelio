# shellcheck shell=bash
Describe 'Replication'
  # These are the tests that justify the architecture. Everything else could be
  # achieved with a single Git server on a disk.

  It 'makes a push to one node immediately visible on another'
    repo=$(new_repo)
    source=$(make_source)
    clone=$(mktemp -d)/clone

    admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null

    When run bash -c "
      set -e
      cd '$source'
      git push -q '$(git_url "$NODE1_URL" "$repo")' main

      # No wait, no retry, no sleep. Node 2 has never seen this repository, and
      # must serve it consistently on the first request by materializing it
      # from the log.
      git clone -q '$(git_url "$NODE2_URL" "$repo")' '$clone'
      cat '$clone/README.md'
    "
    The status should equal 0
    The output should include "# e2e"
  End

  It 'moves a repository larger than any buffer we would want to hold'
    repo=$(new_repo)
    source=$(make_source)
    clone=$(mktemp -d)/clone

    admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null

    # A pack is as large as a customer's history, so nothing on this path may
    # hold one whole: not the node that receives the push, not the node that
    # materializes the repository from the log. 64 MiB of incompressible bytes
    # is small next to a real repository but far larger than any buffer, and it
    # travels through a real S3 the same way a large one would.
    When run bash -c "
      set -e
      cd '$source'
      head -c 67108864 /dev/urandom > big.bin
      git add big.bin && git commit -qm 'feat: a large blob'
      git push -q '$(git_url "$NODE1_URL" "$repo")' main

      # Node 2 has never seen this repository: it streams the pack down from
      # the log to answer.
      git clone -q '$(git_url "$NODE2_URL" "$repo")' '$clone'
      cmp big.bin '$clone/big.bin' && echo identical
    "
    The status should equal 0
    The output should include "identical"
  End

  It 'accepts pushes on either node'
    repo=$(new_repo)
    source=$(make_source)
    admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null

    When run bash -c "
      set -e
      cd '$source'
      git push -q '$(git_url "$NODE1_URL" "$repo")' main

      echo two > two.txt && git add . && git commit -qm two
      # A different node accepts the follow-up. There is no primary to find.
      git push -q '$(git_url "$NODE2_URL" "$repo")' main

      echo three > three.txt && git add . && git commit -qm three
      git push -q '$(git_url "$NODE1_URL" "$repo")' main

      git ls-remote '$(git_url "$NODE2_URL" "$repo")' refs/heads/main
    "
    The status should equal 0
    The output should include "refs/heads/main"
  End

  It 'rebuilds a repository after its local cache is evicted'
    repo=$(new_repo)
    source=$(make_source)
    clone=$(mktemp -d)/clone

    admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null

    When run bash -c "
      set -e
      cd '$source' && git push -q '$(git_url "$NODE1_URL" "$repo")' main

      # Throw the warm cache away. This is the crashed-node case, the
      # scaled-down case and the never-seen-it case, all at once.
      curl -sS -X POST -H 'Authorization: Bearer ${E2E_ADMIN_TOKEN}' \
        '${NODE1_ADMIN_URL}/evict/${repo}' >/dev/null

      git clone -q '$(git_url "$NODE1_URL" "$repo")' '$clone'
      cat '$clone/README.md'
    "
    The status should equal 0
    The output should include "# e2e"
  End

  It 'survives compaction without losing history'
    repo=$(new_repo)
    source=$(make_source)
    clone=$(mktemp -d)/clone

    admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null

    When run bash -c "
      set -e
      cd '$source'
      for n in 1 2 3 4; do
        echo \$n > file\$n.txt
        git add . && git commit -qm \"feat: commit \$n\"
        git push -q '$(git_url "$NODE1_URL" "$repo")' main
      done

      curl -sS -X POST -H 'Authorization: Bearer ${E2E_ADMIN_TOKEN}' \
        '${NODE1_ADMIN_URL}/compact/${repo}' >/dev/null

      # A node that was not involved in the compaction must adopt the new base
      # and end up with the complete history, not just the tip.
      curl -sS -X POST -H 'Authorization: Bearer ${E2E_ADMIN_TOKEN}' \
        '${NODE2_ADMIN_URL}/evict/${repo}' >/dev/null

      git clone -q '$(git_url "$NODE2_URL" "$repo")' '$clone'
      cd '$clone' && git log --oneline | wc -l
    "
    The status should equal 0
    The output should include "5"
  End

  It 'reports placement identically from every node'
    repo=$(new_repo)
    admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null

    # Placement is computed from the repository id and the live node set, so
    # two nodes seeing the same membership must give the same answer.
    from_one=$(admin "$NODE1_ADMIN_URL" GET "/placement/${repo}")
    from_two=$(admin "$NODE2_ADMIN_URL" GET "/placement/${repo}")

    When call test "$from_one" = "$from_two"
    The status should equal 0
  End

  It 'keeps pushing correct under concurrent writers'
    repo=$(new_repo)
    source=$(make_source)
    admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null

    # Two clients racing on the same branch through different nodes. Exactly
    # one must win; the loser must be told to fetch, not silently clobber.
    When run bash -c "
      cd '$source'
      git push -q '$(git_url "$NODE1_URL" "$repo")' main

      a=\$(mktemp -d)/a; b=\$(mktemp -d)/b
      git clone -q '$(git_url "$NODE1_URL" "$repo")' \"\$a\"
      git clone -q '$(git_url "$NODE2_URL" "$repo")' \"\$b\"

      (cd \"\$a\" && echo a > x.txt && git add . && git commit -qm a)
      (cd \"\$b\" && echo b > x.txt && git add . && git commit -qm b)

      (cd \"\$a\" && git push -q '$(git_url "$NODE1_URL" "$repo")' main) &
      pid_a=\$!
      (cd \"\$b\" && git push -q '$(git_url "$NODE2_URL" "$repo")' main) &
      pid_b=\$!

      wait \$pid_a; ra=\$?
      wait \$pid_b; rb=\$?

      # Exactly one succeeded.
      echo \"winners=\$(( (ra == 0 ? 1 : 0) + (rb == 0 ? 1 : 0) ))\"
    "
    The status should equal 0
    The stdout should include "winners=1"
    # The loser must be told why, in terms a person can act on.
    The stderr should include "has moved since you last fetched"
  End
End
