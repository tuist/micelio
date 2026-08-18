defmodule Micelio.Auth.Static do
  @moduledoc """
  Bearer tokens from configuration.

  Suitable for development, tests, and installations small enough that rotating
  a token by hand is reasonable. Tokens are compared in constant time, since a
  Git server is a perfectly good oracle for a timing attack otherwise.
  """

  @behaviour Micelio.Auth

  alias Micelio.Auth.Principal

  @impl true
  def authenticate({:bearer, token}, config) do
    tokens = Keyword.get(config, :tokens, %{})

    case find_token(tokens, token) do
      nil -> {:error, :invalid_credential}
      {_token, attrs} -> {:ok, build(attrs)}
    end
  end

  def authenticate({:basic, _user, password}, config), do: authenticate({:bearer, password}, config)
  def authenticate(:anonymous, _config), do: {:error, :unauthenticated}

  # Compare every candidate so the work done does not depend on which token
  # matched, or on how early a mismatch occurred.
  defp find_token(tokens, candidate) do
    Enum.reduce(tokens, nil, fn {token, attrs}, acc ->
      if secure_compare(token, candidate), do: {token, attrs}, else: acc
    end)
  end

  defp secure_compare(a, b) when byte_size(a) == byte_size(b), do: :crypto.hash_equals(a, b)
  defp secure_compare(_a, _b), do: false

  defp build(attrs) do
    grants =
      case Map.get(attrs, :grants) do
        nil -> default_grants(attrs)
        grants -> Enum.map(grants, &normalize_grant/1)
      end

    %Principal{
      subject: Map.get(attrs, :subject, Map.get(attrs, :account, "static")),
      account: Map.get(attrs, :account),
      grants: grants,
      source: :static
    }
  end

  # A token configured with only an account and a scope list is the common
  # shape; expand it to a grant over that account's namespace.
  defp default_grants(attrs) do
    permissions = Map.get(attrs, :scopes, [:read])

    case Map.get(attrs, :account) do
      nil -> [Principal.grant("**", permissions)]
      account -> [Principal.grant("**", permissions), Principal.grant("#{account}/**", permissions)]
    end
  end

  defp normalize_grant(%{pattern: _, permissions: _} = grant), do: grant
  defp normalize_grant({pattern, permissions}), do: Principal.grant(pattern, permissions)

  @doc """
  Parse `MICELIO_AUTH_TOKENS` into the configuration shape.

  Format is `token=account:permissions` entries separated by commas, e.g.
  `sekret=acme:read,write;other=beta:read`.
  """
  @spec parse_tokens(String.t()) :: map()
  def parse_tokens(""), do: %{}

  def parse_tokens(raw) do
    raw
    |> String.split(";", trim: true)
    |> Map.new(fn entry ->
      [token, rest] = String.split(entry, "=", parts: 2)
      [account, permissions] = String.split(rest, ":", parts: 2)

      {String.trim(token),
       %{
         account: String.trim(account),
         scopes:
           permissions |> String.split(",", trim: true) |> Enum.map(&String.to_existing_atom(String.trim(&1)))
       }}
    end)
  end
end
