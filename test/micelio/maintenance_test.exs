defmodule Micelio.MaintenanceTest do
  use Micelio.Case, async: true

  alias Micelio.Config
  alias Micelio.Maintenance
  alias Micelio.MCP.Tools

  test "normalizes node capability roles" do
    Config.put_overrides(Map.put(Config.overrides(), :roles, "serve, events,serve"))

    assert Config.roles() == [:serve, :events]
    assert Config.serve?()
    refute Config.maintain?()
    assert Config.events?()
  end

  test "rejects unknown maintenance job kinds" do
    assert {:error, {:unknown_maintenance_kind, :unknown}} = Maintenance.run("acme/app", :unknown)
  end

  test "scheduler runs an eligible cache-only job locally when membership is unavailable", %{repo: repo} do
    start_replica_runtime()
    assert {:ok, _} = Micelio.Control.create_repository(repo)
    scheduler = start_maintenance_scheduler()

    assert :not_due = Maintenance.run(repo, :lookup, mode: :if_due, scheduler: scheduler)
  end

  test "a forced lookup rebuild bypasses the pack-count threshold", %{repo: repo} do
    start_replica_runtime()
    assert {:ok, _} = Micelio.Control.create_repository(repo)

    principal = %Micelio.Auth.Principal{
      subject: "test",
      grants: [Micelio.Auth.Principal.grant("**", [:admin])]
    }

    assert {:ok, _} =
             Tools.call(
               "commit",
               %{
                 "repository" => repo,
                 "branch" => "main",
                 "message" => "lookup fixture",
                 "changes" => [%{"path" => "README.md", "content" => "lookup\n"}]
               },
               principal
             )

    scheduler = start_maintenance_scheduler()

    assert {:ok, %{packs: packs}} = Maintenance.run(repo, :lookup, scheduler: scheduler)
    assert packs >= 1
  end

  test "scheduler compacts from an exact write-ahead-log snapshot", %{repo: repo} do
    start_replica_runtime()
    assert {:ok, _} = Micelio.Control.create_repository(repo)

    principal = %Micelio.Auth.Principal{
      subject: "test",
      grants: [Micelio.Auth.Principal.grant("**", [:admin])]
    }

    assert {:ok, _} =
             Tools.call(
               "commit",
               %{
                 "repository" => repo,
                 "branch" => "main",
                 "message" => "maintenance fixture",
                 "changes" => [%{"path" => "README.md", "content" => "maintenance\n"}]
               },
               principal
             )

    scheduler = start_maintenance_scheduler()

    assert {:ok, %{epoch: 2, seq: 1}} = Maintenance.run(repo, :compact, scheduler: scheduler)
  end

  defp start_maintenance_scheduler do
    overrides = Map.put(Config.overrides(), :roles, [:maintain])
    Config.put_overrides(overrides)

    name =
      {:via, Registry, {Maintenance.registry(), {:maintenance_test, :erlang.unique_integer([:positive])}}}

    start_supervised!({Maintenance, name: name, interval: :timer.hours(1), overrides: overrides})
    name
  end
end
