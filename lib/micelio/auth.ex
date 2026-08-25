defmodule Micelio.Auth do
  @moduledoc """
  Authentication and authorization.

  Micelio is an OAuth 2.1 **resource server** and nothing else. It validates
  credentials; it never issues them, stores them, or maintains a user database.
  That is deliberate: the whole point of the architecture is that a node holds
  no authoritative state, and an identity database would be exactly that. It
  would also be the control plane this system is trying not to need.

  ## One identity model, three surfaces

  Git smart-HTTP, the admin API and the MCP endpoint all resolve to the same
  `Micelio.Auth.Principal`. Git clients send HTTP Basic (the only thing they
  reliably do without configuration), agents and tooling send Bearer. Both land
  in the same place, so a permission granted once means the same thing whether
  it arrives over `git fetch` or a `tools/call`.

  ## Backends

    * `Micelio.Auth.OIDC` validates JWTs against a JWKS. This is the one that
      matters in production, and it is what makes the Kubernetes story work:
      a pod's projected service account token is already an OIDC JWT the
      cluster will vouch for, so an agent can authenticate with a credential
      it was born with and no secret ever has to be distributed.
    * `Micelio.Auth.Webhook` defers to an external authority, for deployments
      that already have one.
    * `Micelio.Auth.Static` is a token map, for development and small
      installations.
    * `Micelio.Auth.Allow` permits everything, and exists so a local
      single-node run needs no setup at all.
  """

  alias Micelio.Auth.Principal
  alias Micelio.Config

  @type credential :: {:bearer, String.t()} | {:basic, String.t(), String.t()} | :anonymous
  @type reason :: :invalid_credential | :expired | :unauthenticated | term()

  @callback authenticate(credential(), config :: keyword()) :: {:ok, Principal.t()} | {:error, reason()}

  @doc """
  Resolve a credential to a principal.

  Expiry is checked here rather than in each backend so that a cached principal
  cannot outlive the token it came from.
  """
  @spec authenticate(credential()) :: {:ok, Principal.t()} | {:error, reason()}
  def authenticate(credential) do
    {mod, config} = Config.auth()

    case mod.authenticate(credential, config) do
      {:ok, principal} ->
        if Principal.expired?(principal, DateTime.utc_now()) do
          {:error, :expired}
        else
          {:ok, principal}
        end

      error ->
        error
    end
  end

  @doc """
  Whether `principal` may perform `permission` on `repo_id`.

  Two sources are consulted, and either suffices:

    * the grants the credential itself carried, which is how a machine identity
      authorises itself with a token it was born with, and
    * the account's policy in object storage, which is how grants are changed
      without reissuing anything — and revoked without waiting for a token to
      expire.

  The policy is only read when the token alone is not enough, so the common
  case for machine identities costs nothing.
  """
  @spec authorize(Principal.t(), String.t(), Principal.permission()) :: :ok | {:error, :forbidden}
  def authorize(%Principal{} = principal, repo_id, permission) do
    if Principal.allows?(principal, repo_id, permission) or granted_by_policy?(principal, repo_id, permission) do
      :telemetry.execute([:micelio, :auth, :authorized], %{}, %{permission: permission, repo_id: repo_id})
      :ok
    else
      :telemetry.execute([:micelio, :auth, :denied], %{}, %{permission: permission, repo_id: repo_id})
      {:error, :forbidden}
    end
  end

  @doc """
  Whether `principal` may administer account-scoped configuration.

  Account configuration must not be anchored on one repository. The synthetic
  nested path requires a grant that covers the whole account, such as
  `acme/**`, rather than an administrator grant on `acme/one-repository`.
  """
  @spec authorize_account(Principal.t(), String.t(), Principal.permission()) :: :ok | {:error, :forbidden}
  def authorize_account(%Principal{} = principal, account, permission) when is_binary(account) do
    authorize(principal, "#{account}/.micelio/account-configuration", permission)
  end

  defp granted_by_policy?(principal, repo_id, permission) do
    account = Micelio.Policy.account_of(repo_id)

    account
    |> Micelio.Policy.grants_for(principal.subject)
    |> Enum.any?(fn %{pattern: pattern, permissions: permissions} ->
      Principal.matches?(pattern, repo_id) and (permission in permissions or :admin in permissions)
    end)
  end

  @doc """
  Extract a credential from an `Authorization` header value.

  Git sends Basic. Two conventions are honoured for carrying a token through
  it, both of which real clients produce: a username of `x-access-token`,
  `oauth2` or `token` with the token as the password, and the reverse. Anything
  else is treated as a genuine username and password pair.
  """
  @spec credential_from_header(String.t() | nil) :: credential()
  def credential_from_header(nil), do: :anonymous

  def credential_from_header("Bearer " <> token), do: {:bearer, String.trim(token)}
  def credential_from_header("bearer " <> token), do: {:bearer, String.trim(token)}

  def credential_from_header("Basic " <> encoded), do: decode_basic(encoded)
  def credential_from_header("basic " <> encoded), do: decode_basic(encoded)

  def credential_from_header(_other), do: :anonymous

  defp decode_basic(encoded) do
    case Base.decode64(String.trim(encoded)) do
      {:ok, decoded} ->
        case String.split(decoded, ":", parts: 2) do
          [user, password] -> normalize_basic(user, password)
          _ -> :anonymous
        end

      :error ->
        :anonymous
    end
  end

  @token_usernames ~w(x-access-token oauth2 token bearer micelio)

  defp normalize_basic(user, password) do
    cond do
      String.downcase(user) in @token_usernames and password != "" -> {:bearer, password}
      password == "" and user != "" -> {:bearer, user}
      true -> {:basic, user, password}
    end
  end

  @doc """
  The `WWW-Authenticate` header value for a rejected request.

  Pointing at the protected-resource metadata document is what lets an MCP
  client discover where to get a token without being told out of band, which
  is the difference between an agent that can onboard itself and one that
  needs a human to paste a secret.
  """
  @spec challenge(String.t()) :: String.t()
  def challenge(resource_metadata_url) do
    ~s(Bearer realm="micelio", resource_metadata="#{resource_metadata_url}")
  end
end
