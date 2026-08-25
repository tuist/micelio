defmodule Micelio.HTTP.GitRouterTest do
  use Micelio.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Micelio.Config
  alias Micelio.Control
  alias Micelio.HTTP.Router

  setup %{repo: repo, namespace: namespace} do
    start_replica_runtime()
    assert {:ok, _} = Control.create_repository(repo)

    Config.put_overrides(
      Map.put(
        Config.overrides(),
        :auth,
        {Micelio.Auth.Static,
         tokens: %{
           "writer" => %{account: namespace, scopes: [:read, :write]}
         }}
      )
    )

    {:ok, token: "writer"}
  end

  test "rejects a Git service request with the wrong content type", %{repo: repo, token: token} do
    conn =
      conn(:post, "/#{repo}.git/git-receive-pack", "")
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "text/plain")
      |> Router.call(Router.init([]))

    assert conn.status == 415

    assert conn.resp_body ==
             "micelio: expected application/x-git-receive-pack-request, got text/plain\n"
  end
end
