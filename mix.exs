defmodule Compos.MixProject do
  use Mix.Project

  @version "0.9.1"

  def project do
    [
      apps_path: "apps",
      version: @version,
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
        # The commit rides in the release version, so Burrito unpacks each
        # build into its own directory instead of reusing the last 0.9.0.
        version: "#{@version}+#{commit()}",
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
            macos_arm: [os: :darwin, cpu: :aarch64],
            linux: [os: :linux, cpu: :x86_64]
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

    # The Chrome extension; Compos.Core.ChromeExtension copies it to
    # ~/.compos/chrome-extension at boot.
    File.cp_r!("extension", Path.join([release.path, "lib", "compos_core-#{vsn}", "priv", "extension"]))

    # What the modeline names as this build (scheme/packages/build-identity.scm).
    built = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    File.write!(
      Path.join([release.path, "lib", "compos_core-#{vsn}", "priv", "build-info.scm"]),
      ~s|(version "#{vsn}" commit "#{commit()}" built "#{built}")\n|
    )

    release
  end

  defp commit do
    {sha, 0} = System.cmd("git", ["rev-parse", "--short", "HEAD"])
    String.trim(sha)
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
