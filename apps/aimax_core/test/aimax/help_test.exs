defmodule Aimax.HelpTest do
  @moduledoc "Help is a rendered markdown page: ? in a list, C-h m anywhere."

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp eval!(src) do
    {:ok, out} = Session.eval(src)
    out
  end

  setup do
    Editor.minibuffer_close()
    Editor.completion_dismiss()
    Editor.set_pending([])
    Editor.delete_other_windows()

    on_exit(fn ->
      for b <- ["*Help*", "*ibuffer*", "*zz-help*"], do: Aimax.Core.kill_buffer(b)
      Editor.delete_other_windows()
    end)

    :ok
  end

  test "? in ibuffer opens the mode's page, rendered and read-only" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*")
                    (run-command "ibuffer"))})

    press("?")

    assert Buffer.exists?("*Help*")
    text = Buffer.text("*Help*")

    # the page is markdown: a title, the mode's own words, a key table
    assert text =~ "# ibuffer-mode"
    assert text =~ "The buffer list as a dired"
    assert text =~ "| key | command | what it does |"
    assert text =~ "| `RET` | ibuffer-visit |"
    assert text =~ "Show the selected buffer in another window"

    # and it opens as a page, not as a buffer to edit
    assert {:ok, ~s{"markdown"}} = Session.eval(~s{(buffer-local "*Help*" 'render-mode)})
    assert {:ok, "#t"} = Session.eval(~s{(buffer-read-only? "*Help*")})
    assert {:ok, ~s{"help-mode"}} = Session.eval(~s{(buffer-local "*Help*" 'mode-name)})
  end

  test "C-c C-v toggles the source of a generated page, C-h m describes a plain buffer" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*"))})

    press(["C-h", "m"])
    assert Buffer.text("*Help*") =~ "# fundamental-mode"

    # the help buffer has no ".md" name — the buffer-local renderer carries it
    press(["C-c", "C-v"])
    assert {:ok, "#f"} = Session.eval(~s{(buffer-local "*Help*" 'render-mode)})
    press(["C-c", "C-v"])
    assert {:ok, ~s{"markdown"}} = Session.eval(~s{(buffer-local "*Help*" 'render-mode)})
  end

  test "C-h b lists local bindings before global ones" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*")
                    (run-command "ibuffer"))})

    press(["C-h", "b"])
    text = Buffer.text("*Help*")

    assert text =~ "## This buffer"
    assert text =~ "## Everywhere"
    assert text =~ "| `C-x C-b` | ibuffer |"

    [local, global] = [:binary.match(text, "## This buffer"), :binary.match(text, "## Everywhere")]
    assert elem(local, 0) < elem(global, 0)
  end

  test "a restored *Help* comes back rendered and read-only" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*"))})
    press(["C-h", "m"])

    # what a desktop restore does: locals are back, the mode setup re-runs
    eval!(~s{(begin (buffer-set-local! "*Help*" 'render-mode #f)
                    (buffer-set-read-only! "*Help*" #f)
                    (desktop-apply-mode! "*Help*" "help-mode"))})

    assert {:ok, ~s{"markdown"}} = Session.eval(~s{(buffer-local "*Help*" 'render-mode)})
    assert {:ok, "#t"} = Session.eval(~s{(buffer-read-only? "*Help*")})
  end
end
