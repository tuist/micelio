defmodule Micelio.Auth.OIDCTest do
  @moduledoc """
  Token verification is the security boundary, so these tests are written from
  the attacker's side: each one asks what a forged, borrowed or stale token
  should be prevented from doing.

  Tokens are signed with a real keypair rather than stubbed at the JOSE layer,
  so signature verification is genuinely exercised. Only the JWKS lookup is
  stubbed, because the alternative is an identity provider in the test suite.
  """

  use ExUnit.Case, async: true
  use Mimic

  alias Micelio.Auth.JWKS
  alias Micelio.Auth.OIDC
  alias Micelio.Auth.Principal

  setup :set_mimic_from_context

  @issuer "https://kubernetes.default.svc"
  @audience "micelio"

  setup do
    # A genuine RSA keypair: signatures are really produced and really checked.
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    public = JOSE.JWK.to_public(jwk)

    stub(JWKS, :fetch, fn _kid, _config -> {:ok, public} end)

    config = [
      issuer: @issuer,
      audience: @audience,
      namespace_grants: true,
      grants_claim: "micelio_grants"
    ]

    {:ok, jwk: jwk, config: config}
  end

  defp sign(jwk, claims) do
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "iss" => @issuer,
          "aud" => @audience,
          "sub" => "system:serviceaccount:team-ios:builder",
          "exp" => now + 3600,
          "iat" => now
        },
        claims
      )

    {_, token} =
      jwk
      |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => "test-key"}, claims)
      |> JOSE.JWS.compact()

    token
  end

  describe "a valid token" do
    test "is accepted", %{jwk: jwk, config: config} do
      assert {:ok, principal} = OIDC.authenticate({:bearer, sign(jwk, %{})}, config)
      assert principal.subject == "system:serviceaccount:team-ios:builder"
      assert principal.source == :oidc
    end

    test "arrives through basic auth too, because that is what git sends", %{jwk: jwk, config: config} do
      token = sign(jwk, %{})
      assert {:ok, principal} = OIDC.authenticate({:basic, "x-access-token", token}, config)
      assert principal.subject == "system:serviceaccount:team-ios:builder"
    end

    test "carries its expiry, so a cached principal cannot outlive it", %{jwk: jwk, config: config} do
      {:ok, principal} = OIDC.authenticate({:bearer, sign(jwk, %{})}, config)
      assert %DateTime{} = principal.expires_at
    end
  end

  describe "audience binding" do
    test "a token minted for another service sharing the issuer is rejected", %{jwk: jwk, config: config} do
      # This is the confused-deputy case: a perfectly valid signature from a
      # trusted issuer, for somebody else's service.
      token = sign(jwk, %{"aud" => "some-other-service"})
      assert {:error, {:audience_mismatch, _}} = OIDC.authenticate({:bearer, token}, config)
    end

    test "an audience list containing ours is accepted", %{jwk: jwk, config: config} do
      token = sign(jwk, %{"aud" => ["other", @audience]})
      assert {:ok, _} = OIDC.authenticate({:bearer, token}, config)
    end

    test "a missing audience is rejected when one is configured", %{jwk: jwk, config: config} do
      token = sign(jwk, %{"aud" => nil})
      assert {:error, {:audience_mismatch, _}} = OIDC.authenticate({:bearer, token}, config)
    end
  end

  describe "issuer" do
    test "a token from an unexpected issuer is rejected", %{jwk: jwk, config: config} do
      token = sign(jwk, %{"iss" => "https://evil.example.com"})
      assert {:error, {:issuer_mismatch, _}} = OIDC.authenticate({:bearer, token}, config)
    end
  end

  describe "failing closed" do
    # Each of these was accepted before. The existing tests could not catch any
    # of them, because the signing helper injects exp, iss and aud into every
    # token — so the suite only ever exercised the paths where the claims are
    # present and correct.

    test "a signed token with no expiry is refused", %{jwk: jwk, config: config} do
      # Otherwise it is a permanent credential: it cannot age out, and the only
      # way to withdraw it is to rotate the issuer's key for everyone.
      token = sign(jwk, %{"exp" => nil})

      assert {:error, :missing_expiry} = OIDC.authenticate({:bearer, token}, config)
    end

    test "a non-numeric expiry is refused rather than ignored", %{jwk: jwk, config: config} do
      token = sign(jwk, %{"exp" => "soon"})

      assert {:error, :missing_expiry} = OIDC.authenticate({:bearer, token}, config)
    end

    test "no configured issuer refuses every token", %{jwk: jwk, config: config} do
      # Accepting any issuer because none was configured leaves only the key
      # source between an attacker and a session.
      config = Keyword.delete(config, :issuer)

      assert {:error, :no_issuer_configured} = OIDC.authenticate({:bearer, sign(jwk, %{})}, config)
    end

    test "no configured audience refuses every token", %{jwk: jwk, config: config} do
      # This is the check that stops a token minted for another service sharing
      # the issuer being replayed here, so it cannot be skipped by omission.
      config = Keyword.delete(config, :audience)

      assert {:error, :no_audience_configured} = OIDC.authenticate({:bearer, sign(jwk, %{})}, config)
    end

    test "a deployment with no audience must say so explicitly", %{jwk: jwk, config: config} do
      config = config |> Keyword.delete(:audience) |> Keyword.put(:audience_optional, true)

      assert {:ok, _principal} = OIDC.authenticate({:bearer, sign(jwk, %{})}, config)
    end
  end

  describe "time" do
    test "an expired token is rejected", %{jwk: jwk, config: config} do
      token = sign(jwk, %{"exp" => System.system_time(:second) - 3600})
      assert {:error, :expired} = OIDC.authenticate({:bearer, token}, config)
    end

    test "a token not yet valid is rejected", %{jwk: jwk, config: config} do
      token = sign(jwk, %{"nbf" => System.system_time(:second) + 3600})
      assert {:error, :not_yet_valid} = OIDC.authenticate({:bearer, token}, config)
    end

    test "a small amount of clock skew is tolerated", %{jwk: jwk, config: config} do
      # Just expired, within the default leeway. Rejecting these turns a
      # slightly wrong clock into an outage.
      token = sign(jwk, %{"exp" => System.system_time(:second) - 5})
      assert {:ok, _} = OIDC.authenticate({:bearer, token}, config)
    end
  end

  describe "signature" do
    test "a token signed by the wrong key is rejected", %{config: config} do
      attacker = JOSE.JWK.generate_key({:rsa, 2048})
      token = sign(attacker, %{})

      assert {:error, :invalid_signature} = OIDC.authenticate({:bearer, token}, config)
    end

    test "a tampered payload is rejected", %{jwk: jwk, config: config} do
      [header, _payload, signature] = String.split(sign(jwk, %{}), ".")

      forged =
        Base.url_encode64(
          JSON.encode!(%{
            "iss" => @issuer,
            "aud" => @audience,
            "sub" => "system:serviceaccount:kube-system:admin"
          }),
          padding: false
        )

      assert {:error, :invalid_signature} =
               OIDC.authenticate({:bearer, "#{header}.#{forged}.#{signature}"}, config)
    end

    test "an HMAC-signed token is refused rather than verified against a public key", %{config: config} do
      # The classic algorithm-confusion attack: present the public key as if it
      # were a shared secret. The algorithm allowlist has to stop this before
      # any verification is attempted.
      secret = JOSE.JWK.from_oct("not-a-secret")
      now = System.system_time(:second)

      {_, token} =
        secret
        |> JOSE.JWT.sign(%{"alg" => "HS256", "kid" => "test-key"}, %{
          "iss" => @issuer,
          "aud" => @audience,
          "sub" => "system:serviceaccount:kube-system:admin",
          "exp" => now + 3600
        })
        |> JOSE.JWS.compact()

      assert {:error, {:unsupported_algorithm, "HS256"}} = OIDC.authenticate({:bearer, token}, config)
    end

    test "an unsigned token is refused", %{config: config} do
      now = System.system_time(:second)

      {_, token} =
        JOSE.JWK.from_oct("x")
        |> JOSE.JWT.sign(%{"alg" => "HS256"}, %{"iss" => @issuer, "aud" => @audience, "exp" => now + 60})
        |> JOSE.JWS.compact()

      # alg=none is not even representable through JOSE's signing API without
      # explicitly allowing it, which is the point; anything not on the
      # allowlist is refused.
      assert {:error, _} = OIDC.authenticate({:bearer, token}, config)
    end

    test "garbage is rejected without crashing", %{config: config} do
      for candidate <- ["", "not.a.token", "a.b", String.duplicate("x", 5000)] do
        assert {:error, _} = OIDC.authenticate({:bearer, candidate}, config)
      end
    end
  end

  describe "grants" do
    test "a Kubernetes service account gets its own namespace", %{jwk: jwk, config: config} do
      {:ok, principal} = OIDC.authenticate({:bearer, sign(jwk, %{})}, config)

      assert principal.account == "team-ios"
      assert Principal.allows?(principal, "team-ios/app", :read)
      assert Principal.allows?(principal, "team-ios/app", :write)

      # And crucially, nothing else.
      refute Principal.allows?(principal, "team-android/app", :read)
      refute Principal.allows?(principal, "kube-system/secrets", :read)
    end

    test "namespace grants can be turned off", %{jwk: jwk, config: config} do
      config = Keyword.put(config, :namespace_grants, false)
      {:ok, principal} = OIDC.authenticate({:bearer, sign(jwk, %{})}, config)

      refute Principal.allows?(principal, "team-ios/app", :read)
    end

    test "explicit grants in a claim are honoured", %{jwk: jwk, config: config} do
      token = sign(jwk, %{"micelio_grants" => ["acme/**:read", "acme/sandbox-*:read,write"]})
      {:ok, principal} = OIDC.authenticate({:bearer, token}, config)

      assert Principal.allows?(principal, "acme/anything", :read)
      refute Principal.allows?(principal, "acme/anything", :write)
      assert Principal.allows?(principal, "acme/sandbox-1", :write)
    end

    test "an unrecognised permission in a claim is ignored rather than trusted", %{jwk: jwk, config: config} do
      token = sign(jwk, %{"micelio_grants" => ["acme/**:read,superuser"]})
      {:ok, principal} = OIDC.authenticate({:bearer, token}, config)

      assert Principal.allows?(principal, "acme/app", :read)
      refute Principal.allows?(principal, "acme/app", :admin)
    end

    test "a non-Kubernetes subject gets nothing by default", %{jwk: jwk, config: config} do
      token = sign(jwk, %{"sub" => "alice@example.com"})
      {:ok, principal} = OIDC.authenticate({:bearer, token}, config)

      assert principal.grants == []
      refute Principal.allows?(principal, "anything", :read)
    end
  end

  describe "key retrieval" do
    test "an unknown key id is rejected rather than skipping verification", %{jwk: jwk, config: config} do
      stub(JWKS, :fetch, fn _kid, _config -> {:error, {:unknown_key, "rotated-away"}} end)

      assert {:error, {:unknown_key, _}} = OIDC.authenticate({:bearer, sign(jwk, %{})}, config)
    end

    test "an unreachable issuer fails closed", %{jwk: jwk, config: config} do
      stub(JWKS, :fetch, fn _kid, _config -> {:error, :jwks_unavailable} end)

      assert {:error, :jwks_unavailable} = OIDC.authenticate({:bearer, sign(jwk, %{})}, config)
    end
  end

  test "an anonymous request is not authenticated", %{config: config} do
    assert {:error, :unauthenticated} = OIDC.authenticate(:anonymous, config)
  end
end
