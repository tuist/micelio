defmodule Micelio.WAL do
  @moduledoc """
  The write-ahead log: the source of truth for every repository.

  ## Layout

      repos/<repo_id>/index.pb            the only mutable object, under CAS
      repos/<repo_id>/wal/<digest>.pb     entries, immutable, content-addressed
      repos/<repo_id>/packs/<name>.pack   packfiles, immutable
      repos/<repo_id>/packs/<name>.idx
      repos/<repo_id>/history/<epoch>.pb  index snapshots kept for provenance

  Everything but the packfiles is protobuf (`priv/proto/micelio/wal/v1`). The
  log outlives any single version of this code, so its encoding is a schema
  with compatibility rules rather than whatever a serializer happened to emit.

  ## How a push becomes visible

  Objects are written before they are referenced, and the reference is
  installed with a compare-and-swap:

    1. The packfile is uploaded. It is content-addressed, so this is idempotent
       and can be retried freely.
    2. The entry describing the ref transaction is uploaded under the hash of
       its own bytes. Also idempotent, which is why a lost CAS costs one small
       `PUT` on retry rather than re-uploading the pack.
    3. The index is read, the entry pointer appended, and the result written
       back with `If-Match` on the ETag we read. Exactly one writer can win.

  Nothing is acknowledged to the client until step 3 succeeds. A push that is
  in the log is durable and ordered; a push that is not is as if it never
  happened. There is no third state, and no window in which a client is told
  "yes" and the log says otherwise.

  ## Why there is no consensus protocol here

  Ordering is decided by one atomic operation on one object. That is enough to
  linearize pushes, which means any node can accept a push without first
  agreeing with the others about who is in charge. Losing the race is not a
  failure: it means someone else's push landed first, so we re-read and try
  again against the state they left behind.
  """

  alias Micelio.Config
  alias Micelio.ObjectStore
  alias Micelio.WAL.Entry
  alias Micelio.WAL.Index

  @type repo_id :: String.t()
  @type read_result :: {:ok, Index.t(), ObjectStore.etag()} | {:ok, :not_modified} | {:error, term()}

  @cas_attempts 12
  @content_type "application/vnd.micelio.wal.v1+protobuf"

  @typedoc """
  An entry whose object is already stored, ready to be installed in the index.

  `validate` is re-run against the live index on every compare-and-swap
  attempt, so a check like "this ref must still be where the client thought"
  is evaluated against the state that actually won, not a stale read.
  """
  @type prepared :: %{
          entry: Entry.t(),
          key: String.t(),
          size: non_neg_integer(),
          digest: String.t(),
          validate: (Index.t() -> :ok | {:error, term()})
        }

  @doc "Validate a repository identifier, which is also an object-store key prefix."
  @spec valid_id?(term()) :: boolean()
  def valid_id?(id) when is_binary(id) do
    byte_size(id) <= 512 and
      Regex.match?(~r{^[a-zA-Z0-9][a-zA-Z0-9._\-]*(/[a-zA-Z0-9][a-zA-Z0-9._\-]*)*$}, id) and
      not String.contains?(id, "..")
  end

  def valid_id?(_), do: false

  @spec index_key(repo_id()) :: String.t()
  def index_key(repo_id), do: "repos/#{repo_id}/index.pb"

  @spec entry_key(repo_id(), String.t()) :: String.t()
  def entry_key(repo_id, digest), do: "repos/#{repo_id}/wal/#{digest}.pb"

  @spec pack_key(repo_id(), String.t()) :: String.t()
  def pack_key(repo_id, name), do: "repos/#{repo_id}/packs/#{name}"

  @spec history_key(repo_id(), non_neg_integer()) :: String.t()
  def history_key(repo_id, epoch), do: "repos/#{repo_id}/history/#{epoch}.pb"

  @doc """
  Create the log for a new repository.

  Uses `If-None-Match: *`, so if two nodes create the same repository at the
  same moment exactly one wins and the other is told `:already_exists`. No
  locking, no coordination.
  """
  @spec create(repo_id(), keyword()) :: {:ok, Index.t()} | {:error, :already_exists | term()}
  def create(repo_id, opts \\ []) do
    unless valid_id?(repo_id), do: throw({:invalid_repo_id, repo_id})

    index = Index.new(repo_id, Keyword.put_new(opts, :node_id, Config.node_id()))

    case ObjectStore.put(index_key(repo_id), Index.encode(index),
           if_none_match: "*",
           content_type: @content_type
         ) do
      {:ok, _etag} -> {:ok, index}
      {:error, :precondition_failed} -> {:error, :already_exists}
      {:error, reason} -> {:error, reason}
    end
  catch
    {:invalid_repo_id, id} -> {:error, {:invalid_repo_id, id}}
  end

  @doc """
  Read the index, optionally conditionally.

  Passing the ETag from a previous read turns this into the cheap path that the
  whole consistency story rests on: a `304` is a metadata-only round trip and
  means the replica may serve immediately.
  """
  @spec read(repo_id(), ObjectStore.etag() | nil) :: read_result()
  def read(repo_id, etag \\ nil) do
    started = System.monotonic_time(:microsecond)
    result = ObjectStore.get(index_key(repo_id), etag: etag)
    duration = System.monotonic_time(:microsecond) - started

    case result do
      {:ok, :not_modified} ->
        emit_read(:not_modified, duration, repo_id)
        {:ok, :not_modified}

      {:ok, body, new_etag} ->
        emit_read(:modified, duration, repo_id)

        with {:ok, index} <- Index.decode(body), do: {:ok, index, new_etag}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Read the index unconditionally, failing if the repository does not exist."
  @spec fetch(repo_id()) :: {:ok, Index.t(), ObjectStore.etag()} | {:error, term()}
  def fetch(repo_id) do
    case read(repo_id, nil) do
      {:ok, :not_modified} -> {:error, :unexpected_not_modified}
      other -> other
    end
  end

  @doc """
  Append an entry to the log, retrying until the compare-and-swap wins.

  `build` receives the current index and returns `{:ok, entry}` to proceed or
  `{:error, reason}` to abort. It is re-invoked on every attempt, so a caller
  that needs to validate against the latest state (a non-fast-forward check,
  say) sees fresh data each time rather than deciding once against a stale read.

  Returns the entry's assigned sequence number and the resulting index.
  """
  @spec append(repo_id(), (Index.t() -> {:ok, Entry.t()} | {:error, term()})) ::
          {:ok, %{seq: non_neg_integer(), epoch: non_neg_integer(), index: Index.t()}} | {:error, term()}
  def append(repo_id, build) do
    append(repo_id, build, @cas_attempts)
  end

  defp append(_repo_id, _build, 0), do: {:error, :cas_exhausted}

  defp append(repo_id, build, attempts) do
    with {:ok, index, etag} <- fetch(repo_id),
         {:ok, entry} <- build.(index),
         {:ok, key, size, digest} <- put_entry(repo_id, entry) do
      updated = Index.append(index, entry, key, size, digest, Config.node_id())

      case ObjectStore.put(index_key(repo_id), Index.encode(updated),
             if_match: etag,
             content_type: @content_type
           ) do
        {:ok, _etag} ->
          :telemetry.execute(
            [:micelio, :wal, :append],
            %{seq: updated.seq, attempts: @cas_attempts - attempts + 1},
            %{
              repo_id: repo_id
            }
          )

          {:ok, %{seq: updated.seq, epoch: updated.epoch, index: updated}}

        {:error, :precondition_failed} ->
          # Either somebody else's push landed between our read and our write,
          # or ours landed and we never heard the answer. Those are
          # indistinguishable from here, and treating the second as the first
          # is how an operation that succeeded gets reported as rejected.
          #
          # The entry is addressed by the hash of its own bytes, so the
          # question is answerable: if the index already carries this exact
          # entry, the write was ours and it is already durable.
          :telemetry.execute([:micelio, :wal, :cas_retry], %{attempts: 1}, %{repo_id: repo_id})

          case already_committed(repo_id, digest) do
            {:ok, position} ->
              :telemetry.execute([:micelio, :wal, :ambiguous_commit], %{seq: position.seq}, %{
                repo_id: repo_id
              })

              {:ok, position}

            :no ->
              backoff(@cas_attempts - attempts)
              append(repo_id, build, attempts - 1)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Append several prepared entries under a single compare-and-swap.

  This is group commit. Each push already uploaded its own packs and its own
  entry object — both content-addressed, both contention-free — so the only
  serialized part is installing the pointers in the index. Doing that for a
  batch costs one read and one conditional write regardless of how many pushes
  are in it, which is what turns per-repository write throughput from "one
  round trip per push" into "one round trip per batch".

  Each prepared entry is validated in turn against the index as it evolves, so
  a batch behaves exactly as if its pushes had arrived one at a time: a push
  that would be a non-fast-forward *given the ones ahead of it in the batch* is
  rejected, and the rest still land. Results come back in the order given.
  """
  @spec append_batch(repo_id(), [prepared()]) ::
          {:ok, [{:ok, non_neg_integer()} | {:error, term()}]} | {:error, term()}
  def append_batch(repo_id, prepared), do: append_batch(repo_id, prepared, @cas_attempts)

  defp append_batch(_repo_id, _prepared, 0), do: {:error, :cas_exhausted}

  defp append_batch(repo_id, prepared, attempts) do
    with {:ok, index, etag} <- fetch(repo_id) do
      {updated, results} = apply_batch(index, prepared)

      if updated == index do
        # Every entry in the batch was rejected, so there is nothing to write.
        {:ok, results}
      else
        case ObjectStore.put(index_key(repo_id), Index.encode(updated),
               if_match: etag,
               content_type: @content_type
             ) do
          {:ok, _etag} ->
            :telemetry.execute(
              [:micelio, :wal, :append_batch],
              %{size: length(prepared), seq: updated.seq},
              %{repo_id: repo_id}
            )

            {:ok, results}

          {:error, :precondition_failed} ->
            :telemetry.execute([:micelio, :wal, :cas_retry], %{attempts: 1}, %{repo_id: repo_id})
            backoff(@cas_attempts - attempts)
            append_batch(repo_id, prepared, attempts - 1)

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  # Whether an entry with this digest is already installed.
  #
  # Only meaningful because entries are content-addressed and a digest is
  # therefore unique to one proposed change: finding it means this attempt
  # already succeeded, not that someone else made the same change.
  defp already_committed(repo_id, digest) do
    with {:ok, index, _etag} <- fetch(repo_id),
         pointer when not is_nil(pointer) <- Enum.find(index.entries, &(&1.digest == digest)) do
      {:ok, %{seq: pointer.seq, epoch: index.epoch, index: index}}
    else
      _ -> :no
    end
  end

  # Fold the batch in order, so each entry sees the ref state left by the ones
  # before it.
  defp apply_batch(index, prepared) do
    {index, results} =
      Enum.reduce(prepared, {index, []}, fn item, {index, results} ->
        case item.validate.(index) do
          :ok ->
            updated = Index.append(index, item.entry, item.key, item.size, item.digest, Config.node_id())
            {updated, [{:ok, %{seq: updated.seq, epoch: updated.epoch}} | results]}

          {:error, reason} ->
            {index, [{:error, reason} | results]}
        end
      end)

    {index, Enum.reverse(results)}
  end

  @doc """
  Upload an entry object and return what `append_batch/2` needs to install it.

  Separated from the append so the expensive, contention-free part — writing
  content-addressed objects — happens on whichever node received the push,
  while only the index update is funnelled through one writer.
  """
  @spec prepare(repo_id(), Entry.t(), (Index.t() -> :ok | {:error, term()})) ::
          {:ok, prepared()} | {:error, term()}
  def prepare(repo_id, entry, validate) do
    body = Entry.encode(entry)
    digest = digest(body)
    key = entry_key(repo_id, digest)

    with {:ok, _} <- write_immutable(key, body) do
      {:ok, %{entry: entry, key: key, size: byte_size(body), digest: digest, validate: validate}}
    end
  end

  @doc """
  Replace the log's base with a compaction result.

  The previous index is snapshotted under `history/<epoch>.json` first, so the
  full sequence of states a repository has been in stays reconstructible even
  though the active index no longer lists the replayed entries.

  Compaction is itself a compare-and-swap, so a push racing a compaction cannot
  be lost: whichever lands second sees the other's result and retries.
  """
  @spec compact(repo_id(), [Entry.pack()], map(), map(), Index.t(), ObjectStore.etag()) ::
          {:ok, Index.t()} | {:error, term()}
  def compact(repo_id, packs, refs, symrefs, index, etag) do
    with {:ok, _} <-
           ObjectStore.put(history_key(repo_id, index.epoch), Index.encode(index),
             if_none_match: "*",
             content_type: @content_type
           )
           |> allow_already_present() do
      compacted = Index.rebase(index, packs, refs, symrefs, Config.node_id())

      case ObjectStore.put(index_key(repo_id), Index.encode(compacted),
             if_match: etag,
             content_type: @content_type
           ) do
        {:ok, _etag} ->
          :telemetry.execute([:micelio, :wal, :compact], %{epoch: compacted.epoch, packs: length(packs)}, %{
            repo_id: repo_id
          })

          {:ok, compacted}

        {:error, :precondition_failed} ->
          {:error, :raced}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Read one entry, verifying it against the digest recorded in the index."
  @spec read_entry(repo_id(), Index.pointer()) :: {:ok, Entry.t()} | {:error, term()}
  def read_entry(_repo_id, pointer) do
    case ObjectStore.get(pointer.key) do
      {:ok, body, _etag} ->
        if digest(body) == pointer.digest do
          Entry.decode(body)
        else
          {:error, {:entry_digest_mismatch, pointer.key}}
        end

      {:ok, :not_modified} ->
        {:error, :unexpected_not_modified}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Upload a packfile and its index, returning the descriptor to record in a WAL
  entry.

  Packs are content-addressed by Git itself, so a name collision means the same
  object set, and re-uploading is a no-op. `If-None-Match: *` makes that
  explicit: a precondition failure here is success.
  """
  @spec put_pack(repo_id(), Path.t()) :: {:ok, Entry.pack()} | {:error, term()}
  def put_pack(repo_id, pack_path) do
    name = Path.basename(pack_path)
    body = File.read!(pack_path)

    with {:ok, _} <- write_immutable(pack_key(repo_id, name), body),
         :ok <- put_pack_index(repo_id, pack_path) do
      {:ok, %Micelio.Wal.V1.Pack{key: pack_key(repo_id, name), size: byte_size(body), digest: digest(body)}}
    end
  end

  defp put_pack_index(repo_id, pack_path) do
    idx = Path.rootname(pack_path) <> ".idx"

    if File.exists?(idx) do
      with {:ok, _} <- write_immutable(pack_key(repo_id, Path.basename(idx)), File.read!(idx)), do: :ok
    else
      # Not fatal: a replica can rebuild the index locally with `index-pack`.
      :ok
    end
  end

  @doc """
  Download a pack (and its index when present) into `dir`.

  The pack bytes are verified against the digest the log recorded before they
  are handed to Git, so a truncated or corrupted transfer fails here rather
  than surfacing as a mysterious repository error later.
  """
  @spec get_pack(repo_id(), Entry.pack(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def get_pack(repo_id, pack, dir) do
    File.mkdir_p!(dir)
    name = Path.basename(pack.key)
    destination = Path.join(dir, name)

    case ObjectStore.get(pack.key) do
      {:ok, body, _etag} ->
        if pack.digest && digest(body) != pack.digest do
          {:error, {:pack_digest_mismatch, pack.key}}
        else
          File.write!(destination, body)
          fetch_pack_index(repo_id, pack, dir, name)
          {:ok, destination}
        end

      {:ok, :not_modified} ->
        {:error, :unexpected_not_modified}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_pack_index(_repo_id, pack, dir, name) do
    idx_key = Path.rootname(pack.key) <> ".idx"

    case ObjectStore.get(idx_key) do
      {:ok, body, _etag} -> File.write!(Path.join(dir, Path.rootname(name) <> ".idx"), body)
      _ -> :ok
    end
  end

  @doc "Delete every object belonging to a repository. Irreversible."
  @spec destroy(repo_id()) :: :ok | {:error, term()}
  def destroy(repo_id) do
    with {:ok, entries} <- ObjectStore.list("repos/#{repo_id}/") do
      Enum.each(entries, &ObjectStore.delete(&1.key))
      ObjectStore.delete(index_key(repo_id))
    end
  end

  @doc "Every repository in the store, by scanning for index objects."
  @spec list_repositories() :: {:ok, [repo_id()]} | {:error, term()}
  def list_repositories do
    with {:ok, entries} <- ObjectStore.list("repos/") do
      ids =
        entries
        |> Enum.filter(&String.ends_with?(&1.key, "/index.pb"))
        |> Enum.map(fn %{key: key} ->
          key |> String.replace_prefix("repos/", "") |> String.replace_suffix("/index.pb", "")
        end)
        |> Enum.sort()

      {:ok, ids}
    end
  end

  @spec digest(binary()) :: String.t()
  def digest(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  defp put_entry(repo_id, entry) do
    body = Entry.encode(entry)
    key = entry_key(repo_id, digest(body))

    with {:ok, _} <- write_immutable(key, body), do: {:ok, key, byte_size(body), digest(body)}
  end

  # Immutable objects are keyed by their content, so "it is already there"
  # and "we just wrote it" are the same outcome.
  defp write_immutable(key, body) do
    ObjectStore.put(key, body, if_none_match: "*") |> allow_already_present()
  end

  defp allow_already_present({:error, :precondition_failed}), do: {:ok, :already_present}
  defp allow_already_present(other), do: other

  defp backoff(attempt) do
    # Jitter so that a burst of concurrent pushers spreads out instead of
    # colliding on the same retry instant.
    Process.sleep(min(200, trunc(:math.pow(2, attempt))) + :rand.uniform(25))
  end

  defp emit_read(outcome, duration, repo_id) do
    :telemetry.execute([:micelio, :wal, :read], %{duration_us: duration}, %{
      outcome: outcome,
      repo_id: repo_id
    })
  end
end
