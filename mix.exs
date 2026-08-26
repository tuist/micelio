defmodule Micelio.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/tuist/micelio"

  def project do
    [
      app: :micelio,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      source_url: @source_url,
      docs: docs(),
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Micelio.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:req, "~> 0.5"},

      # The public forge API is specified from the same schema it publishes.
      {:open_api_spex, "~> 3.22"},

      # Every `git` invocation is a supervised OS process. MuonTrap ties the
      # child's lifetime to the owning BEAM process, so a crashed or killed
      # replica can never leave an orphaned upload-pack holding a repository
      # open, and long-running pushes can be given hard resource ceilings.
      {:muontrap, "~> 1.5"},

      # The write-ahead log is a persisted, cross-version wire format.
      {:protobuf, "~> 0.13"},

      # JWT/JWKS verification. Micelio validates tokens; it never issues them.
      {:jose, "~> 1.11"},

      # Node discovery only. Membership, broadcast and failure detection are
      # handled by distributed Erlang itself; see `Micelio.Cluster`.
      {:libcluster, "~> 3.4"},

      # Observability. A replica that cannot explain its own staleness is
      # impossible to operate, so instrumentation is a dependency, not a
      # nice-to-have.
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},
      {:prom_ex, "~> 1.11"},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_exporter, "~> 1.8"},
      {:opentelemetry_bandit, "~> 0.2"},
      {:opentelemetry_telemetry, "~> 1.1"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      # Used sparingly: the suite runs against real git and a real object store
      # wherever it can, and reaches for a stub only for the paths that cannot
      # be provoked otherwise (an unreachable issuer, a storage failure).
      {:mimic, "~> 2.0", only: :test},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "compile"],
      lint: ["format --check-formatted", "credo --strict"]
    ]
  end

  defp releases do
    [micelio: [include_executables_for: [:unix], applications: [runtime_tools: :permanent]]]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "docs/architecture.md", "docs/operations.md", "docs/issues.md"]
    ]
  end
end
