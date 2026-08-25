defmodule Micelio.FactoryTest do
  use Micelio.Case, async: true

  alias Micelio.Auth.Principal
  alias Micelio.Factory
  alias Micelio.WAL
  alias Micelio.WAL.Entry

  setup %{namespace: namespace, repo: repo} do
    principal = %Principal{
      subject: "factory-author",
      account: namespace,
      grants: [Principal.grant("#{namespace}/**", [:read, :write])],
      source: :test
    }

    base_commit = base_commit()
    assert {:ok, _} = WAL.create(repo)

    assert {:ok, _} =
             WAL.append(repo, fn _ ->
               {:ok,
                Entry.new(
                  type: :ENTRY_TYPE_PUSH,
                  commands: [Entry.command("refs/heads/main", Entry.zero_oid(), base_commit)]
                )}
             end)

    {:ok, principal: principal}
  end

  test "advances a dependency graph through a durable attempt and approval", %{
    repo: repo,
    principal: principal
  } do
    assert {:ok, created} = Factory.create(repo, graph(), %{base_commit: base_commit()}, principal)
    assert created.status == "active"

    assert Enum.map(created.nodes, &{&1["id"], &1["status"]}) == [
             {"implement", "ready"},
             {"release", "pending"},
             {"review", "pending"}
           ]

    assert {:ok, %{events: [created_event], next_cursor: 1}} = Factory.events(repo, created.id)
    assert created_event["type"] == "work_run_created"

    assert {:ok, %{runs: [listed]}} = Factory.list(repo)
    assert listed.id == created.id

    assert {:ok, claimed} = Factory.claim(repo, created.id, "pod-a", principal)
    assert claimed.attempt["node"] == "implement"
    assert claimed.nodes |> Enum.find(&(&1["id"] == "implement")) |> Map.fetch!("status") == "running"

    assert {:ok, completed} =
             Factory.complete(
               repo,
               created.id,
               "implement",
               claimed.attempt["id"],
               "succeeded",
               [%{"name" => "patch", "uri" => "s3://evidence/patch"}],
               principal
             )

    assert completed.status == "active"
    assert completed.nodes |> Enum.find(&(&1["id"] == "review")) |> Map.fetch!("status") == "waiting"

    assert {:ok, approved} = Factory.approve(repo, created.id, "review", principal)
    assert approved.nodes |> Enum.find(&(&1["id"] == "release")) |> Map.fetch!("status") == "ready"

    assert {:ok, release} = Factory.claim(repo, created.id, "pod-b", principal)

    assert {:ok, finished} =
             Factory.complete(repo, created.id, "release", release.attempt["id"], "succeeded", [], principal)

    assert finished.status == "succeeded"

    assert {:ok, %{attempt: attempt, result: result}} =
             Factory.attempt(repo, created.id, claimed.attempt["id"])

    assert attempt["executor"] == "pod-a"
    assert result["outcome"] == "succeeded"

    assert {:ok, %{events: events, next_cursor: 6}} = Factory.events(repo, created.id)

    assert Enum.map(events, & &1["type"]) == [
             "work_run_created",
             "node_claimed",
             "attempt_succeeded",
             "approval_granted",
             "node_claimed",
             "attempt_succeeded"
           ]

    assert {:ok, %{events: [], next_cursor: 6}} = Factory.events(repo, created.id, 6)
  end

  test "emits bounded telemetry for durable graph operations", %{repo: repo, principal: principal} do
    handler = {__MODULE__, :factory_operation, self()}

    :ok =
      :telemetry.attach(
        handler,
        [:micelio, :factory, :operation],
        fn _event, measurements, meta, pid ->
          if self() == pid, do: send(pid, {:factory_operation, measurements, meta})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, _run} = Factory.create(repo, one_node_graph(), %{base_commit: base_commit()}, principal)
    assert_receive {:factory_operation, %{duration_us: duration_us}, %{operation: :create, outcome: :ok}}
    assert duration_us >= 0
  end

  test "accepts exactly one concurrent claim for a ready node", %{repo: repo, principal: principal} do
    assert {:ok, run} = Factory.create(repo, one_node_graph(), %{base_commit: base_commit()}, principal)

    results =
      1..20
      |> Task.async_stream(
        fn number -> Factory.claim(repo, run.id, "pod-#{number}", principal) end,
        max_concurrency: 20,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1, inspect(results)

    assert {:ok, current} = Factory.get(repo, run.id)
    [node] = current.nodes
    assert node["status"] == "running"
    assert node["attempts"] == 1

    assert {:ok, %{events: events}} = Factory.events(repo, run.id)
    assert Enum.count(events, &(&1["type"] == "node_claimed")) == 1
  end

  test "does not lose either result when independent attempts complete together", %{
    repo: repo,
    principal: principal
  } do
    graph = %{
      "nodes" => [
        %{"id" => "first", "title" => "First"},
        %{"id" => "second", "title" => "Second"}
      ]
    }

    assert {:ok, run} = Factory.create(repo, graph, %{base_commit: base_commit()}, principal)
    assert {:ok, first} = Factory.claim(repo, run.id, "pod-a", principal)
    assert {:ok, second} = Factory.claim(repo, run.id, "pod-b", principal)

    results =
      [first.attempt, second.attempt]
      |> Task.async_stream(
        fn attempt ->
          Factory.complete(repo, run.id, attempt["node"], attempt["id"], "succeeded", [], principal)
        end,
        max_concurrency: 2,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _}, &1)), inspect(results)

    assert {:ok, finished} = Factory.get(repo, run.id)
    assert finished.status == "succeeded"
    assert Enum.all?(finished.nodes, &(&1["status"] == "succeeded"))
  end

  test "accepts evidence only from the claiming identity", %{repo: repo, principal: principal} do
    assert {:ok, run} = Factory.create(repo, one_node_graph(), %{base_commit: base_commit()}, principal)
    assert {:ok, claimed} = Factory.claim(repo, run.id, "pod-a", principal)

    other = %{principal | subject: "another-worker"}

    assert {:error, "attempt belongs to a different executor identity"} =
             Factory.complete(repo, run.id, "work", claimed.attempt["id"], "succeeded", [], other)

    assert {:ok, current} = Factory.get(repo, run.id)
    assert [%{"status" => "running", "attempt_id" => attempt_id}] = current.nodes
    assert attempt_id == claimed.attempt["id"]
  end

  test "preserves evidence reported after cancellation without accepting it", %{
    repo: repo,
    principal: principal
  } do
    assert {:ok, run} = Factory.create(repo, one_node_graph(), %{base_commit: base_commit()}, principal)
    assert {:ok, claimed} = Factory.claim(repo, run.id, "pod-a", principal)
    assert {:ok, %{status: "cancelled"}} = Factory.cancel(repo, run.id, principal)

    assert {:ok, rejected} =
             Factory.complete(
               repo,
               run.id,
               "work",
               claimed.attempt["id"],
               "succeeded",
               [%{"name" => "late-log"}],
               principal
             )

    assert rejected.status == "cancelled"
    refute rejected.accepted

    assert {:ok, replay} =
             Factory.complete(
               repo,
               run.id,
               "work",
               claimed.attempt["id"],
               "succeeded",
               [%{"name" => "late-log"}],
               principal
             )

    refute replay.accepted

    assert {:ok, %{result: result}} = Factory.attempt(repo, run.id, claimed.attempt["id"])
    assert result["outcome"] == "succeeded"

    assert {:ok, %{events: events}} = Factory.events(repo, run.id)

    assert Enum.map(events, & &1["type"]) == [
             "work_run_created",
             "node_claimed",
             "work_run_cancelled",
             "attempt_rejected"
           ]
  end

  test "retains evidence after a lease requeue and makes result delivery replay-safe", %{
    repo: repo,
    principal: principal
  } do
    assert {:ok, run} =
             Factory.create(
               repo,
               one_node_graph(),
               %{base_commit: base_commit(), lease_duration_ms: 1_000},
               principal
             )

    assert {:ok, claimed} = Factory.claim(repo, run.id, "pod-a", principal)
    Process.sleep(1_050)
    assert {:ok, %{status: "active"}} = Factory.expire(repo, run.id, "work")

    assert {:ok, late} =
             Factory.complete(repo, run.id, "work", claimed.attempt["id"], "succeeded", [], principal)

    refute late.accepted

    assert {:ok, replay} =
             Factory.complete(repo, run.id, "work", claimed.attempt["id"], "succeeded", [], principal)

    refute replay.accepted

    assert {:ok, %{events: events}} = Factory.events(repo, run.id)

    assert Enum.map(events, & &1["type"]) == [
             "work_run_created",
             "node_claimed",
             "attempt_expired",
             "attempt_rejected"
           ]

    assert {:ok, %{result: %{"outcome" => "succeeded"}}} =
             Factory.attempt(repo, run.id, claimed.attempt["id"])
  end

  test "marks unstarted sibling nodes skipped after a failure", %{repo: repo, principal: principal} do
    graph = %{
      "nodes" => [
        %{"id" => "first", "title" => "First"},
        %{"id" => "second", "title" => "Second"}
      ]
    }

    assert {:ok, run} = Factory.create(repo, graph, %{base_commit: base_commit()}, principal)
    assert {:ok, claimed} = Factory.claim(repo, run.id, "pod-a", principal)

    assert {:ok, failed} =
             Factory.complete(repo, run.id, "first", claimed.attempt["id"], "failed", [], principal)

    assert failed.status == "failed"
    assert failed.nodes |> Enum.find(&(&1["id"] == "second")) |> Map.fetch!("status") == "skipped"
  end

  test "replays an accepted result without appending a second event", %{repo: repo, principal: principal} do
    assert {:ok, run} = Factory.create(repo, one_node_graph(), %{base_commit: base_commit()}, principal)
    assert {:ok, claimed} = Factory.claim(repo, run.id, "pod-a", principal)

    assert {:ok, accepted} =
             Factory.complete(repo, run.id, "work", claimed.attempt["id"], "succeeded", [], principal)

    assert accepted.accepted

    assert {:ok, replay} =
             Factory.complete(repo, run.id, "work", claimed.attempt["id"], "succeeded", [], principal)

    assert replay.accepted
    assert {:ok, %{events: events}} = Factory.events(repo, run.id)
    assert Enum.map(events, & &1["type"]) == ["work_run_created", "node_claimed", "attempt_succeeded"]
  end

  test "rejects invalid graph dependencies and storage-path identifiers", %{repo: repo, principal: principal} do
    cycle = %{
      "nodes" => [
        %{"id" => "one", "depends_on" => ["two"]},
        %{"id" => "two", "depends_on" => ["one"]}
      ]
    }

    assert {:error, "work graph must not contain a cycle"} =
             Factory.create(repo, cycle, %{base_commit: base_commit()}, principal)

    assert {:ok, run} = Factory.create(repo, one_node_graph(), %{base_commit: base_commit()}, principal)
    assert {:error, "work attempt id is invalid"} = Factory.attempt(repo, run.id, "../../state")
    assert {:error, "after must be a non-negative integer"} = Factory.events(repo, run.id, "not-a-cursor")

    assert {:error, "issue must be a positive integer"} =
             Factory.create(repo, one_node_graph(), %{base_commit: base_commit(), issue: 0}, principal)

    assert {:error, "base_commit is not the current head of a public reference"} =
             Factory.create(repo, one_node_graph(), %{base_commit: String.duplicate("b", 40)}, principal)
  end

  defp graph do
    %{
      "nodes" => [
        %{"id" => "implement", "kind" => "agent", "title" => "Implement issue"},
        %{"id" => "review", "kind" => "approval", "title" => "Review", "depends_on" => ["implement"]},
        %{"id" => "release", "kind" => "command", "title" => "Release", "depends_on" => ["review"]}
      ]
    }
  end

  defp one_node_graph, do: %{"nodes" => [%{"id" => "work", "title" => "Work"}]}
  defp base_commit, do: String.duplicate("a", 40)
end
