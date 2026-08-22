defmodule Aimax.Core.MixProject do
  use Mix.Project

  def project do
    [
      app: :aimax_core,
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

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Aimax.Core.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:aimax_scheme, in_umbrella: true},
      {:req, "~> 0.5"},
      {:telemetry, "~> 1.0"},
      {:req_llm, "~> 1.19"},
      {:jason, "~> 1.4"},
      # the wire seam: Req's plug adapter lets tests inspect the exact
      # request req_llm builds (cache breakpoints, tool defs) with no network
      {:plug, "~> 1.18", only: :test},
      {:earmark, "~> 1.4"},
      # fsevents/inotify: how a diff buffer learns that an agent wrote to disk
      {:file_system, "~> 1.0"},
      {:exqlite, "~> 0.27"},
      {:rustler, "~> 0.36.0"}
    ]
  end
end
