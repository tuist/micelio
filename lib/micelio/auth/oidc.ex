defmodule Micelio.Auth.OIDC do
  @moduledoc """
  Validates JSON Web Tokens against a JWKS.

  This is the backend that makes Micelio deployable without a control plane.
  It holds no user records and issues nothing; it verifies a signature, checks
  the standard claims, and turns the result into grants.

  ## Kubernetes without secrets

  Every pod already has a projected service account token, which is an OIDC
  JWT the cluster's own issuer will vouch for. Mount one with the right
  audience:

      volumes:
        - name: micelio-token
          projected:
            sources:
              - serviceAccountToken:
                  audience: micelio
                  expirationSeconds: 3600
                  path: token

  and an agent authenticates with a credential it was born with. Nothing has to
  be created, distributed, rotated or revoked, because the kubelet already
  rotates it. The subject arrives as `system:serviceaccount:<namespace>:<name>`,
  and with `namespace_grants` enabled that becomes read/write on `<namespace>/**`
  — so a pod in `team-ios` can use the repositories belonging to `team-ios` and
  nothing else, with no configuration per team.

  ## Audience binding is not optional

  `aud` is verified against this deployment's own resource identifier. Without
  it, a token minted for any other service that shares an issuer would be
  replayable here, which is precisely the confused-deputy problem the MCP
  authorization spec calls out. A token that does not name Micelio is rejected
  even when its signature is perfectly valid.

  ## Key handling

  JWKS documents are fetched lazily and cached with a TTL. An unknown key id
  triggers at most one refetch per cooldown window, so a rotation is picked up
  promptly while a stream of tokens signed by a bogus key cannot be used to
  hammer the issuer.
  """

  @behaviour Micelio.Auth

  alias Micelio.Auth.Principal

  @impl true
  def authenticate({:bearer, token}, config), do: verify(token, config)
  def authenticate({:basic, _user, password}, config), do: verify(password, config)
  def authenticate(:anonymous, _config), do: {:error, :unauthenticated}

  defp verify(token, config) do
    with {:ok, kid, alg} <- peek_header(token),
         {:ok, jwk} <- key_for(kid, config),
         {:ok, claims} <- verify_signature(token, jwk, alg, config),
         :ok <- verify_claims(claims, config) do
      {:ok, principal(claims, config)}
    end
  end

  defp peek_header(token) do
    header = JOSE.JWS.peek_protected(token) |> JSON.decode!()
    {:ok, Map.get(header, "kid"), Map.get(header, "alg")}
  rescue
    _ -> {:error, :invalid_credential}
  end

  # Reject `none` and any symmetric algorithm outright. A JWKS contains public
  # keys, so an HMAC algorithm arriving here means someone is trying to get a
  # public key treated as a shared secret.
  @allowed_algorithms ~w(RS256 RS384 RS512 ES256 ES384 ES512 PS256 PS384 PS512)

  defp verify_signature(_token, _jwk, alg, _config) when alg not in @allowed_algorithms do
    {:error, {:unsupported_algorithm, alg}}
  end

  defp verify_signature(token, jwk, alg, _config) do
    case JOSE.JWT.verify_strict(jwk, [alg], token) do
      {true, jwt, _jws} -> {:ok, JOSE.JWT.to_map(jwt) |> elem(1)}
      {false, _jwt, _jws} -> {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :invalid_credential}
  end

  defp verify_claims(claims, config) do
    now = System.system_time(:second)
    leeway = Keyword.get(config, :leeway_seconds, 60)

    with :ok <- check_time(claims, now, leeway),
         :ok <- check_issuer(claims, config) do
      check_audience(claims, config)
    end
  end

  # An absent `exp` is rejected, not ignored. A signed token with no expiry is
  # a permanent credential: it cannot be aged out, and the only way to withdraw
  # it is to rotate the issuer's signing key for everyone. Treating "no expiry
  # stated" as "never expires" turns a compromised or over-generous issuer into
  # indefinite access.
  defp check_time(claims, now, leeway) do
    exp = claims["exp"]
    nbf = claims["nbf"]

    cond do
      not is_number(exp) -> {:error, :missing_expiry}
      now > exp + leeway -> {:error, :expired}
      is_number(nbf) and now < nbf - leeway -> {:error, :not_yet_valid}
      true -> :ok
    end
  end

  # Fails closed. Accepting any issuer because none was configured means the
  # only thing standing between an attacker and a valid session is which keys
  # happen to be in the key source — which is a property of configuration, not
  # a decision anyone made.
  defp check_issuer(claims, config) do
    case expected_issuer(config) do
      nil -> {:error, :no_issuer_configured}
      issuer -> if claims["iss"] == issuer, do: :ok, else: {:error, {:issuer_mismatch, claims["iss"]}}
    end
  end

  # Configured wins. Otherwise, in a cluster, the issuer is read from the API
  # server rather than assumed — Kubernetes is reached at
  # `kubernetes.default.svc` but issues tokens naming
  # `kubernetes.default.svc.cluster.local`.
  defp expected_issuer(config) do
    case Keyword.get(config, :issuer) do
      issuer when is_binary(issuer) and issuer != "" ->
        issuer

      _ ->
        if Keyword.get(config, :kubernetes, false) do
          case Micelio.Auth.JWKS.issuer(config) do
            {:ok, issuer} -> issuer
            {:error, _reason} -> nil
          end
        end
    end
  end

  # Also fails closed, and this is the check that stops a token minted for
  # another service sharing the issuer from being replayed here. A warning was
  # not enough: nobody reads a warning that arrives on every successful
  # request, and the consequence of missing it is that every audience is
  # accepted. Deployments that genuinely have no audience to bind to must say
  # so, by setting `audience_optional`.
  defp check_audience(claims, config) do
    case Keyword.get(config, :audience) do
      audience when is_binary(audience) and audience != "" ->
        if audience in List.wrap(claims["aud"]) do
          :ok
        else
          {:error, {:audience_mismatch, claims["aud"]}}
        end

      _ ->
        if Keyword.get(config, :audience_optional, false) do
          :ok
        else
          {:error, :no_audience_configured}
        end
    end
  end

  defp principal(claims, config) do
    subject = claims["sub"] || "unknown"

    %Principal{
      subject: subject,
      account: account_for(subject, claims, config),
      grants: grants_for(subject, claims, config),
      claims: claims,
      expires_at: expires_at(claims),
      source: :oidc
    }
  end

  defp expires_at(%{"exp" => exp}) when is_number(exp), do: DateTime.from_unix!(trunc(exp))
  defp expires_at(_claims), do: nil

  defp account_for(subject, claims, config) do
    case Keyword.get(config, :account_claim) do
      nil -> kubernetes_namespace(subject)
      claim -> claims[claim] || kubernetes_namespace(subject)
    end
  end

  # `system:serviceaccount:<namespace>:<name>`
  defp kubernetes_namespace("system:serviceaccount:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [namespace, _name] -> namespace
      _ -> nil
    end
  end

  defp kubernetes_namespace(_subject), do: nil

  defp grants_for(subject, claims, config) do
    from_claim(claims, config) ++ from_namespace(subject, config) ++ configured_defaults(config)
  end

  defp from_claim(claims, config) do
    claim = Keyword.get(config, :grants_claim, "micelio_grants")

    case claims[claim] do
      nil ->
        []

      grants when is_list(grants) ->
        Enum.map(grants, &parse_grant/1) |> Enum.reject(&is_nil/1)

      grants when is_binary(grants) ->
        grants |> String.split(",", trim: true) |> Enum.map(&parse_grant/1) |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  # "acme/**:read,write"
  defp parse_grant(grant) when is_binary(grant) do
    case String.split(grant, ":", parts: 2) do
      [pattern, permissions] ->
        Principal.grant(String.trim(pattern), parse_permissions(permissions))

      [pattern] ->
        Principal.grant(String.trim(pattern), [:read])
    end
  end

  defp parse_grant(%{"pattern" => pattern} = grant) do
    Principal.grant(pattern, parse_permissions(Map.get(grant, "permissions", "read")))
  end

  defp parse_grant(_other), do: nil

  defp parse_permissions(permissions) when is_binary(permissions) do
    permissions |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> parse_permissions()
  end

  defp parse_permissions(permissions) when is_list(permissions) do
    permissions
    |> Enum.map(&to_string/1)
    |> Enum.filter(&(&1 in ~w(read write execute admin)))
    |> Enum.map(&String.to_existing_atom/1)
  end

  defp from_namespace(subject, config) do
    with true <- Keyword.get(config, :namespace_grants, true),
         namespace when is_binary(namespace) <- kubernetes_namespace(subject) do
      permissions = Keyword.get(config, :namespace_permissions, [:read, :write])
      [Principal.grant("#{namespace}/**", permissions)]
    else
      _ -> []
    end
  end

  defp configured_defaults(config) do
    config
    |> Keyword.get(:default_grants, [])
    |> Enum.map(&parse_grant/1)
    |> Enum.reject(&is_nil/1)
  end

  # ----------------------------------------------------------------------
  # JWKS
  # ----------------------------------------------------------------------

  defp key_for(kid, config) do
    case Micelio.Auth.JWKS.fetch(kid, config) do
      {:ok, jwk} -> {:ok, jwk}
      {:error, reason} -> {:error, reason}
    end
  end
end
