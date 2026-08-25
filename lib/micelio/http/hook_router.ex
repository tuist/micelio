defmodule Micelio.HTTP.HookRouter do
  @moduledoc """
  The loopback endpoint Git's `pre-receive` hook calls.

  It listens on `127.0.0.1` only and requires a per-process secret that is
  generated at boot and never written to disk. Both matter: this endpoint can
  commit a push to the log, so reaching it must require already being inside
  the node.

  The hook is answered synchronously because its exit code *is* the decision.
  A `200` means the push is durably in the log and Git may apply the reference
  updates; anything else means it is not, and Git will discard the quarantined
  objects as though the push never arrived.
  """

  use Plug.Router

  alias Micelio.Ingest
  alias Micelio.Wal.V1

  plug(:match)
  plug(:dispatch)

  post "/pre-receive" do
    with :ok <- verify_token(conn),
         {:ok, body, conn} <- read_full_body(conn),
         {:ok, commands} <- Ingest.parse_commands(body) do
      repo_id = header(conn, "x-micelio-repository")

      quarantine =
        Ingest.resolve_quarantine(header(conn, "x-micelio-quarantine"), header(conn, "x-micelio-git-dir"))

      actor = %V1.Actor{subject: header(conn, "x-micelio-actor") || "", node: Micelio.Config.node_id()}

      case Ingest.commit(repo_id, commands: commands, quarantine: quarantine, actor: actor) do
        {:ok, result} ->
          send_resp(conn, 200, JSON.encode!(%{seq: result.seq, epoch: result.epoch}))

        {:error, message} ->
          # The body is shown verbatim to whoever ran `git push`.
          send_resp(conn, 409, message)
      end
    else
      {:error, :unauthorized} -> send_resp(conn, 401, "micelio: hook token rejected\n")
      {:error, reason} when is_binary(reason) -> send_resp(conn, 400, reason)
      {:error, reason} -> send_resp(conn, 400, "micelio: #{inspect(reason)}\n")
    end
  end

  get "/health" do
    send_resp(conn, 200, "ok")
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp verify_token(conn) do
    expected = Micelio.Config.hook_token()

    case header(conn, "x-micelio-token") do
      nil ->
        {:error, :unauthorized}

      token when byte_size(token) == byte_size(expected) ->
        if :crypto.hash_equals(token, expected), do: :ok, else: {:error, :unauthorized}

      _ ->
        {:error, :unauthorized}
    end
  end

  defp read_full_body(conn, acc \\ []) do
    case read_body(conn, length: 1_000_000) do
      {:ok, chunk, conn} -> {:ok, acc |> Enum.reverse() |> then(&[&1, chunk]) |> IO.iodata_to_binary(), conn}
      {:more, chunk, conn} -> read_full_body(conn, [chunk | acc])
      {:error, reason} -> {:error, reason}
    end
  end

  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _] when value != "" -> value
      _ -> nil
    end
  end
end
