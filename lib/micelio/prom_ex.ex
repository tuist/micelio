defmodule Micelio.PromEx do
  @moduledoc """
  Prometheus metrics.

  Exposed at `/metrics` on the admin listener, which keeps it off the public
  port without needing a second process.

  These metrics are not only for dashboards. `micelio_git_requests_in_flight`
  and `micelio_wal_read_duration_seconds` are the signals a HorizontalPodAutoscaler
  should scale on: Git serving is bound by concurrent streams and by how much
  catch-up the read path is doing, neither of which shows up cleanly in CPU
  until the node is already struggling.
  """

  use PromEx, otp_app: :micelio

  alias PromEx.Plugins

  @impl true
  def plugins do
    [
      Plugins.Application,
      Plugins.Beam,
      Micelio.PromEx.Plugin
    ]
  end

  @impl true
  def dashboard_assigns do
    [datasource_id: "prometheus", default_selected_interval: "30s"]
  end

  @impl true
  def dashboards, do: []
end
