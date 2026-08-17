defmodule Aimax.WritingTest do
  @moduledoc "writing-mode: editable Markdown workspace, scratch, and prose presentation."

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
        &(String.starts_with?(&1, "*writing:") or String.starts_with?(&1, "*scratch:"))
      )
      |> Enum.each(&Aimax.Core.kill_buffer/1)
    end)

    :ok
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
    writing_leaf = Enum.find(Editor.render_state().tree.children, &(&1.buffer == buf))
    assert writing_leaf.visual_line_mode == true
    assert Buffer.get_local(buf, "group") == buf
    style = Buffer.get_local(buf, "style")
    assert style =~ "--default-family:Spectral, Georgia, serif;"
    assert style =~ "--writing-measure:62ch;"
    assert Buffer.get_local(buf, "modeline-info") =~ ~r/^3 words · 1 min$/
  end

  test "count-words counts whitespace-separated words" do
    buf = fresh_buffer("wr-cw-#{System.unique_integer([:positive])}", "a b  c\nd\n")
    assert eval!(~s{(count-words "#{buf}")}) == "4"
  end

  test "word count live-updates as you type" do
    buf = fresh_buffer("wr-live-#{System.unique_integer([:positive])}", "")
    eval!(~s{(run-command "writing-mode")})
    assert Buffer.get_local(buf, "modeline-info") == "0 words"

    type("hello brave new world")

    assert :ok =
             wait_until(fn ->
               Buffer.get_local(buf, "modeline-info") == "4 words · 1 min"
             end)
  end

  test "Shift-left and Shift-right extend the region instead of changing buffers" do
    buf = fresh_buffer("wr-select-#{System.unique_integer([:positive])}.md", "abc")
    eval!(~s{(run-command "writing-mode")})
    eval!("(end-of-buffer!)")

    press(["S-<left>", "S-<left>"])
    assert Editor.current_buffer() == buf
    assert Buffer.point(buf) == 1
    assert Buffer.mark(buf) == 3

    press(["S-<right>"])
    assert Editor.current_buffer() == buf
    assert Buffer.point(buf) == 2
    assert Buffer.mark(buf) == 3
  end

  test "Alt-arrows move by word and Alt-Shift-arrows select by word" do
    buf = fresh_buffer("wr-word-#{System.unique_integer([:positive])}.md", "one two three")
    eval!(~s{(run-command "writing-mode")})
    eval!("(end-of-buffer!)")

    press(["M-<left>"])
    assert Buffer.point(buf) == 8
    press(["M-<right>"])
    assert Buffer.point(buf) == 13

    press(["M-S-<left>", "M-S-<left>"])
    assert Editor.current_buffer() == buf
    assert Buffer.point(buf) == 4
    assert Buffer.mark(buf) == 13

    press(["M-S-<right>"])
    assert Buffer.point(buf) == 7
    assert Buffer.mark(buf) == 13
  end

  test "common line and document selection chords extend the region" do
    buf =
      fresh_buffer(
        "wr-native-select-#{System.unique_integer([:positive])}.md",
        "alpha beta\ngamma delta"
      )

    eval!(~s{(run-command "writing-mode")})

    Buffer.goto(buf, 16)
    press(["s-S-<left>"])
    assert Buffer.point(buf) == 11
    assert Buffer.mark(buf) == 16

    Buffer.set_mark(buf, nil)
    Buffer.goto(buf, 16)
    press(["s-S-<right>"])
    assert Buffer.point(buf) == 22
    assert Buffer.mark(buf) == 16

    Buffer.set_mark(buf, nil)
    press(["s-S-<up>"])
    assert Buffer.point(buf) == 0
    assert Buffer.mark(buf) == 22

    Buffer.set_mark(buf, nil)
    press(["s-a"])
    assert Buffer.mark(buf) == 0
    assert Buffer.point(buf) == 22
  end

  test "disabling restores the previous look (composes with org-mode)" do
    buf = fresh_buffer("wr-org-#{System.unique_integer([:positive])}.org", "* head\nbody\n")
    eval!(~s{(set-mode! "org-mode")})
    org_style = Buffer.get_local(buf, "style")
    assert org_style =~ "--default-size:14.5px;"

    eval!(~s{(run-command "writing-mode")})
    assert Buffer.get_local(buf, "style") =~ "--default-size:17px;"

    eval!(~s{(run-command "writing-mode")})
    assert Buffer.get_local(buf, "style") == org_style
    assert Buffer.get_local(buf, "minor-modes") == []
    refute Buffer.get_local(buf, "window-class")
    refute Buffer.get_local(buf, "modeline-info")
    refute Buffer.get_local(buf, "line-numbers")
    refute Buffer.get_local(buf, "render-mode")
    refute Buffer.get_local(buf, "preview-renderer")
    refute Buffer.get_local(buf, "visual-line-mode")
    refute Buffer.get_local(buf, "writing-saved")
  end

  test "enabling writing mode opens its grouped plain scratch beside the preview" do
    buf =
      fresh_buffer(
        "wr-scratch-#{System.unique_integer([:positive])}.md",
        "# Draft\n\nMain text.\n"
      )

    scratch = "*scratch:#{buf}*"

    on_exit(fn ->
      if Buffer.exists?(scratch), do: Aimax.Core.kill_buffer(scratch)
    end)

    eval!(~s{(run-command "writing-mode")})

    assert Editor.current_buffer() == buf
    assert length(Editor.list_windows()) == 2
    assert Enum.any?(Editor.list_windows(), fn {_id, name} -> name == buf end)
    assert Enum.any?(Editor.list_windows(), fn {_id, name} -> name == scratch end)
    assert Buffer.text(scratch) == "# Scratch — #{Path.basename(buf)}\n\n"
    assert Buffer.get_local(buf, "scratch-buffer") == scratch
    assert Buffer.get_local(scratch, "scratch-owner") == buf
    assert Buffer.get_local(buf, "group") == buf
    assert Buffer.get_local(scratch, "group") == buf
    assert Buffer.get_local(scratch, "mode-name") == "text-mode"
    refute Buffer.get_local(scratch, "render-mode")
    refute Buffer.get_local(scratch, "preview-renderer")
    refute Buffer.get_local(scratch, "visual-line-mode")
    assert Buffer.get_local(scratch, "minor-modes") == ["llm-mode"]
    assert Buffer.get_local(scratch, "chat-presets") == [sym: "aimax"]
    assert eval!(~s{(buffer-llm-connector "#{scratch}")}) == ~s("codex-app-server")
    refute "llm-mode" in Buffer.get_local(buf, "minor-modes")

    # C-c s is navigation once Writing Mode has established the workspace.
    press(["C-c", "s"])
    assert Editor.current_buffer() == scratch
    assert length(Editor.list_windows()) == 2

    press(["C-c", "s"])
    assert Editor.current_buffer() == buf
    assert length(Editor.list_windows()) == 2
  end

  test "writing LLM configuration lands on the scratch only" do
    buf = fresh_buffer("wr-config-#{System.unique_integer([:positive])}.md", "Draft.\n")
    scratch = "*scratch:#{buf}*"
    on_exit(fn -> eval!(~s{(customize-set! 'writing-model "")}) end)

    eval!(~s{(customize-set! 'writing-model "openai:test-writer")})
    eval!(~s{(run-command "writing-mode")})
    assert Buffer.get_local(buf, "writing-model") == "openai:test-writer"
    assert Buffer.get_local(buf, "writing-instructions") =~ "Preserve their voice"
    refute "llm-mode" in Buffer.get_local(buf, "minor-modes")
    assert Buffer.get_local(scratch, "llm-model") == "openai:test-writer"
    assert Buffer.get_local(scratch, "writing-instructions") =~ "Preserve their voice"
    assert Buffer.get_local(scratch, "minor-modes") == ["llm-mode"]
  end

  test "writing presets are always applied and existing presets are restored" do
    buf = fresh_buffer("wr-presets-#{System.unique_integer([:positive])}.md", "Draft.\n")
    scratch = "*scratch:#{buf}*"

    on_exit(fn -> eval!("(set! writing-presets '())") end)

    eval!(~s{(buffer-set-local! "#{buf}" 'chat-presets '(project aimax))})
    eval!("(set! writing-presets '(aimax web))")
    eval!(~s{(run-command "writing-mode")})

    assert Buffer.get_local(scratch, "chat-presets") == [sym: "aimax", sym: "web", sym: "project"]

    # A live customization is rebuilt from the original document value, so a
    # preset removed from the writing setting does not linger.
    eval!("(customize-set! 'writing-presets '(research))")

    assert Buffer.get_local(scratch, "chat-presets") == [
             sym: "aimax",
             sym: "research",
             sym: "project"
           ]

    eval!(~s{(run-command "writing-mode")})
    assert Buffer.get_local(buf, "chat-presets") == [sym: "project", sym: "aimax"]
  end

  test "C-c w opens the optional companion for the writing workspace" do
    buf = fresh_buffer("wr-chat-#{System.unique_integer([:positive])}.md", "Draft.\n")
    companion = "*chat:#{buf}*"

    on_exit(fn ->
      if Buffer.exists?(companion), do: Aimax.Core.kill_buffer(companion)
    end)

    eval!(~s{(run-command "writing-mode")})
    press(["C-c", "w"])

    assert Editor.current_buffer() == companion
    assert Buffer.get_local(companion, "mode-name") == "chat-mode"
    assert Buffer.get_local(companion, "group") == buf
    assert Buffer.text(companion) =~ "companion · #{buf}"
  end

  test "customizing the measure repaints live writing buffers" do
    buf = fresh_buffer("wr-cust-#{System.unique_integer([:positive])}", "words here\n")
    eval!(~s{(run-command "writing-mode")})
    assert Buffer.get_local(buf, "style") =~ "--writing-measure:62ch;"

    eval!(~s{(customize-set! 'writing-measure "44ch")})
    assert Buffer.get_local(buf, "style") =~ "--writing-measure:44ch;"

    eval!(~s{(customize-set! 'writing-measure "62ch")})
    eval!(~s{(run-command "writing-mode")})
  end

  test "restore-minor-modes! re-runs setup idempotently (reload path)" do
    buf = fresh_buffer("wr-restore-#{System.unique_integer([:positive])}", "some prose\n")
    eval!(~s{(run-command "writing-mode")})

    eval!(~s{(restore-minor-modes! "#{buf}")})

    hooks =
      eval!(~s{(length (filter (lambda (h) (equal? (car h) "#{buf}")) *writing-hooks*))})

    assert hooks == "1"
    assert Buffer.get_local(buf, "window-class") == "writing"
    assert Buffer.get_local(buf, "modeline-info") == "2 words · 1 min"
  end
end
