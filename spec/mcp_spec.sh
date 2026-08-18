# shellcheck shell=bash
Describe 'MCP'
  Describe 'discovery'
    It 'publishes protected resource metadata'
      When run curl -sS "${NODE1_URL}/.well-known/oauth-protected-resource"
      The status should equal 0
      The output should include '"resource"'
      The output should include '"bearer_methods_supported"'
    End

    It 'challenges an unauthenticated request with Bearer only'
      # Advertising Basic here would make a browser pop a password prompt for
      # something no human logs into.
      When run curl -sS -i -X POST -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"ping"}' "${NODE1_URL}/mcp"
      The status should equal 0
      The output should include "401"
      The output should include "Bearer"
      The output should not include 'Basic realm'
    End
  End

  Describe 'protocol'
    It 'answers server/discover without any handshake'
      # The stateless revision: the first request a client makes can be any
      # request, and nothing is remembered between them.
      When run bash -c "mcp '$NODE1_URL' '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\",\"params\":{}}'"
      The status should equal 0
      The output should include '"supportedVersions"'
      The output should include "2026-07-28"
      The output should include "micelio"
    End

    It 'refuses a protocol version it does not implement, and says which it does'
      When run bash -c "mcp '$NODE1_URL' '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"1900-01-01\"}}}'"
      The status should equal 0
      The output should include "-32022"
      The output should include '"supported"'
    End

    It 'still answers the legacy handshake'
      # Legacy clients have no fall-forward mechanism, so dropping this would
      # simply break them.
      When run bash -c "mcp '$NODE1_URL' '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\"}}'"
      The status should equal 0
      The output should include '"serverInfo"'
      The output should include "micelio"
    End

    It 'lists tools'
      When run bash -c "mcp '$NODE1_URL' '{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}'"
      The status should equal 0
      The output should include "read_file"
      The output should include "commit"
      The output should include "search"
    End

    It 'answers a notification with 202 and no body'
      When run curl -sS -o /dev/null -w '%{http_code}' -X POST \
        -H "Authorization: Bearer ${E2E_TOKEN}" \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
        "${NODE1_URL}/mcp"
      The status should equal 0
      The output should equal "202"
    End
  End

  Describe 'as a forge'
    It 'commits and reads back without cloning'
      repo=$(new_repo)
      admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null

      When run bash -c "
        set -e
        mcp '$NODE1_URL' '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"commit\",\"arguments\":{\"repository\":\"$repo\",\"branch\":\"main\",\"message\":\"feat: from an agent\",\"changes\":[{\"path\":\"AGENT.md\",\"content\":\"written by an agent\"}]}}}' >/dev/null
        mcp '$NODE1_URL' '{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"read_file\",\"arguments\":{\"repository\":\"$repo\",\"path\":\"AGENT.md\"}}}'
      "
      The status should equal 0
      The output should include "written by an agent"
    End

    It 'makes an agent commit visible to git on another node'
      # The claim that matters: writes through MCP are real Git writes, and
      # they go through the same log, so a plain clone from a different node
      # sees them.
      repo=$(new_repo)
      clone=$(mktemp -d)/clone
      admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null

      When run bash -c "
        set -e
        mcp '$NODE1_URL' '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"commit\",\"arguments\":{\"repository\":\"$repo\",\"branch\":\"main\",\"message\":\"feat: agent\",\"changes\":[{\"path\":\"hello.txt\",\"content\":\"from mcp\"}]}}}' >/dev/null
        git clone -q '$(git_url "$NODE2_URL" "$repo")' '$clone'
        cat '$clone/hello.txt'
      "
      The status should equal 0
      The output should include "from mcp"
    End

    It 'searches server-side'
      repo=$(new_repo)
      admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null

      When run bash -c "
        set -e
        mcp '$NODE1_URL' '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"commit\",\"arguments\":{\"repository\":\"$repo\",\"branch\":\"main\",\"message\":\"seed\",\"changes\":[{\"path\":\"a.txt\",\"content\":\"find the needle here\"}]}}}' >/dev/null
        mcp '$NODE1_URL' '{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"search\",\"arguments\":{\"repository\":\"$repo\",\"query\":\"needle\"}}}'
      "
      The status should equal 0
      The output should include "a.txt"
    End

    It 'reports an unauthorized repository as not found rather than forbidden'
      When run bash -c "mcp '$NODE1_URL' '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"describe_repository\",\"arguments\":{\"repository\":\"someone-else/private\"}}}'"
      The status should equal 0
      The output should include "not found"
      The output should not include "forbidden"
    End

    It 'refuses a conditional commit when the branch moved'
      repo=$(new_repo)
      admin "$NODE1_ADMIN_URL" POST /repositories -d "{\"repository\":\"$repo\"}" >/dev/null

      When run bash -c "
        set -e
        mcp '$NODE1_URL' '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"commit\",\"arguments\":{\"repository\":\"$repo\",\"branch\":\"main\",\"message\":\"one\",\"changes\":[{\"path\":\"a\",\"content\":\"a\"}]}}}' >/dev/null
        mcp '$NODE1_URL' '{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"commit\",\"arguments\":{\"repository\":\"$repo\",\"branch\":\"main\",\"message\":\"two\",\"changes\":[{\"path\":\"b\",\"content\":\"b\"}],\"expected_head\":\"0000000000000000000000000000000000000000\"}}}'
      "
      The status should equal 0
      The output should include "branch is at"
    End
  End
End
