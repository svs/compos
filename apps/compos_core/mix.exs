defmodule Compos.Core.MixProject do
  use Mix.Project

  def project do
    [
      app: :compos_core,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  # test/support holds the one test case template and the fakes every
  # test shares; the .exs fixtures there run as their own programs
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Compos.Core.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:compos_scheme, in_umbrella: true},
      {:req, "~> 0.5"},
      {:telemetry, "~> 1.0"},
      {:req_llm, "~> 1.19"},
      {:jason, "~> 1.4"},
      # the wire seam: Req's plug adapter lets tests inspect the exact
      # request req_llm builds (cache breakpoints, tool defs) with no network
      {:plug, "~> 1.18"},
      # Agents create short-lived inbound HTTP servers. Bandit owns the
      # socket and HTTP byte parsing; Scheme owns every request handler.
      {:bandit, "~> 1.5"},
      # fsevents/inotify: how a diff buffer learns that an agent wrote to disk
      {:file_system, "~> 1.0"},
      {:exqlite, "~> 0.27"},
      # the database mechanism: wire protocol, auth, pooling, and type
      # decoding are not things Scheme can supply
      {:postgrex, "~> 0.20"},
      # cron: Quantum owns the timer and the cron grammar; Scheme owns the
      # jobs (scheme/packages/cron.scm). tz gives it the local time zone.
      {:quantum, "~> 3.5"},
      {:tz, "~> 0.28"},
      {:rustler, "~> 0.36.0"}
    ]
  end
end
