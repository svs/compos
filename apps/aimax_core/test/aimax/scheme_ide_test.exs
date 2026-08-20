defmodule Aimax.SchemeIdeTest do
  @moduledoc """
  scheme-ide.scm: the editor answering for its own dialect — definition
  across buffers and source files, primitive docs, and completion over
  the catalog. Driven through KeyDispatch, the GUI's path.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp scheme_buffer(text) do
    name = "/tmp/scheme-ide-#{System.unique_integer([:positive])}.scm"
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    Editor.set_window_buffer(name)
    :ok = Buffer.append(name, text, source: :editor)
    Buffer.goto(name, 0)
    eval!(~s{(with-current-buffer "#{name}" (lambda () (set-mode! "scheme-mode")))})
    on_exit(fn -> if Buffer.exists?(name), do: Aimax.Core.kill_buffer(name) end)
    name
  end

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    :ok
  end

  test "find-def reaches the bundled source and the catalog's packages" do
    assert eval!(~S{(car (cdr (scheme-ide--find-def "kill-region-1")))}) =~ "editor.scm"
    assert eval!(~S{(car (cdr (scheme-ide--find-def "paredit-in-scheme-mode")))}) =~
             "paredit.scm"

    assert eval!(~S{(scheme-ide--find-def "zz-no-such-name-9x9")}) == "#f"
  end

  test "M-. jumps to a definition in the buffer; M-, returns" do
    buf = scheme_buffer("(define (zz-here x) x)\n(zz-here 1)\n")

    Buffer.goto(buf, 24)
    press(["M-."])
    assert Buffer.point(buf) == 0
    assert Editor.snapshot().echo =~ "Definition of zz-here"

    press(["M-,"])
    assert Buffer.point(buf) == 24
  end

  test "M-. on a primitive echoes its doc instead of jumping" do
    buf = scheme_buffer("(buffer-text b)\n")

    Buffer.goto(buf, 3)
    press(["M-."])
    assert Buffer.point(buf) == 3
    assert Editor.snapshot().echo =~ "is a primitive"
  end

  test "C-c C-d echoes a one-line doc" do
    buf = scheme_buffer("(goto-char! 0)\n")

    Buffer.goto(buf, 2)
    press(["C-c", "C-d"])
    assert Editor.snapshot().echo =~ "(goto-char! POS)"
    assert Buffer.text(buf) == "(goto-char! 0)\n"
  end

  test "completion offers primitives and catalog names" do
    buf = scheme_buffer("(buffer-te")

    Buffer.goto(buf, 10)
    press(["C-M-i"])

    comp = Editor.render_state().completion
    assert comp != nil
    labels = Enum.map(comp.candidates, & &1.label)
    assert "buffer-text" in labels
    press(["C-g"])
  end

  test "the squiggle check is quiet without the scheme grammar" do
    buf = scheme_buffer("(unbalanced\n")
    eval!(~s{(scheme-ide--check! "#{buf}")})
    refute eval!(~s{(buffer-overlays "#{buf}")}) =~ "scheme-err"
  end
end
