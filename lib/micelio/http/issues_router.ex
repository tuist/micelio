defmodule Micelio.HTTP.IssuesRouter do
  @moduledoc false

  use Plug.Router

  import Plug.Conn

  alias Micelio.HTTP.AuthPlug
  alias Micelio.Issues

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: JSON, pass: ["application/json"])
  plug(:dispatch)

  get "/" do
    with_authorized(conn, :read, fn repo_id, _principal -> Issues.list(repo_id) end)
  end

  post "/" do
    with_authorized(
      conn,
      :write,
      fn repo_id, principal ->
        Issues.create(repo_id, conn.body_params["title"], conn.body_params["body"] || "", principal)
      end,
      201
    )
  end

  get "/:issue/history" do
    with_issue(conn, issue, :read, fn repo_id, number, _principal -> Issues.events(repo_id, number) end)
  end

  get "/:issue/comments" do
    with_issue(conn, issue, :read, fn repo_id, number, _principal ->
      with {:ok, %{issue: issue}} <- Issues.get(repo_id, number) do
        {:ok, %{issue: number, comments: issue.comments, count: length(issue.comments)}}
      end
    end)
  end

  post "/:issue/comments" do
    with_issue(
      conn,
      issue,
      :write,
      fn repo_id, number, principal ->
        Issues.add_comment(repo_id, number, conn.body_params["body"], principal)
      end,
      201
    )
  end

  get "/:issue/comments/:comment" do
    with_issue(conn, issue, :read, fn repo_id, number, _principal ->
      Issues.get_comment(repo_id, number, comment)
    end)
  end

  patch "/:issue/comments/:comment" do
    with_issue(conn, issue, :write, fn repo_id, number, principal ->
      Issues.update_comment(repo_id, number, comment, conn.body_params["body"], principal)
    end)
  end

  delete "/:issue/comments/:comment" do
    with_issue(conn, issue, :write, fn repo_id, number, principal ->
      Issues.delete_comment(repo_id, number, comment, principal)
    end)
  end

  get "/:issue" do
    with_issue(conn, issue, :read, fn repo_id, number, _principal -> Issues.get(repo_id, number) end)
  end

  patch "/:issue" do
    with_issue(conn, issue, :write, fn repo_id, number, principal ->
      Issues.update(repo_id, number, issue_changes(conn.body_params), principal)
    end)
  end

  delete "/:issue" do
    with_issue(conn, issue, :write, fn repo_id, number, principal ->
      Issues.delete(repo_id, number, principal)
    end)
  end

  match _ do
    error(conn, 404, "micelio: endpoint not found")
  end

  defp with_issue(conn, raw_number, permission, fun, status \\ 200) do
    with {:ok, number} <- issue_number(raw_number),
         {:ok, repo_id, conn} <- repository(conn),
         {:ok, conn} <- AuthPlug.authorize(conn, repo_id, permission) do
      respond(conn, fun.(repo_id, number, conn.assigns.principal), status)
    else
      {:halt, conn} -> conn
      {:error, :invalid_issue_number} -> error(conn, 422, "issue must be a positive integer")
      {:error, conn} -> conn
    end
  end

  defp with_authorized(conn, permission, fun, status \\ 200) do
    with {:ok, repo_id, conn} <- repository(conn),
         {:ok, conn} <- AuthPlug.authorize(conn, repo_id, permission) do
      respond(conn, fun.(repo_id, conn.assigns.principal), status)
    else
      {:halt, conn} -> conn
      {:error, conn} -> conn
    end
  end

  defp repository(conn) do
    conn = fetch_query_params(conn)

    case conn.query_params["repository"] do
      repo_id when is_binary(repo_id) and byte_size(repo_id) > 0 -> {:ok, repo_id, conn}
      _ -> {:error, error(conn, 422, "repository query parameter is required")}
    end
  end

  defp issue_number(raw_number) do
    case Integer.parse(raw_number) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, :invalid_issue_number}
    end
  end

  defp issue_changes(params) do
    %{}
    |> maybe_put_change(:title, params["title"])
    |> maybe_put_change(:body, params["body"])
    |> maybe_put_change(:state, params["state"])
  end

  defp maybe_put_change(changes, _key, nil), do: changes
  defp maybe_put_change(changes, key, value), do: Map.put(changes, key, value)

  defp respond(conn, {:ok, payload}, status), do: json(conn, status, payload)

  defp respond(conn, {:error, message}, _status) do
    status =
      cond do
        String.contains?(message, "not found") -> 404
        String.contains?(message, "changed concurrently") -> 409
        true -> 422
      end

    error(conn, status, "micelio: #{message}")
  end

  defp error(conn, status, message), do: json(conn, status, %{error: message})

  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(payload))
  end
end
