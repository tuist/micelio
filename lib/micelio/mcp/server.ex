defmodule Micelio.MCP.Server do
  @moduledoc """
  JSON-RPC dispatch for the Model Context Protocol.

  Kept deliberately transport-free: it takes a decoded request and a principal
  and returns a decoded response, so the HTTP layer stays a thin adapter and
  the protocol can be exercised in tests without a socket.

  ## Stateless, in the protocol's own terms

  Revision `2026-07-28` removed the `initialize` handshake: every request
  declares its own protocol version in `_meta`, and the server accepts or
  rejects each one independently. `server/discover` replaces the handshake for
  clients that want to ask up front.

  That is a good fit here, because it was already true of this implementation.
  Nothing is stored between requests: every request carries its own credential
  and every tool call is routed to the right node from scratch, so an agent can
  be load-balanced across pods mid-conversation without anything breaking. A
  session store would be the one piece of cluster-wide mutable state this
  architecture has otherwise managed to avoid, and it would have to be
  replicated, expired and reconciled.

  ## Dual-era

  Legacy clients (`2025-11-25` and earlier) still open with `initialize`, and
  that path is kept: those clients have no fall-forward mechanism, so dropping
  it would simply break them. A request carrying modern `_meta` is served under
  the current revision; an `initialize` selects legacy semantics. Since this
  server holds no session state either way, the two eras differ only in how a
  version is declared.
  """

  require Logger

  alias Micelio.MCP.Tools

  # JSON-RPC 2.0 error codes, named because -32601 means nothing on sight.
  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602

  # The current revision, and every earlier one whose semantics this server
  # still satisfies. Nothing here holds session state, so supporting the older
  # handshake-based revisions costs only the `initialize` clause.
  @protocol_version "2026-07-28"
  @supported_versions ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

  # Where a modern request declares its version.
  @version_meta_key "io.modelcontextprotocol/protocolVersion"
  @server_info_meta_key "io.modelcontextprotocol/serverInfo"

  # Reserved by the specification for an unsupported protocol version.
  @unsupported_version -32_022

  @spec protocol_version() :: String.t()
  def protocol_version, do: @protocol_version

  @spec supported_versions() :: [String.t()]
  def supported_versions, do: @supported_versions

  @doc "The JSON-RPC code for a body that could not be parsed."
  @spec parse_error_code() :: integer()
  def parse_error_code, do: @parse_error

  @doc "The JSON-RPC code for a structurally invalid request."
  @spec invalid_request_code() :: integer()
  def invalid_request_code, do: @invalid_request

  @doc "The specification's code for an unsupported protocol version."
  @spec unsupported_version_code() :: integer()
  def unsupported_version_code, do: @unsupported_version

  @doc """
  Handle one JSON-RPC message.

  Returns `{:reply, response}` for requests and `:noreply` for notifications,
  which the transport turns into a `202` with no body.
  """
  @spec handle(map(), keyword()) :: {:reply, map()} | :noreply
  def handle(%{"method" => method} = message, opts) do
    id = Map.get(message, "id")
    params = Map.get(message, "params") || %{}

    started = System.monotonic_time(:microsecond)

    result =
      case check_version(method, params, opts) do
        :ok -> dispatch(method, params, opts)
        {:error, _, _, _} = error -> error
      end

    :telemetry.execute(
      [:micelio, :mcp, :request],
      %{duration_us: System.monotonic_time(:microsecond) - started},
      %{method: metric_method(method), outcome: elem(result, 0)}
    )

    case {result, id} do
      # A notification has no id and must never be answered.
      {_, nil} -> :noreply
      {{:ok, payload}, id} -> {:reply, %{jsonrpc: "2.0", id: id, result: payload}}
      {{:error, code, message}, id} -> {:reply, error(id, code, message)}
      {{:error, code, message, data}, id} -> {:reply, error(id, code, message, data)}
    end
  end

  def handle(_message, _opts), do: {:reply, error(nil, @invalid_request, "invalid request")}

  # A request declares its version per-request rather than once per session.
  # `initialize` is exempt: it *is* the legacy version declaration.
  #
  # A request that declares nothing is accepted. A legacy client's follow-up
  # requests carry no version, and with no session to consult there is nothing
  # to check them against; since this server behaves identically across every
  # revision it supports, refusing them would break interoperability to prove a
  # point.
  defp check_version("initialize", _params, _opts), do: :ok

  defp check_version(_method, params, opts) do
    declared = get_in(params, ["_meta", @version_meta_key]) || Keyword.get(opts, :protocol_version)

    cond do
      is_nil(declared) -> :ok
      declared in @supported_versions -> :ok
      true -> {:error, @unsupported_version, "Unsupported protocol version", unsupported_data(declared)}
    end
  end

  defp unsupported_data(requested) do
    %{supported: @supported_versions, requested: requested}
  end

  # ----------------------------------------------------------------------
  # Methods
  # ----------------------------------------------------------------------

  # Mandatory in the current revision: it replaces the handshake for clients
  # that want the server's versions, capabilities and identity up front.
  defp dispatch("server/discover", _params, opts) do
    {:ok,
     %{
       resultType: "complete",
       supportedVersions: @supported_versions,
       capabilities: capabilities(),
       instructions: instructions(opts),
       # Discovery is derived entirely from compiled-in values, so it is safe
       # to cache and pointless to recompute.
       ttlMs: 3_600_000,
       cacheScope: "public",
       _meta: %{@server_info_meta_key => server_info()}
     }}
  end

  defp dispatch("initialize", params, opts) do
    requested = params["protocolVersion"]

    # A legacy client cannot fall forward, so answer with something it can use
    # rather than refusing outright.
    version = if requested in @supported_versions, do: requested, else: @protocol_version

    {:ok,
     %{
       protocolVersion: version,
       capabilities: capabilities(),
       serverInfo: server_info(),
       instructions: instructions(opts)
     }}
  end

  defp dispatch("notifications/initialized", _params, _opts), do: {:ok, %{}}
  defp dispatch("notifications/cancelled", _params, _opts), do: {:ok, %{}}
  defp dispatch("ping", _params, _opts), do: {:ok, %{}}

  defp dispatch("tools/list", _params, _opts), do: {:ok, %{tools: Tools.list()}}

  defp dispatch("tools/call", params, opts) do
    name = params["name"]
    args = params["arguments"] || %{}
    principal = Keyword.fetch!(opts, :principal)

    if is_binary(name) do
      execute(name, args, principal, opts)
    else
      {:error, @invalid_params, "tools/call requires a tool name"}
    end
  end

  defp dispatch("resources/list", _params, _opts) do
    {:ok,
     %{
       resources: [],
       resourceTemplates: [
         %{
           uriTemplate: "micelio://{repository}/refs",
           name: "Repository refs",
           description: "Branches and tags with the object ids they point at.",
           mimeType: "application/json"
         },
         %{
           uriTemplate: "micelio://{repository}/blob/{ref}/{path}",
           name: "File contents",
           description: "A file's contents at a revision.",
           mimeType: "text/plain"
         }
       ]
     }}
  end

  defp dispatch("resources/templates/list", params, opts), do: dispatch("resources/list", params, opts)

  defp dispatch("resources/read", params, opts) do
    principal = Keyword.fetch!(opts, :principal)

    case read_resource(params["uri"], principal, opts) do
      {:ok, contents} -> {:ok, %{contents: contents}}
      {:error, message} -> {:error, @invalid_params, message}
    end
  end

  defp dispatch("prompts/list", _params, _opts), do: {:ok, %{prompts: []}}

  defp dispatch("logging/setLevel", _params, _opts), do: {:ok, %{}}

  defp dispatch(method, _params, _opts), do: {:error, @method_not_found, "method not found: #{method}"}

  # The request method becomes a metrics label. Unknown methods must share one
  # value: a client-controlled string would otherwise create an unbounded
  # number of time series.
  defp metric_method(method)
       when method in [
              "initialize",
              "logging/setLevel",
              "notifications/cancelled",
              "notifications/initialized",
              "ping",
              "prompts/list",
              "resources/list",
              "resources/read",
              "resources/templates/list",
              "server/discover",
              "tools/call",
              "tools/list"
            ],
       do: method

  defp metric_method(_method), do: "unknown"

  defp capabilities do
    %{
      tools: %{listChanged: false},
      resources: %{subscribe: false, listChanged: false},
      logging: %{}
    }
  end

  defp server_info do
    %{name: "micelio", title: "Micelio", version: Micelio.version()}
  end

  # ----------------------------------------------------------------------

  defp execute(name, args, principal, opts) do
    case Tools.call(name, args, principal, opts) do
      {:ok, payload} ->
        {:ok,
         %{
           content: [%{type: "text", text: render(payload)}],
           structuredContent: payload,
           isError: false
         }}

      {:error, message} ->
        # A tool that fails for an ordinary reason ("branch moved", "file not
        # found") reports it as a tool result rather than a protocol error, so
        # the model sees it and can react instead of the conversation aborting.
        {:ok, %{content: [%{type: "text", text: message}], isError: true}}
    end
  rescue
    error ->
      Logger.error("mcp tool #{name} crashed: #{Exception.format(:error, error, __STACKTRACE__)}")
      {:ok, %{content: [%{type: "text", text: "tool #{name} failed unexpectedly"}], isError: true}}
  end

  defp render(payload) when is_binary(payload), do: payload
  defp render(payload), do: JSON.encode!(payload)

  defp read_resource("micelio://" <> rest, principal, opts) do
    case String.split(rest, "/") do
      [account, name, "refs"] ->
        with {:ok, result} <-
               Tools.call("list_refs", %{"repository" => "#{account}/#{name}"}, principal, opts) do
          {:ok, [%{uri: "micelio://#{rest}", mimeType: "application/json", text: JSON.encode!(result)}]}
        end

      [account, name, "blob", ref | path] ->
        args = %{"repository" => "#{account}/#{name}", "ref" => ref, "path" => Enum.join(path, "/")}

        with {:ok, result} <- Tools.call("read_file", args, principal, opts) do
          {:ok, [%{uri: "micelio://#{rest}", mimeType: "text/plain", text: result.content}]}
        end

      _ ->
        {:error, "unrecognised resource uri"}
    end
  end

  defp read_resource(uri, _principal, _opts), do: {:error, "unrecognised resource uri: #{inspect(uri)}"}

  defp instructions(opts) do
    url = Keyword.get(opts, :public_url) || Micelio.Config.public_url()

    """
    Micelio is a Git host. You can read, search and commit to repositories through these
    tools without cloning anything.

    Repositories are identified as account/name, for example acme/ios-app. Use
    list_repositories to see what you can reach.

    Reading: read_file, list_tree, search and log all take an optional ref (branch, tag or
    commit) and default to the repository's default branch.

    Writing: commit writes files and creates a commit in one call. Pass expected_head when
    you need the write to fail rather than overwrite a concurrent change. Writes are
    durable and ordered the moment the call returns.

    If you genuinely need a working tree, clone_url gives you a URL to clone from: #{url}
    """
    |> String.trim()
  end

  defp error(id, code, message, data \\ nil) do
    payload = %{code: code, message: message}
    payload = if data, do: Map.put(payload, :data, data), else: payload
    %{jsonrpc: "2.0", id: id, error: payload}
  end
end
