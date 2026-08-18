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

  ## Fetching from a Kubernetes API server

  A cluster's own issuer is not a public endpoint, and treating it like one
  fails twice over: its certificate is signed by the cluster CA, which nothing
  else trusts, and its discovery document requires authentication. A plain GET
  gets a TLS failure or a `401`.

  So when the standard service account files are present, they are used: the
  cluster CA for verification, and the pod's own token as a bearer credential.
  Both are mounted by Kubernetes itself, so this needs no configuration — but
  the pod does need `automountServiceAccountToken` and the
  `system:service-account-issuer-discovery` role, which the chart grants when
  it is configured for in-cluster OIDC.

  The issuer is discovered rather than assumed for the same reason. It is
  commonly `https://kubernetes.default.svc.cluster.local` and not the
  `https://kubernetes.default.svc` the endpoint is reached at, and a mismatch
  rejects every token with an issuer error that looks nothing like its cause.
  """

  use GenServer

  require Logger

  @refresh_interval :timer.minutes(15)
  @refetch_cooldown :timer.seconds(30)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Return the JWK for `kid`, fetching the JWKS if it is not cached."
  @spec fetch(String.t() | nil, keyword()) :: {:ok, term()} | {:error, term()}
  def fetch(kid, config) do
    server = Keyword.get(config, :server, __MODULE__)

    case GenServer.whereis(server) do
      nil -> {:error, :jwks_unavailable}
      pid -> GenServer.call(pid, {:fetch, kid, config}, :timer.seconds(15))
    end
  end

  @doc """
  The issuer this deployment should expect in a token's `iss` claim.

  Returns the configured issuer when there is one. Otherwise it is read from
  the discovery document and cached, because Kubernetes is reached at
  `kubernetes.default.svc` but issues tokens naming
  `kubernetes.default.svc.cluster.local` — configuring the address you connect
  to would reject every token, with an error that looks nothing like its cause.
  """
  @spec issuer(keyword()) :: {:ok, String.t()} | {:error, term()}
  def issuer(config) do
    case Keyword.get(config, :issuer) do
      configured when is_binary(configured) and configured != "" ->
        {:ok, configured}

      _ ->
        server = Keyword.get(config, :server, __MODULE__)

        case GenServer.whereis(server) do
          nil -> {:error, :jwks_unavailable}
          pid -> GenServer.call(pid, {:issuer, config}, :timer.seconds(15))
        end
    end
  end

  @impl true
  # `nil` rather than `0` for "never". Erlang's monotonic clock has an
  # arbitrary origin and on Linux starts at a large *negative* value, so `now -
  # 0` is negative and every "has enough time passed?" test answers no. The
  # effect here was that the cooldown never elapsed, the keys were never
  # fetched, and every token was rejected as signed by an unknown key — on
  # Linux only, which is to say in production only.
  def init(_opts), do: {:ok, %{keys: %{}, fetched_at: nil, last_attempt: nil, document: nil}}

  @impl true
  def handle_call({:issuer, config}, _from, state) do
    case document(state, config) do
      {:ok, %{"issuer" => issuer}, state} when is_binary(issuer) -> {:reply, {:ok, issuer}, state}
      {:ok, _document, state} -> {:reply, {:error, :no_issuer_in_discovery}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:fetch, kid, config}, _from, state) do
    state = maybe_refresh(state, kid, config)

    case lookup(state.keys, kid) do
      nil -> {:reply, {:error, {:unknown_key, kid}}, state}
      jwk -> {:reply, {:ok, jwk}, state}
    end
  end

  defp maybe_refresh(state, kid, config) do
    now = System.monotonic_time(:millisecond)
    stale? = elapsed?(state.fetched_at, now, Keyword.get(config, :refresh_interval_ms, @refresh_interval))
    unknown? = lookup(state.keys, kid) == nil
    cooled? = elapsed?(state.last_attempt, now, Keyword.get(config, :refetch_cooldown_ms, @refetch_cooldown))

    if (stale? or unknown?) and cooled? do
      refresh(state, config, now)
    else
      state
    end
  end

  # Never having happened counts as long enough ago.
  defp elapsed?(nil, _now, _interval), do: true
  defp elapsed?(at, now, interval), do: now - at > interval

  defp refresh(state, config, now) do
    state = %{state | last_attempt: now}

    case load(state, config) do
      {:ok, keys, state} ->
        Logger.debug("micelio: loaded #{map_size(keys)} signing key(s)")
        %{state | keys: keys, fetched_at: now}

      {:error, reason, state} ->
        # Keep serving with what we have. Losing the issuer should not take the
        # Git server down with it.
        Logger.warning("micelio: could not refresh JWKS: #{inspect(reason)}")
        state
    end
  end

  defp load(state, config) do
    case jwks_url(state, config) do
      {:ok, url, state} ->
        case get(url, config) do
          {:ok, %{status: 200, body: body}} -> {:ok, parse(body), state}
          {:ok, %{status: status}} -> {:error, {:jwks_status, status}, state}
          {:error, reason} -> {:error, reason, state}
        end

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  # A request that carries the cluster's CA and the pod's own token when those
  # exist, and is an ordinary HTTPS GET when they do not.
  defp get(url, config) do
    options =
      [retry: :safe_transient, max_retries: 2]
      |> put_ca_cert(ca_cert_file(config))
      |> put_bearer(token_file(config))

    Req.get(url, options)
  end

  defp put_ca_cert(options, nil), do: options

  defp put_ca_cert(options, path) do
    Keyword.put(options, :connect_options, transport_opts: [cacertfile: path])
  end

  defp put_bearer(options, nil), do: options

  defp put_bearer(options, path) do
    case File.read(path) do
      {:ok, token} -> Keyword.put(options, :headers, [{"authorization", "Bearer " <> String.trim(token)}])
      {:error, _} -> options
    end
  end

  @kubernetes_ca "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
  @kubernetes_token "/var/run/secrets/kubernetes.io/serviceaccount/token"

  defp ca_cert_file(config) do
    case Keyword.get(config, :ca_cert_file) do
      nil -> if File.exists?(@kubernetes_ca), do: @kubernetes_ca
      path -> path
    end
  end

  defp token_file(config) do
    case Keyword.get(config, :token_file) do
      nil -> if File.exists?(@kubernetes_token), do: @kubernetes_token
      path -> path
    end
  end

  # Either the JWKS URI is configured directly, or it comes from a discovery
  # document — the issuer's, or in a cluster the API server's.
  defp jwks_url(state, config) do
    case Keyword.get(config, :jwks_uri) do
      uri when is_binary(uri) and uri != "" ->
        {:ok, uri, state}

      _ ->
        case document(state, config) do
          {:ok, %{"jwks_uri" => uri}, state} when is_binary(uri) -> {:ok, uri, state}
          {:ok, _document, state} -> {:error, :no_jwks_uri_in_discovery, state}
          {:error, reason, state} -> {:error, reason, state}
        end
    end
  end

  # Fetched once and kept: it names both the signing keys and the issuer, and
  # both change far less often than the keys themselves.
  defp document(%{document: {signature, document}} = state, config) when is_map(document) do
    if signature == config_signature(config) do
      {:ok, document, state}
    else
      fetch_document(state, config)
    end
  end

  defp document(state, config), do: fetch_document(state, config)

  # Keyed by the configuration it came from: a node pointed at a different
  # issuer must not keep answering from the previous one's document.
  defp config_signature(config) do
    :erlang.phash2(Keyword.take(config, [:issuer, :jwks_uri, :kubernetes, :discovery_endpoint]))
  end

  defp fetch_document(state, config) do
    case discovery_url(config) do
      {:ok, url} ->
        case get(url, config) do
          {:ok, %{status: 200, body: body}} ->
            document = if is_map(body), do: body, else: decode(body)
            {:ok, document, %{state | document: {config_signature(config), document}}}

          {:ok, %{status: status}} ->
            {:error, {:discovery_status, status}, state}

          {:error, reason} ->
            {:error, reason, state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp discovery_url(config) do
    issuer = Keyword.get(config, :issuer)

    cond do
      is_binary(issuer) and issuer != "" ->
        {:ok, String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration"}

      Keyword.get(config, :kubernetes, false) or File.exists?(@kubernetes_token) ->
        endpoint = Keyword.get(config, :discovery_endpoint, "https://kubernetes.default.svc")
        {:ok, String.trim_trailing(endpoint, "/") <> "/.well-known/openid-configuration"}

      true ->
        {:error, :no_jwks_configured}
    end
  end

  defp decode(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end

  defp decode(_body), do: %{}

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
