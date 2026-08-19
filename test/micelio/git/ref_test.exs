defmodule Micelio.Git.RefTest do
  @moduledoc """
  A reference name Git cannot represent must never reach the log. Once it is
  recorded, no replica can apply it, and the repository becomes unservable the
  moment the last cache holding it is evicted.
  """

  use ExUnit.Case, async: true

  alias Micelio.Git.Ref

  test "ordinary names are accepted" do
    for name <- [
          "refs/heads/main",
          "refs/heads/feature/some-thing",
          "refs/tags/v1.2.3",
          "refs/heads/user@example.com",
          "refs/heads/UPPER_and-lower.1"
        ] do
      assert Ref.valid?(name), "expected #{name} to be valid"
    end
  end

  test "names git refuses are rejected" do
    for name <- [
          "refs/heads/bad..name",
          "refs/heads/trailing.",
          "refs/heads/.hidden",
          "refs/heads/name.lock",
          "refs/heads/with space",
          "refs/heads/tilde~1",
          "refs/heads/caret^1",
          "refs/heads/colon:name",
          "refs/heads/question?",
          "refs/heads/star*",
          "refs/heads/bracket[",
          "refs/heads/back\\slash",
          "refs/heads/at@{1}",
          "refs/heads//double",
          "/refs/heads/leading",
          "refs/heads/trailing/",
          "@",
          "no-slash",
          "",
          "refs/heads/tab\there",
          "refs/heads/del\x7F"
        ] do
      refute Ref.valid?(name), "expected #{inspect(name)} to be rejected"
    end
  end

  test "anything that is not a string is rejected" do
    for value <- [nil, 42, :atom, ["refs/heads/main"]] do
      refute Ref.valid?(value)
    end
  end

  test "the rules agree with git itself" do
    # The implementation re-states git check-ref-format rather than shelling
    # out to it, so it is worth confirming git agrees on the cases that matter.
    dir = Path.join(System.tmp_dir!(), "micelio-ref-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    for name <- ["refs/heads/main", "refs/heads/bad..name", "refs/heads/name.lock", "refs/tags/v1"] do
      {_out, status} = System.cmd("git", ["check-ref-format", name], stderr_to_stdout: true, cd: dir)
      assert Ref.valid?(name) == (status == 0), "disagreed with git about #{inspect(name)}"
    end
  end

  test "validate/1 names the first unusable reference" do
    assert :ok = Ref.validate(["refs/heads/main", "refs/tags/v1"])
    assert {:error, {:invalid_ref, "refs/heads/a..b"}} = Ref.validate(["refs/heads/main", "refs/heads/a..b"])
  end
end
