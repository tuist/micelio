defmodule Micelio.MCP.ServerTest do
  use Micelio.Case, async: false

  alias Micelio.Auth.Principal
  alias Micelio.Control
  alias Micelio.MCP.Server

  @repo "acme/app"

  setup do
    start_replica_runtime()
    {:ok, _} = Control.create_repository(@repo)

    principal = %Principal{
      subject: "agent-1",
      account: "acme",
      grants: [Principal.grant("acme/**", [:read, :write])],
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

  describe "initialize" do
    test "negotiates a protocol version the client asked for", %{opts: opts} do
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
  end

  describe "authorization" do
    test "a repository outside the principal's grants is reported as not found", %{opts: opts} do
      result = call_tool("describe_repository", %{"repository" => "other/secret"}, opts)

      assert result.isError
      # Deliberately indistinguishable from a genuinely missing repository, so
      # the tool cannot be used to enumerate what exists.
      assert hd(result.content).text =~ "not found"
    end

    test "a read-only principal cannot create repositories", %{opts: opts} do
      reader = %Principal{subject: "r", grants: [Principal.grant("acme/**", [:read])]}
      opts = Keyword.put(opts, :principal, reader)

      result = call_tool("create_repository", %{"repository" => "acme/new"}, opts)
      assert result.isError
    end

    test "list_repositories only shows what the principal may read", %{opts: opts} do
      {:ok, _} = Control.create_repository("other/hidden")

      result = call_tool("list_repositories", %{}, opts)

      assert result.structuredContent.repositories == [@repo]
    end
  end

  describe "tool errors" do
    test "an ordinary failure is a tool result, not a protocol error", %{opts: opts} do
      # The model has to see this and react, rather than the conversation
      # aborting with a JSON-RPC error.
      result = call_tool("read_file", %{"repository" => @repo, "path" => "nope.txt"}, opts)

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
    test "writes a file and reads it back", %{opts: opts} do
      write =
        call_tool(
          "commit",
          %{
            "repository" => @repo,
            "branch" => "main",
            "message" => "feat: add readme",
            "changes" => [%{"path" => "README.md", "content" => "# hello\n"}]
          },
          opts
        )

      refute write[:isError], inspect(write)
      assert write.structuredContent.commit =~ ~r/^[0-9a-f]{40}$/
      assert write.structuredContent.seq > 0

      read = call_tool("read_file", %{"repository" => @repo, "path" => "README.md"}, opts)
      refute read[:isError]
      assert read.structuredContent.content == "# hello\n"
    end

    test "expected_head makes a write conditional", %{opts: opts} do
      call_tool(
        "commit",
        %{
          "repository" => @repo,
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
            "repository" => @repo,
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

    test "base64 content round trips", %{opts: opts} do
      binary = <<0, 1, 2, 3, 255>>

      call_tool(
        "commit",
        %{
          "repository" => @repo,
          "branch" => "main",
          "message" => "binary",
          "changes" => [%{"path" => "blob.bin", "content" => Base.encode64(binary), "encoding" => "base64"}]
        },
        opts
      )

      read = call_tool("read_file", %{"repository" => @repo, "path" => "blob.bin"}, opts)
      assert read.structuredContent.encoding == "base64"
      assert Base.decode64!(read.structuredContent.content) == binary
    end

    test "deleting a file omits content", %{opts: opts} do
      call_tool(
        "commit",
        %{
          "repository" => @repo,
          "branch" => "main",
          "message" => "add",
          "changes" => [%{"path" => "gone.txt", "content" => "x"}, %{"path" => "kept.txt", "content" => "y"}]
        },
        opts
      )

      call_tool(
        "commit",
        %{
          "repository" => @repo,
          "branch" => "main",
          "message" => "remove",
          "changes" => [%{"path" => "gone.txt"}]
        },
        opts
      )

      assert call_tool("read_file", %{"repository" => @repo, "path" => "gone.txt"}, opts).isError
      refute call_tool("read_file", %{"repository" => @repo, "path" => "kept.txt"}, opts)[:isError]
    end
  end

  describe "reading" do
    setup %{opts: opts} do
      call_tool(
        "commit",
        %{
          "repository" => @repo,
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

    test "list_tree lists a directory", %{opts: opts} do
      result = call_tool("list_tree", %{"repository" => @repo}, opts)
      paths = Enum.map(result.structuredContent.entries, & &1.path)

      assert "README.md" in paths
      assert "lib" in paths
    end

    test "search finds content", %{opts: opts} do
      result = call_tool("search", %{"repository" => @repo, "query" => "needle"}, opts)

      assert result.structuredContent.count == 1
      assert hd(result.structuredContent.matches).path == "README.md"
    end

    test "search with no matches is a normal empty result", %{opts: opts} do
      result = call_tool("search", %{"repository" => @repo, "query" => "haystack"}, opts)
      refute result[:isError]
      assert result.structuredContent.count == 0
    end

    test "log returns commit history", %{opts: opts} do
      result = call_tool("log", %{"repository" => @repo}, opts)

      assert result.structuredContent.count == 1
      assert hd(result.structuredContent.commits).subject == "feat: seed"
    end

    test "list_refs reports the branch", %{opts: opts} do
      result = call_tool("list_refs", %{"repository" => @repo}, opts)
      assert Enum.map(result.structuredContent.refs, & &1.ref) == ["refs/heads/main"]
    end

    test "history exposes the write-ahead log", %{opts: opts} do
      result = call_tool("history", %{"repository" => @repo}, opts)

      assert result.structuredContent.seq >= 1
      assert hd(result.structuredContent.entries).type == "push"
    end

    test "clone_url hands back a usable URL", %{opts: opts} do
      result = call_tool("clone_url", %{"repository" => @repo}, opts)
      assert result.structuredContent.http == "http://micelio.test/#{@repo}.git"
    end
  end

  describe "branches" do
    setup %{opts: opts} do
      write =
        call_tool(
          "commit",
          %{
            "repository" => @repo,
            "branch" => "main",
            "message" => "seed",
            "changes" => [%{"path" => "a", "content" => "a"}]
          },
          opts
        )

      {:ok, commit: write.structuredContent.commit}
    end

    test "creates a branch at a commit", %{opts: opts, commit: commit} do
      result =
        call_tool("create_branch", %{"repository" => @repo, "branch" => "feature", "target" => commit}, opts)

      refute result[:isError], inspect(result)
      assert result.structuredContent.oid == commit

      refs = call_tool("list_refs", %{"repository" => @repo}, opts).structuredContent.refs
      assert "refs/heads/feature" in Enum.map(refs, & &1.ref)
    end

    test "refuses to move an existing branch without force", %{opts: opts, commit: commit} do
      call_tool("create_branch", %{"repository" => @repo, "branch" => "feature", "target" => commit}, opts)

      result =
        call_tool("create_branch", %{"repository" => @repo, "branch" => "feature", "target" => commit}, opts)

      assert result.isError
      assert hd(result.content).text =~ "already exists"
    end

    test "deletes a branch", %{opts: opts, commit: commit} do
      call_tool("create_branch", %{"repository" => @repo, "branch" => "doomed", "target" => commit}, opts)
      result = call_tool("delete_branch", %{"repository" => @repo, "branch" => "doomed"}, opts)

      refute result[:isError]

      refs = call_tool("list_refs", %{"repository" => @repo}, opts).structuredContent.refs
      refute "refs/heads/doomed" in Enum.map(refs, & &1.ref)
    end
  end

  describe "resources" do
    test "lists templates rather than enumerating every repository", %{opts: opts} do
      {:reply, %{result: result}} = request("resources/list", %{}, opts)
      assert length(result.resourceTemplates) == 2
    end

    test "reads refs through a resource uri", %{opts: opts} do
      {:reply, %{result: result}} = request("resources/read", %{"uri" => "micelio://acme/app/refs"}, opts)
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
