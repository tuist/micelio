defmodule Micelio.Auth.JWKS do
  @moduledoc """
  Caches the signing keys used to verify tokens.

  Keys are public, so caching them is a latency and availability concern rather
  than a secrecy one: a node that cannot reach the issuer should keep serving
  with the keys it already has instead of failing every request. The cache
  therefore has a refresh interval, not an expiry — stale keys are preferred to
  no keys, and a key that has genuinely been retired stops appearing in tokens
  anyway.

  An unrecognised key id triggers a refetch, rate-limited by a cooldown so that
  a stream of tokens signed by a key that will never exist cannot be turned
  into a denial-of-service against the issuer.
  """

  use GenServer

  require Logger

  @refresh_interval :timer.minutes(15)
  @refetch_cooldown :timer.seconds(30)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Return the JWK for `kid`, fetching the JWKS if it is not cached."
  @spec fetch(String.t() | nil, keyword()) :: {:ok, term()} | {:error, term()}
  def fetch(kid, config) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :jwks_unavailable}
      _pid -> GenServer.call(__MODULE__, {:fetch, kid, config}, :timer.seconds(15))
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{keys: %{}, fetched_at: 0, last_attempt: 0}}

  @impl true
  def handle_call({:fetch, kid, config}, _from, state) do
    state = maybe_refresh(state, kid, config)

    case lookup(state.keys, kid) do
      nil -> {:reply, {:error, {:unknown_key, kid}}, state}
      jwk -> {:reply, {:ok, jwk}, state}
    end
  end

  defp maybe_refresh(state, kid, config) do
    now = System.monotonic_time(:millisecond)
    stale? = now - state.fetched_at > Keyword.get(config, :refresh_interval_ms, @refresh_interval)
    unknown? = lookup(state.keys, kid) == nil
    cooled? = now - state.last_attempt > Keyword.get(config, :refetch_cooldown_ms, @refetch_cooldown)

    if (stale? or unknown?) and cooled? do
      refresh(state, config, now)
    else
      state
    end
  end

  defp refresh(state, config, now) do
    state = %{state | last_attempt: now}

    case load(config) do
      {:ok, keys} ->
        Logger.debug("micelio: loaded #{map_size(keys)} signing key(s)")
        %{state | keys: keys, fetched_at: now}

      {:error, reason} ->
        # Keep serving with what we have. Losing the issuer should not take the
        # Git server down with it.
        Logger.warning("micelio: could not refresh JWKS: #{inspect(reason)}")
        state
    end
  end

  defp load(config) do
    with {:ok, url} <- jwks_url(config),
         {:ok, %{status: 200, body: body}} <- Req.get(url, retry: :safe_transient, max_retries: 2) do
      {:ok, parse(body)}
    else
      {:ok, %{status: status}} -> {:error, {:jwks_status, status}}
      {:error, reason} -> {:error, reason}
      other -> other
    end
  end

  # Either the JWKS URI is configured directly, or it is discovered from the
  # issuer's OpenID configuration document, which is what a Kubernetes cluster
  # and every hosted identity provider publish.
  defp jwks_url(config) do
    cond do
      url = Keyword.get(config, :jwks_uri) ->
        {:ok, url}

      issuer = Keyword.get(config, :issuer) ->
        discover(issuer)

      true ->
        {:error, :no_jwks_configured}
    end
  end

  defp discover(issuer) do
    url = String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"

    case Req.get(url, retry: :safe_transient, max_retries: 2) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        case body["jwks_uri"] do
          nil -> {:error, :no_jwks_uri_in_discovery}
          uri -> {:ok, uri}
        end

      {:ok, %{status: status}} ->
        {:error, {:discovery_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> parse(decoded)
      _ -> %{}
    end
  end

  defp parse(%{"keys" => keys}) when is_list(keys) do
    Map.new(keys, fn key -> {key["kid"], JOSE.JWK.from_map(key)} end)
  end

  defp parse(_body), do: %{}

  # A JWKS with exactly one key is allowed to omit `kid`, and some issuers do.
  defp lookup(keys, nil) when map_size(keys) == 1, do: keys |> Map.values() |> List.first()
  defp lookup(keys, kid), do: Map.get(keys, kid)
end
