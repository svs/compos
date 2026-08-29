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
      for b <- ["*Help*", "*switch*", "*zz-help*"], do: Aimax.Core.kill_buffer(b)
      Editor.delete_other_windows()
    end)

    :ok
  end

  # `?` narrows in the switcher — every printable is the filter — so the
  # mode's page opens through C-h m there
  test "C-h m in the switcher opens the mode's page, rendered and read-only" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*")
                    (run-command "switch-to-buffer"))})

    press(["C-h", "m"])

    assert Buffer.exists?("*Help*")
    text = Buffer.text("*Help*")

    # the page is markdown: a title, the mode's own words, a key table
    assert text =~ "# switch-mode"
    assert text =~ "The buffer switcher"
    assert text =~ "| keys | command | what it does |"
    assert text =~ "| `RET` | [`switch-visit`](aimax:cmd/switch-visit) |"
    assert text =~ "Visit the selected row"

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

  test "the binding help lists local bindings before global ones" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*")
                    (run-command "switch-to-buffer"))})

    press(["C-h", "b"])
    text = Buffer.text("*Help*")

    assert text =~ "## This buffer"
    assert text =~ "## Everywhere"

    # both tables carry rows. Naming a binding here would send this red
    # for a rebinding, which is a preference and not a bug in the help.
    [this, every] = String.split(text, "## Everywhere", parts: 2)
    assert this =~ "aimax:cmd/", "the local table listed no command"
    assert every =~ "aimax:cmd/", "the global table listed no command"

    [local, global] = [
      :binary.match(text, "## This buffer"),
      :binary.match(text, "## Everywhere")
    ]

    assert elem(local, 0) < elem(global, 0)
  end

  test "C-h k describes the next key instead of running it" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*"))})

    press(["C-h", "k"])
    press(["C-x", "C-f"])

    text = Buffer.text("*Help*")
    assert text =~ "# `C-x C-f`"
    assert text =~ "**[`find-file`](aimax:cmd/find-file)** — Visit a file"
    assert text =~ "global, in every buffer"

    # the key described is a key not pressed: find-file never prompted
    assert Editor.snapshot().minibuffer == nil
    assert {:ok, ~s{"help-mode"}} = Session.eval(~s{(buffer-local "*Help*" 'mode-name)})
  end

  test "C-h k names the map that answered: a local key wins" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*")
                    (run-command "switch-to-buffer"))})

    press(["C-h", "k"])
    press("RET")

    text = Buffer.text("*Help*")
    assert text =~ "# `RET`"
    assert text =~ "switch-visit"
    assert text =~ "local to this buffer"
  end

  test "C-h k over an unbound key says so, and the capture ends" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*"))})

    press(["C-h", "k"])
    press(["C-x", "C-M-y"])

    assert Buffer.text("*Help*") =~ "No command runs this key."

    # one shot only: the next key runs its own command again
    press(["C-x", "C-f"])
    assert Editor.snapshot().minibuffer != nil
    Editor.minibuffer_close()
  end

  test "a name in a help page is a link to its source, and the link opens it" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*"))})

    press(["C-h", "k"])
    press(["C-x", "C-f"])

    # the page draws the name as a link the client can click. The page
    # describes a command, so the link asks for the command definition:
    # find-file is a function as well, and both answer to the name.
    assert Buffer.text("*Help*") =~ "**[`find-file`](aimax:cmd/find-file)**"

    # following it lands in the file that defines find-file, at the form
    eval!(~s{(preview-follow-link! (active-window) "aimax:cmd/find-file")})

    assert eval!(~s{(current-buffer)}) =~ "editor.scm"
    line = eval!(~s{(buffer-substring (point) (+ (point) 30))})
    assert line =~ "define-command \\\"find-file\\\""

    # the popup closed: the page must not cover the code it sent you to
    assert eval!(~s{(popup-open?)}) == "#f"
  end

  test "M-. in a help page opens the source of the name at point" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*"))})

    press(["C-h", "k"])
    press(["C-x", "C-f"])

    # point on the name in the page's own markdown
    eval!(~s{(goto-char! (string-index (buffer-text "*Help*") "find-file"))})
    press(["M-."])

    assert eval!(~s{(current-buffer)}) =~ "editor.scm"
  end

  test "C-h a searches the editor and renders the hits as a page" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*"))})

    press(["C-h", "a"])
    Enum.each(String.graphemes("split window"), &KeyDispatch.handle_key/1)
    press("RET")

    text = Buffer.text("*Help*")
    assert text =~ "# apropos `split window`"
    assert text =~ "## Functions"
    assert text =~ "- **`(split-window! 'h|'v [RATIO])`**"
    assert {:ok, ~s{"help-mode"}} = Session.eval(~s{(buffer-local "*Help*" 'mode-name)})

    # the M-x list carries it too — the command that finds commands was
    # the one command M-x could not find
    assert eval!(~s{(member "apropos" (command-names))}) != "#f"
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
    assert text =~ "group `hg-grp-#{n}`"
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

    assert text =~ "## [`split-window-right`](aimax:cmd/split-window-right) — a command"
    assert text =~ "bound to `C-x 3`"
    # and the page still says where the reader is
    assert text =~ "`*zz-help*` in `fundamental-mode`"
  end

  test "M-? describes a public function at point by its signature" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*")
                    (insert! "(help-doc! \\"t\\" \\"x\\")")
                    (goto-char! 3))})

    press("M-?")
    assert Buffer.text("*Help*") =~ "## [`help-doc!`](aimax:def/help-doc%21) — a function"
    assert Buffer.text("*Help*") =~ "(help-doc! TITLE MARKDOWN)"
  end

  test "M-? over a name the editor does not know falls back to the apropos hits" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*")
                    (insert! "window") (goto-char! 2))})

    press("M-?")
    text = Buffer.text("*Help*")

    assert text =~ "## `window` — the closest matches"
    assert text =~ "### Functions"
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
                    (run-command "switch-to-buffer"))})

    press("M-?")
    text = Buffer.text("*Help*")

    assert text =~ "# Here"
    assert text =~ "## switch-mode"
    assert text =~ "| `RET` | [`switch-visit`](aimax:cmd/switch-visit) |"
    assert {:ok, ~s{"help-mode"}} = Session.eval(~s{(buffer-local "*Help*" 'mode-name)})
  end

  test "M-? inside *Help* asks about the buffer the reader came from" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*")
                    (run-command "switch-to-buffer"))})

    press("M-?")
    press("M-?")

    assert Buffer.text("*Help*") =~ "## switch-mode"
    refute Buffer.text("*Help*") =~ "in `help-mode`"
  end

  # substring-bytes floors both ends to a character boundary, so one byte
  # of an em dash comes back empty — and string-index rejects an empty
  # pattern. M-? over prose used to abort the whole command here.
  # A mode with no doc still gets its key table, so the gap is invisible
  # until a reader presses M-? and finds keys with nothing saying what the
  # mode is for. Nineteen modes drifted that way before anyone noticed.
  # A preview is one rendered document in an iframe: point moves inside it
  # and nothing on screen changes. Every key that moves through a buffer
  # has to scroll the page instead, or a help page longer than the window
  # is unreadable from the keyboard.
  defp ctop(buf), do: find_ctop(Editor.render_state().tree, buf)

  defp find_ctop(%{type: :leaf, buffer: b} = leaf, b), do: Map.get(leaf, :ctop, 0)
  defp find_ctop(%{type: :leaf}, _b), do: nil

  defp find_ctop(%{type: :split, children: [a, b]}, buf),
    do: find_ctop(a, buf) || find_ctop(b, buf)

  # A writable preview takes edits. A read-only HTML page remains a reader.
  test "the motion keys move point in the Help page, not the page itself" do
    eval!(~s{(begin (buffer-create "*zz-help*") (switch-to-buffer! "*zz-help*"))})
    press(["C-h", "b"])

    assert {:ok, ~s{"markdown"}} = Session.eval(~s{(buffer-local "*Help*" 'render-mode)})
    assert eval!(~s{(current-buffer)}) == ~s{"*Help*"}
    assert ctop("*Help*") == 0

    point = eval!(~s{(point)})
    press("<down>")
    assert eval!(~s{(point)}) != point
    assert ctop("*Help*") == 0
  end

  test "the scroll keys move an html preview page instead of point" do
    eval!(~s{(begin (buffer-create "*zz-html*") (switch-to-buffer! "*zz-html*")
                    (insert! "<h1>Hi</h1>")
                    (buffer-set-read-only! "*zz-html*" #t)
                    (buffer-set-local! "*zz-html*" 'render-mode "html"))})

    assert ctop("*zz-html*") == 0

    # the down arrow scrolls the page, and point stays where it was
    point = eval!(~s{(point)})
    press("<down>")
    down = ctop("*zz-html*")
    assert down > 0, "<down> did not scroll the preview"
    assert eval!(~s{(point)}) == point

    # a page key moves further than a line key
    press("<next>")
    assert ctop("*zz-html*") > down

    # and it goes back up, never past the top
    press(["M-<", "M-<"])
    assert ctop("*zz-html*") == 0
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
