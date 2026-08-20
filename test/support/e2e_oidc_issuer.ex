defmodule Micelio.E2EOIDCIssuer do
  @moduledoc false

  import Plug.Conn

  def run(port, token_path) do
    key = JOSE.JWK.generate_key({:rsa, 2048})
    {_, public} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    public = Map.merge(public, %{"kid" => "e2e-key", "alg" => "RS256", "use" => "sig"})
    issuer = "https://127.0.0.1:4443/issuer"
    now = System.system_time(:second)

    {_, token} =
      key
      |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => "e2e-key"}, %{
        "iss" => issuer,
        "aud" => "micelio",
        "sub" => "e2e-developer",
        "exp" => now + 3600,
        "iat" => now,
        "micelio_grants" => ["acme/**:read,write"]
      })
      |> JOSE.JWS.compact()

    File.write!(token_path, token)

    {:ok, _} =
      Bandit.start_link(plug: {__MODULE__, %{issuer: issuer, key: public}}, scheme: :http, port: port)

    Process.sleep(:infinity)
  end

  def init(state), do: state

  def call(%{request_path: "/issuer/.well-known/openid-configuration"} = conn, %{issuer: issuer}) do
    body = JSON.encode!(%{"issuer" => issuer, "jwks_uri" => issuer <> "/keys"})
    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  def call(%{request_path: "/issuer/keys"} = conn, %{key: key}) do
    conn |> put_resp_content_type("application/json") |> send_resp(200, JSON.encode!(%{"keys" => [key]}))
  end

  def call(%{request_path: "/issuer/register"} = conn, _state) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      201,
      JSON.encode!(%{
        "client_id" => "e2e-dynamic-client",
        "redirect_uris" => ["http://127.0.0.1"],
        "token_endpoint_auth_method" => "none"
      })
    )
  end

  def call(conn, _state), do: send_resp(conn, 404, "")
end
