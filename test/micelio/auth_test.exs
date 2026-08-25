defmodule Micelio.AuthTest do
  use ExUnit.Case, async: true

  alias Micelio.Auth
  alias Micelio.Auth.Principal
  alias Micelio.Auth.Static

  describe "credential_from_header/1" do
    test "reads bearer tokens" do
      assert Auth.credential_from_header("Bearer abc") == {:bearer, "abc"}
      assert Auth.credential_from_header("bearer abc") == {:bearer, "abc"}
    end

    test "reads a token carried through basic auth the way git sends it" do
      # Every Git client sends Basic, so the conventions real hosts accept for
      # smuggling a token through it have to be honoured.
      for user <- ~w(x-access-token oauth2 token) do
        header = "Basic " <> Base.encode64("#{user}:secret")
        assert Auth.credential_from_header(header) == {:bearer, "secret"}
      end
    end

    test "treats a token in the username position with an empty password as a token" do
      header = "Basic " <> Base.encode64("secret:")
      assert Auth.credential_from_header(header) == {:bearer, "secret"}
    end

    test "keeps a genuine username and password pair" do
      header = "Basic " <> Base.encode64("alice:hunter2")
      assert Auth.credential_from_header(header) == {:basic, "alice", "hunter2"}
    end

    test "anything unparseable is anonymous" do
      assert Auth.credential_from_header(nil) == :anonymous
      assert Auth.credential_from_header("Basic !!!not base64!!!") == :anonymous
      assert Auth.credential_from_header("Digest xyz") == :anonymous
    end
  end

  describe "Principal.matches?/2" do
    test "* stays within one path segment" do
      assert Principal.matches?("acme/*", "acme/app")
      refute Principal.matches?("acme/*", "acme/team/app")
    end

    test "** crosses path segments" do
      assert Principal.matches?("acme/**", "acme/app")
      assert Principal.matches?("acme/**", "acme/team/app")
      assert Principal.matches?("**", "anything/at/all")
    end

    test "does not match a different account" do
      refute Principal.matches?("acme/**", "beta/app")
      refute Principal.matches?("acme/**", "notacme/app")
    end

    test "treats dots literally rather than as regex" do
      assert Principal.matches?("acme/my.app", "acme/my.app")
      refute Principal.matches?("acme/my.app", "acme/myXapp")
    end
  end

  describe "Principal.allows?/3" do
    test "grants only what is listed" do
      principal = %Principal{grants: [Principal.grant("acme/**", [:read])]}

      assert Principal.allows?(principal, "acme/app", :read)
      refute Principal.allows?(principal, "acme/app", :write)
      refute Principal.allows?(principal, "beta/app", :read)
    end

    test "admin implies every permission" do
      principal = %Principal{grants: [Principal.grant("acme/**", [:admin])]}

      assert Principal.allows?(principal, "acme/app", :read)
      assert Principal.allows?(principal, "acme/app", :write)
      assert Principal.allows?(principal, "acme/app", :execute)
      assert Principal.allows?(principal, "acme/app", :admin)
    end

    test "a principal with no grants can do nothing" do
      refute Principal.allows?(%Principal{}, "acme/app", :read)
    end
  end

  describe "expiry" do
    test "a principal past its expiry is expired" do
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      assert Principal.expired?(%Principal{expires_at: past}, DateTime.utc_now())
    end

    test "a principal with no expiry never expires" do
      refute Principal.expired?(%Principal{}, DateTime.utc_now())
    end
  end

  describe "Static backend" do
    @tokens %{"good" => %{account: "acme", scopes: [:read, :write]}}

    test "accepts a configured token" do
      assert {:ok, principal} = Static.authenticate({:bearer, "good"}, tokens: @tokens)
      assert principal.account == "acme"
      assert Principal.allows?(principal, "acme/app", :write)
    end

    test "a token scoped to an account cannot touch another one" do
      # Regression: the expansion used to add a `**` grant alongside the scoped
      # one, which subsumed it and made every account token a superuser token.
      assert {:ok, principal} = Static.authenticate({:bearer, "good"}, tokens: @tokens)

      refute Principal.allows?(principal, "someone-else/private", :read)
      refute Principal.allows?(principal, "someone-else/private", :write)
      refute Principal.allows?(principal, "acmeter/lookalike", :read)
    end

    test "a token with no account is unscoped, which has to be chosen deliberately" do
      tokens = %{"root" => %{scopes: [:admin]}}

      assert {:ok, principal} = Static.authenticate({:bearer, "root"}, tokens: tokens)
      assert Principal.allows?(principal, "anything/at/all", :admin)
    end

    test "explicit grants are used verbatim" do
      tokens = %{"t" => %{account: "acme", grants: [Principal.grant("acme/one", [:read])]}}

      assert {:ok, principal} = Static.authenticate({:bearer, "t"}, tokens: tokens)
      assert Principal.allows?(principal, "acme/one", :read)
      refute Principal.allows?(principal, "acme/two", :read)
    end

    test "rejects an unknown token" do
      assert {:error, :invalid_credential} =
               Static.authenticate({:bearer, "bad"}, tokens: @tokens)
    end

    test "rejects an anonymous request" do
      assert {:error, :unauthenticated} = Static.authenticate(:anonymous, tokens: @tokens)
    end

    test "parse_tokens/1 reads the environment format" do
      parsed = Static.parse_tokens("t1=acme:read,write,execute;t2=beta:read")

      assert parsed["t1"].account == "acme"
      assert parsed["t1"].scopes == [:read, :write, :execute]
      assert parsed["t2"].scopes == [:read]
    end

    test "parse_tokens/1 accepts the execution scope without dynamically creating an atom" do
      assert %{"worker" => %{scopes: [:execute]}} = Static.parse_tokens("worker=acme:execute")
    end
  end
end
