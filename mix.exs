defmodule Compos.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      # No Phoenix.CodeReloader listener. It purges and deletes, in this VM,
      # every module an outside `mix compile` or `mix test` rebuilt — including
      # the ones Compos.Core.Hotload's own child compile rebuilds. A call
      # landing in that window raises "module is not available", which is how
      # Compos.Core.Editor disappeared under a keystroke. Hotload owns code
      # loading here, and its swap loads before it purges.
      deps: deps(),
      releases: releases()
    ]
  end

  defp releases do
    [
      compos: [
        applications: [
          compos_scheme: :permanent,
          compos_core: :permanent,
          compos_ui: :permanent,
          compos_rpc: :permanent
        ],
        include_executables_for: [:unix],
        steps: [:assemble, &copy_scheme_packages/1, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos_arm: [os: :darwin, cpu: :aarch64]
          ]
        ]
      ]
    ]
  end

  # The packages and apps live at the project root, and a release has no
  # checkout: they ride in compos_core's priv/packages and priv/apps, the
  # load-path entries that stay in a release, so the Scheme side needs no
  # release branch.
  defp copy_scheme_packages(release) do
    vsn = release.applications[:compos_core][:vsn]

    for dir <- ["packages", "apps"] do
      dest = Path.join([release.path, "lib", "compos_core-#{vsn}", "priv", dir])
      File.mkdir_p!(dest)
      File.cp_r!(Path.join("scheme", dir), dest)
    end

    release
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
