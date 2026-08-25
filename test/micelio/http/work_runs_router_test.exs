defmodule Micelio.HTTP.WorkRunsRouterTest do
  use Micelio.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Micelio.Config
  alias Micelio.Control
  alias Micelio.HTTP.Router
  alias Micelio.WAL
  alias Micelio.WAL.Entry

  setup %{repo: repo, namespace: namespace} do
    start_replica_runtime()
    {:ok, _} = Control.create_repository(repo)
    base_commit = String.duplicate("a", 40)

    assert {:ok, _} =
             WAL.append(repo, fn _ ->
               {:ok,
                Entry.new(
                  type: :ENTRY_TYPE_PUSH,
                  commands: [Entry.command("refs/heads/main", Entry.zero_oid(), base_commit)]
                )}
             end)

    Config.put_overrides(
      Map.put(
        Config.overrides(),
        :auth,
        {Micelio.Auth.Static,
         tokens: %{
           "writer" => %{account: namespace, scopes: [:read, :write]},
           "reader" => %{account: namespace, scopes: [:read]},
           "executor" => %{account: namespace, scopes: [:read, :execute]},
           "admin" => %{account: namespace, scopes: [:admin]}
         }}
      )
    )

    {:ok, writer: "writer", reader: "reader", executor: "executor", admin: "admin", base_commit: base_commit}
  end

  test "lets a mocked Condukt worker claim, complete, and observe a work run", %{
    repo: repo,
    writer: writer,
    executor: executor,
    base_commit: base_commit
  } do
    graph = %{
      "nodes" => [
        %{
          "id" => "implement",
          "kind" => "agent",
          "title" => "Implement issue",
          "execution" => %{
            "type" => "condukt_operation",
            "operation" => "implement_issue",
            "input" => %{"issue" => 42},
            "output_schema" => %{"type" => "object"}
          }
        }
      ]
    }

    created =
      request(:post, "/api/work-runs?repository=#{repo}", %{graph: graph, base_commit: base_commit}, writer)

    assert created.status == 201
    assert %{"id" => run_id, "status" => "active"} = JSON.decode!(created.resp_body)

    claimed =
      request(:post, "/api/work-runs/#{run_id}/claim?repository=#{repo}", %{executor: "mock-pod"}, executor)

    assert claimed.status == 200

    assert %{
             "attempt" => %{"id" => attempt_id, "executor" => "mock-pod"},
             "work" => %{
               "base_commit" => ^base_commit,
               "node" => %{
                 "execution" => %{"type" => "condukt_operation", "operation" => "implement_issue"}
               }
             }
           } = JSON.decode!(claimed.resp_body)

    completed =
      request(
        :post,
        "/api/work-runs/#{run_id}/nodes/implement/complete?repository=#{repo}",
        %{
          attempt: attempt_id,
          outcome: "succeeded",
          artifacts: [%{name: "mock-log", uri: "s3://evidence/log"}]
        },
        executor
      )

    assert completed.status == 200
    assert %{"status" => "succeeded"} = JSON.decode!(completed.resp_body)

    attempt = request(:get, "/api/work-runs/#{run_id}/attempts/#{attempt_id}?repository=#{repo}", nil, writer)
    assert attempt.status == 200
    assert %{"result" => %{"outcome" => "succeeded"}} = JSON.decode!(attempt.resp_body)

    history = request(:get, "/api/work-runs/#{run_id}/events?repository=#{repo}", nil, writer)
    assert history.status == 200
    assert %{"next_cursor" => 3, "events" => events} = JSON.decode!(history.resp_body)
    assert Enum.map(events, & &1["type"]) == ["work_run_created", "node_claimed", "attempt_succeeded"]
  end

  test "requires write permission to create work", %{
    repo: repo,
    reader: reader,
    base_commit: base_commit
  } do
    response =
      request(
        :post,
        "/api/work-runs?repository=#{repo}",
        %{graph: %{"nodes" => [%{"id" => "work", "title" => "Work"}]}, base_commit: base_commit},
        reader
      )

    assert response.status == 403
    assert %{"error" => error} = JSON.decode!(response.resp_body)
    assert error =~ "not permitted"
  end

  test "delivers a configured profile only to an execution-scoped worker", %{
    repo: repo,
    writer: writer,
    executor: executor,
    admin: admin,
    base_commit: base_commit
  } do
    configured =
      request(
        :put,
        "/api/inference-profiles/coding?repository=#{repo}",
        %{
          endpoint: "https://inference.example.com/v1",
          model: "coding-model",
          credential_source: %{
            type: "injected_secret",
            reference: "account-coding-api-key"
          }
        },
        admin
      )

    assert configured.status == 200
    profile = JSON.decode!(configured.resp_body)
    version = profile["version"]
    refute Map.has_key?(profile, "token")

    created =
      request(
        :post,
        "/api/work-runs?repository=#{repo}",
        %{
          graph: %{
            nodes: [
              %{
                id: "implement",
                title: "Implement issue",
                execution: %{
                  type: "condukt_operation",
                  operation: "implement_issue",
                  inference_profile: "coding"
                }
              }
            ]
          },
          base_commit: base_commit
        },
        writer
      )

    assert %{"id" => run_id} = JSON.decode!(created.resp_body)

    assert request(:post, "/api/work-runs/#{run_id}/claim?repository=#{repo}", %{executor: "writer"}, writer).status ==
             403

    claimed =
      request(:post, "/api/work-runs/#{run_id}/claim?repository=#{repo}", %{executor: "worker"}, executor)

    assert claimed.status == 200

    assert %{
             "work" => %{
               "inference_profile" => %{
                 "name" => "coding",
                 "version" => ^version,
                 "credential_source" => %{
                   "type" => "injected_secret",
                   "reference" => "account-coding-api-key"
                 }
               }
             }
           } = JSON.decode!(claimed.resp_body)
  end

  test "rejects an invalid event cursor", %{repo: repo, writer: writer} do
    response =
      request(:get, "/api/work-runs/unknown/events?repository=#{repo}&after=not-a-number", nil, writer)

    assert response.status == 422
    assert %{"error" => "micelio: after must be a non-negative integer"} = JSON.decode!(response.resp_body)
  end

  test "reserves approval, cancellation, and lease expiry for repository administrators", %{
    repo: repo,
    writer: writer,
    admin: admin,
    base_commit: base_commit
  } do
    created =
      request(
        :post,
        "/api/work-runs?repository=#{repo}",
        %{
          graph: %{"nodes" => [%{"id" => "review", "kind" => "approval", "title" => "Review"}]},
          base_commit: base_commit
        },
        writer
      )

    assert created.status == 201
    assert %{"id" => run_id} = JSON.decode!(created.resp_body)

    assert request(:post, "/api/work-runs/#{run_id}/nodes/review/approve?repository=#{repo}", %{}, writer).status ==
             403

    assert request(:post, "/api/work-runs/#{run_id}/cancel?repository=#{repo}", %{}, writer).status == 403

    approved = request(:post, "/api/work-runs/#{run_id}/nodes/review/approve?repository=#{repo}", %{}, admin)
    assert approved.status == 200
    assert %{"status" => "succeeded"} = JSON.decode!(approved.resp_body)
  end

  defp request(method, path, payload, token) do
    conn = conn(method, path, if(payload, do: JSON.encode!(payload), else: ""))

    conn =
      if payload do
        put_req_header(conn, "content-type", "application/json")
      else
        conn
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, Router.init([]))
  end
end
