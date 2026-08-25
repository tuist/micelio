defmodule Micelio.Factory.InferenceProfile do
  @moduledoc """
  Versioned, account-scoped inference configuration for sandbox workers.

  The objects in this module deliberately describe *how a worker obtains* an
  inference credential. They never contain the credential itself, the secret
  manager endpoint, or the workload-token audience. Those deployment-owned
  values stay in the trusted runtime proxy. That keeps the object-store log
  suitable as the authoritative record while leaving plaintext secrets outside
  both Micelio and the agent sandbox.
  """

  alias Micelio.Auth.Principal
  alias Micelio.Factory.SecretBackend
  alias Micelio.ObjectStore
  alias Micelio.Telemetry

  @content_type "application/vnd.micelio.factory.inference-profile.v2+json"

  @type result :: {:ok, map()} | {:error, String.t()}

  @doc "Create or replace an account profile with a new immutable version."
  @spec put(String.t(), String.t(), map(), Principal.t()) :: result()
  def put(account, name, attrs, %Principal{} = principal) do
    observe(:configure_inference_profile, fn -> do_put(account, name, attrs, principal) end)
  end

  def put(_account, _name, _attrs, _principal),
    do: {:error, "profile update requires an authenticated principal"}

  @doc "Read the current version of one account profile."
  @spec get(String.t(), String.t()) :: result()
  def get(account, name) do
    observe(:get_inference_profile, fn -> do_get(account, name) end)
  end

  @doc "Read the exact immutable version pinned by a work run."
  @spec get_version(String.t(), String.t(), String.t()) :: result()
  def get_version(account, name, version) do
    observe(:get_inference_profile, fn ->
      with :ok <- account(account),
           :ok <- name(name),
           :ok <- version(version),
           {:ok, profile} <- read(version_key(account, name, version)) do
        {:ok, profile}
      else
        {:error, :not_found} -> {:error, "inference profile #{name} version #{version} not found"}
        {:error, reason} -> {:error, message(reason)}
      end
    end)
  end

  @doc "List current account profiles. Immutable historical versions are not enumerated."
  @spec list(String.t()) :: result()
  def list(account) do
    observe(:list_inference_profiles, fn -> do_list(account) end)
  end

  @doc "Resolve a named current profile to the immutable version a run must pin."
  @spec pin(String.t(), String.t()) :: result()
  def pin(account, name) do
    with {:ok, profile} <- get(account, name), do: {:ok, Map.take(profile, ["name", "version"])}
  end

  defp do_put(account, name, attrs, principal) when is_map(attrs) do
    with :ok <- account(account),
         :ok <- name(name),
         :ok <- attributes(attrs),
         {:ok, endpoint} <- endpoint(attrs["endpoint"] || attrs[:endpoint]),
         {:ok, model} <- model(attrs["model"] || attrs[:model]),
         {:ok, credential_binding} <-
           credential_binding(account, attrs["credential_binding"] || attrs[:credential_binding]),
         {:ok, current, etag} <- current(account, name),
         :ok <- expected_version(attrs["previous_version"] || attrs[:previous_version], current) do
      version = identifier()

      profile = %{
        "schema_version" => 2,
        "account" => account,
        "name" => name,
        "version" => version,
        "endpoint" => endpoint,
        "model" => model,
        "credential_binding" => credential_binding,
        "created_at_ms" => System.system_time(:millisecond),
        "created_by" => actor(principal)
      }

      with {:ok, _} <- put_immutable(version_key(account, name, version), profile),
           {:ok, _} <- put_current(account, name, version, etag) do
        {:ok, profile}
      else
        {:error, :precondition_failed} -> {:error, "inference profile changed concurrently"}
        {:error, reason} -> {:error, "could not store inference profile: #{inspect(reason)}"}
      end
    end
  end

  defp do_put(_account, _name, _attrs, _principal), do: {:error, "inference profile must be an object"}

  defp attributes(attrs) do
    allowed = MapSet.new(~w(endpoint model credential_binding previous_version))

    if Enum.all?(Map.keys(attrs), &(to_string(&1) in allowed)) do
      :ok
    else
      {:error, "inference profile contains an unsupported field"}
    end
  end

  defp do_get(account, name) do
    with :ok <- account(account),
         :ok <- name(name),
         {:ok, pointer, _etag} <- read_with_etag(current_key(account, name)),
         {:ok, version} <- pointer_version(pointer),
         {:ok, profile} <- read(version_key(account, name, version)) do
      {:ok, profile}
    else
      {:error, :not_found} -> {:error, "inference profile #{name} not found"}
      {:error, reason} -> {:error, message(reason)}
    end
  end

  defp do_list(account) do
    with :ok <- account(account),
         {:ok, entries} <- ObjectStore.list(prefix(account)) do
      names =
        entries
        |> Enum.filter(&String.ends_with?(&1.key, "/current.json"))
        |> Enum.map(&name_from_current_key/1)
        |> Enum.sort()

      profiles =
        Enum.reduce_while(names, {:ok, []}, fn name, {:ok, profiles} ->
          case do_get(account, name) do
            {:ok, profile} -> {:cont, {:ok, profiles ++ [profile]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      case profiles do
        {:ok, profiles} -> {:ok, %{account: account, profiles: profiles, count: length(profiles)}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, "could not list inference profiles: #{inspect(reason)}"}
    end
  end

  # `current.json` is deliberately the only mutable configuration object. A
  # losing writer may leave an unreferenced immutable version behind, but can
  # never replace a version a work run has already pinned.
  defp current(account, name) do
    case ObjectStore.get(current_key(account, name)) do
      {:ok, body, etag} ->
        with {:ok, pointer} <- decode(current_key(account, name), body), do: {:ok, pointer, etag}

      {:error, :not_found} ->
        {:ok, nil, nil}

      {:error, reason} ->
        {:error, "could not read inference profile: #{inspect(reason)}"}
    end
  end

  defp expected_version(nil, nil), do: :ok

  defp expected_version(nil, _current),
    do: {:error, "previous_version is required to replace an inference profile"}

  defp expected_version(expected, current) when is_binary(expected) do
    with {:ok, actual} <- pointer_version(current),
         true <- expected == actual do
      :ok
    else
      false -> {:error, "inference profile changed concurrently"}
      {:error, _} -> {:error, "inference profile pointer is malformed"}
    end
  end

  defp expected_version(_expected, _current), do: {:error, "previous_version must be a profile version"}

  defp put_current(account, name, version, nil) do
    ObjectStore.put(current_key(account, name), JSON.encode!(%{"version" => version}),
      if_none_match: "*",
      content_type: @content_type
    )
  end

  defp put_current(account, name, version, etag) do
    ObjectStore.put(current_key(account, name), JSON.encode!(%{"version" => version}),
      if_match: etag,
      content_type: @content_type
    )
  end

  defp credential_binding(
         account,
         %{"backend" => backend_name, "identity_id" => identity_id, "secret" => secret} = binding
       )
       when map_size(binding) == 3 do
    with :ok <- name(backend_name),
         {:ok, backend} <- SecretBackend.get(account, backend_name),
         :ok <- reference(identity_id),
         {:ok, secret} <- secret(secret) do
      {:ok,
       %{
         "backend" => backend_name,
         "backend_version" => backend["version"],
         "identity_id" => identity_id,
         "secret" => secret
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp credential_binding(_account, _binding), do: {:error, "credential_binding has an unsupported shape"}

  defp secret(%{"reference" => reference} = secret) do
    field = secret["field"]

    with true <- Enum.all?(Map.keys(secret), &(&1 in ["reference", "field"])),
         :ok <- reference(reference),
         :ok <- optional_reference(field) do
      {:ok, %{"reference" => reference} |> maybe_put("field", field)}
    else
      false -> {:error, "credential_binding secret has an unsupported shape"}
    end
  end

  defp secret(_), do: {:error, "credential_binding secret has an unsupported shape"}

  defp endpoint(value) when is_binary(value) and byte_size(value) <= 2_048 do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" -> {:ok, value}
      _ -> {:error, "endpoint must be an HTTPS URL without user information"}
    end
  end

  defp endpoint(_), do: {:error, "endpoint must be an HTTPS URL without user information"}

  defp model(value) when is_binary(value) and byte_size(value) in 1..256, do: {:ok, value}
  defp model(_), do: {:error, "model must be a non-empty string up to 256 bytes"}

  defp account(value) when is_binary(value) do
    if Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/, value),
      do: :ok,
      else: {:error, "account is invalid"}
  end

  defp account(_), do: {:error, "account is invalid"}

  defp name(value) when is_binary(value) do
    if Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/, value),
      do: :ok,
      else: {:error, "inference profile name is invalid"}
  end

  defp name(_), do: {:error, "inference profile name is invalid"}

  defp version(value) when is_binary(value) do
    if Regex.match?(~r/^p[A-Za-z0-9_-]{16,127}$/, value),
      do: :ok,
      else: {:error, "inference profile version is invalid"}
  end

  defp version(_), do: {:error, "inference profile version is invalid"}

  defp reference(value) when is_binary(value) and byte_size(value) in 1..512 do
    if String.match?(value, ~r/[\x00-\x1F]/),
      do: {:error, "credential reference must be a non-empty printable string"},
      else: :ok
  end

  defp reference(_), do: {:error, "credential reference must be a non-empty printable string"}
  defp optional_reference(nil), do: :ok
  defp optional_reference(value), do: reference(value)

  defp pointer_version(%{"version" => version}),
    do: version(version) |> then(&if(&1 == :ok, do: {:ok, version}, else: &1))

  defp pointer_version(_), do: {:error, "inference profile pointer is malformed"}

  defp read(key) do
    with {:ok, body, _etag} <- ObjectStore.get(key), do: decode(key, body)
  end

  defp read_with_etag(key) do
    with {:ok, body, etag} <- ObjectStore.get(key),
         {:ok, value} <- decode(key, body) do
      {:ok, value, etag}
    end
  end

  defp decode(key, body) do
    case JSON.decode(body) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, "malformed inference profile object #{key}"}
    end
  end

  defp put_immutable(key, value),
    do: ObjectStore.put(key, JSON.encode!(value), if_none_match: "*", content_type: @content_type)

  defp message(reason) when is_binary(reason), do: reason
  defp message(reason), do: "could not read inference profile: #{inspect(reason)}"

  defp actor(%Principal{} = principal), do: %{"subject" => principal.subject, "account" => principal.account}
  defp identifier, do: "p" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp observe(operation, fun) do
    started_at = System.monotonic_time()

    result =
      Telemetry.span(
        "factory.#{operation}",
        %{"micelio.factory.operation" => Atom.to_string(operation)},
        fn ->
          fun.() |> Telemetry.put_span_outcome()
        end
      )

    :telemetry.execute(
      [:micelio, :factory, :operation],
      %{duration_us: System.convert_time_unit(System.monotonic_time() - started_at, :native, :microsecond)},
      %{operation: operation, outcome: outcome(result)}
    )

    result
  end

  defp outcome({:ok, _}), do: :ok
  defp outcome({:error, _}), do: :error

  defp prefix(account), do: "accounts/#{account}/factory/inference-profiles/"
  defp profile_prefix(account, name), do: prefix(account) <> name <> "/"
  defp current_key(account, name), do: profile_prefix(account, name) <> "current.json"
  defp version_key(account, name, version), do: profile_prefix(account, name) <> "versions/#{version}.json"

  defp name_from_current_key(%{key: key}) do
    key
    |> String.replace_suffix("/current.json", "")
    |> Path.basename()
  end
end
