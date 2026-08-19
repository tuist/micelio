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

  Two things about it are load-bearing rather than incidental:

    * **Entries are evicted, not merely ignored.** An expired entry that stays
      in the table is still memory, and a deployment authenticating a stream of
      short-lived tokens would accumulate one row per credential it ever saw
      until the node died. Expiry is enforced by sweeping, with a hard cap as a
      backstop.
    * **The key includes the authority.** Hashing the credential alone means
      that after a configuration change, a token the previous authority
      accepted keeps being honoured by a node now pointed at a different one.
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
    key = cache_key(token, config)

    case cached(key, config) do
      {:ok, principal} -> {:ok, principal}
      :miss -> resolve(key, token, config)
    end
  end

  defp token_of({:bearer, token}), do: token
  defp token_of({:basic, user, password}), do: user <> ":" <> password

  # The authority is part of the key, so a node repointed at a different one
  # cannot serve its predecessor's decisions.
  defp cache_key(token, config) do
    :crypto.hash(:sha256, [
      token,
      0,
      to_string(Keyword.get(config, :endpoint, "")),
      0,
      to_string(Keyword.get(config, :token, ""))
    ])
  end

  defp cached(key, config) do
    ttl = Keyword.get(config, :cache_ttl_ms, 30_000)
    now = System.monotonic_time(:millisecond)

    case :ets.whereis(@table) do
      :undefined ->
        :miss

      _ ->
        case :ets.lookup(@table, key) do
          [{^key, principal, at}] when now - at < ttl ->
            {:ok, principal}

          [{^key, _principal, _at}] ->
            # Expired. Delete rather than leave it: an entry nobody will use
            # again is pure memory, and there is one per credential ever seen.
            :ets.delete(@table, key)
            :miss

          [] ->
            :miss
        end
    end
  end

  # Entries are only reachable through their own credential, so nothing sweeps
  # them on its own. Sweeping on insert keeps the cost proportional to traffic,
  # and the cap bounds the table even against a flood of distinct credentials.
  @max_entries 10_000

  defp evict_expired(config) do
    ttl = Keyword.get(config, :cache_ttl_ms, 30_000)
    cutoff = System.monotonic_time(:millisecond) - ttl

    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])

    if :ets.info(@table, :size) > @max_entries, do: :ets.delete_all_objects(@table)
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

        if :ets.whereis(@table) != :undefined do
          evict_expired(config)
          :ets.insert(@table, {key, principal, System.monotonic_time(:millisecond)})
        end

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
