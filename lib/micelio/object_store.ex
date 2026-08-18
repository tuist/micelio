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

  @doc "The backend module and configuration this node is running with."
  @spec backend() :: {module(), keyword()}
  def backend, do: Micelio.Config.object_store()

  defp dispatch(fun, args) do
    {mod, config} = backend()
    apply(mod, fun, args ++ [config])
  end
end
