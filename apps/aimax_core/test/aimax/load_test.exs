defmodule Aimax.LoadTest do
  @moduledoc """
  (load ...) is how init.scm sources more config. A relative path resolves
  against the config home, not the daemon's working directory.
  """

  use ExUnit.Case

  alias Aimax.Core.Session

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
