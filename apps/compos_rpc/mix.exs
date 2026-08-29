defmodule Compos.Rpc.MixProject do
  use Mix.Project

  def project do
    [
      app: :compos_rpc,
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
      mod: {Compos.Rpc.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:compos_core, in_umbrella: true},
      {:jason, "~> 1.4"}
    ]
  end
end
