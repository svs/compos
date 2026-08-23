defmodule Aimax.WritingTest do
  @moduledoc """
  The writing bridge: what only the Elixir side can answer.

  writing.scm is Scheme and its tests are Scheme —
  priv/tests/writing-test.scm covers the look, the workspace, the
  selection keymap, the presets, the measure and the restore path. What is
  left here is the render tree carrying visual-line-mode, and the one
  delivery Scheme cannot reach: typing updates the word count through the
  Reactor, debounced and only while the buffer is visible.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(str), do: str |> String.graphemes() |> press()

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp fresh_buffer(name, text) do
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    Editor.set_window_buffer(name)
    :ok = Buffer.append(name, text, source: :editor)
    name
  end

  defp wait_until(fun, tries \\ 30) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        :timeout

      true ->
        Process.sleep(30)
        wait_until(fun, tries - 1)
    end
  end

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])

    on_exit(fn ->
      Editor.minibuffer_close()

      {:ok, _} =
        Session.eval("""
        (for-each
          (lambda (b)
            (when (minor-mode-on? b "writing-mode")
              (disable-minor-mode! b "writing-mode")))
          (buffer-list))
        """)

      Aimax.Core.list_buffers()
      |> Enum.filter(
        &(String.starts_with?(&1, "*writing:") or String.starts_with?(&1, "*scratch:") or
            String.starts_with?(&1, "*chat:"))
      )
      |> Enum.each(&Aimax.Core.kill_buffer/1)
    end)

    :ok
  end

  test "M-x visual-line-mode toggles visual-row motion for any buffer" do
    buf = fresh_buffer("vl-mx-#{System.unique_integer([:positive])}", "one long line\n")

    press(["M-x"])
    type("visual-line-mode")
    press(["RET"])

    assert Buffer.get_local(buf, "visual-line-mode") == true
    assert "visual-line-mode" in Buffer.get_local(buf, "minor-modes")
    tree = Editor.render_state().tree
    leaf = if tree.type == :leaf, do: tree, else: Enum.find(tree.children, &(&1.buffer == buf))
    assert leaf.visual_line_mode == true

    press(["M-x"])
    type("visual-line-mode")
    press(["RET"])

    refute Buffer.get_local(buf, "visual-line-mode")
    refute "visual-line-mode" in Buffer.get_local(buf, "minor-modes")
  end


  test "M-x writing-mode enables the centered prose look" do
    buf = fresh_buffer("wr-mx-#{System.unique_integer([:positive])}", "one two three\n")

    press(["M-x"])
    type("writing-mode")
    press(["RET"])

    assert Buffer.get_local(buf, "minor-modes") == ["writing-mode"]
    assert Buffer.get_local(buf, "line-numbers") == "off"
    assert Buffer.get_local(buf, "window-class") == "writing"
    assert Buffer.get_local(buf, "render-mode") == "markdown"
    assert Buffer.get_local(buf, "preview-renderer") == "markdown"
    assert Buffer.get_local(buf, "visual-line-mode") == true
    # writing-mode is presentation only: the panes and the group belong to
    # writing-layout, which M-x write turns on
    tree = Editor.render_state().tree
    leaf = if tree.type == :leaf, do: tree, else: Enum.find(tree.children, &(&1.buffer == buf))
    assert leaf.visual_line_mode == true
    refute Buffer.get_local(buf, "group")
    style = Buffer.get_local(buf, "style")
    assert style =~ "--default-family:Spectral, Georgia, serif;"
    assert style =~ "--writing-measure:62ch;"
    assert Buffer.get_local(buf, "modeline-info") =~ ~r/^3 words · 1 min$/
  end


  test "word count live-updates as you type" do
    buf = fresh_buffer("wr-live-#{System.unique_integer([:positive])}", "")
    eval!(~s{(run-command "write")})
    assert Buffer.get_local(buf, "modeline-info") == "0 words"

    type("hello brave new world")

    assert :ok =
             wait_until(fn ->
               Buffer.get_local(buf, "modeline-info") == "4 words · 1 min"
             end)
  end


end
