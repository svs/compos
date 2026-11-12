defmodule Compos.LoadOrderTest do
  @moduledoc """
  A package loads without the order init.scm gives it.

  The check boots the Scheme world once for each package. The manifest of
  that boot is core.scm and the one package, so the package gets only the
  kernel, the core libraries, and the files it requires itself. A package
  that uses a name of another package at load, with no require, fails here.

  It takes about one minute, so it runs apart:

      mix test --include load_order apps/compos_core/test/compos/load_order_test.exs
      LOAD_ORDER=notmuch,pdf mix test --include load_order apps/compos_core/test/compos/load_order_test.exs
  """

  use ExUnit.Case, async: false

  alias Compos.Core.Session

  @moduletag :load_order

  defp requires(src) do
    Regex.scan(~r/^\(require\s+'([\w-]+)(?:\s+"([^"]+)")?\)/m, src)
    |> Enum.map(fn
      [_, name] -> name <> ".scm"
      [_, _name, path] -> path
    end)
  end

  defp loads(src), do: Regex.scan(~r/^\(load\s+"([^"]+)"\)/m, src) |> Enum.map(&Enum.at(&1, 1))

  # the entry points, in two lists: what init.scm requires at boot, and
  # every other package or app file that no file loads as its module. A
  # file of the second list loads after boot, from its autoload or from
  # the user init, so the check loads it into a booted core.
  defp entries do
    priv = Application.app_dir(:compos_core, "priv")
    root = Compos.Core.project_dir()
    dirs = [Path.join(root, "scheme/packages"), Path.join(root, "scheme/apps")]

    files =
      Enum.flat_map(dirs, fn dir ->
        dir |> Path.join("**/*.scm") |> Path.wildcard() |> Enum.map(&{Path.relative_to(&1, dir), &1})
      end)
      |> Enum.reject(fn {rel, _} -> String.ends_with?(rel, "-test.scm") end)

    modules = Enum.flat_map(files, fn {_, path} -> path |> File.read!() |> loads() end)
    stock = priv |> Path.join("init.scm") |> File.read!() |> requires()

    # a file in a package directory that is no entry point is a module of
    # its package: only a top-level file stands alone
    standalone = for {rel, _} <- files, rel not in modules, Path.dirname(rel) == ".", do: rel

    {stock -- ["core.scm"], (standalone -- stock) -- ["core.scm"]}
  end

  defp boot!(manifest, source) do
    File.write!(manifest, source)
    :ok = Supervisor.terminate_child(Compos.Core.Supervisor, Session)
    {:ok, _} = Supervisor.restart_child(Compos.Core.Supervisor, Session)
    Session.ready?() || GenServer.call(Session, :await_boot, 120_000)
    Session.boot_errors()
  end

  @tag timeout: 900_000
  test "every package loads with the core and its own requires" do
    manifest = Path.join(System.tmp_dir!(), "compos-load-order-#{System.pid()}.scm")
    level = Logger.level()

    on_exit(fn ->
      # the suite's own world comes back: the stock manifest, booted again
      Application.delete_env(:compos_core, :boot_manifest)
      File.rm(manifest)
      Supervisor.terminate_child(Compos.Core.Supervisor, Session)
      Supervisor.restart_child(Compos.Core.Supervisor, Session)
      Logger.configure(level: level)
    end)

    only = System.get_env("LOAD_ORDER")
    chosen = if only, do: Enum.map(String.split(only, ","), &(&1 <> ".scm")), else: nil
    pick = fn list -> Enum.filter(list, &(chosen == nil or Path.basename(&1) in chosen)) end
    {stock, later} = entries()
    {stock, later} = {pick.(stock), pick.(later)}
    assert stock ++ later != [], "no package matched LOAD_ORDER=#{only}"

    Application.put_env(:compos_core, :boot_manifest, manifest)
    # a failed load logs an error; the assertion below reports it once
    Logger.configure(level: :emergency)

    at_boot =
      for entry <- stock,
          errors = boot!(manifest, "(require 'core)\n(load #{inspect(entry)})\n"),
          errors != [] do
        "#{entry}: " <> Enum.map_join(errors, "; ", fn {file, msg} -> "#{file}: #{msg}" end)
      end

    after_boot =
      for entry <- later,
          [] = boot!(manifest, "(require 'core)\n"),
          {:error, msg} <- [Session.eval("(load #{inspect(entry)})")] do
        "#{entry}: #{msg}"
      end

    failures = at_boot ++ after_boot

    assert failures == [],
           "these packages do not load alone. Add (require 'NAME) for the package that defines the name:\n" <>
             Enum.join(failures, "\n")
  end
end
