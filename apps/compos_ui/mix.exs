defmodule Compos.Ui.MixProject do
  use Mix.Project

  def project do
    [
      app: :compos_ui,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      # os_mon feeds the dashboard's OS page: CPU, memory, and disk
      extra_applications: [:logger, :os_mon],
      mod: {Compos.Ui.Application, []}
    ]
  end

  defp deps do
    [
      {:compos_core, in_umbrella: true},
      {:earmark, "~> 1.4"},
      {:req, "~> 0.5"},
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_live_reload, "~> 1.6", only: :dev},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:telemetry_metrics, "~> 1.1"},
      {:telemetry_poller, "~> 1.3"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:lazy_html, ">= 0.1.0", only: :test},
      # runtime MCP server for coding agents: /tidewave/mcp on the editor port
      {:tidewave, "~> 0.9", only: :dev}
    ]
  end
end
