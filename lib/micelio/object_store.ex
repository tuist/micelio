defmodule Micelio.ObjectStore do
  @moduledoc """
  The contract Micelio needs from object storage.

  Only three things matter beyond plain reads and writes, and all three exist
  in S3 and in every serious S3-compatible implementation:

    * **Conditional GET.** `get/2` takes the ETag we last saw. A `:not_modified`
      reply is a metadata-only operation, which is what makes "verify every
      read against the source of truth" affordable.
    * **Compare-and-swap.** `put/3` accepts `:if_match` and `:if_none_match`,
      which is how pushes are linearized without a consensus protocol. A
      rejected CAS is a `{:error, :precondition_failed}`, never a lost write.
    * **Immutability by convention.** Packfiles are content-addressed, so they
      are written once and never mutated. Only the WAL index is ever updated in
      place, and only under CAS.

  Backends receive their own configuration as the last argument, so a node can
  in principle talk to more than one store.
  """

  @type key :: String.t()
  @type etag :: String.t()
  @type error :: {:error, term()}
  @type entry :: %{key: key(), size: non_neg_integer()}

  @typedoc """
  Conditions for a write.

    * `{:if_none_match, "*"}` creates the object only if it does not exist.
    * `{:if_match, etag}` replaces the object only if it still has that ETag.
  """
  @type put_opt :: {:if_match, etag()} | {:if_none_match, String.t()} | {:content_type, String.t()}

  @type get_result :: {:ok, binary(), etag()} | {:ok, :not_modified} | {:error, :not_found} | error()

  @callback get(key(), opts :: keyword(), config :: keyword()) :: get_result()
  @callback put(key(), iodata(), [put_opt()], config :: keyword()) ::
              {:ok, etag()} | {:error, :precondition_failed} | error()
  @callback delete(key(), config :: keyword()) :: :ok | error()
  @callback list(prefix :: String.t(), config :: keyword()) :: {:ok, [entry()]} | error()
  @callback stat(key(), config :: keyword()) ::
              {:ok, %{etag: etag(), size: non_neg_integer()}} | {:error, :not_found} | error()

  @doc """
  Upload a local file without reading it into memory.

  Packfiles are the only objects whose size is set by the user rather than by
  us, and a repository's pack is as large as its history. Holding one in a
  binary means a node's memory ceiling is a customer's repository size, which
  is not a ceiling anyone can plan around.
  """
  @callback put_file(key(), Path.t(), [put_opt()], config :: keyword()) ::
              {:ok, etag()} | {:error, :precondition_failed} | error()

  @doc "Download an object straight to a local file, without buffering it."
  @callback get_file(key(), Path.t(), opts :: keyword(), config :: keyword()) ::
              {:ok, non_neg_integer()} | {:error, :not_found} | error()

  @doc """
  Read an object.

  Pass `etag: previous` to make the read conditional; the reply is
  `{:ok, :not_modified}` when nothing has changed since that ETag.
  """
  @spec get(key(), keyword()) :: get_result()
  def get(key, opts \\ []), do: dispatch(:get, [key, opts])

  @doc "Write an object, optionally under a compare-and-swap precondition."
  @spec put(key(), iodata(), [put_opt()]) :: {:ok, etag()} | {:error, :precondition_failed} | error()
  def put(key, body, opts \\ []), do: dispatch(:put, [key, body, opts])

  @spec delete(key()) :: :ok | error()
  def delete(key), do: dispatch(:delete, [key])

  @spec list(String.t()) :: {:ok, [entry()]} | error()
  def list(prefix), do: dispatch(:list, [prefix])

  @spec stat(key()) :: {:ok, %{etag: etag(), size: non_neg_integer()}} | {:error, :not_found} | error()
  def stat(key), do: dispatch(:stat, [key])

  @doc "Upload a local file without reading it into memory."
  @spec put_file(key(), Path.t(), [put_opt()]) :: {:ok, etag()} | {:error, :precondition_failed} | error()
  def put_file(key, path, opts \\ []), do: dispatch(:put_file, [key, path, opts])

  @doc "Download an object straight to a local file, without buffering it."
  @spec get_file(key(), Path.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, :not_found} | error()
  def get_file(key, path, opts \\ []), do: dispatch(:get_file, [key, path, opts])

  @doc """
  The SHA-256 of a local file, read in chunks.

  Used to describe a pack in the log without ever holding it whole.
  """
  @spec digest_file(Path.t()) :: {:ok, String.t(), non_neg_integer()} | {:error, term()}
  def digest_file(path) do
    case File.stat(path) do
      {:ok, %{size: size}} ->
        digest =
          path
          |> File.stream!(256 * 1024)
          |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
          |> :crypto.hash_final()
          |> Base.encode16(case: :lower)

        {:ok, digest, size}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The backend module and configuration this node is running with."
  @spec backend() :: {module(), keyword()}
  def backend, do: Micelio.Config.object_store()

  defp dispatch(fun, args) do
    {mod, config} = backend()
    started = System.monotonic_time(:microsecond)

    result =
      Micelio.Telemetry.span(
        "micelio.object_store.#{fun}",
        %{
          "micelio.object_store.operation" => Atom.to_string(fun),
          "micelio.object_store.backend" => inspect(mod)
        },
        fn ->
          apply(mod, fun, args ++ [config])
          |> Micelio.Telemetry.put_span_outcome()
        end
      )

    :telemetry.execute(
      [:micelio, :object_store, :request],
      %{duration_us: System.monotonic_time(:microsecond) - started},
      %{operation: fun, outcome: operation_outcome(result)}
    )

    result
  end

  defp operation_outcome(:ok), do: :ok
  defp operation_outcome({:ok, _}), do: :ok
  defp operation_outcome({:ok, _, _}), do: :ok
  defp operation_outcome({:error, :not_found}), do: :not_found
  defp operation_outcome({:error, :precondition_failed}), do: :precondition_failed
  defp operation_outcome({:error, _}), do: :error
end
