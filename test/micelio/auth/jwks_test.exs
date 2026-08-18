defmodule Micelio.Auth.JWKSTest do
  @moduledoc """
  Key retrieval against a real HTTP endpoint.

  These are integration tests rather than stubbed ones on purpose. The bug that
  made OIDC authentication impossible — a monotonic-clock comparison meaning
  the keys were never fetched at all — was invisible to every test that stubbed
  the fetch, because stubbing the fetch assumes the fetch happens.
  """

  use ExUnit.Case, async: true

  alias Micelio.Auth.JWKS

  defmodule Issuer do
    @moduledoc false
    # A minimal stand-in for an identity provider: a discovery document and a
    # JWKS, over real HTTP.
    import Plug.Conn

    def init(keys), do: keys

    def call(%{request_path: "/.well-known/openid-configuration"} = conn, _keys) do
      issuer = "http://127.0.0.1:#{conn.port}"

      body =
        JSON.encode!(%{
          "issuer" => issuer,
          "jwks_uri" => issuer <> "/keys",
          "id_token_signing_alg_values_supported" => ["RS256"]
        })

      conn |> put_resp_content_type("application/json") |> send_resp(200, body)
    end

    def call(%{request_path: "/keys"} = conn, keys) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, JSON.encode!(%{"keys" => keys}))
    end

    def call(conn, _keys), do: send_resp(conn, 404, "")
  end

  setup do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, public} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    public = Map.merge(public, %{"kid" => "test-key", "alg" => "RS256", "use" => "sig"})

    listener =
      start_supervised!(
        {Bandit, plug: {Issuer, [public]}, scheme: :http, port: 0, startup_log: false},
        id: :issuer
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(listener)

    # Its own instance, so these tests neither depend on nor disturb the one the
    # application runs.
    name = :"jwks_#{:erlang.unique_integer([:positive])}"
    start_supervised!(%{id: name, start: {JWKS, :start_link, [[name: name]]}})

    {:ok, config: [issuer: "http://127.0.0.1:#{port}", server: name]}
  end

  test "fetches a key on the very first request", %{config: config} do
    # The regression. A fresh process has never fetched anything, and "never"
    # must count as "long enough ago" — Erlang's monotonic clock starts at a
    # large negative number, so comparing against a zero default concludes the
    # opposite and no fetch ever happens.
    assert {:ok, jwk} = JWKS.fetch("test-key", config)
    assert jwk
  end

  test "discovers the issuer from the endpoint", %{config: config} do
    expected = Keyword.fetch!(config, :issuer)
    assert {:ok, ^expected} = JWKS.issuer(config)
  end

  test "a configured issuer is returned without asking anyone", %{config: config} do
    config = Keyword.put(config, :issuer, "https://configured.example.com")
    assert {:ok, "https://configured.example.com"} = JWKS.issuer(config)
  end

  test "an unknown key id is reported rather than silently accepted", %{config: config} do
    assert {:error, {:unknown_key, "nope"}} = JWKS.fetch("nope", config)
  end

  test "an unreachable issuer is an error, not an empty key set", %{config: config} do
    config = Keyword.put(config, :issuer, "http://127.0.0.1:1")
    assert {:error, _reason} = JWKS.fetch("test-key", config)
  end

  test "a repeat lookup is served from cache", %{config: config} do
    assert {:ok, first} = JWKS.fetch("test-key", config)
    assert {:ok, second} = JWKS.fetch("test-key", config)
    assert first == second
  end

  test "pointing at a different issuer does not keep answering from the old one", %{config: config} do
    assert {:ok, _} = JWKS.issuer(config)

    # The discovery document is cached; it must be cached per configuration,
    # or a node reconfigured to a new issuer keeps trusting the previous one.
    moved = Keyword.put(config, :issuer, "https://elsewhere.example.com")
    assert {:ok, "https://elsewhere.example.com"} = JWKS.issuer(moved)
  end
end
