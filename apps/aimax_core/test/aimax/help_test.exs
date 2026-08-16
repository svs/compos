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

  test "C-h a searches the editor and renders the hits as a page" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*"))})

    press(["C-h", "a"])
    Enum.each(String.graphemes("split window"), &KeyDispatch.handle_key/1)
    press("RET")

    text = Buffer.text("*Help*")
    assert text =~ "# apropos `split window`"
    assert text =~ "| kind | name | call it | owner | effects | what it does |"
    assert text =~ "| function | `split-window!` |"
    assert {:ok, ~s{"help-mode"}} = Session.eval(~s{(buffer-local "*Help*" 'mode-name)})

    # the M-x list carries it too — the command that finds commands was
    # the one command M-x could not find
    assert eval!(~s{(member "apropos" (command-names))}) != "#f"
  end

  test "the apropos page names each hit's kind and keeps a docstring on one row" do
    eval!(~s{(begin (define-command "zz-apr" "First line.\nSecond | line." (lambda () #t))
                    (apropos-page "zz-apr"))})

    text = Buffer.text("*Help*")
    assert text =~
             "| command | `zz-apr` | `M-x` | user | unknown | First line. Second \\| line. |"
  end

  test "the component gallery renders every registered example" do
    eval!(~s{(run-command "component-gallery")})

    assert {:ok, ~s{"blocks"}} =
             Session.eval(~s{(buffer-local "*Components*" 'render-mode)})

    blocks = eval!(~s{(buffer-local "*Components*" 'render-blocks)})
    assert blocks =~ "ui/card"
    assert blocks =~ "c-badge"
    refute blocks =~ "error"
  end

  test "M-? names the buffer's group beside its modes" do
    n = System.unique_integer([:positive])
    b = "*hg-#{n}*"

    eval!("""
    (begin (buffer-create "#{b}")
           (switch-to-buffer! "#{b}")
           (buffer-set-local! "#{b}" 'group "hg-grp-#{n}")
           (group-meta-set! "hg-grp-#{n}" "where the help test lives"))
    """)

    press("M-?")
    text = Buffer.text("*Help*")
    assert text =~ "Group: `hg-grp-#{n}`"
    assert text =~ "where the help test lives"
    press("q")

    # a minor mode is a section with its doc, not a bare name
    eval!(~s{(begin (switch-to-buffer! "#{b}")
                    (buffer-set-local! "#{b}" 'minor-modes '("llm-mode")))})
    press("M-?")
    text = Buffer.text("*Help*")
    assert text =~ "## llm-mode (minor)"
    assert text =~ "In-buffer LLM interaction"
    press("q")
    eval!(~s{(begin (buffer-kill! "#{b}") (buffer-kill! "*chat:hg-grp-#{n}*") #t)})
  end

  test "M-? describes the command named at point, with the key that runs it" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*")
                    (insert! "  (run-command \\"split-window-right\\")")
                    (goto-char! 18))})

    press("M-?")
    text = Buffer.text("*Help*")

    assert text =~ "## `split-window-right` — a command"
    assert text =~ "Bound to `C-x 3`"
    # and the page still says where the reader is
    assert text =~ "Buffer `*zz-help*` in `fundamental-mode`."
  end

  test "M-? describes a public function at point by its signature" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*")
                    (insert! "(help-doc! \\"t\\" \\"x\\")")
                    (goto-char! 3))})

    press("M-?")
    assert Buffer.text("*Help*") =~ "## `help-doc!` — a function"
    assert Buffer.text("*Help*") =~ "(help-doc! TITLE MARKDOWN)"
  end

  test "M-? over a name the editor does not know falls back to the apropos hits" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*")
                    (insert! "window") (goto-char! 2))})

    press("M-?")
    text = Buffer.text("*Help*")

    assert text =~ "## `window` — the closest matches"
    assert text =~ "| kind | name | call it | owner | effects | what it does |"
  end

  test "M-? over prose says nothing about it and describes the buffer instead" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*")
                    (insert! "Unstaged") (goto-char! 3))})

    press("M-?")
    text = Buffer.text("*Help*")

    # no heading that only reports a dead end
    refute text =~ "Unstaged"
    assert text =~ "# Here"
    assert text =~ "## Keys in this buffer"
  end

  test "M-? with no name at point still shows the buffer, its mode and its keys" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*")
                    (run-command "ibuffer"))})

    press("M-?")
    text = Buffer.text("*Help*")

    assert text =~ "# Here"
    assert text =~ "## ibuffer-mode"
    assert text =~ "| `RET` | ibuffer-visit |"
    assert {:ok, ~s{"help-mode"}} = Session.eval(~s{(buffer-local "*Help*" 'mode-name)})
  end

  test "M-? inside *Help* asks about the buffer the reader came from" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*")
                    (run-command "ibuffer"))})

    press("M-?")
    press("M-?")

    assert Buffer.text("*Help*") =~ "## ibuffer-mode"
    refute Buffer.text("*Help*") =~ "in `help-mode`"
  end

  test "symbol-at-point reads the name around point, and stops at the edges" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*")
                    (insert! "a (split-window! 2) b"))})

    # inside the name
    assert eval!(~s{(begin (goto-char! 7) (symbol-at-point))}) == ~s{"split-window!"}
    # just after its last character — Emacs answers here too
    assert eval!(~s{(begin (goto-char! 16) (symbol-at-point))}) == ~s{"split-window!"}
    # on the space before it
    assert eval!(~s{(begin (goto-char! 2) (symbol-at-point))}) == "#f"
  end

  # substring-bytes floors both ends to a character boundary, so one byte
  # of an em dash comes back empty — and string-index rejects an empty
  # pattern. M-? over prose used to abort the whole command here.
  test "symbol-at-point survives a point inside a multi-byte character" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*")
                    (insert! "a — b"))})

    for p <- 0..7 do
      assert {:ok, _} = Session.eval(~s{(begin (goto-char! #{p}) (symbol-at-point))})
    end
  end

  # A mode with no doc still gets its key table, so the gap is invisible
  # until a reader presses M-? and finds keys with nothing saying what the
  # mode is for. Nineteen modes drifted that way before anyone noticed.
  test "every mode says what it is for" do
    undocumented =
      eval!(~s{(filter (lambda (m) (not (mode-doc m))) (map car *mode-setups*))})

    assert undocumented == "()",
           "these modes call define-mode but never mode-doc!: #{undocumented}"
  end

  # A preview is one rendered document in an iframe: point moves inside it
  # and nothing on screen changes. Every key that moves through a buffer
  # has to scroll the page instead, or a help page longer than the window
  # is unreadable from the keyboard.
  defp ctop(buf), do: find_ctop(Editor.render_state().tree, buf)

  defp find_ctop(%{type: :leaf, buffer: b} = leaf, b), do: Map.get(leaf, :ctop, 0)
  defp find_ctop(%{type: :leaf}, _b), do: nil

  defp find_ctop(%{type: :split, children: [a, b]}, buf),
    do: find_ctop(a, buf) || find_ctop(b, buf)

  test "the scroll keys move a preview page instead of point" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*"))})
    press(["C-h", "b"])

    assert {:ok, ~s{"markdown"}} = Session.eval(~s{(buffer-local "*Help*" 'render-mode)})
    assert eval!(~s{(current-buffer)}) == ~s{"*Help*"}
    assert ctop("*Help*") == 0

    # the down arrow scrolls the page, and point stays where it was
    point = eval!(~s{(point)})
    press("<down>")
    down = ctop("*Help*")
    assert down > 0, "<down> did not scroll the preview"
    assert eval!(~s{(point)}) == point

    # a page key moves further than a line key
    press("<next>")
    assert ctop("*Help*") > down

    # and it goes back up, never past the top
    press(["M-<", "M-<"])
    assert ctop("*Help*") == 0
  end

  test "the scroll keys still move point in an ordinary buffer" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*")
                    (insert! "one\\ntwo\\nthree") (goto-char! 0))})

    press("<down>")
    assert eval!(~s{(point)}) != "0"
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
