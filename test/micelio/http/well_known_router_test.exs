defmodule Micelio.HTTP.WellKnownRouterTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Micelio.Config
  alias Micelio.HTTP.WellKnownRouter

  setup do
    previous = Config.overrides()
    on_exit(fn -> Config.put_overrides(previous) end)
  end

  test "does not advertise browser Git login until an operator enables it" do
    Config.put_overrides(%{git_auth: nil})

    conn = call("/micelio-git-auth")

    assert conn.status == 404
    assert conn.resp_body == ""
  end

  test "publishes only public Git Credential Manager configuration" do
    Config.put_overrides(%{
      git_auth: %{
        issuer: "https://identity.example.com",
        client_id: "micelio-developers",
        authorization_endpoint: "https://identity.example.com/authorize",
        token_endpoint: "https://identity.example.com/token",
        redirect_uri: "http://127.0.0.1",
        scopes: ["openid", "profile", "offline_access"],
        username: "oauth2"
      }
    })

    conn = call("/micelio-git-auth")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    assert conn.resp_body == """
           version=1
           issuer=https://identity.example.com
           client_id=micelio-developers
           authorization_endpoint=https://identity.example.com/authorize
           token_endpoint=https://identity.example.com/token
           redirect_uri=http://127.0.0.1
           scopes=openid profile offline_access
           username=oauth2
           """
  end

  defp call(path) do
    conn(:get, path)
    |> WellKnownRouter.call(WellKnownRouter.init([]))
  end
end
