defmodule Micelio.HTTP.AuthPlug do
  @moduledoc """
  Resolves the caller's credential into a principal.

  Authentication is separated from authorization on purpose: which repository a
  request is about is not known until the route has been parsed, so this plug
  only establishes *who* is calling and leaves *may they* to the routers via
  `authorize/3`.

  A rejected request is answered with a `WWW-Authenticate` challenge that
  points at the protected-resource metadata document. That is what lets an MCP
  client discover where to obtain a token instead of being handed one out of
  band, and it is also what makes `git` prompt for credentials rather than
  failing with an opaque error.
  """

  import Plug.Conn

  alias Micelio.Auth

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    credential =
      conn
      |> get_req_header("authorization")
      |> List.first()
      |> Auth.credential_from_header()

    case Auth.authenticate(credential) do
      {:ok, principal} ->
        conn
        |> assign(:principal, principal)
        |> Micelio.Telemetry.put_span_attributes(%{
          "enduser.id" => principal.subject,
          "micelio.auth.source" => to_string(principal.source)
        })

      {:error, reason} ->
        assign(conn, :auth_error, reason)
    end
  end

  @doc """
  Ensure the request is authenticated and permitted, or halt.

  Note the deliberate choice to answer `404` rather than `403` for a repository
  the caller may not read. Distinguishing the two tells an unauthorized caller
  which repositories exist, which on a multi-tenant Git host leaks the shape of
  every customer's estate.
  """
  @spec authorize(Plug.Conn.t(), String.t(), Micelio.Auth.Principal.permission()) ::
          {:ok, Plug.Conn.t()} | {:halt, Plug.Conn.t()}
  def authorize(conn, repo_id, permission) do
    case conn.assigns[:principal] do
      nil ->
        {:halt, challenge(conn)}

      principal ->
        case Auth.authorize(principal, repo_id, permission) do
          :ok ->
            {:ok, conn}

          {:error, :forbidden} ->
            # A caller who can already see the repository learns nothing from
            # being told it exists, so they get an honest 403. Everyone else
            # gets 404 — including callers authorised by policy rather than by
            # their token, which is why this asks `Auth` rather than inspecting
            # the principal's own grants.
            case Auth.authorize(principal, repo_id, :read) do
              :ok -> {:halt, deny(conn, 403, "micelio: not permitted to #{permission} #{repo_id}")}
              {:error, :forbidden} -> {:halt, deny(conn, 404, "micelio: repository not found")}
            end
        end
    end
  end

  @doc """
  Reject the request with an authentication challenge.

  Two schemes are offered, and which ones depends on the surface:

    * `Basic`, because `git` will not send credentials until it sees a scheme
      it recognises, and `Bearer` is not one of them. Without this a `git
      clone` fails outright instead of prompting, even when the user has
      perfectly good credentials configured.
    * `Bearer`, carrying the location of the protected-resource metadata, which
      is how an MCP client discovers where to obtain a token rather than being
      handed one out of band.

  The MCP endpoint is offered `Bearer` only. Advertising `Basic` there would
  make a browser open a password prompt for something no human is meant to log
  into interactively.
  """
  @spec challenge(Plug.Conn.t()) :: Plug.Conn.t()
  def challenge(conn) do
    bearer = Auth.challenge(resource_metadata_url(conn))

    challenges =
      if mcp?(conn) do
        [{"www-authenticate", bearer}]
      else
        [{"www-authenticate", ~s(Basic realm="micelio")}, {"www-authenticate", bearer}]
      end

    conn
    |> prepend_resp_headers(challenges)
    |> deny(401, "micelio: authentication required")
  end

  defp mcp?(%{path_info: ["mcp" | _]}), do: true
  defp mcp?(_conn), do: false

  defp deny(conn, status, message) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message <> "\n")
    |> halt()
  end

  @doc "URL of this deployment's OAuth protected-resource metadata document."
  @spec resource_metadata_url(Plug.Conn.t()) :: String.t()
  def resource_metadata_url(conn) do
    Micelio.Config.public_url(conn) <> "/.well-known/oauth-protected-resource"
  end
end
