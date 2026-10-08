defmodule Compos.LoadTest do
  @moduledoc """
  (load ...) is how init.scm sources more config. A relative path resolves
  against the config home, not the daemon's working directory.
  """

  use ExUnit.Case

  alias Compos.Core.Session

  # the files one Scheme file names at its top level. A (load "x.scm") is
  # a module of a compound package; a (require 'x) or (require 'x
  # "dir/x.scm") is an entry point in init.scm and a dependency anywhere
  # else, so the two are read apart.
  defp loads(src), do: Regex.scan(~r/^\(load\s+"([^"]+)"\)/m, src) |> Enum.map(&Enum.at(&1, 1))

  defp requires(src) do
    Regex.scan(~r/^\(require\s+'([\w-]+)(?:\s+"([^"]+)")?\)/m, src)
    |> Enum.map(fn
      [_, name] -> name <> ".scm"
      [_, _name, path] -> path
    end)
  end

  test "every bundled file loads at boot" do
    assert Session.boot_errors() == []
  end

  # A package may call define-workflow! at load, inside Session's boot. The
  # first call starts the workflow tree when the application did not, and
  # an application child that starts later fails as "already started".
  test "the workflow tree is up before the Scheme world boots" do
    # which_children lists the newest child first
    children = Enum.reverse(Supervisor.which_children(Compos.Core.Supervisor))
    ids = for {id, _, _, _} <- children, do: id
    assert Enum.find_index(ids, &(&1 == Compos.Core.Workflows)) < Enum.find_index(ids, &(&1 == Session))

    pids = for {_, pid, _, _} <- children, do: pid
    assert Process.whereis(Compos.Core.Workflows) in pids
  end

  test "stock init reaches every bundled package through package entry points" do
    priv = Application.app_dir(:compos_core, "priv")
    init = File.read!(Path.join(priv, "init.scm"))

    # the bundled packages: scheme/packages at the project root
    dirs = [Path.join(Compos.Core.project_dir(), "scheme/packages")]
    locate = fn name -> Enum.find(Enum.map(dirs, &Path.join(&1, name)), &File.regular?/1) end

    # init.scm also loads editor/blocks and editor/goto-address by name;
    # only the entries a package directory holds are packages
    top_level = (requires(init) ++ loads(init)) |> Enum.filter(locate)

    nested =
      Enum.flat_map(top_level, fn package -> package |> locate.() |> File.read!() |> loads() end)

    loaded = top_level ++ nested

    # the package files, without the tests beside them
    packages =
      Enum.flat_map(dirs, fn dir ->
        dir |> Path.join("**/*.scm") |> Path.wildcard() |> Enum.map(&Path.relative_to(&1, dir))
      end)
      |> Enum.reject(&String.ends_with?(&1, "-test.scm"))

    # the apps the stock boot leaves out. A user init may load one by
    # name; test_helper.exs loads them for the suite; and the ones with
    # commands reach M-x through their ;;;###autoload cookies, which the
    # harvest at the end of init.scm installs.
    opt_in =
      ~w(spreadsheet amazon doom-lite doom graphql linkedin peers movie recording substack px0 spotify title training
         ats chart decide fast-code fast-code-eval housekeeping onboarding recruiting site-app slides)
      |> Enum.map(&(&1 <> ".scm"))

    # an app nobody loads must still be reachable: a command means a cookie.
    # A file another package requires is a library, and its commands are
    # that package's to reach.
    libraries = Enum.flat_map(packages, fn pkg -> pkg |> locate.() |> File.read!() |> requires() end)

    for app <- opt_in -- libraries,
        src = File.read!(locate.(app)),
        src =~ ~r/^\(define-command /m do
      assert src =~ ~r/^;;;###autoload\n\(define-command /m,
             "#{app} defines commands but marks none with ;;;###autoload"
    end

    expected = packages -- (opt_in ++ ["calendar/calendar.scm"])
    assert Enum.sort(loaded -- expected) == [], "loaded, but not a stock package"
    assert Enum.sort(expected -- loaded) == [], "a stock package init.scm does not reach: #{inspect(Enum.sort(expected -- loaded))}"
    assert Enum.sort(opt_in -- packages) == [], "an opt-in app is missing from scheme/packages"
    assert length(loaded) == length(Enum.uniq(loaded))

    assert "agent.scm" in top_level
    refute "agent-transcript.scm" in top_level

    agent_modules = "agent.scm" |> locate.() |> File.read!() |> loads()

    # agent-fleet is the chats table, loaded by init.scm after ibuffer
    assert agent_modules == [
             "agent-permissions.scm",
             "agent-connectors.scm",
             "agent-transcript.scm",
             "agent-session.scm"
           ]

    # one file is one package: the loader stamps a module of a compound
    # package with the module's own name
    assert {:ok, entry} =
             Session.eval(~s{(catalog-entry 'function "agent-answer-question!")})

    assert entry =~ ~s{qualified-name "agent-transcript/agent-answer-question!"}
  end

  test "(load ...) resolves a relative path against the config home" do
    home = Compos.Core.home()
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
    editor = Application.app_dir(:compos_core, "priv/editor.scm")

    {elapsed, result} = :timer.tc(fn -> Session.reload_files([editor]) end)

    assert {:ok, %{files: 1, forms: forms}} = result
    assert forms > 0
    assert elapsed < 5_000_000
  end

  # Mix symlinks priv into _build, so Application.app_dir/2 and a reload
  # request name the same file with two different strings. The boot manifest
  # is keyed by one and looked up by the other. Before Session.canonical/1 the
  # two never matched, and the first reload of any file from the checkout
  # re-evaluated all of it — every `mix compos.reload` paid the whole file.
  test "the boot manifest matches a path from the source tree, not only the build symlink" do
    build = Application.app_dir(:compos_core, "priv/themes.scm")
    source = Session.canonical(build)

    refute source == build, "priv is not a symlink in this build; the test proves nothing"

    all = source |> File.read!() |> Compos.Scheme.Reader.read_all() |> length()
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

  test "changed list options reach the registered mode without resetting package state" do
    path = Path.join(System.tmp_dir!(), "zz-list-options-reload.scm")
    on_exit(fn -> File.rm(path) end)

    source = fn delay ->
      """
      (define zz-reload-list-state 0)
      (define zz-reload-list-opts (list 'filter-delay-ms #{delay}))
      (define-list-mode! "zz-reload-list-mode" zz-reload-list-opts)
      """
    end

    File.write!(path, source.(0))
    assert {:ok, _} = Session.reload_files([path])
    assert {:ok, _} = Session.eval("(set! zz-reload-list-state 7)")

    File.write!(path, source.(60))
    assert {:ok, %{forms: 2}} = Session.reload_files([path])

    assert {:ok, "(60 7)"} =
             Session.eval("""
             (list (plist-get (list-mode-opts "zz-reload-list-mode") 'filter-delay-ms)
                   zz-reload-list-state)
             """)

    assert {:ok, %{forms: 0}} = Session.reload_files([path])
  end

  test "the reload prompt completes over stdlib, bundled, and user packages" do
    home_pkg = Path.join([Compos.Core.home(), "packages"])
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

    Enum.each(String.graphemes("zz-user-pkg"), &Compos.Core.KeyDispatch.handle_key/1)
    Compos.Core.KeyDispatch.handle_key("RET")

    assert {:ok, "3"} = Session.eval("zz-user-pkg-mark")
  end
end
