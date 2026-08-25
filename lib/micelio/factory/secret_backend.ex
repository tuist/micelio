defmodule Micelio.Factory.SecretBackend do
  @moduledoc """
  Versioned, account-scoped bindings to the deployment's managed secret backend.

  A backend records the tenant-facing part of a secret-manager integration. It
  deliberately does not contain an endpoint, an audience, a provider token, or
  a secret value. Those are deployment-owned values supplied to the trusted
  runtime proxy. Keeping them out of account configuration prevents an account
  administrator from turning a projected workload token into a credential for
  an arbitrary host.
  """

  alias Micelio.Auth.Principal
  alias Micelio.ObjectStore
  alias Micelio.Telemetry

  @content_type "application/vnd.micelio.factory.secret-backend.v1+json"

  @type result :: {:ok, map()} | {:error, String.t()}

  @doc "Create or replace an account secret backend with a new immutable version."
  @spec put(String.t(), String.t(), map(), Principal.t()) :: result()
  def put(account, name, attrs, %Principal{} = principal) do
    observe(:configure_secret_backend, fn -> do_put(account, name, attrs, principal) end)
  end

  def put(_account, _name, _attrs, _principal),
    do: {:error, "secret backend update requires an authenticated principal"}

  @doc "Read the current version of one account secret backend."
  @spec get(String.t(), String.t()) :: result()
  def get(account, name), do: observe(:get_secret_backend, fn -> do_get(account, name) end)

  @doc "Read the exact immutable version of an account secret backend."
  @spec get_version(String.t(), String.t(), String.t()) :: result()
  def get_version(account, name, version) do
    observe(:get_secret_backend, fn ->
      with :ok <- account(account),
           :ok <- name(name),
           :ok <- version(version),
           {:ok, backend} <- read(version_key(account, name, version)) do
        {:ok, backend}
      else
        {:error, :not_found} -> {:error, "secret backend #{name} version #{version} not found"}
        {:error, reason} -> {:error, message(reason)}
      end
    end)
  end

  @doc "List current account secret backends. Immutable historical versions are not enumerated."
  @spec list(String.t()) :: result()
  def list(account), do: observe(:list_secret_backends, fn -> do_list(account) end)

  defp do_put(account, name, attrs, principal) when is_map(attrs) do
    with :ok <- account(account),
         :ok <- name(name),
         :ok <- attributes(attrs),
         {:ok, driver} <- driver(attrs["driver"] || attrs[:driver]),
         {:ok, project} <- project(attrs["project"] || attrs[:project]),
         {:ok, current, etag} <- current(account, name),
         :ok <- expected_version(attrs["previous_version"] || attrs[:previous_version], current) do
      version = identifier()

      backend = %{
        "schema_version" => 1,
        "account" => account,
        "name" => name,
        "version" => version,
        "driver" => driver,
        "project" => project,
        "created_at_ms" => System.system_time(:millisecond),
        "created_by" => actor(principal)
      }

      with {:ok, _} <- put_immutable(version_key(account, name, version), backend),
           {:ok, _} <- put_current(account, name, version, etag) do
        {:ok, backend}
      else
        {:error, :precondition_failed} -> {:error, "secret backend changed concurrently"}
        {:error, reason} -> {:error, "could not store secret backend: #{inspect(reason)}"}
      end
    end
  end

  defp do_put(_account, _name, _attrs, _principal), do: {:error, "secret backend must be an object"}

  defp attributes(attrs) do
    allowed = MapSet.new(~w(driver project previous_version))

    if Enum.all?(Map.keys(attrs), &(to_string(&1) in allowed)) do
      :ok
    else
      {:error, "secret backend contains an unsupported field"}
    end
  end

  defp do_get(account, name) do
    with :ok <- account(account),
         :ok <- name(name),
         {:ok, pointer, _etag} <- read_with_etag(current_key(account, name)),
         {:ok, version} <- pointer_version(pointer),
         {:ok, backend} <- read(version_key(account, name, version)) do
      {:ok, backend}
    else
      {:error, :not_found} -> {:error, "secret backend #{name} not found"}
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

      backends =
        Enum.reduce_while(names, {:ok, []}, fn name, {:ok, backends} ->
          case do_get(account, name) do
            {:ok, backend} -> {:cont, {:ok, backends ++ [backend]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      case backends do
        {:ok, backends} -> {:ok, %{account: account, backends: backends, count: length(backends)}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, "could not list secret backends: #{inspect(reason)}"}
    end
  end

  # `current.json` is deliberately the only mutable configuration object. A
  # losing writer may leave an unreferenced immutable version behind, but can
  # never replace a version a profile has already pinned.
  defp current(account, name) do
    case ObjectStore.get(current_key(account, name)) do
      {:ok, body, etag} ->
        with {:ok, pointer} <- decode(current_key(account, name), body), do: {:ok, pointer, etag}

      {:error, :not_found} ->
        {:ok, nil, nil}

      {:error, reason} ->
        {:error, "could not read secret backend: #{inspect(reason)}"}
    end
  end

  defp expected_version(nil, nil), do: :ok

  defp expected_version(nil, _current),
    do: {:error, "previous_version is required to replace a secret backend"}

  defp expected_version(expected, current) when is_binary(expected) do
    with {:ok, actual} <- pointer_version(current),
         true <- expected == actual do
      :ok
    else
      false -> {:error, "secret backend changed concurrently"}
      {:error, _} -> {:error, "secret backend pointer is malformed"}
    end
  end

  defp expected_version(_expected, _current), do: {:error, "previous_version must be a backend version"}

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

  # The initial provider is managed Infisical. Its endpoint and workload-token
  # audience are deployment configuration, so this tenant record cannot direct
  # a projected token to an arbitrary recipient.
  defp driver("managed_infisical"), do: {:ok, "managed_infisical"}
  defp driver(_), do: {:error, "secret backend driver must be managed_infisical"}

  defp project(value) when is_binary(value) and byte_size(value) in 1..512 do
    if String.match?(value, ~r/[\x00-\x1F]/),
      do: {:error, "secret backend project must be a non-empty printable string"},
      else: {:ok, value}
  end

  defp project(_), do: {:error, "secret backend project must be a non-empty printable string"}

  defp account(value) when is_binary(value) do
    if Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/, value),
      do: :ok,
      else: {:error, "account is invalid"}
  end

  defp account(_), do: {:error, "account is invalid"}

  defp name(value) when is_binary(value) do
    if Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/, value),
      do: :ok,
      else: {:error, "secret backend name is invalid"}
  end

  defp name(_), do: {:error, "secret backend name is invalid"}

  defp version(value) when is_binary(value) do
    if Regex.match?(~r/^s[A-Za-z0-9_-]{16,127}$/, value),
      do: :ok,
      else: {:error, "secret backend version is invalid"}
  end

  defp version(_), do: {:error, "secret backend version is invalid"}

  defp pointer_version(%{"version" => version}),
    do: version(version) |> then(&if(&1 == :ok, do: {:ok, version}, else: &1))

  defp pointer_version(_), do: {:error, "secret backend pointer is malformed"}

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
      _ -> {:error, "malformed secret backend object #{key}"}
    end
  end

  defp put_immutable(key, value),
    do: ObjectStore.put(key, JSON.encode!(value), if_none_match: "*", content_type: @content_type)

  defp message(reason) when is_binary(reason), do: reason
  defp message(reason), do: "could not read secret backend: #{inspect(reason)}"

  defp actor(%Principal{} = principal), do: %{"subject" => principal.subject, "account" => principal.account}
  defp identifier, do: "s" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp observe(operation, fun) do
    started_at = System.monotonic_time()

    result =
      Telemetry.span(
        "factory.#{operation}",
        %{"micelio.factory.operation" => Atom.to_string(operation)},
        fn -> fun.() |> Telemetry.put_span_outcome() end
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

  defp prefix(account), do: "accounts/#{account}/factory/secret-backends/"
  defp backend_prefix(account, name), do: prefix(account) <> name <> "/"
  defp current_key(account, name), do: backend_prefix(account, name) <> "current.json"
  defp version_key(account, name, version), do: backend_prefix(account, name) <> "versions/#{version}.json"

  defp name_from_current_key(%{key: key}) do
    key
    |> String.replace_suffix("/current.json", "")
    |> Path.basename()
  end
end
