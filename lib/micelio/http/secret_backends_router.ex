defmodule Micelio.HTTP.SecretBackendsRouter do
  @moduledoc false

  use Plug.Router

  import Plug.Conn

  alias Micelio.Factory.SecretBackend
  alias Micelio.HTTP.AuthPlug
  alias Micelio.Policy

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: JSON, pass: ["application/json"])
  plug(:dispatch)

  get "/" do
    with_account(conn, fn account -> SecretBackend.list(account) end)
  end

  get "/:backend" do
    with_account(conn, fn account -> SecretBackend.get(account, backend) end)
  end

  put "/:backend" do
    with_account(conn, fn account ->
      SecretBackend.put(account, backend, conn.body_params, conn.assigns.principal)
    end)
  end

  match _ do
    error(conn, 404, "micelio: endpoint not found")
  end

  defp with_account(conn, fun) do
    with {:ok, repository, conn} <- repository(conn),
         {:ok, conn} <- AuthPlug.authorize(conn, repository, :admin) do
      account = Policy.account_of(repository)

      case AuthPlug.authorize_account(conn, account, :admin) do
        {:ok, conn} -> respond(conn, fun.(account))
        {:halt, conn} -> conn
      end
    else
      {:halt, conn} -> conn
      {:error, conn} -> conn
    end
  end

  defp repository(conn) do
    conn = fetch_query_params(conn)

    case conn.query_params["repository"] do
      repository when is_binary(repository) and byte_size(repository) > 0 -> {:ok, repository, conn}
      _ -> {:error, error(conn, 422, "repository query parameter is required")}
    end
  end

  defp respond(conn, {:ok, payload}), do: json(conn, 200, payload)

  defp respond(conn, {:error, message}) do
    status = if String.contains?(message, "not found"), do: 404, else: 422
    error(conn, status, "micelio: #{message}")
  end

  defp error(conn, status, message), do: json(conn, status, %{error: message})

  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(payload))
  end
end
