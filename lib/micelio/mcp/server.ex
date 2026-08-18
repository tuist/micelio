defmodule Micelio.MCP.Server do
  @moduledoc """
  JSON-RPC dispatch for the Model Context Protocol.

  Kept deliberately transport-free: it takes a decoded request and a principal
  and returns a decoded response, so the HTTP layer stays a thin adapter and
  the protocol can be exercised in tests without a socket.

  Sessions are not stored. Every request carries its own credential and every
  tool call is routed to the right node from scratch, which means an agent can
  be load-balanced across pods mid-conversation without anything breaking. A
  session store would be the one piece of cluster-wide mutable state this
  design has otherwise managed to avoid, and it would have to be replicated,
  expired and reconciled — so there isn't one.
  """

  require Logger

  alias Micelio.MCP.Tools

  # JSON-RPC 2.0 error codes, named because -32601 means nothing on sight.
  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602

  @protocol_version "2025-06-18"
  @supported_versions ["2025-06-18", "2025-03-26", "2024-11-05"]

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
    result = dispatch(method, params, opts)

    :telemetry.execute(
      [:micelio, :mcp, :request],
      %{duration_us: System.monotonic_time(:microsecond) - started},
      %{method: method, outcome: elem(result, 0)}
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

  # ----------------------------------------------------------------------
  # Methods
  # ----------------------------------------------------------------------

  defp dispatch("initialize", params, opts) do
    requested = params["protocolVersion"]

    version = if requested in @supported_versions, do: requested, else: @protocol_version

    {:ok,
     %{
       protocolVersion: version,
       capabilities: %{
         tools: %{listChanged: false},
         resources: %{subscribe: false, listChanged: false},
         logging: %{}
       },
       serverInfo: %{
         name: "micelio",
         title: "Micelio",
         version: Micelio.version()
       },
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
