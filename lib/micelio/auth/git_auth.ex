defmodule Micelio.Auth.GitAuth do
  @moduledoc false

  @type config :: %{
          issuer: String.t(),
          client_id: String.t(),
          authorization_endpoint: String.t(),
          token_endpoint: String.t(),
          redirect_uri: String.t(),
          scopes: [String.t()],
          username: String.t()
        }

  @spec build(String.t() | nil, keyword()) :: config() | nil
  def build(client_id, _opts) when client_id in [nil, ""], do: nil

  def build(client_id, opts) do
    backend = Keyword.fetch!(opts, :backend)
    kubernetes = Keyword.fetch!(opts, :kubernetes)

    if backend != "oidc" or kubernetes do
      raise ArgumentError, """
      MICELIO_GIT_AUTH_CLIENT_ID requires MICELIO_AUTH_BACKEND=oidc with
      MICELIO_OIDC_KUBERNETES=false.

      Browser Git login needs an external OpenID Connect issuer. Kubernetes
      service-account tokens are workload credentials and cannot be obtained
      through a browser authorization flow.
      """
    end

    %{
      issuer: https_url!(Keyword.fetch!(opts, :issuer), "MICELIO_OIDC_ISSUER"),
      client_id: one_line!(client_id, "MICELIO_GIT_AUTH_CLIENT_ID", 512),
      authorization_endpoint:
        https_url!(
          Keyword.fetch!(opts, :authorization_endpoint),
          "MICELIO_GIT_AUTH_AUTHORIZATION_ENDPOINT"
        ),
      token_endpoint: https_url!(Keyword.fetch!(opts, :token_endpoint), "MICELIO_GIT_AUTH_TOKEN_ENDPOINT"),
      redirect_uri: loopback_redirect_uri!(Keyword.fetch!(opts, :redirect_uri)),
      scopes: scopes!(Keyword.fetch!(opts, :scopes)),
      username: username!(Keyword.fetch!(opts, :username))
    }
  end

  defp https_url!(value, name) do
    value = one_line!(value, name, 2_048)
    uri = URI.parse(value)

    if uri.scheme != "https" or is_nil(uri.host) or not is_nil(uri.userinfo) or not is_nil(uri.fragment) do
      raise ArgumentError, "#{name} must be an HTTPS URL without credentials or a fragment"
    end

    value
  end

  # OAuth permits a loopback redirect to use HTTP because the request never
  # leaves the developer machine. Keeping this to 127.0.0.1 avoids a hostname
  # that a hostile local resolver could redirect elsewhere.
  defp loopback_redirect_uri!(value) do
    value = one_line!(value, "MICELIO_GIT_AUTH_REDIRECT_URI", 2_048)
    uri = URI.parse(value)

    if uri.scheme != "http" or uri.host != "127.0.0.1" or not is_nil(uri.userinfo) or
         not is_nil(uri.fragment) or uri.path not in [nil, "", "/"] or not is_nil(uri.query) do
      raise ArgumentError,
            "MICELIO_GIT_AUTH_REDIRECT_URI must be an HTTP 127.0.0.1 origin without credentials, a path, query, or fragment"
    end

    value
  end

  defp scopes!(value) when is_binary(value) do
    scopes = String.split(value, " ", trim: true)

    if scopes == [] or
         Enum.any?(scopes, &(not String.match?(&1, ~r/\A[^\s\x00-\x1f]{1,256}\z/u))) do
      raise ArgumentError, "MICELIO_GIT_AUTH_SCOPES must be space-separated, non-empty scope names"
    end

    scopes
  end

  defp scopes!(_value), do: raise(ArgumentError, "MICELIO_GIT_AUTH_SCOPES must be a string")

  defp username!(""), do: "oauth2"

  defp username!(value) do
    value = one_line!(value, "MICELIO_GIT_AUTH_USERNAME", 256)

    unless String.match?(value, ~r/\A[A-Za-z0-9._-]+\z/) do
      raise ArgumentError, "MICELIO_GIT_AUTH_USERNAME contains unsupported characters"
    end

    value
  end

  defp one_line!(value, name, maximum) when is_binary(value) do
    if value == "" or String.length(value) > maximum or String.contains?(value, ["\r", "\n"]) do
      raise ArgumentError, "#{name} must be a non-empty one-line string no longer than #{maximum} characters"
    end

    value
  end

  defp one_line!(_value, name, _maximum), do: raise(ArgumentError, "#{name} must be a string")
end
