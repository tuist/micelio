defmodule Micelio.Auth.GitAuthTest do
  use ExUnit.Case, async: true

  alias Micelio.Auth.GitAuth

  @opts [
    backend: "oidc",
    kubernetes: false,
    issuer: "https://identity.example.com",
    authorization_endpoint: "https://identity.example.com/authorize",
    token_endpoint: "https://identity.example.com/token",
    registration_endpoint: nil,
    redirect_uri: "http://127.0.0.1",
    scopes: "openid profile",
    username: "oauth2"
  ]

  test "leaves browser login disabled without a client id" do
    assert GitAuth.build(nil, @opts) == nil
    assert GitAuth.build("", @opts) == nil
  end

  test "validates and builds public browser-login settings" do
    assert %{issuer: "https://identity.example.com", username: "oauth2", scopes: ["openid", "profile"]} =
             GitAuth.build("micelio-developers", @opts)
  end

  test "builds dynamic client-registration settings without a client id" do
    opts = Keyword.put(@opts, :registration_endpoint, "https://identity.example.com/register")

    assert %{client_id: nil, registration_endpoint: "https://identity.example.com/register"} =
             GitAuth.build(nil, opts)
  end

  test "rejects static and dynamic client settings together" do
    opts = Keyword.put(@opts, :registration_endpoint, "https://identity.example.com/register")

    assert_raise ArgumentError, ~r/mutually exclusive/, fn ->
      GitAuth.build("micelio-developers", opts)
    end
  end

  test "defaults an empty username" do
    assert %{username: "oauth2"} = GitAuth.build("micelio-developers", Keyword.put(@opts, :username, ""))
  end

  for {name, key, value, message} <- [
        {:insecure_issuer, :issuer, "http://identity.example.com", "MICELIO_OIDC_ISSUER"},
        {:credentialed_issuer, :issuer, "https://user:pass@identity.example.com", "MICELIO_OIDC_ISSUER"},
        {:insecure_endpoint, :token_endpoint, "http://identity.example.com/token",
         "MICELIO_GIT_AUTH_TOKEN_ENDPOINT"},
        {:insecure_registration_endpoint, :registration_endpoint, "http://identity.example.com/register",
         "MICELIO_GIT_AUTH_REGISTRATION_ENDPOINT"},
        {:bad_redirect, :redirect_uri, "https://identity.example.com/callback",
         "MICELIO_GIT_AUTH_REDIRECT_URI"},
        {:empty_scopes, :scopes, "", "MICELIO_GIT_AUTH_SCOPES"},
        {:control_character_scope, :scopes, "openid\tprofile", "MICELIO_GIT_AUTH_SCOPES"},
        {:multiline_client_id, :client_id, "micelio\ndevelopers", "MICELIO_GIT_AUTH_CLIENT_ID"},
        {:bad_username, :username, "oauth user", "MICELIO_GIT_AUTH_USERNAME"}
      ] do
    test "rejects #{name}" do
      opts = if unquote(key) == :client_id, do: @opts, else: Keyword.put(@opts, unquote(key), unquote(value))
      client_id = if unquote(key) == :client_id, do: unquote(value), else: "micelio-developers"

      assert_raise ArgumentError, ~r/#{unquote(message)}/, fn ->
        GitAuth.build(client_id, opts)
      end
    end
  end

  test "rejects a non-OpenID Connect or Kubernetes backend" do
    assert_raise ArgumentError, ~r/MICELIO_GIT_AUTH_CLIENT_ID/, fn ->
      GitAuth.build("micelio-developers", Keyword.put(@opts, :backend, "webhook"))
    end

    assert_raise ArgumentError, ~r/MICELIO_GIT_AUTH_CLIENT_ID/, fn ->
      GitAuth.build("micelio-developers", Keyword.put(@opts, :kubernetes, true))
    end
  end
end
