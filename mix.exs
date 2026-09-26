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
        steps: [:assemble, &copy_scheme_packages/1, &compile_bundled_grammars/1, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos_arm: [os: :darwin, cpu: :aarch64],
            # Rustler NIFs need an ERTS built for the same Linux libc.
            linux_x86_64: [
              os: :linux,
              cpu: :x86_64,
              custom_erts: System.get_env("COMPOS_CUSTOM_ERTS"),
              skip_nifs: true
            ]
          ]
        ]
      ]
    ]
  end

  # The packages live at the project root, and a release has no checkout:
  # they ride in compos_core's priv/packages, the load-path entry that
  # stays in a release, so the Scheme side needs no release branch.
  defp copy_scheme_packages(release) do
    vsn = release.applications[:compos_core][:vsn]
    dest = Path.join([release.path, "lib", "compos_core-#{vsn}", "priv", "packages"])
    File.mkdir_p!(dest)
    File.cp_r!("scheme/packages", dest)
    release
  end

  # Compile bundled grammars inside the assembled Linux release. The user
  # can then run the executable on a machine without a C compiler.
  defp compile_bundled_grammars(release) do
    if System.get_env("BURRITO_TARGET") == "linux_x86_64" do
      vsn = release.applications[:compos_core][:vsn]
      root = Path.join([release.path, "lib", "compos_core-#{vsn}", "priv", "grammars"])

      for parser <- Path.wildcard(Path.join([root, "*", "src", "parser.c"])) do
        src = Path.dirname(parser)
        grammar = src |> Path.dirname() |> Path.basename()
        scanner = Path.join(src, "scanner.c")
        out_dir = Path.join([root, grammar, "prebuilt", "linux_x86_64"])
        File.mkdir_p!(out_dir)
        sources = [parser] ++ if(File.exists?(scanner), do: [scanner], else: [])

        args =
          ["-fPIC", "-shared", "-O2", "-I", src] ++
            sources ++ ["-o", Path.join(out_dir, "#{grammar}.so")]

        case System.cmd("cc", args, stderr_to_stdout: true) do
          {_, 0} -> :ok
          {output, status} -> raise "cannot compile #{grammar} grammar (#{status}): #{output}"
        end
      end
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
