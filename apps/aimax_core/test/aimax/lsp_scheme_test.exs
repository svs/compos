defmodule Aimax.LSPSchemeTest do
  @moduledoc """
  packages/lsp.scm: registry, auto-attach through a mode hook, the
  diagnostics pipeline into overlays/modeline/list, and next/prev
  motion — against the fake server, on a real file in a temp project.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, LSP, Session}

  @fixture Path.expand("../support/fake_lsp_server.exs", __DIR__)

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp wait_until(fun, tries \\ 300) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true ->
        Process.sleep(20)
        wait_until(fun, tries - 1)
    end
  end

  # a temp git project with one file; a fake server registered for a
  # fresh synthetic mode, so real registrations stay untouched
  defp scene!(tag, text) do
    root = Path.join(System.tmp_dir!(), "lsp-proj-#{tag}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".git"))
    path = Path.join(root, "main.lspt")
    File.write!(path, text)

    name = "fake#{tag}"
    mode = "lspt#{tag}-mode"

    on_exit(fn ->
      case LSP.parse_id("#{name}@#{root}") do
        {n, r} -> LSP.stop(n, r)
        _ -> :ok
      end

      if Buffer.exists?(path), do: Aimax.Core.kill_buffer(path)
      File.rm_rf!(root)
    end)

    eval!("""
    (begin
      (define-mode "#{mode}" (lambda () #t))
      (lsp-register! "#{name}"
        (list 'command "elixir" 'args (list "#{@fixture}")
              'language "x" 'modes (list "#{mode}"))))
    """)

    %{root: root, path: path, name: name, mode: mode, id: "#{name}@#{root}"}
  end

  defp visit!(sc) do
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    eval!(~s{(begin (visit "#{sc.path}") (set-mode! "#{sc.mode}"))})
  end

  test "a visited project file attaches, gets overlays, modeline, and motion" do
    sc = scene!("a", "x WARNME y\n")
    visit!(sc)

    assert eval!(~s{(minor-mode-on? "#{sc.path}" "lsp-mode")}) == "#t"
    assert eval!(~s{(buffer-local "#{sc.path}" 'lsp-server)}) == ~s{"#{sc.id}"}

    wait_until(fn -> eval!(~s{(buffer-local "#{sc.path}" 'lsp-diagnostics)}) != "#f" end)

    assert eval!(~s{(buffer-overlays "#{sc.path}")}) == ~S{((2 8 "lsp-warning"))}
    assert eval!(~s{(buffer-local "#{sc.path}" 'modeline-info)}) == ~s{"#{sc.name} ⚠1"}

    eval!(~s{(run-command "lsp-next-diagnostic")})
    assert Buffer.point(sc.path) == 2
    assert Editor.snapshot().echo =~ "warn me not"

    eval!(~s{(run-command "lsp-show-diagnostic")})
    assert Editor.snapshot().echo =~ "warning"
  end

  test "an edit round-trips: new diagnostics repaint the overlays" do
    sc = scene!("b", "clean\n")
    visit!(sc)

    wait_until(fn -> eval!(~s{(buffer-local "#{sc.path}" 'lsp-diagnostics)}) == "()" end)

    :ok = Buffer.insert_at(sc.path, 0, "WARNME ", source: :editor)

    wait_until(fn ->
      eval!(~s{(buffer-overlays "#{sc.path}")}) == ~S{((0 6 "lsp-warning"))}
    end)
  end

  test "the diagnostics list shows rows and the defcustom disables attach" do
    sc = scene!("c", "a WARNME b\n")
    visit!(sc)
    wait_until(fn -> eval!(~s{(buffer-local "#{sc.path}" 'lsp-diagnostics)}) != "#f" end)

    eval!(~s{(run-command "lsp-diagnostics-list")})
    assert eval!(~s{(buffer-text "*diagnostics*")}) =~ "warn me not"

    # opt out: a fresh scene must not attach
    eval!("(set! lsp-auto-start #f)")
    sc2 = scene!("c2", "x WARNME\n")
    visit!(sc2)
    assert eval!(~s{(minor-mode-on? "#{sc2.path}" "lsp-mode")}) == "#f"
    eval!("(set! lsp-auto-start #t)")
  end

  test "teardown closes the doc and clears the paint" do
    sc = scene!("d", "z WARNME\n")
    visit!(sc)
    wait_until(fn -> eval!(~s{(buffer-local "#{sc.path}" 'lsp-diagnostics)}) != "#f" end)

    eval!(~s{(disable-minor-mode! "#{sc.path}" "lsp-mode")})
    assert eval!(~s{(buffer-overlays "#{sc.path}")}) == "()"
    assert eval!(~s{(buffer-local "#{sc.path}" 'modeline-info)}) == "#f"
  end
end
