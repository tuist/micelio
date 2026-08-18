defmodule Micelio.PolicyTest do
  @moduledoc """
  Authorization is data in object storage, so it gets the same scrutiny as the
  write-ahead log: concurrent updates must not clobber each other, and a change
  must take effect without anything being reissued or restarted.
  """

  use Micelio.Case, async: true

  alias Micelio.Auth
  alias Micelio.Auth.Principal
  alias Micelio.Policy

  setup %{namespace: namespace} do
    start_supervised!({Policy, []})
    # Only this account's entry: the cache is shared with tests running
    # concurrently, and clearing all of it would reach into them.
    Policy.invalidate(namespace)
    on_exit(fn -> Policy.invalidate(namespace) end)
    {:ok, account: namespace}
  end

  defp principal(subject) do
    %Principal{subject: subject, grants: [], source: :test}
  end

  describe "an account with no policy" do
    test "grants nothing", %{account: account} do
      assert Policy.grants_for(account, "anyone") == []
    end

    test "is not an error", %{account: account} do
      assert {:ok, policy} = Policy.get(account)
      assert policy.bindings == []
      assert policy.version == 0
    end
  end

  describe "binding" do
    test "grants a subject access to matching repositories", %{account: account} do
      {:ok, _} = Policy.bind(account, "alice@example.com", ["#{account}/**"], ["read", "write"])

      grants = Policy.grants_for(account, "alice@example.com")
      assert [%{pattern: pattern, permissions: permissions}] = grants
      assert pattern == "#{account}/**"
      assert Enum.sort(permissions) == [:read, :write]
    end

    test "leaves other subjects alone", %{account: account} do
      {:ok, _} = Policy.bind(account, "alice", ["#{account}/**"], ["read"])
      assert Policy.grants_for(account, "bob") == []
    end

    test "a subject pattern binds a whole class of identities", %{account: account} do
      # This is what makes it usable for machine identities: every service
      # account in a namespace, without enumerating them.
      {:ok, _} =
        Policy.bind(account, "system:serviceaccount:builders:*", ["#{account}/**"], ["read"])

      assert Policy.grants_for(account, "system:serviceaccount:builders:ci-1") != []
      assert Policy.grants_for(account, "system:serviceaccount:builders:ci-2") != []
      assert Policy.grants_for(account, "system:serviceaccount:other:ci-1") == []
    end

    test "re-binding replaces rather than accumulates", %{account: account} do
      {:ok, _} = Policy.bind(account, "alice", ["#{account}/**"], ["read", "write"])
      {:ok, policy} = Policy.bind(account, "alice", ["#{account}/one"], ["read"])

      assert length(policy.bindings) == 1
      assert [%{pattern: "#{account}/one", permissions: [:read]}] == Policy.grants_for(account, "alice")
    end

    test "ignores a permission it does not recognise", %{account: account} do
      {:ok, _} = Policy.bind(account, "alice", ["#{account}/**"], ["read", "superuser"])

      assert [%{permissions: [:read]}] = Policy.grants_for(account, "alice")
    end

    test "an expired binding stops applying", %{account: account} do
      past = System.system_time(:millisecond) - 1_000

      {:ok, _} =
        Policy.bind(account, "temp-agent", ["#{account}/**"], ["write"], expires_at_ms: past)

      assert Policy.grants_for(account, "temp-agent") == []
    end

    test "a future expiry still applies", %{account: account} do
      future = System.system_time(:millisecond) + 60_000

      {:ok, _} =
        Policy.bind(account, "temp-agent", ["#{account}/**"], ["write"], expires_at_ms: future)

      assert Policy.grants_for(account, "temp-agent") != []
    end
  end

  describe "revocation" do
    test "takes effect without reissuing anything", %{account: account} do
      # The reason policy lives here rather than in a token claim: a claim is
      # true until the token expires.
      {:ok, _} = Policy.bind(account, "alice", ["#{account}/**"], ["write"])
      assert Policy.grants_for(account, "alice") != []

      {:ok, _} = Policy.unbind(account, "alice")
      Policy.invalidate(account)

      assert Policy.grants_for(account, "alice") == []
    end
  end

  describe "concurrent updates" do
    test "do not clobber each other", %{account: account} do
      # The same compare-and-swap discipline as the log: every writer's change
      # must survive, even though they all read the same starting state.
      results =
        1..10
        |> Task.async_stream(
          fn n -> Policy.bind(account, "subject-#{n}", ["#{account}/repo-#{n}"], ["read"]) end,
          max_concurrency: 10,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      # Every writer must succeed. Losing one to exhausted retries would mean a
      # grant silently not being applied, which is the worst possible failure
      # mode for an authorization system.
      assert Enum.all?(results, &match?({:ok, _}, &1)), inspect(results)

      Policy.invalidate(account)
      {:ok, policy} = Policy.get(account)

      assert length(policy.bindings) == 10
      assert policy.version == 10

      for n <- 1..10 do
        assert Policy.grants_for(account, "subject-#{n}") != []
      end
    end
  end

  describe "integration with authorization" do
    test "a token with no grants is authorized by policy", %{account: account} do
      repo = "#{account}/app"
      assert {:error, :forbidden} = Auth.authorize(principal("alice"), repo, :read)

      {:ok, _} = Policy.bind(account, "alice", ["#{account}/**"], ["read"])
      Policy.invalidate(account)

      assert :ok = Auth.authorize(principal("alice"), repo, :read)
      assert {:error, :forbidden} = Auth.authorize(principal("alice"), repo, :write)
    end

    test "token grants still work on their own", %{account: account} do
      # Machine identities should not need a policy entry at all.
      carrying = %Principal{subject: "pod", grants: [Principal.grant("#{account}/**", [:write])]}

      assert :ok = Auth.authorize(carrying, "#{account}/app", :write)
    end

    test "policy for one account does not leak into another", %{account: account} do
      {:ok, _} = Policy.bind(account, "alice", ["**"], ["admin"])
      Policy.invalidate(account)

      # The binding is generous, but it is scoped to this account's policy
      # object, and authorization reads the policy of the repository's own
      # account.
      assert :ok = Auth.authorize(principal("alice"), "#{account}/app", :admin)
      assert {:error, :forbidden} = Auth.authorize(principal("alice"), "someone-else/app", :admin)
    end
  end

  test "destroy/1 removes the policy", %{account: account} do
    {:ok, _} = Policy.bind(account, "alice", ["#{account}/**"], ["read"])
    assert :ok = Policy.destroy(account)
    Policy.invalidate(account)

    assert Policy.grants_for(account, "alice") == []
  end
end
