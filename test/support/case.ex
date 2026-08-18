defmodule Micelio.Case do
  @moduledoc """
  Test case that gives each test its own object store and data directory.

  Isolation is per-test rather than per-run because almost everything here is
  about what happens when two writers race, and a shared store would make those
  tests order-dependent in exactly the way that hides real bugs.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Micelio.Case
      alias Micelio.Wal.V1
    end
  end

  setup do
    id = :erlang.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "micelio-test-#{id}")
    store = Path.join(root, "store")
    data = Path.join(root, "repositories")
    File.mkdir_p!(store)
    File.mkdir_p!(data)

    previous = %{
      object_store: Application.get_env(:micelio, :object_store),
      data_dir: Application.get_env(:micelio, :data_dir),
      node_id: Application.get_env(:micelio, :node_id)
    }

    Application.put_env(:micelio, :object_store, {Micelio.ObjectStore.Filesystem, root: store})
    Application.put_env(:micelio, :data_dir, data)
    Application.put_env(:micelio, :node_id, "test-#{id}")

    # The application already runs the lock in the test environment; only start
    # one when running against a bare VM.
    if is_nil(Process.whereis(Micelio.ObjectStore.Filesystem.Lock)) do
      start_supervised!(Micelio.ObjectStore.Filesystem.Lock)
    end

    # Replica processes cache the path they were started with, and the registry
    # is application-wide, so a survivor from a previous test would serve the
    # wrong directory. Clear them before and after each test.
    stop_replicas()

    on_exit(fn ->
      stop_replicas()

      Enum.each(previous, fn {key, value} ->
        if value, do: Application.put_env(:micelio, key, value), else: Application.delete_env(:micelio, key)
      end)

      File.rm_rf(root)
    end)

    {:ok, root: root, store: store, data: data}
  end

  @doc """
  Ensure the replica runtime is available.

  The application supplies it when the suite runs under `mix test`; this starts
  the missing pieces when running against a bare VM, and is idempotent either
  way.
  """
  def start_replica_runtime do
    ensure_started({Registry, keys: :unique, name: Micelio.ReplicaRegistry}, Micelio.ReplicaRegistry)

    ensure_started(
      {DynamicSupervisor, strategy: :one_for_one, name: Micelio.ReplicaSupervisor},
      Micelio.ReplicaSupervisor
    )

    ensure_started({Task.Supervisor, name: Micelio.TaskSupervisor}, Micelio.TaskSupervisor)
    :ok
  end

  defp ensure_started(spec, name) do
    if is_nil(Process.whereis(name)), do: ExUnit.Callbacks.start_supervised!(spec)
  end

  @doc "Terminate every resident replica process."
  def stop_replicas do
    case Process.whereis(Micelio.ReplicaSupervisor) do
      nil ->
        :ok

      supervisor ->
        for {_, pid, _, _} <- DynamicSupervisor.which_children(supervisor) do
          DynamicSupervisor.terminate_child(supervisor, pid)
        end

        :ok
    end
  end

  @doc "Build a scratch git repository with one commit and return its path."
  def fixture_repository(name \\ "source") do
    path = Path.join(System.tmp_dir!(), "micelio-fixture-#{:erlang.unique_integer([:positive])}-#{name}")
    File.mkdir_p!(path)

    git(["init", "-q", "-b", "main"], path)
    File.write!(Path.join(path, "README.md"), "# fixture\n")
    git(["add", "."], path)
    git(["commit", "-qm", "initial"], path)

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(path) end)
    path
  end

  @doc "Run git in `cd` with a hermetic environment."
  def git(args, cd) do
    env = [
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"HOME", cd},
      {"GIT_AUTHOR_NAME", "Test"},
      {"GIT_AUTHOR_EMAIL", "test@example.com"},
      {"GIT_COMMITTER_NAME", "Test"},
      {"GIT_COMMITTER_EMAIL", "test@example.com"}
    ]

    System.cmd("git", args, cd: cd, env: env, stderr_to_stdout: true)
  end

  @doc "Resolve a revision in a repository to its object id."
  def oid(path, rev \\ "HEAD") do
    {out, 0} = git(["rev-parse", rev], path)
    String.trim(out)
  end
end
