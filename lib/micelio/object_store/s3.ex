defmodule Micelio.ObjectStore.S3 do
  @moduledoc """
  S3-compatible object store.

  Requests are signed with SigV4 and issued through `Req`, which keeps full
  control over the conditional headers the write-ahead log depends on:

    * `If-None-Match: *` on the very first write of a repository's WAL index,
      so two nodes racing to create the same repository cannot both win.
    * `If-Match: <etag>` on every subsequent index update, which is the
      compare-and-swap that linearizes pushes.
    * `If-None-Match: <etag>` on reads, so an up-to-date replica pays for a
      metadata round trip instead of a body transfer.

  Packfiles are content-addressed and written with `If-None-Match: *`; a
  precondition failure there means the exact same bytes are already stored,
  which is success, not an error.

  Works against AWS S3, MinIO, Tigris, Cloudflare R2 and Ceph. Set
  `path_style: true` (the default) for anything that is not AWS proper.
  """

  @behaviour Micelio.ObjectStore

  # Chunk size for streamed uploads. Large enough that the per-chunk overhead
  # is irrelevant, small enough that memory stays flat regardless of the file.
  @chunk 1024 * 1024

  @doc """
  The largest object a single upload can carry.

  S3 refuses a `PUT` over five gibibytes; beyond that a multipart upload is
  required, which is not implemented. A pack larger than this fails loudly at
  the point of upload rather than being silently truncated.
  """
  @spec max_object_size() :: pos_integer()
  def max_object_size, do: 5 * 1024 * 1024 * 1024

  @impl true
  def get(key, opts, config) do
    headers =
      case Keyword.get(opts, :etag) do
        nil -> []
        etag -> [{"if-none-match", etag}]
      end

    case request(:get, key, config, headers: headers, decode_body: false) do
      {:ok, %{status: 200} = resp} -> {:ok, resp.body, etag(resp)}
      {:ok, %{status: 304}} -> {:ok, :not_modified}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, resp} -> {:error, {:unexpected_status, resp.status, body_excerpt(resp)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def put(key, body, opts, config) do
    headers =
      []
      |> maybe_header("if-match", Keyword.get(opts, :if_match))
      |> maybe_header("if-none-match", Keyword.get(opts, :if_none_match))
      |> maybe_header("content-type", Keyword.get(opts, :content_type, "application/octet-stream"))

    case request(:put, key, config, headers: headers, body: IO.iodata_to_binary(body), decode_body: false) do
      {:ok, %{status: status} = resp} when status in 200..299 ->
        {:ok, etag(resp)}

      # 412 is a lost compare-and-swap. 409 is what some implementations return
      # when two conditional writes collide; both mean "retry against the
      # current state", never "the write partially applied".
      {:ok, %{status: status}} when status in [409, 412] ->
        {:error, :precondition_failed}

      {:ok, resp} ->
        {:error, {:unexpected_status, resp.status, body_excerpt(resp)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def put_file(key, source, opts, config) do
    case File.stat(source) do
      {:ok, %{size: size}} when size > 5 * 1024 * 1024 * 1024 ->
        # S3 rejects this with an opaque `EntityTooLarge`. Naming the limit
        # here means an operator reading the log learns what to do about it.
        {:error, {:object_too_large, key, size, max_object_size()}}

      {:ok, %{size: size}} ->
        headers =
          [{"content-length", Integer.to_string(size)}]
          |> maybe_header("if-match", Keyword.get(opts, :if_match))
          |> maybe_header("if-none-match", Keyword.get(opts, :if_none_match))
          |> maybe_header("content-type", Keyword.get(opts, :content_type, "application/octet-stream"))

        # An enumerable body makes Req sign with UNSIGNED-PAYLOAD, which is why
        # content-length has to be explicit. The payload is therefore not
        # covered by the signature, so the transport has to be — use HTTPS for
        # anything but a local store.
        options = [
          headers: headers,
          body: File.stream!(source, @chunk),
          decode_body: false,
          # Not retried: the body is a stream and cannot be replayed, and a
          # half-sent object is worse than a reported failure the caller
          # retries from the start.
          retry: false
        ]

        case request(:put, key, config, options) do
          {:ok, %{status: status} = resp} when status in 200..299 -> {:ok, etag(resp)}
          {:ok, %{status: status}} when status in [409, 412] -> {:error, :precondition_failed}
          {:ok, resp} -> {:error, {:unexpected_status, resp.status, body_excerpt(resp)}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def get_file(key, destination, _opts, config) do
    File.mkdir_p!(Path.dirname(destination))
    partial = destination <> ".partial"

    # Written to a temporary name and renamed, so an interrupted download can
    # never be mistaken for a complete object by whatever reads it next.
    result =
      request(:get, key, config,
        into: File.stream!(partial),
        decode_body: false,
        retry: :safe_transient,
        max_retries: 2
      )

    case result do
      {:ok, %{status: 200}} ->
        File.rename!(partial, destination)
        {:ok, File.stat!(destination).size}

      {:ok, %{status: 404}} ->
        File.rm(partial)
        {:error, :not_found}

      {:ok, resp} ->
        File.rm(partial)
        {:error, {:unexpected_status, resp.status, ""}}

      {:error, reason} ->
        File.rm(partial)
        {:error, reason}
    end
  end

  @impl true
  def delete(key, config) do
    case request(:delete, key, config, decode_body: false) do
      {:ok, %{status: status}} when status in 200..299 or status == 404 -> :ok
      {:ok, resp} -> {:error, {:unexpected_status, resp.status, body_excerpt(resp)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list(prefix, config) do
    list_page(prefix, config, nil, [])
  end

  @impl true
  def stat(key, config) do
    case request(:head, key, config, decode_body: false) do
      {:ok, %{status: 200} = resp} ->
        size =
          resp
          |> Req.Response.get_header("content-length")
          |> List.first("0")
          |> String.to_integer()

        {:ok, %{etag: etag(resp), size: size}}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, resp} ->
        {:error, {:unexpected_status, resp.status, body_excerpt(resp)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_page(prefix, config, token, acc) do
    params =
      [{"list-type", "2"}, {"prefix", full_key(prefix, config)}]
      |> then(fn p -> if token, do: p ++ [{"continuation-token", token}], else: p end)

    url = bucket_url(config) <> "?" <> URI.encode_query(params)

    case Req.request(build(config, method: :get, url: url, decode_body: false)) do
      {:ok, %{status: 200} = resp} ->
        {keys, next} = parse_list_response(resp.body, config)
        acc = acc ++ keys

        if next, do: list_page(prefix, config, next, acc), else: {:ok, acc}

      {:ok, resp} ->
        {:error, {:unexpected_status, resp.status, body_excerpt(resp)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ListObjectsV2 returns XML. Rather than take an XML dependency for one call
  # site, pull out the two elements we need with a scan; keys are URL-safe
  # because Micelio generates all of them.
  defp parse_list_response(xml, config) do
    prefix = Keyword.get(config, :prefix, "")

    keys =
      Regex.scan(~r{<Contents>.*?</Contents>}s, xml)
      |> Enum.map(fn [chunk] ->
        %{
          key: chunk |> extract("Key") |> strip_prefix(prefix),
          size: chunk |> extract("Size") |> String.to_integer()
        }
      end)

    next =
      case extract(xml, "NextContinuationToken") do
        "" -> nil
        token -> token
      end

    truncated? = extract(xml, "IsTruncated") == "true"

    {keys, if(truncated?, do: next, else: nil)}
  end

  defp extract(xml, tag) do
    case Regex.run(~r{<#{tag}>(.*?)</#{tag}>}s, xml) do
      [_, value] -> value
      nil -> ""
    end
  end

  defp strip_prefix(key, ""), do: key

  defp strip_prefix(key, prefix) do
    prefix = String.trim_trailing(prefix, "/") <> "/"
    String.replace_prefix(key, prefix, "")
  end

  defp request(method, key, config, opts) do
    Req.request(build(config, Keyword.merge(opts, method: method, url: object_url(key, config))))
  end

  defp build(config, opts) do
    Req.new(
      retry: :safe_transient,
      max_retries: 3,
      receive_timeout: Keyword.get(config, :receive_timeout, :timer.seconds(60)),
      aws_sigv4: [
        service: :s3,
        region: Keyword.get(config, :region, "auto"),
        access_key_id: Keyword.fetch!(config, :access_key_id),
        secret_access_key: Keyword.fetch!(config, :secret_access_key)
      ]
    )
    |> Req.merge(opts)
  end

  defp object_url(key, config), do: bucket_url(config) <> "/" <> encode_key(full_key(key, config))

  defp bucket_url(config) do
    endpoint = config |> Keyword.fetch!(:endpoint) |> String.trim_trailing("/")
    bucket = Keyword.fetch!(config, :bucket)

    if Keyword.get(config, :path_style, true) do
      endpoint <> "/" <> bucket
    else
      %URI{host: host} = uri = URI.parse(endpoint)
      URI.to_string(%{uri | host: bucket <> "." <> host})
    end
  end

  defp full_key(key, config) do
    case Keyword.get(config, :prefix, "") do
      "" -> key
      prefix -> String.trim_trailing(prefix, "/") <> "/" <> key
    end
  end

  # S3 keys are path segments: encode each segment but keep the separators.
  defp encode_key(key) do
    key |> String.split("/") |> Enum.map_join("/", &encode_segment/1)
  end

  defp encode_segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  defp maybe_header(headers, _name, nil), do: headers
  defp maybe_header(headers, name, value), do: [{name, value} | headers]

  defp etag(resp) do
    resp |> Req.Response.get_header("etag") |> List.first() || ""
  end

  defp body_excerpt(%{body: body}) when is_binary(body), do: String.slice(body, 0, 500)
  defp body_excerpt(%{body: body}), do: inspect(body, limit: 20)
end
