defmodule Micelio.Factory do
  @moduledoc """
  Durable, leaderless work runs for repository automation.

  A work run is deliberately separate from a repository's source write-ahead
  log. Source history remains in `Micelio.WAL`; the factory keeps its own small
  journal in the same object store because attempt claims, logs and graph
  transitions are much higher-volume coordination data than Git pushes.

  There is no scheduler record on a node. The mutable `state.json` object is
  advanced with compare-and-swap, while specifications, claims, results and
  events are immutable objects. Two reconcilers may prepare the same work, but
  only the attempt named by the accepted state can publish a canonical result.
  All other results remain visible as superseded evidence.
  """

  alias Micelio.Auth.Principal
  alias Micelio.Factory.InferenceProfile
  alias Micelio.ObjectStore
  alias Micelio.Policy
  alias Micelio.Telemetry
  alias Micelio.WAL

  @content_type "application/vnd.micelio.factory.v1+json"
  @cas_attempts 16
  @default_lease_duration_ms 30 * 60 * 1_000

  @type result :: {:ok, map()} | {:error, String.t()}
  @type node_id :: String.t()
  @type dependency_graph :: %{optional(node_id()) => [node_id()]}
  @type visited_nodes :: %{optional(node_id()) => true}

  @doc "Create an immutable work specification and its initial graph state."
  @spec create(String.t(), map(), map(), Principal.t()) :: result()
  def create(repo_id, graph, attrs, principal) do
    observe(:create, fn -> do_create(repo_id, graph, attrs, principal) end)
  end

  defp do_create(repo_id, graph, attrs, %Principal{} = principal) when is_map(graph) and is_map(attrs) do
    with :ok <- repository(repo_id),
         {:ok, nodes} <- normalize_graph(graph),
         {:ok, nodes} <- pin_inference_profiles(Policy.account_of(repo_id), nodes),
         {:ok, base_commit} <- base_commit(attrs["base_commit"] || attrs[:base_commit]),
         :ok <- current_public_commit(repo_id, base_commit),
         {:ok, issue} <- issue(attrs["issue"] || attrs[:issue]),
         {:ok, lease_duration_ms} <- lease_duration(attrs["lease_duration_ms"] || attrs[:lease_duration_ms]) do
      id = identifier()
      now = now()

      manifest = %{
        "version" => 1,
        "id" => id,
        "repository" => repo_id,
        "issue" => issue,
        "base_commit" => base_commit,
        "graph" => %{"nodes" => nodes},
        "lease_duration_ms" => lease_duration_ms,
        "created_at_ms" => now,
        "created_by" => actor(principal)
      }

      event = event(id, 1, "work_run_created", actor(principal), %{"base_commit" => base_commit}, now)

      state = %{
        "version" => 1,
        "run_id" => id,
        "revision" => 1,
        "status" => "active",
        "nodes" => initial_nodes(nodes),
        "event_ids" => [event["id"]],
        "updated_at_ms" => now
      }

      with {:ok, _} <- put_immutable(manifest_key(repo_id, id), manifest),
           {:ok, _} <- put_immutable(event_key(repo_id, id, event["id"]), event),
           {:ok, _} <- put_immutable(state_key(repo_id, id), state) do
        {:ok, present(manifest, state)}
      else
        {:error, :precondition_failed} -> {:error, "work run id collision"}
        {:error, reason} -> {:error, "could not create work run: #{inspect(reason)}"}
      end
    end
  end

  defp do_create(_repo_id, _graph, _attrs, _principal),
    do: {:error, "work graph and attributes must be objects"}

  @doc "Read one work run's immutable specification and current projection."
  @spec get(String.t(), String.t()) :: result()
  def get(repo_id, run_id) do
    observe(:get, fn -> do_get(repo_id, run_id) end)
  end

  defp do_get(repo_id, run_id) do
    with :ok <- repository(repo_id),
         :ok <- run_id(run_id),
         {:ok, manifest} <- read_json(manifest_key(repo_id, run_id)),
         {:ok, state, _etag} <- read_json_with_etag(state_key(repo_id, run_id)) do
      {:ok, present(manifest, state)}
    else
      {:error, :not_found} -> {:error, "work run #{run_id} not found"}
      {:error, reason} -> {:error, "could not read work run: #{inspect(reason)}"}
    end
  end

  @doc "List work-run projections in a repository, newest first."
  @spec list(String.t()) :: result()
  def list(repo_id) do
    observe(:list, fn -> do_list(repo_id) end)
  end

  defp do_list(repo_id) do
    with :ok <- repository(repo_id),
         {:ok, entries} <- ObjectStore.list(runs_prefix(repo_id)) do
      runs =
        entries
        |> Enum.filter(&String.ends_with?(&1.key, "/state.json"))
        |> Enum.map(&run_id_from_state_key/1)
        |> Enum.map(&do_get(repo_id, &1))
        |> Enum.flat_map(fn
          {:ok, run} -> [run]
          _ -> []
        end)
        |> Enum.sort_by(& &1.created_at_ms, :desc)

      {:ok, %{repository: repo_id, runs: runs, count: length(runs)}}
    else
      {:error, reason} -> {:error, "could not list work runs: #{inspect(reason)}"}
    end
  end

  @doc "Claim one ready non-approval node. A lost race is retried from storage."
  @spec claim(String.t(), String.t(), String.t(), Principal.t()) :: result()
  def claim(repo_id, run_id, executor, principal) do
    observe(:claim, fn -> do_claim(repo_id, run_id, executor, principal) end)
  end

  defp do_claim(repo_id, run_id, executor, %Principal{} = principal)
       when is_binary(executor) and executor != "" do
    transition(repo_id, run_id, &claim_update(repo_id, run_id, executor, principal, &1, &2))
  end

  defp do_claim(_repo_id, _run_id, _executor, _principal), do: {:error, "executor must be a non-empty string"}

  @doc "Record an attempt result and conditionally make it the node's accepted result."
  @spec complete(String.t(), String.t(), String.t(), String.t(), String.t(), [map()], Principal.t()) ::
          result()
  def complete(repo_id, run_id, node_id, attempt_id, outcome, artifacts, principal) do
    observe(:complete, fn ->
      do_complete(repo_id, run_id, node_id, attempt_id, outcome, artifacts, principal)
    end)
  end

  defp do_complete(repo_id, run_id, node_id, attempt_id, outcome, artifacts, %Principal{} = principal)
       when outcome in ["succeeded", "failed"] and is_list(artifacts) do
    with :ok <- run_id(run_id),
         :ok <- node_id(node_id),
         :ok <- attempt_id(attempt_id) do
      completion = %{
        repo_id: repo_id,
        run_id: run_id,
        node_id: node_id,
        attempt_id: attempt_id,
        outcome: outcome,
        artifacts: artifacts,
        principal: principal
      }

      transition(repo_id, run_id, &complete_update(completion, &1, &2))
    end
  end

  defp do_complete(_repo_id, _run_id, _node_id, _attempt_id, outcome, _artifacts, _principal)
       when outcome not in ["succeeded", "failed"],
       do: {:error, "outcome must be succeeded or failed"}

  defp do_complete(_repo_id, _run_id, _node_id, _attempt_id, _outcome, _artifacts, _principal),
    do: {:error, "artifacts must be an array"}

  @doc "Approve a waiting approval node without granting an executor a source-code write."
  @spec approve(String.t(), String.t(), String.t(), Principal.t()) :: result()
  def approve(repo_id, run_id, node_id, %Principal{} = principal) do
    observe(:approve, fn -> do_approve(repo_id, run_id, node_id, principal) end)
  end

  def approve(_repo_id, _run_id, _node_id, _principal),
    do: {:error, "approval requires an authenticated principal"}

  defp do_approve(repo_id, run_id, node_id, %Principal{} = principal) do
    with :ok <- run_id(run_id),
         :ok <- node_id(node_id) do
      transition(repo_id, run_id, fn manifest, state ->
        with :ok <- active(state),
             {:ok, node} <- node(state, node_id),
             :ok <- approval_waiting(node) do
          updated =
            state
            |> put_node(node_id, Map.put(node, "status", "succeeded"))
            |> refresh_ready_nodes(manifest)
            |> finish_if_complete()

          {:ok, updated, {"approval_granted", actor(principal), %{"node" => node_id}, %{}}}
        end
      end)
    end
  end

  @doc "Cancel a run. A running attempt may still upload evidence but cannot be accepted."
  @spec cancel(String.t(), String.t(), Principal.t()) :: result()
  def cancel(repo_id, run_id, %Principal{} = principal) do
    observe(:cancel, fn -> do_cancel(repo_id, run_id, principal) end)
  end

  def cancel(_repo_id, _run_id, _principal), do: {:error, "cancellation requires an authenticated principal"}

  defp do_cancel(repo_id, run_id, %Principal{} = principal) do
    with :ok <- run_id(run_id) do
      transition(repo_id, run_id, fn _manifest, state ->
        with :ok <- active(state) do
          {:ok, Map.put(state, "status", "cancelled"), {"work_run_cancelled", actor(principal), %{}, %{}}}
        end
      end)
    end
  end

  @doc "Return the immutable event history after a durable state revision cursor."
  @spec events(String.t(), String.t(), non_neg_integer()) :: result()
  def events(repo_id, run_id, after_revision \\ 0) do
    observe(:events, fn -> do_events(repo_id, run_id, after_revision) end)
  end

  defp do_events(repo_id, run_id, after_revision) when is_integer(after_revision) and after_revision >= 0 do
    with :ok <- repository(repo_id),
         :ok <- run_id(run_id),
         {:ok, _manifest} <- read_json(manifest_key(repo_id, run_id)),
         {:ok, state, _etag} <- read_json_with_etag(state_key(repo_id, run_id)) do
      events =
        state["event_ids"]
        |> Enum.map(&read_json(event_key(repo_id, run_id, &1)))
        |> Enum.flat_map(fn
          {:ok, event} -> [event]
          _ -> []
        end)
        |> Enum.filter(&(&1["revision"] > after_revision))
        |> Enum.sort_by(& &1["revision"])

      {:ok, %{run_id: run_id, events: events, count: length(events), next_cursor: state["revision"]}}
    else
      {:error, :not_found} -> {:error, "work run #{run_id} not found"}
      {:error, reason} -> {:error, "could not read work events: #{inspect(reason)}"}
    end
  end

  defp do_events(_repo_id, _run_id, _after_revision), do: {:error, "after must be a non-negative integer"}

  @doc "Read a claimed or completed attempt without trusting a pod-local log."
  @spec attempt(String.t(), String.t(), String.t()) :: result()
  def attempt(repo_id, run_id, attempt_id) do
    observe(:attempt, fn -> do_attempt(repo_id, run_id, attempt_id) end)
  end

  defp do_attempt(repo_id, run_id, attempt_id) do
    with :ok <- repository(repo_id),
         :ok <- run_id(run_id),
         :ok <- attempt_id(attempt_id) do
      result = read_json(result_key(repo_id, run_id, attempt_id))
      claim = read_json(claim_key(repo_id, run_id, attempt_id))

      case {claim, result} do
        {{:ok, claim}, {:ok, result}} -> {:ok, %{attempt: claim, result: result}}
        {{:ok, claim}, {:error, :not_found}} -> {:ok, %{attempt: claim}}
        _ -> {:error, "attempt #{attempt_id} not found"}
      end
    end
  end

  @doc "Requeue one stale running node. Expiry is advisory and never invalidates accepted evidence."
  @spec expire(String.t(), String.t(), String.t()) :: result()
  def expire(repo_id, run_id, node_id) do
    observe(:expire, fn -> do_expire(repo_id, run_id, node_id) end)
  end

  defp do_expire(repo_id, run_id, node_id) do
    with :ok <- run_id(run_id),
         :ok <- node_id(node_id) do
      transition(repo_id, run_id, fn _manifest, state ->
        with :ok <- active(state),
             {:ok, node} <- node(state, node_id),
             :ok <- running(node),
             {:ok, claim} <- read_json(claim_key(repo_id, run_id, node["attempt_id"])),
             :ok <- expired(claim["lease_expires_at_ms"]) do
          attempt_id = node["attempt_id"]

          updated_node =
            node
            |> Map.put("status", "ready")
            |> append_attempt("expired_attempt_ids", attempt_id)
            |> Map.delete("attempt_id")
            |> Map.delete("executor")
            |> Map.delete("claimed_by")

          {:ok, put_node(state, node_id, updated_node),
           {"attempt_expired", %{"subject" => "micelio/factory"},
            %{"node" => node_id, "attempt" => attempt_id}, %{}}}
        end
      end)
    end
  end

  # ----------------------------------------------------------------------

  defp claim_update(repo_id, run_id, executor, principal, manifest, state) do
    with :ok <- active(state),
         {:ok, node_id, node} <- ready_node(state),
         definition = graph_node(manifest, node_id),
         {:ok, work} <- work(repo_id, manifest, definition) do
      attempt_id = identifier()
      number = node["attempts"] + 1
      claimed_at_ms = now()

      claim = %{
        "version" => 1,
        "id" => attempt_id,
        "run_id" => run_id,
        "node" => node_id,
        "number" => number,
        "executor" => executor,
        "claimed_by" => actor(principal),
        "claimed_at_ms" => claimed_at_ms,
        "lease_expires_at_ms" => claimed_at_ms + manifest["lease_duration_ms"]
      }

      case put_immutable(claim_key(repo_id, run_id, attempt_id), claim) do
        {:ok, _etag} ->
          updated_node =
            node
            |> Map.put("status", "running")
            |> Map.put("attempts", number)
            |> Map.put("attempt_id", attempt_id)
            |> Map.put("executor", executor)
            |> Map.put("claimed_by", actor(principal))

          updated = put_node(state, node_id, updated_node)

          {:ok, updated,
           {"node_claimed", actor(principal),
            %{"node" => node_id, "attempt" => attempt_id, "number" => number, "executor" => executor},
            %{
              attempt: claim,
              attempt_id: attempt_id,
              lease_duration_ms: manifest["lease_duration_ms"],
              work: work
            }}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp complete_update(completion, manifest, state) do
    with {:ok, node} <- node(state, completion.node_id),
         :ok <- claimed_attempt(completion),
         {:ok, disposition} <- attempt_disposition(node, completion.attempt_id),
         {:ok, artifacts} <- artifacts(completion.artifacts) do
      result = %{
        "version" => 1,
        "attempt" => completion.attempt_id,
        "run_id" => completion.run_id,
        "node" => completion.node_id,
        "outcome" => completion.outcome,
        "artifacts" => artifacts,
        "recorded_at_ms" => now(),
        "recorded_by" => actor(completion.principal)
      }

      case put_result(completion.repo_id, completion.run_id, completion.attempt_id, result) do
        :ok ->
          finalize_attempt(state, manifest, node, completion, result, disposition)

        {:error, reason} ->
          {:error, error_message(reason)}
      end
    end
  end

  defp transition(repo_id, run_id, update, attempts \\ @cas_attempts)
  defp transition(_repo_id, _run_id, _update, 0), do: {:error, "work run changed concurrently"}

  defp transition(repo_id, run_id, update, attempts) do
    with :ok <- repository(repo_id),
         :ok <- run_id(run_id),
         {:ok, manifest} <- read_json(manifest_key(repo_id, run_id)),
         {:ok, state, etag} <- read_json_with_etag(state_key(repo_id, run_id)) do
      case update.(manifest, state) do
        {:ok, updated, {type, actor, payload, extra}} ->
          revision = state["revision"] + 1
          event = event(run_id, revision, type, actor, payload, now())

          updated =
            updated
            |> Map.put("revision", revision)
            |> Map.put("event_ids", state["event_ids"] ++ [event["id"]])
            |> Map.put("updated_at_ms", now())

          with {:ok, _} <- put_immutable(event_key(repo_id, run_id, event["id"]), event),
               {:ok, _} <-
                 ObjectStore.put(state_key(repo_id, run_id), JSON.encode!(updated),
                   if_match: etag,
                   content_type: @content_type
                 ) do
            {:ok, Map.merge(present(manifest, updated), extra)}
          else
            {:error, :precondition_failed} -> transition(repo_id, run_id, update, attempts - 1)
            {:error, reason} -> {:error, "could not update work run: #{inspect(reason)}"}
          end

        {:already, extra} ->
          {:ok, Map.merge(present(manifest, state), extra)}

        {:error, reason} ->
          {:error, error_message(reason)}
      end
    else
      {:error, :not_found} -> {:error, "work run #{run_id} not found"}
      {:error, reason} -> {:error, "could not read work run: #{inspect(reason)}"}
    end
  end

  defp normalize_graph(%{"nodes" => nodes}), do: normalize_nodes(nodes)
  defp normalize_graph(%{nodes: nodes}), do: normalize_nodes(nodes)
  defp normalize_graph(_), do: {:error, "work graph must contain a nodes array"}

  defp normalize_nodes(nodes) when is_list(nodes) and nodes != [] do
    with {:ok, nodes} <- Enum.reduce_while(nodes, {:ok, []}, &normalize_node/2),
         :ok <- unique_node_ids(nodes),
         :ok <- known_dependencies(nodes),
         :ok <- acyclic(nodes) do
      {:ok, nodes}
    end
  end

  defp normalize_nodes(_), do: {:error, "work graph nodes must be a non-empty array"}

  defp normalize_node(raw, {:ok, acc}) when is_map(raw) do
    id = raw["id"] || raw[:id]
    kind = raw["kind"] || raw[:kind] || "agent"
    title = raw["title"] || raw[:title] || id
    depends_on = raw["depends_on"] || raw[:depends_on] || []
    execution = raw["execution"] || raw[:execution]

    with :ok <- node_id_valid?(id),
         :ok <- node_kind_valid?(kind),
         :ok <- node_title_valid?(title),
         :ok <- dependencies_valid?(id, depends_on),
         {:ok, execution} <- normalize_node_execution(id, execution) do
      node =
        %{"id" => id, "kind" => kind, "title" => title, "depends_on" => depends_on}
        |> maybe_put("execution", execution)

      {:cont, {:ok, acc ++ [node]}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp normalize_node(_raw, _acc), do: {:halt, {:error, "every work node must be an object"}}

  defp node_id_valid?(id),
    do: if(valid_identifier?(id), do: :ok, else: {:error, "every work node needs a simple id"})

  defp node_kind_valid?(kind) when kind in ["agent", "command", "evaluate", "approval"], do: :ok
  defp node_kind_valid?(kind), do: {:error, "unknown work node kind #{inspect(kind)}"}

  defp node_title_valid?(title) when is_binary(title) and title != "", do: :ok
  defp node_title_valid?(_title), do: {:error, "every work node needs a title"}

  defp dependencies_valid?(id, dependencies) when is_list(dependencies) do
    if Enum.all?(dependencies, &valid_identifier?/1),
      do: :ok,
      else: {:error, "node #{id} has invalid dependencies"}
  end

  defp dependencies_valid?(id, _dependencies), do: {:error, "node #{id} has invalid dependencies"}

  defp normalize_node_execution(id, execution) do
    case normalize_execution(execution) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:error, "node #{id} #{reason}"}
    end
  end

  # The factory carries a portable operation contract, not an agent session,
  # provider credential, or model selection. A worker maps `operation` to a
  # locally configured Condukt operation and creates the session inside its
  # sandbox. The same contract therefore works with a mocked worker in tests.
  defp normalize_execution(nil), do: {:ok, nil}

  defp normalize_execution(raw) when is_map(raw) do
    type = raw["type"] || raw[:type]
    operation = raw["operation"] || raw[:operation]
    input = raw["input"] || raw[:input] || %{}
    output_schema = raw["output_schema"] || raw[:output_schema]
    inference_profile = raw["inference_profile"] || raw[:inference_profile]

    with :ok <- execution_type_valid?(type),
         :ok <- execution_operation_valid?(operation),
         :ok <- execution_input_valid?(input),
         :ok <- optional_output_schema_valid?(output_schema),
         :ok <- optional_inference_profile_valid?(inference_profile) do
      {:ok,
       %{"type" => type, "operation" => operation, "input" => input}
       |> maybe_put("output_schema", output_schema)
       |> maybe_put("inference_profile", inference_profile)}
    end
  end

  defp normalize_execution(_), do: {:error, "has an execution that is not an object"}

  defp execution_type_valid?("condukt_operation"), do: :ok
  defp execution_type_valid?(_type), do: {:error, "has an unknown execution type"}

  defp execution_operation_valid?(operation) do
    if valid_operation?(operation), do: :ok, else: {:error, "needs a Condukt operation name"}
  end

  defp execution_input_valid?(input) when is_map(input), do: :ok
  defp execution_input_valid?(_input), do: {:error, "has a Condukt operation input that is not an object"}

  defp optional_output_schema_valid?(nil), do: :ok
  defp optional_output_schema_valid?(value) when is_map(value), do: :ok

  defp optional_output_schema_valid?(_value),
    do: {:error, "has a Condukt operation output schema that is not an object"}

  defp optional_inference_profile_valid?(nil), do: :ok

  defp optional_inference_profile_valid?(value) do
    if valid_identifier?(value), do: :ok, else: {:error, "has an invalid inference profile name"}
  end

  # A run stores only the selected profile and its immutable version. The
  # credential binding stays out of repository-readable graph state and work
  # claims; the trusted provisioner resolves it from account configuration.
  defp pin_inference_profiles(account, nodes) do
    Enum.reduce_while(nodes, {:ok, []}, fn node, {:ok, pinned} ->
      case get_in(node, ["execution", "inference_profile"]) do
        nil ->
          {:cont, {:ok, pinned ++ [node]}}

        name ->
          case InferenceProfile.pin(account, name) do
            {:ok, profile} ->
              execution =
                node["execution"]
                |> Map.put("inference_profile", profile["name"])
                |> Map.put("inference_profile_version", profile["version"])

              {:cont, {:ok, pinned ++ [Map.put(node, "execution", execution)]}}

            {:error, reason} ->
              {:halt, {:error, "node #{node["id"]} #{reason}"}}
          end
      end
    end)
  end

  defp unique_node_ids(nodes) do
    if length(nodes) == length(Enum.uniq_by(nodes, & &1["id"])),
      do: :ok,
      else: {:error, "work node ids must be unique"}
  end

  defp known_dependencies(nodes) do
    ids = MapSet.new(nodes, & &1["id"])

    if Enum.all?(nodes, fn node -> Enum.all?(node["depends_on"], &MapSet.member?(ids, &1)) end),
      do: :ok,
      else: {:error, "every work-node dependency must exist"}
  end

  @spec acyclic([map()]) :: :ok | {:error, String.t()}
  defp acyclic(nodes) do
    graph = dependency_graph(nodes)

    case Enum.reduce_while(Map.keys(graph), %{}, fn id, done ->
           case visit(id, graph, done, %{}) do
             {:ok, done} -> {:cont, done}
             :cycle -> {:halt, :cycle}
           end
         end) do
      :cycle -> {:error, "work graph must not contain a cycle"}
      _ -> :ok
    end
  end

  @spec dependency_graph([map()]) :: dependency_graph()
  defp dependency_graph(nodes), do: Map.new(nodes, &{&1["id"], &1["depends_on"]})

  @spec visit(node_id(), dependency_graph(), visited_nodes(), visited_nodes()) ::
          {:ok, visited_nodes()} | :cycle
  defp visit(id, graph, done, visiting) do
    cond do
      Map.has_key?(done, id) ->
        {:ok, done}

      Map.has_key?(visiting, id) ->
        :cycle

      true ->
        visiting = Map.put(visiting, id, true)

        Enum.reduce_while(Map.fetch!(graph, id), {:ok, done}, fn dependency, {:ok, done} ->
          case visit(dependency, graph, done, visiting) do
            {:ok, next} -> {:cont, {:ok, next}}
            :cycle -> {:halt, :cycle}
          end
        end)
        |> case do
          {:ok, done} -> {:ok, Map.put(done, id, true)}
          :cycle -> :cycle
        end
    end
  end

  defp initial_nodes(nodes) do
    Map.new(nodes, fn node ->
      status =
        if node["depends_on"] == [] do
          if node["kind"] == "approval", do: "waiting", else: "ready"
        else
          "pending"
        end

      {node["id"], Map.merge(node, %{"status" => status, "attempts" => 0})}
    end)
  end

  defp ready_node(state) do
    case state["nodes"]
         |> Map.values()
         |> Enum.filter(&(&1["status"] == "ready"))
         |> Enum.sort_by(& &1["id"]) do
      [node | _] -> {:ok, node["id"], node}
      [] -> {:error, "no work node is ready"}
    end
  end

  defp refresh_ready_nodes(state, manifest) do
    nodes = state["nodes"]

    refreshed =
      Enum.reduce(manifest["graph"]["nodes"], nodes, fn definition, acc ->
        node = Map.fetch!(acc, definition["id"])

        if node["status"] == "pending" and
             Enum.all?(definition["depends_on"], &(acc[&1]["status"] == "succeeded")) do
          status = if definition["kind"] == "approval", do: "waiting", else: "ready"
          Map.put(acc, definition["id"], Map.put(node, "status", status))
        else
          acc
        end
      end)

    Map.put(state, "nodes", refreshed)
  end

  defp finish_if_complete(state) do
    statuses = state["nodes"] |> Map.values() |> Enum.map(& &1["status"])

    cond do
      Enum.all?(statuses, &(&1 == "succeeded")) ->
        Map.put(state, "status", "succeeded")

      Enum.any?(statuses, &(&1 == "failed")) ->
        state
        |> Map.put("status", "failed")
        |> skip_unstarted_nodes()

      true ->
        state
    end
  end

  defp skip_unstarted_nodes(state) do
    nodes =
      Map.new(state["nodes"], fn {id, node} ->
        skipped =
          if node["status"] in ["pending", "ready", "waiting"],
            do: Map.put(node, "status", "skipped"),
            else: node

        {id, skipped}
      end)

    Map.put(state, "nodes", nodes)
  end

  defp claimed_attempt(completion) do
    with {:ok, claim} <- read_json(claim_key(completion.repo_id, completion.run_id, completion.attempt_id)),
         true <-
           claim["id"] == completion.attempt_id and claim["run_id"] == completion.run_id and
             claim["node"] == completion.node_id,
         true <- claim["claimed_by"] == actor(completion.principal) do
      :ok
    else
      false -> {:error, "attempt belongs to a different executor identity"}
      {:error, :not_found} -> {:error, "attempt #{completion.attempt_id} not found"}
      {:error, reason} -> {:error, "could not read work attempt: #{inspect(reason)}"}
    end
  end

  defp attempt_disposition(node, attempt_id) do
    cond do
      node["result_attempt"] == attempt_id ->
        {:ok, :accepted}

      attempt_id in attempt_ids(node, "rejected_result_attempt_ids") ->
        {:ok, :rejected}

      node["status"] == "running" and node["attempt_id"] == attempt_id ->
        {:ok, :current}

      attempt_id in attempt_ids(node, "expired_attempt_ids") ->
        {:ok, :expired}

      true ->
        {:error, "attempt #{attempt_id} no longer owns node #{node["id"]}"}
    end
  end

  defp finalize_attempt(state, manifest, node, completion, result, disposition) do
    payload = %{
      "node" => completion.node_id,
      "attempt" => completion.attempt_id,
      "artifacts" => completion.artifacts
    }

    case {disposition, state["status"]} do
      {:accepted, _status} ->
        {:already, %{result: result, accepted: true}}

      {:rejected, _status} ->
        {:already, %{result: result, accepted: false}}

      {:current, "active"} ->
        updated_node =
          node
          |> Map.put("status", completion.outcome)
          |> Map.put("result_attempt", completion.attempt_id)
          |> Map.delete("attempt_id")
          |> Map.delete("executor")
          |> Map.delete("claimed_by")

        updated =
          state
          |> put_node(completion.node_id, updated_node)
          |> refresh_ready_nodes(manifest)
          |> finish_if_complete()

        {:ok, updated,
         {"attempt_#{completion.outcome}", actor(completion.principal), payload,
          %{result: result, accepted: true}}}

      {:current, status} ->
        reject_attempt(state, node, completion, payload, result, "work run is #{status}")

      {:expired, _status} ->
        reject_attempt(state, node, completion, payload, result, "attempt lease expired")
    end
  end

  defp reject_attempt(state, node, completion, payload, result, reason) do
    updated =
      state
      |> put_node(
        completion.node_id,
        append_attempt(node, "rejected_result_attempt_ids", completion.attempt_id)
      )

    {:ok, updated,
     {"attempt_rejected", actor(completion.principal), Map.put(payload, "reason", reason),
      %{result: result, accepted: false}}}
  end

  defp node(state, node_id) do
    case get_in(state, ["nodes", node_id]) do
      nil -> {:error, "work node #{node_id} not found"}
      node -> {:ok, node}
    end
  end

  defp put_node(state, node_id, node), do: put_in(state, ["nodes", node_id], node)
  defp attempt_ids(node, key), do: Map.get(node, key, [])

  defp append_attempt(node, key, attempt_id),
    do: Map.update(node, key, [attempt_id], &Enum.uniq(&1 ++ [attempt_id]))

  defp active(%{"status" => "active"}), do: :ok
  defp active(state), do: {:error, "work run is #{state["status"]}"}
  defp running(%{"status" => "running"}), do: :ok
  defp running(_), do: {:error, "work node is not running"}
  defp approval_waiting(%{"kind" => "approval", "status" => "waiting"}), do: :ok
  defp approval_waiting(_), do: {:error, "work node is not awaiting approval"}

  defp artifacts(artifacts) do
    if Enum.all?(artifacts, &valid_artifact?/1),
      do: {:ok, artifacts},
      else: {:error, "artifacts must be objects with a name"}
  end

  defp valid_artifact?(%{"name" => name}) when is_binary(name) and name != "", do: true
  defp valid_artifact?(%{name: name}) when is_binary(name) and name != "", do: true
  defp valid_artifact?(_), do: false

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
      %{operation: operation, outcome: operation_outcome(result)}
    )

    result
  end

  defp operation_outcome({:ok, _}), do: :ok
  defp operation_outcome({:error, _}), do: :error
  defp operation_outcome(_), do: :error

  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: "could not transition work run: #{inspect(reason)}"

  defp expired(lease_expires_at_ms) when is_integer(lease_expires_at_ms) do
    if now() >= lease_expires_at_ms, do: :ok, else: {:error, "work attempt lease has not expired"}
  end

  defp expired(_), do: {:error, "work attempt claim has no lease deadline"}

  defp repository(repo_id) do
    if WAL.valid_id?(repo_id), do: :ok, else: {:error, "repository is invalid"}
  end

  defp run_id(id) do
    if valid_identifier?(id), do: :ok, else: {:error, "work run id is invalid"}
  end

  defp node_id(id) do
    if valid_identifier?(id), do: :ok, else: {:error, "work node id is invalid"}
  end

  defp attempt_id(id) do
    if valid_identifier?(id), do: :ok, else: {:error, "work attempt id is invalid"}
  end

  defp base_commit(commit) when is_binary(commit) do
    if Regex.match?(~r/^[0-9a-f]{40}$/, commit),
      do: {:ok, commit},
      else: {:error, "base_commit must be a 40-character Git object id"}
  end

  defp base_commit(_), do: {:error, "base_commit must be a 40-character Git object id"}

  defp current_public_commit(repo_id, base_commit) do
    with {:ok, index, _etag} <- WAL.fetch(repo_id),
         true <-
           Enum.any?(WAL.Index.refs(index), fn {ref, commit} ->
             commit == base_commit and not Micelio.Git.Ref.internal?(ref)
           end) do
      :ok
    else
      false -> {:error, "base_commit is not the current head of a public reference"}
      {:error, :not_found} -> {:error, "repository #{repo_id} not found"}
      {:error, reason} -> {:error, "could not validate base_commit: #{inspect(reason)}"}
    end
  end

  defp issue(nil), do: {:ok, nil}
  defp issue(number) when is_integer(number) and number > 0, do: {:ok, number}
  defp issue(_), do: {:error, "issue must be a positive integer"}

  defp lease_duration(nil), do: {:ok, @default_lease_duration_ms}
  defp lease_duration(ms) when is_integer(ms) and ms in 1_000..86_400_000, do: {:ok, ms}
  defp lease_duration(_), do: {:error, "lease_duration_ms must be between one second and one day"}

  defp valid_identifier?(value),
    do: is_binary(value) and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/, value)

  defp valid_operation?(value),
    do: is_binary(value) and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/, value)

  defp present(manifest, state) do
    %{
      id: manifest["id"],
      run_id: manifest["id"],
      repository: manifest["repository"],
      issue: manifest["issue"],
      base_commit: manifest["base_commit"],
      graph: manifest["graph"],
      lease_duration_ms: manifest["lease_duration_ms"],
      created_at_ms: manifest["created_at_ms"],
      created_by: manifest["created_by"],
      status: state["status"],
      revision: state["revision"],
      nodes: state["nodes"] |> Map.values() |> Enum.sort_by(& &1["id"])
    }
  end

  defp event(run_id, revision, type, actor, payload, occurred_at_ms) do
    %{
      "version" => 1,
      "id" => identifier(),
      "run_id" => run_id,
      "revision" => revision,
      "type" => type,
      "actor" => actor,
      "payload" => payload,
      "occurred_at_ms" => occurred_at_ms
    }
  end

  defp actor(%Principal{} = principal), do: %{"subject" => principal.subject, "account" => principal.account}
  defp now, do: System.system_time(:millisecond)
  # URL-safe base64 can begin with `-` or `_`, while work ids intentionally
  # begin with an alphanumeric character so they are safe in every path form.
  defp identifier, do: "r" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp put_immutable(key, value),
    do: ObjectStore.put(key, JSON.encode!(value), if_none_match: "*", content_type: @content_type)

  defp put_result(repo_id, run_id, attempt_id, result) do
    case put_immutable(result_key(repo_id, run_id, attempt_id), result) do
      {:ok, _etag} ->
        :ok

      {:error, :precondition_failed} ->
        with {:ok, existing} <- read_json(result_key(repo_id, run_id, attempt_id)),
             true <- same_result?(existing, result) do
          :ok
        else
          false -> {:error, "attempt #{attempt_id} already has a different result"}
          {:error, reason} -> {:error, "could not read prior attempt result: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "could not record attempt result: #{inspect(reason)}"}
    end
  end

  defp same_result?(left, right) do
    Map.take(left, ["attempt", "run_id", "node", "outcome", "artifacts"]) ==
      Map.take(right, ["attempt", "run_id", "node", "outcome", "artifacts"])
  end

  defp graph_node(manifest, node_id) do
    Enum.find(manifest["graph"]["nodes"], &(&1["id"] == node_id))
  end

  defp work(repo_id, manifest, definition) do
    work = %{
      repository: repo_id,
      run_id: manifest["id"],
      issue: manifest["issue"],
      base_commit: manifest["base_commit"],
      node: definition
    }

    case get_in(definition, ["execution", "inference_profile"]) do
      nil ->
        {:ok, work}

      name ->
        version = get_in(definition, ["execution", "inference_profile_version"])

        with {:ok, profile} <- InferenceProfile.get_version(Policy.account_of(repo_id), name, version) do
          {:ok,
           Map.put(
             work,
             :inference_profile,
             # A work claim authorizes execution, not secret delivery. The
             # provisioner reads the pinned profile from account configuration
             # and mounts its non-secret contract into the trusted egress
             # proxy; repository commands never receive secret locators or
             # backend metadata from Micelio.
             Map.take(profile, ["name", "version", "endpoint", "model"])
           )}
        end
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp read_json(key) do
    with {:ok, body, _etag} <- ObjectStore.get(key), do: decode(key, body)
  end

  defp read_json_with_etag(key) do
    with {:ok, body, etag} <- ObjectStore.get(key),
         {:ok, value} <- decode(key, body) do
      {:ok, value, etag}
    end
  end

  defp decode(key, body) do
    case JSON.decode(body) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, "malformed factory object #{key}"}
    end
  end

  defp runs_prefix(repo_id), do: "factory/#{repo_id}/runs/"
  defp run_prefix(repo_id, run_id), do: runs_prefix(repo_id) <> run_id <> "/"
  defp manifest_key(repo_id, run_id), do: run_prefix(repo_id, run_id) <> "specification.json"
  defp state_key(repo_id, run_id), do: run_prefix(repo_id, run_id) <> "state.json"
  defp event_key(repo_id, run_id, event_id), do: run_prefix(repo_id, run_id) <> "events/#{event_id}.json"

  defp claim_key(repo_id, run_id, attempt_id),
    do: run_prefix(repo_id, run_id) <> "attempts/#{attempt_id}/claim.json"

  defp result_key(repo_id, run_id, attempt_id),
    do: run_prefix(repo_id, run_id) <> "attempts/#{attempt_id}/result.json"

  defp run_id_from_state_key(%{key: key}) do
    key
    |> String.replace_suffix("/state.json", "")
    |> Path.basename()
  end
end
