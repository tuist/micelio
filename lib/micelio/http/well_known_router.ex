defmodule Micelio.HTTP.WellKnownRouter do
  @moduledoc """
  OAuth 2.1 protected-resource metadata.

  Micelio is a resource server: it validates tokens and never issues them. This
  document is how an MCP client discovers that, and where to go to get a token,
  without anyone having to configure it out of band.

  Publishing `resource` here and verifying the same value in each token's `aud`
  claim is what binds a token to this deployment. Without that binding, a token
  minted for any other service sharing the same issuer would be replayable
  against Micelio — the confused-deputy problem the MCP authorization spec
  exists to prevent.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/oauth-protected-resource" do
    send_json(conn, %{
      resource: Micelio.Config.resource_identifier(),
      authorization_servers: Micelio.Config.authorization_servers(),
      bearer_methods_supported: ["header"],
      scopes_supported: ["read", "write", "admin"],
      resource_documentation: "https://github.com/tuist/micelio/blob/main/docs/mcp.md"
    })
  end

  # Some clients probe this path first; answering it with the same document
  # avoids a spurious failure before they try the correct one.
  get "/oauth-protected-resource/mcp" do
    send_json(conn, %{
      resource: Micelio.Config.resource_identifier(),
      authorization_servers: Micelio.Config.authorization_servers(),
      bearer_methods_supported: ["header"],
      scopes_supported: ["read", "write", "admin"]
    })
  end

  # Git itself cannot discover an OAuth client or open a browser. This document
  # is consumed by the repository's setup script, which configures Git
  # Credential Manager for this exact origin. It is absent unless an operator
  # explicitly configured a public OAuth client for the deployment.
  get "/micelio-git-auth" do
    case Micelio.Config.git_auth() do
      nil ->
        send_resp(conn, 404, "")

      git_auth ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_content_type("text/plain")
        |> send_resp(200, git_auth_document(git_auth))
    end
  end

  match _ do
    send_resp(conn, 404, "")
  end

  defp send_json(conn, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(payload))
  end

  defp git_auth_document(git_auth) do
    [
      "version=1",
      "issuer=#{git_auth.issuer}",
      "client_id=#{git_auth.client_id}",
      "authorization_endpoint=#{git_auth.authorization_endpoint}",
      "token_endpoint=#{git_auth.token_endpoint}",
      "redirect_uri=#{git_auth.redirect_uri}",
      "scopes=#{Enum.join(git_auth.scopes, " ")}",
      "username=#{git_auth.username}"
    ]
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end
end
