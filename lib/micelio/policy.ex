defmodule Micelio.Policy do
  @moduledoc """
  Authorization as data in object storage.

  ## Why this exists

  Micelio validates tokens and never issues them, which keeps identity out of
  the system entirely. That answers *who you are*. It does not answer *what you
  may do*, and the usual answers all reintroduce the thing this architecture is
  built to avoid:

    * **Grants in token claims** work, and are the right answer for machine
      identities — a Kubernetes pod's projected token already says which
      namespace it belongs to. But a claim is true until the token expires, so
      revocation waits out the token's lifetime, and fine-grained grants for
      humans do not fit in a claim that has to be reissued to change.
    * **A permissions service** is a control plane: something to deploy, keep
      available, and be down when it is down.
    * **A database on each node** is authoritative state on a node, which is
      exactly what the rest of the design refuses to have.

  So policy goes where every other authoritative fact already lives. A policy
  object is read with a conditional GET and updated with a compare-and-swap,
  the same two operations the write-ahead log is built from. Every node can
  serve it, any node can change it, nothing has to be kept in sync, and there
  is still no control plane — the object store arbitrates, as it does for
  pushes.

  Revocation becomes immediate rather than eventual: a binding removed here is
  gone on the next read, not when a token happens to expire.

  ## Caching

  Authorization is on the path of every request, so an unconditional read per
  request would double the round trips. Policies are cached per node and
  revalidated with a conditional GET once the staleness budget elapses; a `304`
  is a metadata-only operation, the same fast path replicas use for the log.

  The budget defaults to five seconds rather than zero. Unlike a repository
  read — where serving stale data would be a correctness failure — a
  five-second-old policy is a bounded, deliberate window, and it is still
  orders of magnitude tighter than the token lifetime it replaces.
  """

  require Logger

  alias Micelio.Auth.Principal
  alias Micelio.Config
  alias Micelio.ObjectStore
  alias Micelio.Policy.V1

  @content_type "application/vnd.micelio.policy.v1+protobuf"
  @cache __MODULE__.Cache
  @cas_attempts 16

  @type account :: String.t()
  @type t :: V1.Policy.t()

  @doc false
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(_opts) do
    Task.start_link(fn ->
      # Idempotent, so starting a second cache (a test running against an
      # already-booted application) is a no-op rather than a crash.
      if :ets.whereis(@cache) == :undefined do
        :ets.new(@cache, [:named_table, :public, :set, read_concurrency: true])
      end

      Process.sleep(:infinity)
    end)
  end

  @doc false
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @spec key(account()) :: String.t()
  def key(account), do: "accounts/#{account}/policy.pb"

  @doc """
  The account a repository belongs to: everything before the first slash.
  """
  @spec account_of(String.t()) :: account()
  def account_of(repo_id) do
    case String.split(repo_id, "/", parts: 2) do
      [account, _rest] -> account
      [account] -> account
    end
  end

  @doc """
  Grants this subject holds over repositories in `account`.

  Returns `Micelio.Auth.Principal` grants, so they compose with whatever the
  token already carried: a principal may act if *either* source allows it.
  """
  @spec grants_for(account(), String.t()) :: [Principal.grant()]
  def grants_for(account, subject) do
    case get(account) do
      {:ok, policy} -> bindings_to_grants(policy, subject)
      {:error, _reason} -> []
    end
  end

  defp bindings_to_grants(policy, subject) do
    now = System.system_time(:millisecond)

    policy.bindings
    |> Enum.filter(&applies?(&1, subject, now))
    |> Enum.flat_map(fn binding ->
      permissions = parse_permissions(binding.permissions)
      Enum.map(binding.repositories, &Principal.grant(&1, permissions))
    end)
  end

  # The subject may be an exact match or a pattern, so a whole namespace of
  # service accounts can be bound in one line.
  defp applies?(binding, subject, now) do
    matches_subject?(binding.subject, subject) and not expired?(binding, now)
  end

  defp matches_subject?(pattern, subject) do
    pattern == subject or Principal.matches?(pattern, subject)
  end

  defp expired?(%{expires_at_ms: 0}, _now), do: false
  defp expired?(%{expires_at_ms: at}, now), do: at < now

  defp parse_permissions(permissions) do
    permissions
    |> Enum.filter(&(&1 in ~w(read write admin)))
    |> Enum.map(&String.to_existing_atom/1)
  end

  @doc """
  Read an account's policy, using the cache when it is fresh enough.

  An account with no policy object is not an error: it simply grants nothing
  beyond what tokens already carry.
  """
  @spec get(account()) :: {:ok, t()} | {:error, term()}
  def get(account) do
    case cached(account) do
      {:fresh, policy} -> {:ok, policy}
      {:stale, etag, policy} -> revalidate(account, etag, policy)
      :miss -> load(account)
    end
  end

  defp cached(account) do
    with true <- :ets.whereis(@cache) != :undefined,
         [{_key, etag, policy, at}] <- :ets.lookup(@cache, cache_key(account)) do
      if System.monotonic_time(:millisecond) - at < Config.policy_staleness_budget_ms() do
        {:fresh, policy}
      else
        {:stale, etag, policy}
      end
    else
      _ -> :miss
    end
  end

  defp revalidate(account, etag, policy) do
    case ObjectStore.get(key(account), etag: etag) do
      {:ok, :not_modified} ->
        touch(account, etag, policy)
        {:ok, policy}

      {:ok, body, new_etag} ->
        decode_and_cache(account, body, new_etag)

      {:error, :not_found} ->
        forget(account)
        {:ok, empty(account)}

      {:error, reason} ->
        # Keep serving what we have. An unreachable object store should not
        # revoke everybody's access.
        Logger.warning("micelio: could not revalidate policy for #{account}: #{inspect(reason)}")
        {:ok, policy}
    end
  end

  defp load(account) do
    case ObjectStore.get(key(account)) do
      {:ok, body, etag} -> decode_and_cache(account, body, etag)
      {:ok, :not_modified} -> {:error, :unexpected_not_modified}
      {:error, :not_found} -> {:ok, empty(account)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_and_cache(account, body, etag) do
    case decode(body) do
      {:ok, policy} ->
        touch(account, etag, policy)
        {:ok, policy}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp touch(account, etag, policy) do
    if :ets.whereis(@cache) != :undefined do
      :ets.insert(@cache, {cache_key(account), etag, policy, System.monotonic_time(:millisecond)})
    end
  end

  defp forget(account) do
    if :ets.whereis(@cache) != :undefined, do: :ets.delete(@cache, cache_key(account))
  end

  # The cache is keyed by the object store it came from as well as the account,
  # so a node pointed at two stores — or a test suite running many in parallel —
  # cannot serve one's policy for the other.
  defp cache_key(account), do: {:erlang.phash2(ObjectStore.backend()), account}

  @doc """
  Replace an account's policy, under compare-and-swap.

  `update` receives the current bindings and returns the new ones. It is
  re-invoked on every attempt, so a concurrent change is merged with rather
  than clobbered.
  """
  @spec update(account(), ([V1.Binding.t()] -> [V1.Binding.t()])) :: {:ok, t()} | {:error, term()}
  def update(account, update), do: update(account, update, @cas_attempts)

  defp update(_account, _update, 0), do: {:error, :cas_exhausted}

  defp update(account, update, attempts) do
    {current, etag} =
      case ObjectStore.get(key(account)) do
        {:ok, body, etag} ->
          case decode(body) do
            {:ok, policy} -> {policy, etag}
            {:error, _} -> {empty(account), etag}
          end

        _ ->
          {empty(account), nil}
      end

    now = System.system_time(:millisecond)

    updated = %{
      current
      | bindings: update.(current.bindings),
        version: current.version + 1,
        updated_at_ms: now,
        updated_by: Config.node_id(),
        created_at_ms: if(current.created_at_ms == 0, do: now, else: current.created_at_ms)
    }

    condition = if etag, do: [if_match: etag], else: [if_none_match: "*"]

    case ObjectStore.put(key(account), encode(updated), [content_type: @content_type] ++ condition) do
      {:ok, new_etag} ->
        touch(account, new_etag, updated)

        :telemetry.execute([:micelio, :policy, :updated], %{bindings: length(updated.bindings)}, %{
          account: account
        })

        {:ok, updated}

      {:error, :precondition_failed} ->
        # Somebody else changed the policy between our read and our write; redo
        # the change against theirs rather than overwriting it.
        #
        # The backoff is not politeness. Without it, every concurrent writer
        # retries in lockstep and keeps colliding, so a burst of updates loses
        # some of its members to exhausted attempts rather than serializing.
        backoff(@cas_attempts - attempts)
        update(account, update, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Grant a subject permissions over repository patterns."
  @spec bind(account(), String.t(), [String.t()], [String.t()], keyword()) :: {:ok, t()} | {:error, term()}
  def bind(account, subject, repositories, permissions, opts \\ []) do
    binding = %V1.Binding{
      subject: subject,
      repositories: repositories,
      permissions: permissions,
      note: Keyword.get(opts, :note, ""),
      created_at_ms: System.system_time(:millisecond),
      expires_at_ms: Keyword.get(opts, :expires_at_ms, 0)
    }

    update(account, fn bindings ->
      # One binding per subject: re-binding replaces rather than accumulates,
      # so a policy cannot silently grow contradictory entries.
      Enum.reject(bindings, &(&1.subject == subject)) ++ [binding]
    end)
  end

  @doc "Remove every binding for a subject. Takes effect on the next read."
  @spec unbind(account(), String.t()) :: {:ok, t()} | {:error, term()}
  def unbind(account, subject) do
    update(account, fn bindings -> Enum.reject(bindings, &(&1.subject == subject)) end)
  end

  @doc "Delete an account's policy entirely."
  @spec destroy(account()) :: :ok | {:error, term()}
  def destroy(account) do
    forget(account)
    ObjectStore.delete(key(account))
  end

  @doc "Drop the cached policy for one account, so the next read is authoritative."
  @spec invalidate(account()) :: :ok
  def invalidate(account) do
    forget(account)
    :ok
  end

  @doc "Drop every cached policy. Used after a restore."
  @spec invalidate() :: :ok
  def invalidate do
    if :ets.whereis(@cache) != :undefined, do: :ets.delete_all_objects(@cache)
    :ok
  end

  # Exponential with jitter, so a burst spreads out instead of resynchronising
  # on every round.
  defp backoff(attempt) do
    Process.sleep(min(200, trunc(:math.pow(2, attempt))) + :rand.uniform(25))
  end

  @spec empty(account()) :: t()
  def empty(account), do: %V1.Policy{account: account, bindings: [], version: 0}

  @spec encode(t()) :: binary()
  def encode(%V1.Policy{} = policy), do: V1.Policy.encode(policy)

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(binary) do
    {:ok, V1.Policy.decode(binary)}
  rescue
    error -> {:error, {:malformed_policy, error}}
  end

  @doc "Render a policy for the admin API."
  @spec describe(t()) :: map()
  def describe(%V1.Policy{} = policy) do
    %{
      account: policy.account,
      version: policy.version,
      updated_at: to_iso(policy.updated_at_ms),
      updated_by: policy.updated_by,
      bindings:
        Enum.map(policy.bindings, fn binding ->
          %{
            subject: binding.subject,
            repositories: binding.repositories,
            permissions: binding.permissions,
            note: binding.note,
            expires_at: to_iso(binding.expires_at_ms)
          }
        end)
    }
  end

  defp to_iso(0), do: nil
  defp to_iso(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
end
