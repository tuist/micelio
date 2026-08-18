defmodule Micelio.Auth.Webhook do
  @moduledoc """
  Defers authentication to an external authority.

  For deployments that already have a service which knows who may touch what.
  Micelio forwards the credential, receives a principal, and caches the answer
  for a short TTL so that a `git fetch` doing several round trips does not
  become several authorization round trips.

  The cache is deliberately short-lived and keyed by a hash of the credential,
  never the credential itself, so a memory dump or a crash report does not hand
  over live tokens.
  """

  @behaviour Micelio.Auth

  require Logger

  alias Micelio.Auth.Principal

  @table __MODULE__.Cache

  @doc false
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(_opts) do
    Task.start_link(fn ->
      # Idempotent, so a supervisor restart re-attaches to the existing cache
      # rather than crashing on a name that is already taken.
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
      end

      Process.sleep(:infinity)
    end)
  end

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @impl true
  def authenticate(:anonymous, _config), do: {:error, :unauthenticated}

  def authenticate(credential, config) do
    token = token_of(credential)
    key = :crypto.hash(:sha256, token)

    case cached(key, config) do
      {:ok, principal} -> {:ok, principal}
      :miss -> resolve(key, token, config)
    end
  end

  defp token_of({:bearer, token}), do: token
  defp token_of({:basic, user, password}), do: user <> ":" <> password

  defp cached(key, config) do
    ttl = Keyword.get(config, :cache_ttl_ms, 30_000)
    now = System.monotonic_time(:millisecond)

    case :ets.whereis(@table) do
      :undefined ->
        :miss

      _ ->
        case :ets.lookup(@table, key) do
          [{^key, principal, at}] when now - at < ttl -> {:ok, principal}
          _ -> :miss
        end
    end
  end

  defp resolve(key, token, config) do
    endpoint = Keyword.fetch!(config, :endpoint)

    headers = [
      {"authorization", "Bearer " <> Keyword.fetch!(config, :token)},
      {"content-type", "application/json"}
    ]

    case Req.post(endpoint, headers: headers, json: %{credential: token, node: Micelio.Config.node_id()}) do
      {:ok, %{status: 200, body: body}} ->
        principal = build(body)

        if :ets.whereis(@table) != :undefined,
          do: :ets.insert(@table, {key, principal, System.monotonic_time(:millisecond)})

        {:ok, principal}

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, :invalid_credential}

      {:ok, %{status: status}} ->
        {:error, {:authority_status, status}}

      {:error, reason} ->
        Logger.warning("micelio: authorization authority unreachable: #{inspect(reason)}")
        {:error, :authority_unreachable}
    end
  end

  defp build(body) when is_map(body) do
    %Principal{
      subject: body["subject"] || "unknown",
      account: body["account"],
      grants: body |> Map.get("grants", []) |> Enum.map(&normalize/1),
      claims: Map.get(body, "claims", %{}),
      expires_at: parse_expiry(body["expires_at"]),
      source: :webhook
    }
  end

  defp normalize(%{"pattern" => pattern, "permissions" => permissions}) do
    Principal.grant(pattern, Enum.map(permissions, &String.to_existing_atom/1))
  end

  defp normalize(grant) when is_binary(grant) do
    case String.split(grant, ":", parts: 2) do
      [pattern, permissions] ->
        Principal.grant(
          pattern,
          permissions |> String.split(",", trim: true) |> Enum.map(&String.to_existing_atom/1)
        )

      [pattern] ->
        Principal.grant(pattern, [:read])
    end
  end

  defp parse_expiry(nil), do: nil

  defp parse_expiry(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> at
      _ -> nil
    end
  end

  defp parse_expiry(value) when is_integer(value), do: DateTime.from_unix!(value)
end
