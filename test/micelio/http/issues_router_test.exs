defmodule Micelio.HTTP.IssuesRouterTest do
  use Micelio.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Micelio.Config
  alias Micelio.Control
  alias Micelio.HTTP.Router

  setup %{repo: repo, namespace: namespace} do
    start_replica_runtime()
    {:ok, _} = Control.create_repository(repo)

    Config.put_overrides(
      Map.put(
        Config.overrides(),
        :auth,
        {Micelio.Auth.Static,
         tokens: %{
           "writer" => %{account: namespace, scopes: [:read, :write]},
           "reader" => %{account: namespace, scopes: [:read]}
         }}
      )
    )

    {:ok, writer: "writer", reader: "reader"}
  end

  test "publishes a documented, authorized issue and comment API", %{repo: repo, writer: writer} do
    created =
      request(
        :post,
        "/api/issues?repository=#{repo}",
        %{title: "REST issue", body: "Stored in Git."},
        writer
      )

    assert created.status == 201

    assert %{"issue" => %{"number" => 1, "author" => %{"subject" => subject}}} =
             JSON.decode!(created.resp_body)

    assert subject == repo |> String.split("/") |> hd()

    comment =
      request(
        :post,
        "/api/issues/1/comments?repository=#{repo}",
        %{body: "The first comment."},
        writer
      )

    assert comment.status == 201

    assert %{"issue" => %{"comments" => [%{"id" => comment_id, "body" => "The first comment."}]}} =
             JSON.decode!(comment.resp_body)

    changed =
      request(
        :patch,
        "/api/issues/1/comments/#{comment_id}?repository=#{repo}",
        %{body: "An edited comment."},
        writer
      )

    assert changed.status == 200

    assert %{"issue" => %{"comments" => [%{"body" => "An edited comment."}]}} =
             JSON.decode!(changed.resp_body)

    comments = request(:get, "/api/issues/1/comments?repository=#{repo}", nil, writer)
    assert comments.status == 200
    assert %{"count" => 1, "comments" => [%{"id" => ^comment_id}]} = JSON.decode!(comments.resp_body)

    history = request(:get, "/api/issues/1/history?repository=#{repo}", nil, writer)
    assert history.status == 200
    assert %{"count" => 3, "events" => events} = JSON.decode!(history.resp_body)
    assert Enum.map(events, & &1["type"]) == ["issue_opened", "comment_added", "comment_updated"]

    deleted_comment =
      request(:delete, "/api/issues/1/comments/#{comment_id}?repository=#{repo}", nil, writer)

    assert deleted_comment.status == 200
    assert %{"issue" => %{"comments" => [], "comment_count" => 0}} = JSON.decode!(deleted_comment.resp_body)

    missing_comment = request(:get, "/api/issues/1/comments/#{comment_id}?repository=#{repo}", nil, writer)
    assert missing_comment.status == 404
  end

  test "changes and tombstones an issue", %{repo: repo, writer: writer} do
    assert %Plug.Conn{status: 201} =
             request(:post, "/api/issues?repository=#{repo}", %{title: "Close me"}, writer)

    changed = request(:patch, "/api/issues/1?repository=#{repo}", %{state: "closed"}, writer)
    assert changed.status == 200
    assert %{"issue" => %{"state" => "closed"}} = JSON.decode!(changed.resp_body)

    assert %Plug.Conn{status: 200} = request(:delete, "/api/issues/1?repository=#{repo}", nil, writer)
    assert %Plug.Conn{status: 404} = request(:get, "/api/issues/1?repository=#{repo}", nil, writer)
  end

  test "requires authentication and write permission for issue changes", %{repo: repo, reader: reader} do
    unauthenticated = request(:post, "/api/issues?repository=#{repo}", %{title: "No token"}, nil)
    assert unauthenticated.status == 401
    assert %{"error" => error} = JSON.decode!(unauthenticated.resp_body)
    assert error =~ "authentication required"

    read_only = request(:post, "/api/issues?repository=#{repo}", %{title: "Read only"}, reader)
    assert read_only.status == 403
    assert %{"error" => error} = JSON.decode!(read_only.resp_body)
    assert error =~ "not permitted"
  end

  test "publishes an OpenAPI description", %{repo: repo} do
    conn = request(:get, "/api/openapi.json?repository=#{repo}", nil, nil)

    assert conn.status == 200
    assert %{"openapi" => version, "paths" => paths} = JSON.decode!(conn.resp_body)
    assert version =~ "3."
    assert Map.has_key?(paths, "/api/issues")
    assert Map.has_key?(paths, "/api/issues/{issue}/comments/{comment}")
    assert Map.has_key?(paths, "/api/work-runs")
    assert Map.has_key?(paths, "/api/work-runs/{run}/nodes/{node}/complete")
    assert Map.has_key?(paths, "/api/inference-profiles/{profile}")
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
