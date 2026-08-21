defmodule Micelio.Git.PrivacyTest do
  use Micelio.Case, async: true

  alias Micelio.Git

  test "does not advertise or accept updates to Micelio's private references", %{root: root} do
    source = fixture_repository("private-reference-source")
    target = Path.join(root, "private-reference-target.git")
    assert :ok = Git.init_bare(target)

    assert {_output, 0} = git(["push", target, "HEAD:refs/heads/main"], source)
    assert {:ok, private_blob} = Git.write_blob(target, "private issue state")

    assert {:ok, private_tree} =
             Git.write_tree(target, nil, [%{path: "issues/1/state.json", oid: private_blob}])

    assert {:ok, private_head} =
             Git.commit_tree(target, private_tree, [], "private issue\n", %{
               name: "Micelio",
               email: "test@example.com"
             })

    assert :ok = Git.update_refs(target, [%V1.RefCommand{ref: "refs/micelio/issues", new_oid: private_head}])

    assert {advertised, 0} = git(["ls-remote", target], source)
    refute advertised =~ "refs/micelio/issues"

    assert {output, status} = git(["fetch", "file://#{target}", "refs/micelio/issues"], source)
    assert status != 0
    assert output =~ "couldn't find remote ref"

    assert {output, status} = git(["push", target, "HEAD:refs/micelio/blocked"], source)
    assert status != 0
    assert output =~ "deny updating a hidden ref"
  end

  test "applies private-reference transport settings to an existing repository", %{root: root} do
    target = Path.join(root, "existing.git")
    assert {_output, 0} = git(["init", "--bare", "--quiet", target], root)

    assert :ok = Git.configure_bare(target)

    assert {"false\n", 0} = git(["config", "--get", "uploadpack.allowAnySHA1InWant"], target)
    assert {"refs/micelio\n", 0} = git(["config", "--get", "transfer.hideRefs"], target)
    assert {"refs/micelio\n", 0} = git(["config", "--get", "uploadpack.hideRefs"], target)
    assert {"refs/micelio\n", 0} = git(["config", "--get", "receive.hideRefs"], target)
  end
end
