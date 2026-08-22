defmodule Aimax.ModeToggleTest do
  @moduledoc """
  A mode toggles from the modeline. The modeline names the major mode; the
  expanded modeline names the minor modes. Both send "mode:NAME" through the
  one click gate, ui-command!.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, Session}

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp fresh_buffer(text) do
    name = "mode-toggle-#{System.unique_integer([:positive])}"
    {:ok, _} = Aimax.Core.create_buffer(name, text: text)
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    Editor.set_window_buffer(name)
    name
  end

  # what the click leaves in the echo area — the modeline's other half
  defp click(name, mode) do
    eval!(~s{(with-current-buffer "#{name}" (lambda () (ui-command! "mode:#{mode}" #f)))})
    Editor.render_state().echo
  end

  test "a minor mode toggles off and on, and the echo area states each result" do
    name = fresh_buffer("alpha\n")
    eval!(~s{(run-command "visual-line-mode")})
    assert eval!(~s{(minor-mode-on? "#{name}" "visual-line-mode")}) == "#t"

    assert click(name, "visual-line-mode") =~ "visual-line-mode disabled"
    assert eval!(~s{(minor-mode-on? "#{name}" "visual-line-mode")}) == "#f"

    assert click(name, "visual-line-mode") =~ "visual-line-mode enabled"
    assert eval!(~s{(minor-mode-on? "#{name}" "visual-line-mode")}) == "#t"
  end

  test "the major mode leaves for Fundamental and takes its grammar with it" do
    name = fresh_buffer("defmodule Foo do\nend\n")
    Buffer.set_local(name, "ts-lang", "elixir")
    eval!(~s{(with-current-buffer "#{name}" (lambda () (set-mode! "elixir-mode")))})
    assert Buffer.ts_highlight(name) != []

    assert click(name, "elixir-mode") =~ "elixir-mode off"
    # no mode at all: the modeline names that Fundamental
    assert eval!(~s{(buffer-local "#{name}" 'mode-name)}) == "#f"
    assert eval!(~s{(buffer-local "#{name}" 'ts-lang)}) == "#f"
    # the parser goes with the mode: no grammar, no spans
    assert Buffer.ts_highlight(name) == []
  end

  # nothing remembers the mode you left. A click on Fundamental runs
  # normal-mode, which reads the file name again — Emacs's way back.
  test "a click on Fundamental reads the file name again" do
    path = Path.join(System.tmp_dir!(), "mode-toggle-#{System.unique_integer([:positive])}.ex")
    File.write!(path, "defmodule Foo do\nend\n")
    on_exit(fn -> File.rm(path) end)

    Editor.minibuffer_close()
    Editor.delete_other_windows()
    eval!(~s{(visit "#{path}")})
    assert eval!(~s{(buffer-local "#{path}" 'mode-name)}) == ~s("elixir-mode")

    assert click(path, "elixir-mode") =~ "elixir-mode off"
    assert eval!(~s{(buffer-local "#{path}" 'mode-name)}) == "#f"

    assert click(path, "Fundamental") =~ "elixir-mode on"
    assert eval!(~s{(buffer-local "#{path}" 'mode-name)}) == ~s("elixir-mode")
    assert eval!(~s{(buffer-local "#{path}" 'ts-lang)}) == ~s("elixir")
    assert Buffer.ts_highlight(path) != []
  end

  test "a buffer with no file has no mode to derive" do
    name = fresh_buffer("alpha\n")
    assert click(name, "Fundamental") =~ "no mode for this buffer"
    assert eval!(~s{(buffer-local "#{name}" 'mode-name)}) == "#f"
  end

  test "a view mode gives the buffer back: no preview, no read-only" do
    name = fresh_buffer("# a page\n")
    eval!(~s{(begin (buffer-set-local! "#{name}" 'render-mode "markdown")
                    (buffer-set-local! "#{name}" 'preview-renderer "markdown")
                    (buffer-set-read-only! "#{name}" #t)
                    (with-current-buffer "#{name}" (lambda () (set-mode! "html-mode"))))})

    click(name, "html-mode")

    assert eval!(~s{(buffer-local "#{name}" 'render-mode)}) == "#f"
    assert eval!(~s{(buffer-local "#{name}" 'preview-renderer)}) == "#f"
    refute Buffer.read_only?(name)
  end

  test "M-x for a mode toggles it: the command that enters the mode leaves it" do
    name = fresh_buffer("defmodule Foo do\nend\n")
    eval!(~s{(with-current-buffer "#{name}" (lambda () (run-command "elixir-mode")))})
    assert eval!(~s{(buffer-local "#{name}" 'mode-name)}) == ~s("elixir-mode")
    assert eval!(~s{(buffer-local "#{name}" 'ts-lang)}) == ~s("elixir")

    eval!(~s{(with-current-buffer "#{name}" (lambda () (run-command "elixir-mode")))})
    assert eval!(~s{(buffer-local "#{name}" 'mode-name)}) == "#f"
    assert eval!(~s{(buffer-local "#{name}" 'ts-lang)}) == "#f"
    assert Buffer.ts_highlight(name) == []

    # and the same command puts it back
    eval!(~s{(with-current-buffer "#{name}" (lambda () (run-command "elixir-mode")))})
    assert eval!(~s{(buffer-local "#{name}" 'mode-name)}) == ~s("elixir-mode")
  end

  test "a command for another mode enters it, it does not leave the current one" do
    name = fresh_buffer("<p>hi</p>\n")
    eval!(~s{(with-current-buffer "#{name}" (lambda () (run-command "elixir-mode")))})

    assert click(name, "html-mode") =~ "html-mode on"
    assert eval!(~s{(buffer-local "#{name}" 'mode-name)}) == ~s("html-mode")
    assert eval!(~s{(buffer-local "#{name}" 'ts-lang)}) == ~s("html")
  end

  test "text-mode is a mode like any other, so it leaves too" do
    name = fresh_buffer("alpha\n")
    eval!(~s{(with-current-buffer "#{name}" (lambda () (set-mode! "text-mode")))})

    assert click(name, "text-mode") =~ "text-mode off"
    assert eval!(~s{(buffer-local "#{name}" 'mode-name)}) == "#f"
  end
end
