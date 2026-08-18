defmodule Micelio.ObjectStore.Filesystem do
  @moduledoc """
  Filesystem-backed object store for development and tests.

  It implements the same conditional-read and compare-and-swap semantics as S3
  so that the WAL code paths under test are the ones that run in production.
  Writes are serialized through `Micelio.ObjectStore.Filesystem.Lock` to make
  read-modify-write atomic; that is only sound within a single node, which is
  exactly the scope this backend is meant for.
  """

  @behaviour Micelio.ObjectStore

  alias Micelio.ObjectStore.Filesystem.Lock

  @impl true
  def get(key, opts, config) do
    path = path_for(key, config)

    case File.read(path) do
      {:ok, body} ->
        etag = etag_for(body)

        if Keyword.get(opts, :etag) == etag do
          {:ok, :not_modified}
        else
          {:ok, body, etag}
        end

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def put(key, body, opts, config) do
    Lock.transaction(fn -> do_put(key, body, opts, config) end)
  end

  @impl true
  def delete(key, config) do
    case File.rm(path_for(key, config)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list(prefix, config) do
    root = root(config)

    entries =
      root
      |> Path.join(prefix <> "**")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(fn path ->
        %{key: Path.relative_to(path, root), size: File.stat!(path).size}
      end)
      |> Enum.sort_by(& &1.key)

    {:ok, entries}
  end

  @impl true
  def stat(key, config) do
    path = path_for(key, config)

    case File.read(path) do
      {:ok, body} -> {:ok, %{etag: etag_for(body), size: byte_size(body)}}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_put(key, body, opts, config) do
    path = path_for(key, config)
    body = IO.iodata_to_binary(body)
    current = File.read(path)

    with :ok <- check_if_none_match(Keyword.get(opts, :if_none_match), current),
         :ok <- check_if_match(Keyword.get(opts, :if_match), current) do
      File.mkdir_p!(Path.dirname(path))
      tmp = path <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
      File.write!(tmp, body)
      File.rename!(tmp, path)
      {:ok, etag_for(body)}
    end
  end

  defp check_if_none_match(nil, _current), do: :ok
  defp check_if_none_match("*", {:ok, _}), do: {:error, :precondition_failed}
  defp check_if_none_match("*", _), do: :ok

  defp check_if_none_match(etag, {:ok, body}) do
    if etag_for(body) == etag, do: {:error, :precondition_failed}, else: :ok
  end

  defp check_if_none_match(_etag, _), do: :ok

  defp check_if_match(nil, _current), do: :ok

  defp check_if_match(etag, {:ok, body}) do
    if etag_for(body) == etag, do: :ok, else: {:error, :precondition_failed}
  end

  defp check_if_match(_etag, _), do: {:error, :precondition_failed}

  defp etag_for(body), do: ~s("#{Base.encode16(:crypto.hash(:md5, body), case: :lower)}")

  defp path_for(key, config), do: Path.join(root(config), key)

  defp root(config), do: Keyword.fetch!(config, :root)
end
