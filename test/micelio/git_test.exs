defmodule Micelio.GitTest do
  use Micelio.Case, async: true

  alias Micelio.Git

  test "records the Git subcommand rather than the repository path", %{root: root} do
    repository = Path.join(root, "observed.git")
    assert :ok = Git.init_bare(repository)

    handler = {__MODULE__, :git_command, self()}

    :ok =
      :telemetry.attach(
        handler,
        [:micelio, :git, :command],
        fn _event, _measurements, metadata, pid ->
          if self() == pid, do: send(pid, {:git_command, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, _} = Git.run(repository, ["rev-parse", "--git-dir"])
    assert_receive {:git_command, %{subcommand: "rev-parse", status: 0}}
  end
end
