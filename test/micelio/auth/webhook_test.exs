defmodule Micelio.Auth.WebhookTest do
  @moduledoc """
  The webhook backend hands authentication to somebody else's service, which
  makes its failure modes the interesting part: what it does when that service
  is slow, wrong, or gone, and whether it can be made to leak the credential it
  was given.
  """

  use ExUnit.Case, async: true
  use Mimic

  alias Micelio.Auth.Principal
  alias Micelio.Auth.Webhook

  setup :set_mimic_from_context

  setup do
    # The cache only exists when this backend is the configured one, which it is
    # not under test. Starting it here is idempotent, and every test uses a
    # distinct credential so the shared table cannot cross-contaminate.
    if is_nil(Process.whereis(Micelio.Auth.Webhook.Cache)) and
         :ets.whereis(Micelio.Auth.Webhook.Cache) == :undefined do
      start_supervised({Webhook, []})
    end

    {:ok, config: [endpoint: "https://auth.example.com/verify", token: "service-token", cache_ttl_ms: 0]}
  end

  defp respond(status, body) do
    stub(Req, :post, fn _url, _opts -> {:ok, %Req.Response{status: status, body: body}} end)
  end

  describe "a successful verification" do
    test "becomes a principal", %{config: config} do
      respond(200, %{
        "subject" => "alice@example.com",
        "account" => "acme",
        "grants" => [%{"pattern" => "acme/**", "permissions" => ["read", "write"]}]
      })

      assert {:ok, principal} = Webhook.authenticate({:bearer, "user-token"}, config)
      assert principal.subject == "alice@example.com"
      assert principal.account == "acme"
      assert principal.source == :webhook
      assert Principal.allows?(principal, "acme/app", :write)
      refute Principal.allows?(principal, "other/app", :read)
    end

    test "accepts the compact grant form", %{config: config} do
      respond(200, %{"subject" => "bot", "grants" => ["acme/**:read", "acme/sandbox:read,write"]})

      assert {:ok, principal} = Webhook.authenticate({:bearer, "t"}, config)
      assert Principal.allows?(principal, "acme/anything", :read)
      assert Principal.allows?(principal, "acme/sandbox", :write)
      refute Principal.allows?(principal, "acme/anything", :write)
    end

    test "carries an expiry when the authority supplies one", %{config: config} do
      expires = DateTime.utc_now() |> DateTime.add(300, :second) |> DateTime.to_iso8601()
      respond(200, %{"subject" => "alice", "expires_at" => expires})

      assert {:ok, principal} = Webhook.authenticate({:bearer, "t"}, config)
      assert %DateTime{} = principal.expires_at
    end

    test "a response with no grants authorises nothing", %{config: config} do
      respond(200, %{"subject" => "nobody"})

      assert {:ok, principal} = Webhook.authenticate({:bearer, "t"}, config)
      assert principal.grants == []
      refute Principal.allows?(principal, "anything", :read)
    end
  end

  describe "rejection" do
    test "401 and 403 are invalid credentials, not errors", %{config: config} do
      for status <- [401, 403] do
        respond(status, "")
        assert {:error, :invalid_credential} = Webhook.authenticate({:bearer, "t"}, config)
      end
    end

    test "any other status is surfaced as an error rather than a denial", %{config: config} do
      # A 500 from the authority is not evidence that the credential is bad,
      # and treating it as such would make an outage look like a mass
      # revocation in the logs.
      respond(500, "")
      assert {:error, {:authority_status, 500}} = Webhook.authenticate({:bearer, "t"}, config)
    end

    test "an unreachable authority fails closed", %{config: config} do
      stub(Req, :post, fn _url, _opts -> {:error, %Mint.TransportError{reason: :econnrefused}} end)

      assert {:error, :authority_unreachable} = Webhook.authenticate({:bearer, "t"}, config)
    end

    test "an anonymous request is not sent to the authority at all", %{config: config} do
      stub(Req, :post, fn _url, _opts -> flunk("should not have called the authority") end)

      assert {:error, :unauthenticated} = Webhook.authenticate(:anonymous, config)
    end
  end

  describe "what is sent" do
    test "the service token authenticates us, and the credential is the payload", %{config: config} do
      test_process = self()

      stub(Req, :post, fn url, opts ->
        send(test_process, {:request, url, opts})
        {:ok, %Req.Response{status: 200, body: %{"subject" => "alice"}}}
      end)

      Webhook.authenticate({:bearer, "user-token"}, config)

      assert_received {:request, url, opts}
      assert url == "https://auth.example.com/verify"

      headers = Keyword.fetch!(opts, :headers)
      assert {"authorization", "Bearer service-token"} in headers

      json = Keyword.fetch!(opts, :json)
      assert json.credential == "user-token"
      assert is_binary(json.node)
    end

    test "basic credentials are forwarded whole", %{config: config} do
      test_process = self()

      stub(Req, :post, fn _url, opts ->
        send(test_process, {:json, Keyword.fetch!(opts, :json)})
        {:ok, %Req.Response{status: 200, body: %{"subject" => "alice"}}}
      end)

      Webhook.authenticate({:basic, "alice", "hunter2"}, config)

      assert_received {:json, json}
      assert json.credential == "alice:hunter2"
    end
  end

  describe "caching" do
    test "a repeat verification within the TTL does not call the authority twice" do
      config = [endpoint: "https://auth.example.com/verify", token: "s", cache_ttl_ms: 60_000]
      counter = :counters.new(1, [])
      token = "cached-#{:erlang.unique_integer([:positive])}"

      stub(Req, :post, fn _url, _opts ->
        :counters.add(counter, 1, 1)
        {:ok, %Req.Response{status: 200, body: %{"subject" => "alice"}}}
      end)

      assert {:ok, _} = Webhook.authenticate({:bearer, token}, config)
      assert {:ok, _} = Webhook.authenticate({:bearer, token}, config)

      assert :counters.get(counter, 1) == 1
    end

    test "different credentials are cached separately" do
      config = [endpoint: "https://auth.example.com/verify", token: "s", cache_ttl_ms: 60_000]
      counter = :counters.new(1, [])
      suffix = :erlang.unique_integer([:positive])

      stub(Req, :post, fn _url, opts ->
        :counters.add(counter, 1, 1)
        credential = Keyword.fetch!(opts, :json).credential
        {:ok, %Req.Response{status: 200, body: %{"subject" => credential}}}
      end)

      assert {:ok, a} = Webhook.authenticate({:bearer, "one-#{suffix}"}, config)
      assert {:ok, b} = Webhook.authenticate({:bearer, "two-#{suffix}"}, config)

      assert a.subject != b.subject
      assert :counters.get(counter, 1) == 2
    end
  end
end
