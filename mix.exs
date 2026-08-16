defmodule Aimax.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  defp releases do
    [
      aimax: [
        applications: [
          aimax_scheme: :permanent,
          aimax_core: :permanent,
          aimax_ui: :permanent,
          aimax_rpc: :permanent
        ],
        include_executables_for: [:unix],
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos_arm: [os: :darwin, cpu: :aarch64]
          ]
        ]
      ]
    ]
  end

  # Dependencies listed here are available only for this
  # project and cannot be accessed from applications inside
  # the apps folder.
  #
  # Run "mix help deps" for examples and options.
  defp deps do
    [
      # single-binary packaging; needs zig + xz on the build machine
      {:burrito, "~> 1.5.0", runtime: false}
    ]
  end
end
