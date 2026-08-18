defmodule Micelio.HTTP.GitBackend do
  @moduledoc """
  Streams a request through `git` and its output back to the client.

  Both directions have to be live. A `git clone` of a large monorepo produces
  gigabytes that must not be buffered, and a `git push` sends a packfile of
  arbitrary size that must not be buffered either. So the request body is fed
  to the process in chunks while its output is drained in the same loop.

  Draining while writing is not an optimisation. A pipe has a fixed buffer: if
  we wrote the whole request without reading, and the process wrote enough
  output to fill its side, both ends would block forever waiting for the other.
  Interleaving is what makes that impossible.

  A client that disconnects mid-clone, or a handler that crashes, takes the
  `git` process with it via `Micelio.Git.terminate/1`. Leaked `upload-pack`
  processes are the classic way a Git server degrades into unexplained load.
  """

  require Logger

  import Plug.Conn

  alias Micelio.Git

  @read_chunk 64 * 1024
  @idle_timeout :timer.minutes(30)

  @doc """
  Run `git <args>` against `repo_path`, streaming `conn`'s body in and the
  process output back as the response.
  """
  @spec run(Plug.Conn.t(), Path.t(), [String.t()], keyword()) :: Plug.Conn.t()
  def run(conn, repo_path, args, opts \\ []) do
    content_type = Keyword.fetch!(opts, :content_type)
    env = Keyword.get(opts, :env, [])
    started = System.monotonic_time(:millisecond)

    port = Git.stream(repo_path, args, env: env)

    conn =
      conn
      |> put_resp_content_type(content_type)
      |> put_no_cache()
      |> send_chunked(200)

    result =
      case pump_request(conn, port) do
        {:ok, conn} -> drain(conn, port, 0)
        {:error, conn, reason} -> {:error, conn, reason}
      end

    finish(result, port, started, opts)
  end

  defp finish({:ok, conn, bytes}, _port, started, opts) do
    :telemetry.execute(
      [:micelio, :git, :served],
      %{duration_ms: System.monotonic_time(:millisecond) - started, bytes: bytes},
      %{service: Keyword.get(opts, :service), repo_id: Keyword.get(opts, :repo_id)}
    )

    conn
  end

  defp finish({:error, conn, reason}, port, started, opts) do
    close(port)

    :telemetry.execute(
      [:micelio, :git, :aborted],
      %{duration_ms: System.monotonic_time(:millisecond) - started},
      %{service: Keyword.get(opts, :service), repo_id: Keyword.get(opts, :repo_id), reason: reason}
    )

    Logger.debug("git stream aborted: #{inspect(reason)}")
    conn
  end

  # Read the request body in chunks, writing each to the process and draining
  # whatever it has produced so far.
  defp pump_request(conn, port) do
    case read_body(conn, length: @read_chunk, read_length: @read_chunk) do
      {:more, chunk, conn} ->
        Port.command(port, chunk)

        case drain_available(conn, port) do
          {:ok, conn} -> pump_request(conn, port)
          error -> error
        end

      {:ok, chunk, conn} ->
        if chunk != "", do: Port.command(port, chunk)
        # `--stateless-rpc` treats end of input as end of request, so the
        # process needs to see EOF rather than just a pause.
        close_stdin(port)
        {:ok, conn}

      {:error, reason} ->
        {:error, conn, {:request_body, reason}}
    end
  end

  # A port cannot half-close stdin, so signal end of input the way the wrapper
  # understands: stop writing and let the process see the pipe drain. Git's
  # stateless-rpc mode is framed by a flush packet, which the client already
  # sent, so this is belt and braces rather than the primary mechanism.
  defp close_stdin(_port), do: :ok

  defp drain_available(conn, port) do
    receive do
      {^port, {:data, data}} ->
        case chunk(conn, data) do
          {:ok, conn} -> drain_available(conn, port)
          {:error, reason} -> {:error, conn, {:client_gone, reason}}
        end

      {^port, {:exit_status, status}} ->
        {:error, conn, {:exited_early, status}}
    after
      0 -> {:ok, conn}
    end
  end

  defp drain(conn, port, bytes) do
    receive do
      {^port, {:data, data}} ->
        case chunk(conn, data) do
          {:ok, conn} -> drain(conn, port, bytes + byte_size(data))
          {:error, reason} -> {:error, conn, {:client_gone, reason}}
        end

      {^port, {:exit_status, 0}} ->
        {:ok, conn, bytes}

      {^port, {:exit_status, status}} ->
        # The response is already in flight, so the status cannot become an
        # HTTP error. Git will have written its own protocol-level error to
        # the client before exiting.
        Logger.warning("git exited #{status} mid-stream after #{bytes} bytes")
        {:ok, conn, bytes}
    after
      @idle_timeout -> {:error, conn, :timeout}
    end
  end

  defp close(port), do: Git.terminate(port)

  @doc """
  The advertisement served from `info/refs`.

  Git decides whether a server is smart or dumb from this exact framing, so the
  service header is generated here and the reference list comes from `git`.
  """
  @spec advertise(Plug.Conn.t(), Path.t(), String.t(), keyword()) :: Plug.Conn.t()
  def advertise(conn, repo_path, service, opts \\ []) do
    env = Keyword.get(opts, :env, [])
    command = String.replace_prefix(service, "git-", "")

    case Git.run(repo_path, [command, "--stateless-rpc", "--advertise-refs", repo_path], env: env) do
      {:ok, advertisement} ->
        body =
          if protocol_v2?(env) do
            # Protocol v2 advertises capabilities rather than refs, and the
            # service header is still expected over HTTP.
            Micelio.Git.PktLine.service_header(service) <> advertisement
          else
            Micelio.Git.PktLine.service_header(service) <> advertisement
          end

        conn
        |> put_resp_content_type("application/x-#{service}-advertisement")
        |> put_no_cache()
        |> send_resp(200, body)

      {:error, reason} ->
        Logger.warning("advertisement failed for #{repo_path}: #{inspect(reason)}")

        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(500, "micelio: could not read the repository\n")
    end
  end

  defp protocol_v2?(env), do: Enum.any?(env, fn {k, v} -> k == "GIT_PROTOCOL" and v =~ "version=2" end)

  @doc """
  Headers that stop any cache from serving a stale advertisement.

  Git's own documentation requires these; without them an intermediate proxy
  can hand a client a reference list from before a push and produce failures
  that look like corruption.
  """
  @spec put_no_cache(Plug.Conn.t()) :: Plug.Conn.t()
  def put_no_cache(conn) do
    conn
    |> put_resp_header("expires", "Fri, 01 Jan 1980 00:00:00 GMT")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_header("cache-control", "no-cache, max-age=0, must-revalidate")
  end
end
