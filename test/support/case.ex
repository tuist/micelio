defmodule Micelio.Case do
  @moduledoc """
  A test case with its own object store, data directory and repository
  namespace.

  Isolation is per-test rather than per-run because most of what is interesting
  here is what happens when two writers race, and a shared store would make
  those tests order-dependent in exactly the way that hides real bugs.

  Everything here runs `async: true`. That is not free — it required the
  configuration a node reads to be overridable per process (see
  `Micelio.Config`) rather than only globally — but a suite that cannot run in
  parallel is a suite that quietly grows shared state, which is precisely the
  class of bug this project cannot afford.

  Three things make it safe:

    * **Configuration is process-local.** Each test points at its own object
      store and data directory through `Micelio.Config.put_overrides/1`, and
      `Micelio.Replica` carries those overrides into the processes it starts.
    * **Repository ids are unique per test.** The replica registry is global,
      so two tests using `acme/app` would share a process. `repo/1` returns an
      id nothing else will use.
    * **Cleanup is scoped.** Only the replicas this test started are stopped,
      never every replica on the node.
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

    Micelio.Config.put_overrides(%{
      object_store: {Micelio.ObjectStore.Filesystem, root: store},
      data_dir: data,
      node_id: "test-#{id}"
    })

    # The application supplies the lock in the test environment; this covers
    # running against a bare VM.
    if is_nil(Process.whereis(Micelio.ObjectStore.Filesystem.Lock)) do
      start_supervised!(Micelio.ObjectStore.Filesystem.Lock)
    end

    namespace = "test#{id}"

    on_exit(fn ->
      stop_replicas(namespace)
      File.rm_rf(root)
    end)

    {:ok, root: root, store: store, data: data, namespace: namespace, repo: "#{namespace}/app"}
  end

  @doc """
  A repository id unique to this test.

  The replica registry is global, so two concurrent tests using the same id
  would share a process and a directory.
  """
  def repo(%{namespace: namespace}, name \\ "app"), do: "#{namespace}/#{name}"

  @doc """
  Ensure the replica runtime is available.

  The application supplies it under `mix test`; this starts the missing pieces
  when running against a bare VM, and is idempotent either way.
  """
  def start_replica_runtime do
    ensure_started({Registry, keys: :unique, name: Micelio.ReplicaRegistry}, Micelio.ReplicaRegistry)

    ensure_started(
      {DynamicSupervisor, strategy: :one_for_one, name: Micelio.ReplicaSupervisor},
      Micelio.ReplicaSupervisor
    )

    ensure_started({Registry, keys: :unique, name: Micelio.WriterRegistry}, Micelio.WriterRegistry)

    ensure_started(
      {DynamicSupervisor, strategy: :one_for_one, name: Micelio.WriterSupervisor},
      Micelio.WriterSupervisor
    )

    ensure_started({Task.Supervisor, name: Micelio.TaskSupervisor}, Micelio.TaskSupervisor)
    :ok
  end

  defp ensure_started(spec, name) do
    if is_nil(Process.whereis(name)), do: ExUnit.Callbacks.start_supervised!(spec)
  end

  @doc """
  Stop the replicas belonging to one namespace.

  Scoped deliberately: terminating every replica on the node would reach into
  whatever else is running concurrently.
  """
  def stop_replicas(namespace) do
    if Process.whereis(Micelio.ReplicaRegistry) do
      for repo_id <- Micelio.Replica.resident(), String.starts_with?(repo_id, namespace <> "/") do
        Micelio.Replica.evict(repo_id)
      end
    end

    :ok
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
