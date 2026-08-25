defmodule Micelio.TelemetryTest do
  use ExUnit.Case, async: true

  test "normalizes web-request metrics without using the request path as a label" do
    handler = {__MODULE__, :http_request, self()}

    :ok =
      :telemetry.attach(
        handler,
        [:micelio, :http, :request],
        fn _event, measurements, meta, pid ->
          if self() == pid, do: send(pid, {:http_request, measurements, meta})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    conn = Plug.Test.conn("GET", "/acme/private-repository.git/info/refs") |> Map.put(:status, 200)

    Micelio.Telemetry.handle_http_event(
      [:bandit, :request, :stop],
      %{
        duration: System.convert_time_unit(25, :millisecond, :native),
        req_body_bytes: 13,
        resp_body_bytes: 21
      },
      %{conn: conn, plug: {Micelio.HTTP.Router, []}},
      nil
    )

    assert_receive {:http_request, %{duration_us: 25_000, request_bytes: 13, response_bytes: 21}, meta}
    assert meta == %{listener: :public, method: :get, status: :"2xx"}
  end

  test "normalizes unknown request methods to a bounded label" do
    handler = {__MODULE__, :unknown_http_method, self()}

    :ok =
      :telemetry.attach(
        handler,
        [:micelio, :http, :request],
        fn _event, measurements, meta, pid ->
          if self() == pid, do: send(pid, {:http_request, measurements, meta})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    conn = Plug.Test.conn("CUSTOM", "/") |> Map.put(:status, 405)

    Micelio.Telemetry.handle_http_event(
      [:bandit, :request, :stop],
      %{duration: 0},
      %{conn: conn, plug: {Micelio.HTTP.Router, []}},
      nil
    )

    assert_receive {:http_request, %{duration_us: 0}, meta}
    assert meta == %{listener: :public, method: :other, status: :"4xx"}
  end
end
