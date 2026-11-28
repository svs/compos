defmodule Compos.EditorIntegrationTest do
  @moduledoc """
  The one suite that drives the real, booted editor. Every other Scheme
  test checks data structures directly; this one proves the pieces meet:
  boot, key dispatch, self-insert, windows, the minibuffer with M-x, major
  modes, and a file round trip through visit, edit and save.

  It uses the stock global bindings (C-x 2, C-x 1, C-x o, M-x, C-x C-s),
  which the per-run test home leaves at their defaults. Keep it small:
  a new check belongs here only when no data-level test can catch it.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.{Editor, KeyDispatch, Session}

  @buf "*zz-integration*"

  setup do
    previous = Editor.last_active_frame()
    {:ok, frame} = Editor.attach_frame(nil)
    {:ok, _} = Session.eval(~s|(test-buffer! "#{@buf}" "") (delete-other-windows!) (switch-to-buffer-here! "#{@buf}")|, frame)

    on_exit(fn ->
      Session.eval(~s|(when (buffer-known? "#{@buf}") (buffer-kill! "#{@buf}"))|, frame)
      Editor.delete_frame(frame)
      Editor.select_frame(previous)
    end)

    %{frame: frame}
  end

  defp eval!(frame, code) do
    assert {:ok, value} = Session.eval(code, frame)
    value
  end

  defp keys(frame, keys), do: Enum.each(keys, &KeyDispatch.handle_key(frame, &1))

  defp type(frame, text), do: keys(frame, String.graphemes(text))

  test "the editor boots with its core commands bound", %{frame: frame} do
    for {key, command} <- [
          {"C-x 2", "split-window-below"},
          {"C-x 1", "delete-other-windows"},
          {"M-x", "execute-extended-command"},
          {"C-x C-s", "save-buffer"}
        ] do
      assert eval!(frame, ~s|(lookup-key "global" "#{key}")|) == ~s|"#{command}"|
    end
  end

  test "typed keys insert text and edit keys change it", %{frame: frame} do
    type(frame, "hello")
    assert eval!(frame, ~s|(buffer-text "#{@buf}")|) == ~s|"hello"|

    keys(frame, ["DEL", "DEL"])
    assert eval!(frame, ~s|(buffer-text "#{@buf}")|) == ~s|"hel"|
    assert eval!(frame, ~s|(buffer-point "#{@buf}")|) == "3"
  end

  test "C-x 2 splits the pane, C-x o moves, C-x 1 joins", %{frame: frame} do
    assert eval!(frame, "(length (window-list))") == "1"
    first = eval!(frame, "(active-window)")

    keys(frame, ["C-x", "2"])
    assert eval!(frame, "(length (window-list))") == "2"

    keys(frame, ["C-x", "o"])
    refute eval!(frame, "(active-window)") == first

    keys(frame, ["C-x", "1"])
    assert eval!(frame, "(length (window-list))") == "1"
  end

  test "M-x reads a command in the minibuffer and runs it", %{frame: frame} do
    eval!(frame, ~s|(define zz-integration-ran #f)
                   (define-command "zz-integration-ping" (lambda () (set! zz-integration-ran #t)))|)

    keys(frame, ["M-x"])
    assert eval!(frame, "(minibuffer-active?)") == "#t"

    type(frame, "zz-integration-ping")
    keys(frame, ["RET"])

    assert eval!(frame, "(minibuffer-active?)") == "#f"
    assert eval!(frame, "zz-integration-ran") == "#t"
  after
    Session.eval("(when (minibuffer-active?) (run-command \"keyboard-quit\"))", frame)
  end

  test "a file opens in the mode auto-mode-alist names, edits, and saves with C-x C-s", %{frame: frame} do
    dir = Path.join(System.tmp_dir!(), "compos-integration-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "note.txt")
    File.write!(path, "Title\n")

    try do
      eval!(frame, ~s|(switch-to-buffer-here! (visit "#{path}" #f))|)
      assert eval!(frame, ~s|(buffer-derived-mode? "#{path}" "text-mode")|) == "#t"

      keys(frame, ["M->"])
      type(frame, "body")
      assert eval!(frame, ~s|(buffer-modified? "#{path}")|) == "#t"

      keys(frame, ["C-x", "C-s"])
      assert eval!(frame, ~s|(buffer-modified? "#{path}")|) == "#f"
      assert File.read!(path) == "Title\nbody"
    after
      Session.eval(~s|(when (buffer-known? "#{path}") (buffer-kill! "#{path}"))|, frame)
      File.rm_rf!(dir)
    end
  end
end
