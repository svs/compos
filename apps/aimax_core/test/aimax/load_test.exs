defmodule Aimax.LoadTest do
  @moduledoc """
  (load ...) is how init.scm sources more config. A relative path resolves
  against the config home, not the daemon's working directory.
  """

  use ExUnit.Case

  alias Aimax.Core.Session

  test "stock init explicitly loads every bundled package" do
    priv = Application.app_dir(:aimax_core, "priv")
    init = File.read!(Path.join(priv, "init.scm"))

    listed =
      ~r/\(load-bundled-package\s+"([^"]+)"\)/
      |> Regex.scan(init, capture: :all_but_first)
      |> Enum.map(&hd/1)

    packages =
      priv
      |> Path.join("packages/**/*.scm")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, Path.join(priv, "packages")))

    assert Enum.sort(listed) == Enum.sort(packages)
    assert length(listed) == length(Enum.uniq(listed))
  end

  test "(load ...) resolves a relative path against the config home" do
    home = Aimax.Core.home()
    File.write!(Path.join(home, "load-relative-test.scm"), "(define load-relative-mark 42)\n")

    on_exit(fn -> File.rm(Path.join(home, "load-relative-test.scm")) end)

    # relative: found under the config home
    assert {:ok, _} = Session.eval(~s{(load "load-relative-test.scm")})
    assert {:ok, "42"} = Session.eval("load-relative-mark")

    # an absolute path still works
    abs = Path.join(home, "load-relative-test.scm")
    assert {:ok, _} = Session.eval(~s{(load "#{abs}")})
  end

  test "reload-file evaluates a .scm and picks up an edit" do
    path = Path.join(System.tmp_dir!(), "zz-reload-test.scm")
    File.write!(path, ~s{(define-command "zz-reloaded" (lambda () (message "one")))\n})
    on_exit(fn -> File.rm(path) end)

    assert {:ok, _} = Session.eval(~s{(reload-file "#{path}")})
    assert {:ok, listed} = Session.eval(~s{(member "zz-reloaded" (command-names))})
    assert listed =~ "zz-reloaded"

    # the edited definition replaces the old one on the next reload
    File.write!(path, ~s{(define zz-reload-mark 7)\n})
    assert {:ok, _} = Session.eval(~s{(reload-file "#{path}")})
    assert {:ok, "7"} = Session.eval("zz-reload-mark")

    # the catalog stamps the file's own package name
    assert {:ok, printed} = Session.eval(~s{(catalog-entry 'command "zz-reloaded")})
    assert printed =~ "zz-reload-test"
  end

  test "the core Scheme reload evaluates changed forms instead of the whole bootstrap" do
    editor = Application.app_dir(:aimax_core, "priv/editor.scm")

    {elapsed, result} = :timer.tc(fn -> Session.reload_files([editor]) end)

    assert {:ok, %{files: 1, forms: forms}} = result
    assert forms > 0
    assert elapsed < 5_000_000
  end

  # Mix symlinks priv into _build, so Application.app_dir/2 and a reload
  # request name the same file with two different strings. The boot manifest
  # is keyed by one and looked up by the other. Before Session.canonical/1 the
  # two never matched, and the first reload of any file from the checkout
  # re-evaluated all of it — every `mix aimax.reload` paid the whole file.
  test "the boot manifest matches a path from the source tree, not only the build symlink" do
    build = Application.app_dir(:aimax_core, "priv/themes.scm")
    source = Session.canonical(build)

    refute source == build, "priv is not a symlink in this build; the test proves nothing"

    all = source |> File.read!() |> Aimax.Scheme.Reader.read_all() |> length()
    assert {:ok, %{forms: forms}} = Session.reload_files([source])

    assert forms < div(all, 2),
           "an unchanged file re-evaluated #{forms} of its #{all} forms"
  end

  test "incremental reload skips unchanged package forms" do
    path = Path.join(System.tmp_dir!(), "zz-incremental-reload.scm")

    File.write!(path, "(define zz-reload-count 1)\n(define zz-reload-value 1)\n")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{forms: 2}} = Session.reload_files([path])

    File.write!(path, "(define zz-reload-count 1)\n(define zz-reload-value 2)\n")
    assert {:ok, %{forms: 1}} = Session.reload_files([path])
    assert {:ok, "2"} = Session.eval("zz-reload-value")
  end

  test "the reload prompt completes over stdlib, bundled, and user packages" do
    home_pkg = Path.join([Aimax.Core.home(), "packages"])
    File.mkdir_p!(home_pkg)
    user = Path.join(home_pkg, "zz-user-pkg.scm")
    File.write!(user, "(define zz-user-pkg-mark 3)\n")
    on_exit(fn -> File.rm(user) end)

    assert {:ok, names} = Session.eval("(map car (reload--files))")
    assert names =~ "editor"
    assert names =~ "annotate"
    assert names =~ "zz-user-pkg"

    # choose one through the real prompt
    assert {:ok, _} = Session.eval(~s{(run-command "reload-file")})
    assert {:ok, "#t"} = Session.eval("(if (minibuffer-state) #t #f)")

    Enum.each(String.graphemes("zz-user-pkg"), &Aimax.Core.KeyDispatch.handle_key/1)
    Aimax.Core.KeyDispatch.handle_key("RET")

    assert {:ok, "3"} = Session.eval("zz-user-pkg-mark")
  end
end
