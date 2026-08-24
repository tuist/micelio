defmodule Micelio.HTTP.AdminRouter do
  @moduledoc """
  Operations and introspection.

  Every node answers every question, because none of them is answered from
  stored state: placement is computed, log state is read from object storage,
  and replica health is gathered by asking the nodes concerned. There is no
  leader to find and no coordinator to be down.

  Kept on its own listener so it can be bound to an internal address or an
  internal-only Service and never reach the internet.
  """

  use Plug.Router

  alias Micelio.Cluster
  alias Micelio.Control
  alias Micelio.Replica

  plug(:match)
  plug(:authenticate)
  plug(Plug.Parsers, parsers: [:json], json_decoder: JSON, pass: ["application/json"])
  plug(:dispatch)

  # ----------------------------------------------------------------------
  # Health
  # ----------------------------------------------------------------------

  get "/health" do
    send_json(conn, 200, %{status: "ok", node: Micelio.Config.node_id()})
  end

  # Readiness means this node can do its assigned work. Every role needs the
  # object store: serving nodes read the log, and maintenance nodes derive and
  # conditionally publish work from it.
  get "/ready" do
    case Micelio.ObjectStore.list("repos/") do
      {:ok, _} -> send_json(conn, 200, %{status: "ready"})
      {:error, reason} -> send_json(conn, 503, %{status: "not_ready", reason: inspect(reason)})
    end
  end

  get "/metrics" do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, PromEx.get_metrics(Micelio.PromEx))
  end

  get "/status" do
    send_json(conn, 200, Control.cluster_status())
  end

  get "/cluster" do
    send_json(conn, 200, %{
      members: Cluster.members(),
      self: node(),
      resident: Replica.resident()
    })
  end

  # ----------------------------------------------------------------------
  # Repositories
  # ----------------------------------------------------------------------

  get "/repositories" do
    case Control.list_repositories() do
      {:ok, ids} -> send_json(conn, 200, %{repositories: ids, count: length(ids)})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/repositories" do
    params = conn.body_params

    case Control.create_repository(params["repository"] || "", replicas: params["replicas"] || 3) do
      {:ok, summary} -> send_json(conn, 201, summary)
      {:error, :already_exists} -> send_json(conn, 409, %{error: "already exists"})
      {:error, reason} -> send_json(conn, 422, %{error: inspect(reason)})
    end
  end

  get "/repositories/*repo" do
    repo_id = Enum.join(conn.path_params["repo"], "/")

    case Control.describe_repository(repo_id) do
      {:ok, description} -> send_json(conn, 200, description)
      {:error, :not_found} -> send_json(conn, 404, %{error: "not found"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  delete "/repositories/*repo" do
    repo_id = Enum.join(conn.path_params["repo"], "/")

    case Control.delete_repository(repo_id) do
      :ok -> send_json(conn, 204, nil)
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  # ----------------------------------------------------------------------
  # Maintenance
  #
  # Repository ids are arbitrary paths, so the id has to be the final segment
  # of a route. That puts the verb first, which reads oddly for REST but is the
  # only unambiguous option when `acme/ios-app` and `acme/ios/app` are both
  # legal names.
  # ----------------------------------------------------------------------

  post "/compact/*repo" do
    repo_id = Enum.join(conn.path_params["repo"], "/")

    # The maintenance capability, rather than a serving replica, owns
    # compaction. That lets operators move expensive repacks to dedicated
    # nodes without giving up the ability to ask any admin endpoint.
    case Micelio.Maintenance.run(repo_id, :compact) do
      {:ok, summary} -> send_json(conn, 200, summary)
      :not_due -> send_json(conn, 200, %{repository: repo_id, compacted: false})
      {:error, reason} -> send_json(conn, 409, %{error: inspect(reason)})
    end
  end

  post "/lookup/*repo" do
    repo_id = Enum.join(conn.path_params["repo"], "/")

    case Micelio.Maintenance.run(repo_id, :lookup) do
      {:ok, summary} -> send_json(conn, 200, summary)
      :not_due -> send_json(conn, 200, %{repository: repo_id, rebuilt: false})
      {:error, reason} -> send_json(conn, 503, %{error: inspect(reason)})
    end
  end

  post "/evict/*repo" do
    repo_id = Enum.join(conn.path_params["repo"], "/")
    Replica.evict(repo_id)
    send_json(conn, 200, %{evicted: repo_id, node: node()})
  end

  get "/placement/*repo" do
    repo_id = Enum.join(conn.path_params["repo"], "/")
    send_json(conn, 200, Control.placement(repo_id))
  end

  put "/default-branch/*repo" do
    repo_id = Enum.join(conn.path_params["repo"], "/")

    case Control.set_default_branch(repo_id, conn.body_params["branch"] || "main") do
      {:ok, result} -> send_json(conn, 200, %{seq: result.seq, epoch: result.epoch})
      {:error, reason} -> send_json(conn, 422, %{error: inspect(reason)})
    end
  end

  put "/replicas/*repo" do
    repo_id = Enum.join(conn.path_params["repo"], "/")

    case Control.set_replica_count(repo_id, conn.body_params["replicas"] || 3) do
      {:ok, result} -> send_json(conn, 200, result)
      {:error, reason} -> send_json(conn, 422, %{error: inspect(reason)})
    end
  end

  # ----------------------------------------------------------------------
  # Authorization policy
  #
  # Policy is an object in the store, like everything else, so any node can
  # read or change it and there is no service to be down.
  # ----------------------------------------------------------------------

  get "/policy/*account" do
    account = Enum.join(conn.path_params["account"], "/")

    case Micelio.Policy.get(account) do
      {:ok, policy} -> send_json(conn, 200, Micelio.Policy.describe(policy))
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  put "/policy/*account" do
    account = Enum.join(conn.path_params["account"], "/")
    params = conn.body_params

    with subject when is_binary(subject) <- params["subject"],
         repositories when is_list(repositories) <- params["repositories"],
         permissions when is_list(permissions) <- params["permissions"] do
      opts =
        [note: params["note"] || ""]
        |> then(fn opts ->
          case params["expires_at_ms"] do
            nil -> opts
            at -> Keyword.put(opts, :expires_at_ms, at)
          end
        end)

      case Micelio.Policy.bind(account, subject, repositories, permissions, opts) do
        {:ok, policy} -> send_json(conn, 200, Micelio.Policy.describe(policy))
        {:error, reason} -> send_json(conn, 422, %{error: inspect(reason)})
      end
    else
      _ -> send_json(conn, 422, %{error: "subject, repositories and permissions are required"})
    end
  end

  delete "/policy/*account" do
    account = Enum.join(conn.path_params["account"], "/")

    case conn.query_params["subject"] || conn.body_params["subject"] do
      nil ->
        send_json(conn, 422, %{error: "subject is required"})

      subject ->
        case Micelio.Policy.unbind(account, subject) do
          {:ok, policy} -> send_json(conn, 200, Micelio.Policy.describe(policy))
          {:error, reason} -> send_json(conn, 422, %{error: inspect(reason)})
        end
    end
  end

  post "/reap" do
    send_json(conn, 200, %{evicted: Micelio.Replica.Reaper.sweep()})
  end

  match _ do
    send_json(conn, 404, %{error: "not found"})
  end

  # ----------------------------------------------------------------------

  # Health and readiness stay unauthenticated: a probe that needs a credential
  # is a probe that fails for the wrong reasons, and neither reveals anything.
  defp authenticate(%{path_info: path} = conn, _opts) when path in [["health"], ["ready"], ["metrics"]],
    do: conn

  defp authenticate(conn, _opts) do
    expected = Micelio.Config.admin_token()

    cond do
      is_nil(expected) ->
        conn

      valid_admin_token?(conn, expected) ->
        conn

      true ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, JSON.encode!(%{error: "admin token required"}))
        |> halt()
    end
  end

  defp valid_admin_token?(conn, expected) do
    case Micelio.Auth.credential_from_header(List.first(get_req_header(conn, "authorization"))) do
      {:bearer, token} when byte_size(token) == byte_size(expected) -> :crypto.hash_equals(token, expected)
      _ -> false
    end
  end

  defp send_json(conn, 204, _payload), do: send_resp(conn, 204, "")

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(payload))
  end
end
