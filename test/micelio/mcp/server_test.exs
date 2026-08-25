defmodule Micelio.MCP.ServerTest do
  use Micelio.Case, async: true

  alias Micelio.Auth.Principal
  alias Micelio.Control
  alias Micelio.Git
  alias Micelio.Issues
  alias Micelio.MCP.Server
  alias Micelio.Replica

  setup %{repo: repo, namespace: namespace} do
    start_replica_runtime()
    {:ok, _} = Control.create_repository(repo)

    # Scoped to this test's namespace, so the authorization assertions below
    # are testing the grant logic rather than a blanket allow.
    principal = %Principal{
      subject: "agent-1",
      account: namespace,
      grants: [Principal.grant("#{namespace}/**", [:read, :write, :execute])],
      source: :test
    }

    {:ok, principal: principal, opts: [principal: principal, public_url: "http://micelio.test"]}
  end

  defp request(method, params, opts) do
    Server.handle(%{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}, opts)
  end

  defp call_tool(name, args, opts) do
    {:reply, %{result: result}} = request("tools/call", %{"name" => name, "arguments" => args}, opts)
    result
  end

  describe "server/discover" do
    test "reports supported versions, capabilities and identity in one request", %{opts: opts} do
      # Mandatory since 2026-07-28: it replaces the handshake for clients that
      # want to know what they are talking to before they talk to it.
      {:reply, %{result: result}} = request("server/discover", %{}, opts)

      assert result.resultType == "complete"
      assert Server.protocol_version() in result.supportedVersions
      assert result.capabilities.tools
      assert result._meta["io.modelcontextprotocol/serverInfo"].name == "micelio"
      assert is_binary(result.instructions)
    end

    test "is cacheable, because it is derived from compiled-in values", %{opts: opts} do
      {:reply, %{result: result}} = request("server/discover", %{}, opts)

      assert result.ttlMs > 0
      assert result.cacheScope == "public"
    end

    test "needs no handshake first", %{opts: opts} do
      # The whole point of the stateless revision: any request may be the first
      # one, and nothing is remembered between them.
      {:reply, %{result: _}} = request("tools/list", %{}, opts)
      {:reply, %{result: _}} = request("server/discover", %{}, opts)
    end
  end

  describe "per-request protocol version" do
    test "a supported version declared in _meta is accepted", %{opts: opts} do
      params = %{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => Server.protocol_version()}}
      assert {:reply, %{result: _}} = request("tools/list", params, opts)
    end

    test "an unsupported version is refused with the versions we do support", %{opts: opts} do
      params = %{"_meta" => %{"io.modelcontextprotocol/protocolVersion" => "1900-01-01"}}

      assert {:reply, %{error: error}} = request("tools/list", params, opts)
      assert error.code == Server.unsupported_version_code()
      assert error.data.requested == "1900-01-01"
      assert Server.protocol_version() in error.data.supported
    end

    test "a version declared in the transport header is honoured", %{opts: opts} do
      opts = Keyword.put(opts, :protocol_version, "1900-01-01")

      assert {:reply, %{error: error}} = request("tools/list", %{}, opts)
      assert error.code == Server.unsupported_version_code()
    end

    test "a request declaring no version is accepted", %{opts: opts} do
      # A legacy client's follow-up requests carry no version and there is no
      # session to consult, so refusing them would break interoperability for
      # no benefit: this server behaves identically across every revision it
      # supports.
      assert {:reply, %{result: _}} = request("tools/list", %{}, opts)
    end
  end

  describe "initialize" do
    test "is still answered, because legacy clients cannot fall forward", %{opts: opts} do
      {:reply, %{result: result}} = request("initialize", %{"protocolVersion" => "2025-03-26"}, opts)
      assert result.protocolVersion == "2025-03-26"
      assert result.serverInfo.name == "micelio"
    end

    test "falls back to its own version when asked for one it does not know", %{opts: opts} do
      {:reply, %{result: result}} = request("initialize", %{"protocolVersion" => "1999-01-01"}, opts)
      assert result.protocolVersion == Server.protocol_version()
    end

    test "advertises tool and resource capabilities", %{opts: opts} do
      {:reply, %{result: result}} = request("initialize", %{}, opts)
      assert result.capabilities.tools
      assert result.capabilities.resources
    end
  end

  test "a notification is never answered", %{opts: opts} do
    message = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
    assert :noreply = Server.handle(message, opts)
  end

  test "an unknown method is a protocol error", %{opts: opts} do
    assert {:reply, %{error: %{code: -32601}}} = request("nonsense/method", %{}, opts)
  end

  test "tools/list describes every tool with a schema", %{opts: opts} do
    {:reply, %{result: %{tools: tools}}} = request("tools/list", %{}, opts)

    assert length(tools) > 10

    for tool <- tools do
      assert is_binary(tool.name)
      assert is_binary(tool.description)
      assert tool.inputSchema.type == "object"
    end

    names = Enum.map(tools, & &1.name)
    assert "read_file" in names
    assert "commit" in names
    assert "search" in names
    assert "create_issue" in names
    assert "add_issue_comment" in names
    assert "create_work_run" in names
    assert "configure_secret_backend" in names
    assert "get_secret_backend" in names
    assert "configure_inference_profile" in names
    assert "get_inference_profile" in names
    assert "claim_work_node" in names
    assert "complete_work_attempt" in names
  end

  describe "authorization" do
    test "a repository outside the principal's grants is reported as not found", %{opts: opts} do
      result = call_tool("describe_repository", %{"repository" => "other/secret"}, opts)

      assert result.isError
      # Deliberately indistinguishable from a genuinely missing repository, so
      # the tool cannot be used to enumerate what exists.
      assert hd(result.content).text =~ "not found"
    end

    test "a read-only principal cannot create repositories", %{opts: opts, namespace: namespace} do
      reader = %Principal{subject: "r", grants: [Principal.grant("#{namespace}/**", [:read])]}
      opts = Keyword.put(opts, :principal, reader)

      result = call_tool("create_repository", %{"repository" => "#{namespace}/new"}, opts)
      assert result.isError
    end

    test "list_repositories only shows what the principal may read", %{opts: opts, repo: repo} do
      {:ok, _} = Control.create_repository("other/hidden")

      result = call_tool("list_repositories", %{}, opts)

      assert result.structuredContent.repositories == [repo]
    end
  end

  describe "tool errors" do
    test "an ordinary failure is a tool result, not a protocol error", %{opts: opts, repo: repo} do
      # The model has to see this and react, rather than the conversation
      # aborting with a JSON-RPC error.
      result = call_tool("read_file", %{"repository" => repo, "path" => "nope.txt"}, opts)

      assert result.isError
      assert is_binary(hd(result.content).text)
    end

    test "an unknown tool is reported as a tool error", %{opts: opts} do
      result = call_tool("teleport", %{}, opts)
      assert result.isError
      assert hd(result.content).text =~ "unknown tool"
    end
  end

  describe "commit and read" do
    test "writes a file and reads it back", %{opts: opts, repo: repo} do
      write =
        call_tool(
          "commit",
          %{
            "repository" => repo,
            "branch" => "main",
            "message" => "feat: add readme",
            "changes" => [%{"path" => "README.md", "content" => "# hello\n"}]
          },
          opts
        )

      refute write[:isError], inspect(write)
      assert write.structuredContent.commit =~ ~r/^[0-9a-f]{40}$/
      assert write.structuredContent.seq > 0

      read = call_tool("read_file", %{"repository" => repo, "path" => "README.md"}, opts)
      refute read[:isError]
      assert read.structuredContent.content == "# hello\n"
    end

    test "expected_head makes a write conditional", %{opts: opts, repo: repo} do
      call_tool(
        "commit",
        %{
          "repository" => repo,
          "branch" => "main",
          "message" => "one",
          "changes" => [%{"path" => "a.txt", "content" => "a"}]
        },
        opts
      )

      stale =
        call_tool(
          "commit",
          %{
            "repository" => repo,
            "branch" => "main",
            "message" => "two",
            "changes" => [%{"path" => "b.txt", "content" => "b"}],
            "expected_head" => String.duplicate("0", 40)
          },
          opts
        )

      assert stale.isError
      assert hd(stale.content).text =~ "branch is at"
    end

    test "base64 content round trips", %{opts: opts, repo: repo} do
      binary = <<0, 1, 2, 3, 255>>

      call_tool(
        "commit",
        %{
          "repository" => repo,
          "branch" => "main",
          "message" => "binary",
          "changes" => [%{"path" => "blob.bin", "content" => Base.encode64(binary), "encoding" => "base64"}]
        },
        opts
      )

      read = call_tool("read_file", %{"repository" => repo, "path" => "blob.bin"}, opts)
      assert read.structuredContent.encoding == "base64"
      assert Base.decode64!(read.structuredContent.content) == binary
    end

    test "deleting a file omits content", %{opts: opts, repo: repo} do
      call_tool(
        "commit",
        %{
          "repository" => repo,
          "branch" => "main",
          "message" => "add",
          "changes" => [%{"path" => "gone.txt", "content" => "x"}, %{"path" => "kept.txt", "content" => "y"}]
        },
        opts
      )

      call_tool(
        "commit",
        %{
          "repository" => repo,
          "branch" => "main",
          "message" => "remove",
          "changes" => [%{"path" => "gone.txt"}]
        },
        opts
      )

      assert call_tool("read_file", %{"repository" => repo, "path" => "gone.txt"}, opts).isError
      refute call_tool("read_file", %{"repository" => repo, "path" => "kept.txt"}, opts)[:isError]
    end
  end

  describe "issues" do
    test "creates, changes, and reads comments through authorized tools", %{opts: opts, repo: repo} do
      created =
        call_tool(
          "create_issue",
          %{"repository" => repo, "title" => "Documentation", "body" => "Explain issue storage."},
          opts
        )

      refute created[:isError], inspect(created)
      assert created.structuredContent.issue.author.subject == "agent-1"
      assert created.structuredContent.issue.number == 1

      comment =
        call_tool(
          "add_issue_comment",
          %{"repository" => repo, "issue" => 1, "body" => "I can take this."},
          opts
        )

      refute comment[:isError], inspect(comment)
      [first_comment] = comment.structuredContent.issue.comments

      changed =
        call_tool(
          "update_issue_comment",
          %{
            "repository" => repo,
            "issue" => 1,
            "comment" => first_comment.id,
            "body" => "I have taken this."
          },
          opts
        )

      refute changed[:isError], inspect(changed)
      assert [%{body: "I have taken this."}] = changed.structuredContent.issue.comments

      history = call_tool("issue_history", %{"repository" => repo, "issue" => 1}, opts)
      refute history[:isError], inspect(history)

      assert Enum.map(history.structuredContent.events, & &1.type) == [
               "issue_opened",
               "comment_added",
               "comment_updated"
             ]
    end

    test "does not expose the private issue reference through source tools", %{opts: opts, repo: repo} do
      created =
        call_tool(
          "create_issue",
          %{"repository" => repo, "title" => "Private state"},
          opts
        )

      refute created[:isError]

      refs = call_tool("list_refs", %{"repository" => repo}, opts)
      refute Enum.any?(refs.structuredContent.refs, &(&1.ref == Issues.ref()))

      result =
        call_tool(
          "read_file",
          %{"repository" => repo, "ref" => Issues.ref(), "path" => "issues/1/state.json"},
          opts
        )

      assert result.isError
      assert hd(result.content).text =~ "reference not found"

      assert {:ok, view} = Replica.ensure_fresh(repo)
      assert {:ok, refs} = Git.refs(view.path)
      private_commit = Map.fetch!(refs, Issues.ref())

      result =
        call_tool(
          "read_file",
          %{
            "repository" => repo,
            "ref" => private_commit,
            "path" => "issues/1/state.json"
          },
          opts
        )

      assert result.isError
      assert hd(result.content).text =~ "reference not found"

      result =
        call_tool(
          "create_branch",
          %{
            "repository" => repo,
            "branch" => "would-leak-issue-state",
            "target" => private_commit
          },
          opts
        )

      assert result.isError
      assert hd(result.content).text =~ "reference not found"
    end
  end

  describe "work runs" do
    test "configures an account backend and inference profile without accepting a credential value", %{
      opts: opts,
      repo: repo,
      namespace: namespace
    } do
      administrator = %Principal{
        subject: "factory-administrator",
        account: namespace,
        grants: [Principal.grant("#{namespace}/**", [:admin])],
        source: :test
      }

      opts = Keyword.put(opts, :principal, administrator)

      backend =
        call_tool(
          "configure_secret_backend",
          %{
            "repository" => repo,
            "backend" => "production",
            "project" => "acme-production"
          },
          opts
        )

      refute backend[:isError], inspect(backend)

      configured =
        call_tool(
          "configure_inference_profile",
          %{
            "repository" => repo,
            "profile" => "coding",
            "endpoint" => "https://inference.example.com/v1",
            "model" => "coding-model",
            "credential_binding" => %{
              "backend" => "production",
              "identity_id" => "coding-machine-identity",
              "secret" => %{"reference" => "/production/coding", "field" => "api_key"}
            }
          },
          opts
        )

      refute configured[:isError], inspect(configured)
      refute Map.has_key?(configured.structuredContent, "token")

      fetched = call_tool("get_inference_profile", %{"repository" => repo, "profile" => "coding"}, opts)
      refute fetched[:isError], inspect(fetched)

      assert fetched.structuredContent["credential_binding"]["backend"] == "production"
      refute Map.has_key?(fetched.structuredContent, "token")

      fetched_backend =
        call_tool("get_secret_backend", %{"repository" => repo, "backend" => "production"}, opts)

      refute fetched_backend[:isError], inspect(fetched_backend)
      assert fetched_backend.structuredContent["driver"] == "managed_infisical"
    end

    test "uses a mocked Condukt operation without needing a model session", %{opts: opts, repo: repo} do
      seeded =
        call_tool(
          "commit",
          %{
            "repository" => repo,
            "branch" => "main",
            "message" => "feat: seed factory work",
            "changes" => [%{"path" => "README.md", "content" => "# factory fixture\n"}]
          },
          opts
        )

      refute seeded[:isError], inspect(seeded)
      base_commit = seeded.structuredContent.commit

      created =
        call_tool(
          "create_work_run",
          %{
            "repository" => repo,
            "base_commit" => base_commit,
            "graph" => %{
              "nodes" => [
                %{
                  "id" => "implement",
                  "title" => "Implement issue",
                  "execution" => %{
                    "type" => "condukt_operation",
                    "operation" => "implement_issue",
                    "input" => %{"issue" => 7}
                  }
                }
              ]
            }
          },
          opts
        )

      refute created[:isError], inspect(created)
      run_id = created.structuredContent.id

      claimed =
        call_tool(
          "claim_work_node",
          %{"repository" => repo, "run" => run_id, "executor" => "mock-condukt-pod"},
          opts
        )

      refute claimed[:isError], inspect(claimed)
      assert claimed.structuredContent.work.node["execution"]["type"] == "condukt_operation"
      assert claimed.structuredContent.work.node["execution"]["operation"] == "implement_issue"
      attempt_id = claimed.structuredContent.attempt["id"]

      completed =
        call_tool(
          "complete_work_attempt",
          %{
            "repository" => repo,
            "run" => run_id,
            "node" => "implement",
            "attempt" => attempt_id,
            "outcome" => "succeeded",
            "artifacts" => [%{"name" => "mocked-worker-log"}]
          },
          opts
        )

      refute completed[:isError], inspect(completed)
      assert completed.structuredContent.status == "succeeded"

      events = call_tool("work_run_events", %{"repository" => repo, "run" => run_id}, opts)
      refute events[:isError], inspect(events)

      assert Enum.map(events.structuredContent.events, & &1["type"]) == [
               "work_run_created",
               "node_claimed",
               "attempt_succeeded"
             ]
    end
  end

  describe "reading" do
    setup %{opts: opts, repo: repo} do
      call_tool(
        "commit",
        %{
          "repository" => repo,
          "branch" => "main",
          "message" => "feat: seed",
          "changes" => [
            %{"path" => "README.md", "content" => "# micelio\nneedle here\n"},
            %{"path" => "lib/app.ex", "content" => "defmodule App do\nend\n"}
          ]
        },
        opts
      )

      :ok
    end

    test "list_tree lists a directory", %{opts: opts, repo: repo} do
      result = call_tool("list_tree", %{"repository" => repo}, opts)
      paths = Enum.map(result.structuredContent.entries, & &1.path)

      assert "README.md" in paths
      assert "lib" in paths
    end

    test "search finds content", %{opts: opts, repo: repo} do
      result = call_tool("search", %{"repository" => repo, "query" => "needle"}, opts)

      assert result.structuredContent.count == 1
      assert hd(result.structuredContent.matches).path == "README.md"
    end

    test "search with no matches is a normal empty result", %{opts: opts, repo: repo} do
      result = call_tool("search", %{"repository" => repo, "query" => "haystack"}, opts)
      refute result[:isError]
      assert result.structuredContent.count == 0
    end

    test "log returns commit history", %{opts: opts, repo: repo} do
      result = call_tool("log", %{"repository" => repo}, opts)

      assert result.structuredContent.count == 1
      assert hd(result.structuredContent.commits).subject == "feat: seed"
    end

    test "list_refs reports the branch", %{opts: opts, repo: repo} do
      result = call_tool("list_refs", %{"repository" => repo}, opts)
      assert Enum.map(result.structuredContent.refs, & &1.ref) == ["refs/heads/main"]
    end

    test "history exposes the write-ahead log", %{opts: opts, repo: repo} do
      result = call_tool("history", %{"repository" => repo}, opts)

      assert result.structuredContent.seq >= 1
      assert hd(result.structuredContent.entries).type == "push"
    end

    test "clone_url hands back a usable URL", %{opts: opts, repo: repo} do
      result = call_tool("clone_url", %{"repository" => repo}, opts)
      assert result.structuredContent.http == "http://micelio.test/#{repo}.git"
    end
  end

  describe "branches" do
    setup %{opts: opts, repo: repo} do
      write =
        call_tool(
          "commit",
          %{
            "repository" => repo,
            "branch" => "main",
            "message" => "seed",
            "changes" => [%{"path" => "a", "content" => "a"}]
          },
          opts
        )

      {:ok, commit: write.structuredContent.commit}
    end

    test "creates a branch at a commit", %{opts: opts, commit: commit, repo: repo} do
      result =
        call_tool("create_branch", %{"repository" => repo, "branch" => "feature", "target" => commit}, opts)

      refute result[:isError], inspect(result)
      assert result.structuredContent.oid == commit

      refs = call_tool("list_refs", %{"repository" => repo}, opts).structuredContent.refs
      assert "refs/heads/feature" in Enum.map(refs, & &1.ref)
    end

    test "refuses to move an existing branch without force", %{opts: opts, commit: commit, repo: repo} do
      call_tool("create_branch", %{"repository" => repo, "branch" => "feature", "target" => commit}, opts)

      result =
        call_tool("create_branch", %{"repository" => repo, "branch" => "feature", "target" => commit}, opts)

      assert result.isError
      assert hd(result.content).text =~ "already exists"
    end

    test "deletes a branch", %{opts: opts, commit: commit, repo: repo} do
      call_tool("create_branch", %{"repository" => repo, "branch" => "doomed", "target" => commit}, opts)
      result = call_tool("delete_branch", %{"repository" => repo, "branch" => "doomed"}, opts)

      refute result[:isError]

      refs = call_tool("list_refs", %{"repository" => repo}, opts).structuredContent.refs
      refute "refs/heads/doomed" in Enum.map(refs, & &1.ref)
    end
  end

  describe "resources" do
    test "lists templates rather than enumerating every repository", %{opts: opts} do
      {:reply, %{result: result}} = request("resources/list", %{}, opts)
      assert length(result.resourceTemplates) == 2
    end

    test "reads refs through a resource uri", %{opts: opts, repo: repo} do
      {:reply, %{result: result}} = request("resources/read", %{"uri" => "micelio://#{repo}/refs"}, opts)
      assert hd(result.contents).mimeType == "application/json"
    end

    test "rejects an unrecognised uri", %{opts: opts} do
      assert {:reply, %{error: %{code: -32602}}} =
               request("resources/read", %{"uri" => "http://elsewhere"}, opts)
    end
  end

  test "ping is answered", %{opts: opts} do
    assert {:reply, %{result: %{}}} = request("ping", %{}, opts)
  end
end
