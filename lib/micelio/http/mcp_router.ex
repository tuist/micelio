defmodule Micelio.HTTP.MCPRouter do
  @moduledoc """
  MCP's Streamable HTTP transport.

  `POST /mcp` accepts a JSON-RPC message and answers with JSON. Server-sent
  events are accepted in the `Accept` header and answered with plain JSON,
  which the specification permits: Micelio never initiates messages, so there
  is nothing a long-lived stream would carry.

  No session state is kept. `Mcp-Session-Id` is echoed if a client sends one,
  purely so client-side correlation works, but nothing on the server depends on
  it. That is what lets an agent be load-balanced across pods freely — there is
  no affinity to preserve, because there is nothing to be affine to.
  """

  @behaviour Plug

  import Plug.Conn

  alias Micelio.HTTP.AuthPlug
  alias Micelio.MCP.Server

  @max_body 8 * 1024 * 1024

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{method: "POST"} = conn, _opts) do
    case conn.assigns[:principal] do
      nil ->
        AuthPlug.challenge(conn)

      principal ->
        with :ok <- check_protocol_version(conn),
             {:ok, body, conn} <- read_json(conn) do
          respond(conn, body, principal)
        else
          {:error, :unsupported_version, version} ->
            json(conn, 400, %{
              jsonrpc: "2.0",
              id: nil,
              error: %{
                code: Server.invalid_request_code(),
                message: "unsupported MCP-Protocol-Version: #{version}",
                data: %{supported: Server.supported_versions()}
              }
            })

          {:error, conn, reason} ->
            json(conn, 400, %{
              jsonrpc: "2.0",
              id: nil,
              error: %{code: Server.parse_error_code(), message: reason}
            })
        end
    end
  end

  # The specification allows a server with nothing to push to decline the
  # server-to-client stream, which is exactly our case.
  def call(%{method: "GET"} = conn, _opts) do
    conn
    |> put_resp_header("allow", "POST, DELETE")
    |> send_resp(405, "micelio: this server does not initiate messages")
  end

  def call(%{method: "DELETE"} = conn, _opts), do: send_resp(conn, 204, "")

  def call(conn, _opts) do
    conn
    |> put_resp_header("allow", "POST, DELETE")
    |> send_resp(405, "")
  end

  defp respond(conn, messages, principal) when is_list(messages) do
    # A batch. Notifications produce nothing, so a batch of only notifications
    # correctly yields an empty acknowledgement rather than an empty array.
    opts = [principal: principal, public_url: Micelio.Config.public_url(conn)]
    replies = messages |> Enum.map(&Server.handle(&1, opts)) |> Enum.flat_map(&collect/1)

    case replies do
      [] -> send_resp(conn, 202, "")
      replies -> json(conn, 200, replies)
    end
  end

  defp respond(conn, message, principal) when is_map(message) do
    opts = [principal: principal, public_url: Micelio.Config.public_url(conn)]

    case Server.handle(message, opts) do
      {:reply, reply} -> json(conn, 200, reply)
      :noreply -> send_resp(conn, 202, "")
    end
  end

  defp respond(conn, _other, _principal) do
    json(conn, 400, %{
      jsonrpc: "2.0",
      id: nil,
      error: %{code: Server.invalid_request_code(), message: "invalid request"}
    })
  end

  defp collect({:reply, reply}), do: [reply]
  defp collect(:noreply), do: []

  defp check_protocol_version(conn) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] ->
        :ok

      [version | _] ->
        if version in Server.supported_versions(), do: :ok, else: {:error, :unsupported_version, version}
    end
  end

  defp read_json(conn) do
    case read_body(conn, length: @max_body, read_length: 256 * 1024) do
      {:ok, body, conn} ->
        case JSON.decode(body) do
          {:ok, decoded} -> {:ok, decoded, conn}
          {:error, _} -> {:error, conn, "request body is not valid JSON"}
        end

      {:more, _partial, conn} ->
        {:error, conn, "request body exceeds #{@max_body} bytes"}

      {:error, reason} ->
        {:error, conn, "could not read request body: #{inspect(reason)}"}
    end
  end

  defp json(conn, status, payload) do
    conn =
      case get_req_header(conn, "mcp-session-id") do
        [session | _] -> put_resp_header(conn, "mcp-session-id", session)
        [] -> conn
      end

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("mcp-protocol-version", Server.protocol_version())
    |> send_resp(status, JSON.encode!(payload))
  end
end
