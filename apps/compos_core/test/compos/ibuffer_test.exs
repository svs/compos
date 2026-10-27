defmodule Compos.IbufferTest do
  @moduledoc "The traditional ibuffer table remains separate from the modal switcher."

  use Compos.Case

  alias Compos.Core.{Buffer, Editor, Session}

  setup do
    Editor.minibuffer_close()
    Editor.completion_dismiss()
    Editor.set_pending([])
    Editor.delete_other_windows()
    Editor.set_window_cols(%{})

    on_exit(fn ->
      for name <- [
            "*ibuffer*",
            "*switch*",
            "*zz-ibuffer-a*",
            "*zz-ibuffer-b*",
            "*zz-ibuffer-c*",
            "*zz-collected-one*",
            "*zz-collected-two*",
            "*zz-unrelated*"
          ] do
        Compos.Core.kill_buffer(name)
      end

      Session.eval(~s{(begin
        (local-unset-key* (minibuffer-buffer) "<f9>")
        (local-unset-key* (minibuffer-buffer) "<f6>"))})

      Editor.delete_other_windows()
      Editor.set_window_cols(%{})
    end)

    :ok
  end

  test "the modal switcher remains available and C-x C-b opens ibuffer" do
    eval!(~s{(begin
      (buffer-create "*zz-ibuffer-a*")
      (switch-to-buffer! "*zz-ibuffer-a*"))})

    eval!(~s{(run-command "switch-to-buffer")})
    assert Editor.current_buffer() == "*switch*"
    assert eval!(~s{(buffer-local "*switch*" 'mode-name)}) == ~s{"switch-mode"}

    press("C-g")
    press(["C-x", "C-b"])
    assert Editor.current_buffer() == "*ibuffer*"
    assert eval!(~s{(buffer-local "*ibuffer*" 'mode-name)}) == ~s{"ibuffer-mode"}
  end

  test "ibuffer renders the full management columns in a wide window" do
    eval!(~s{(begin
      (buffer-create "*zz-ibuffer-a*")
      (switch-to-buffer! "*zz-ibuffer-a*")
      (run-command "ibuffer"))})

    Editor.set_window_cols(%{Editor.active_window() => 140})
    eval!("(window-config-changed!)")

    assert eval!(~s{(plist-get (list-active-layout "*ibuffer*") 'name)}) == "wide"

    text = Buffer.text("*ibuffer*")
    [headline, heading | _rows] = String.split(text, "\n")
    # the head is one line: the counts and the chips; no key bar, no label row
    assert headline =~ ~r/^Buffers  \d+ buffers/
    assert headline =~ "GROUP group · mode · directory · none   SORT name · recent · size   ? keys"
    refute text =~ "SIZE"
    refute text =~ "d flag"
    # a heading names itself in upper case, rules across, and ends with
    # its tally; a column too narrow for the kind word drops that first
    assert heading =~ ~r/^\s+▾  [A-Z0-9].*─+ \d+ buffers?$/
    # every field is a column: the size, then the mode
    assert text =~ ~r/\*zz-ibuffer-a\*\s+0  Fundamental/
  end

  test "ibuffer uses a dense name and details table in its popup width" do
    eval!(~s{(begin
      (buffer-create "*zz-ibuffer-a*")
      (buffer-set-local! "*zz-ibuffer-a*" 'mode-name "example-mode")
      (switch-to-buffer! "*zz-ibuffer-a*")
      (run-command "ibuffer"))})

    Editor.set_window_cols(%{Editor.active_window() => 79})
    eval!("(window-config-changed!)")

    assert eval!(~s{(plist-get (list-active-layout "*ibuffer*") 'name)}) == "compact"

    text = Buffer.text("*ibuffer*")
    # the head is one line, and the rows start under it
    [headline, heading | _rows] = String.split(text, "\n")
    refute text =~ "RET visit"

    assert headline =~
             ~r/^Buffers  \d+ buffers( · \d+ modified)?( · \S+)? · by group · name   \? keys$/

    assert heading =~ ~r/^\s+▾  \S/
    # compact omits the rule lines; a group section's "── name" is not one
    refute text =~ ~r/^\s*─+\s*$/m
    refute text =~ "SIZE"
    # the size and the mode are columns of their own
    assert text =~ ~r/\*zz-ibuffer-a\*\s+0  example/
  end

  test "ibuffer groups rows under switcher-style headings" do
    suffix = System.unique_integer([:positive])
    current = "zz-ibuffer-current-#{suffix}"
    foreign = "zz-ibuffer-foreign-#{suffix}"

    on_exit(fn ->
      Session.eval(~s{(begin
        (group-record-delete! "#{current}")
        (group-record-delete! "#{foreign}"))})
    end)

    eval!(~s{(begin
      (buffer-create "*zz-ibuffer-a*")
      (buffer-create "*zz-ibuffer-b*")
      (buffer-create "*zz-ibuffer-c*")
      (let ((current (group-record-create! "#{current}"))
            (foreign (group-record-create! "#{foreign}")))
        (buffer-add-group! "*zz-ibuffer-a*" current)
        (buffer-add-group! "*zz-ibuffer-a*" foreign)
        (buffer-add-group! "*zz-ibuffer-b*" foreign)
        (set-frame-local! 'current-group current))
      (switch-to-buffer! "*zz-ibuffer-a*")
      (run-command "ibuffer")
      (list-set-filters! "*ibuffer*" (list (list "match" "zz-ibuffer-"))))})

    text = Buffer.text("*ibuffer*")
    # every section wears the name of its group, in the heading's own
    # register: upper case, with the kind of section it is beside it
    current_head = String.upcase(current)
    foreign_head = String.upcase(foreign)
    assert text =~ "▾  #{current_head} "
    assert text =~ "▾  #{foreign_head} "
    assert text =~ "▾  UNGROUPED "
    assert text =~ ~r/^3 buffers · by group · name/m
    refute text =~ "in this group"
    assert :binary.match(text, current_head) < :binary.match(text, "*zz-ibuffer-a*")
    assert :binary.match(text, "*zz-ibuffer-a*") < :binary.match(text, foreign_head)
    assert :binary.match(text, foreign_head) < :binary.match(text, "*zz-ibuffer-b*")
    assert :binary.match(text, "*zz-ibuffer-b*") < :binary.match(text, "UNGROUPED")
    assert :binary.match(text, "UNGROUPED") < :binary.match(text, "*zz-ibuffer-c*")
    assert length(:binary.matches(text, "*zz-ibuffer-a*")) == 1

    # The headings are labels. The live key path skips them in both directions.
    assert eval!("(ibuffer-current)") == ~s{"*zz-ibuffer-a*"}
    press("n")
    assert eval!("(ibuffer-current)") == ~s{"*zz-ibuffer-b*"}
    press("n")
    assert eval!("(ibuffer-current)") == ~s{"*zz-ibuffer-c*"}
    press("p")
    assert eval!("(ibuffer-current)") == ~s{"*zz-ibuffer-b*"}

    eval!(~s{(begin
      (list-filter-clear! "*ibuffer*")
      (ibuffer-filter-push! (list "match" "zz-ibuffer-b")))})

    narrowed = Buffer.text("*ibuffer*")
    refute narrowed =~ "in this group"
    assert narrowed =~ "▾  #{foreign_head}"
    refute narrowed =~ "UNGROUPED"
  end

  test "ibuffer sorts buffer rows by name instead of MRU" do
    eval!(~s{(begin
      (buffer-create "*zz-ibuffer-a*")
      (buffer-create "*zz-ibuffer-b*")
      (set-frame-local! 'current-group #f)
      (switch-to-buffer! "*zz-ibuffer-a*")
      (switch-to-buffer! "*zz-ibuffer-b*")
      (run-command "ibuffer")
      (list-set-filters! "*ibuffer*" (list (list "match" "zz-ibuffer-"))))})

    text = Buffer.text("*ibuffer*")
    assert text =~ "by group · name"
    assert :binary.match(text, "*zz-ibuffer-a*") < :binary.match(text, "*zz-ibuffer-b*")
  end

  test "a scoped ibuffer opens as an ordinary buffer, and q restores the covered layout" do
    eval!(~s{(begin
      (buffer-create "*zz-ibuffer-a*")
      (buffer-create "*zz-ibuffer-b*")
      (buffer-create "*zz-collected-one*")
      (buffer-create "*zz-unrelated*")
      (switch-to-buffer! "*zz-ibuffer-a*")
      (split-window! 'h 0.61)
      (other-window!)
      (switch-to-buffer! "*zz-ibuffer-b*")
      (split-window! 'v 0.43)
      (other-window!)
      (switch-to-buffer! "*zz-unrelated*"))})

    # the buffers in the windows, in order: display-buffer picks the window
    # the table borrows, and q puts that window's buffer back
    tree = fn -> eval!("(map cadr (window-list))") end
    before = tree.()

    eval!(~s{(ibuffer-open-buffers! (list "*zz-collected-one*"))})
    assert Editor.current_buffer() == "*ibuffer*"
    # The work window holds the listing; the popup holds a separate copy.
    assert eval!("(float-open?)") == "#f"
    refute tree.() == before
    assert eval!("(listing-preview-owner)") == "#f"
    refute eval!("(float-buffer)") == ~s{"*zz-collected-one*"}

    press("q")

    assert tree.() == before
    refute Editor.current_buffer() == "*ibuffer*"
  end

  test "d flags a row and x kills it through key dispatch" do
    eval!(~s{(begin
      (buffer-create "*zz-ibuffer-a*")
      (buffer-create "*zz-ibuffer-b*")
      (switch-to-buffer! "*zz-ibuffer-a*")
      (run-command "ibuffer")
      (list-filter-clear! "*ibuffer*")
      (ibuffer-filter-push! (list "match" "zz-ibuffer-b"))
      (ibuffer-goto-first-row! "*ibuffer*"))})

    assert eval!("(ibuffer-current)") == ~s{"*zz-ibuffer-b*"}
    press("d")
    assert eval!(~s{(list-mark-of "*ibuffer*" "*zz-ibuffer-b*")}) == ~s{"D"}

    press("x")
    refute Compos.Core.BufferStore.known?("*zz-ibuffer-b*")
    refute Buffer.text("*ibuffer*") =~ "*zz-ibuffer-b*"
  end

  test "collecting a narrowed buffer prompt reuses scoped ibuffer" do
    group = "zz-collected-group-#{System.unique_integer([:positive])}"
    on_exit(fn -> Session.eval(~s{(group-record-delete! "#{group}")}) end)

    eval!(~s{(begin
      (buffer-create "*zz-ibuffer-a*")
      (buffer-create "*zz-collected-one*")
      (buffer-create "*zz-collected-two*")
      (buffer-create "*zz-unrelated*")
      (switch-to-buffer! "*zz-ibuffer-a*")
      (group-record-create! "#{group}")
      (local-set-key* (minibuffer-buffer) "<f9>" "minibuffer-collect")
      (local-set-key* (minibuffer-buffer) "<f6>" "minibuffer-confirm")
      (run-command "switch-to-buffer-prompt"))})

    type("zz-collected")
    press("<f9>")

    assert Editor.current_buffer() == "*ibuffer*"
    assert eval!(~s{(buffer-local "*ibuffer*" 'mode-name)}) == ~s{"ibuffer-mode"}

    text = Buffer.text("*ibuffer*")
    assert text =~ "*zz-collected-one*"
    assert text =~ "*zz-collected-two*"
    refute text =~ "*zz-unrelated*"

    # The window form previews too: the row under the highlight shows in
    # a card over the frame, and q takes the card.
    assert eval!("(listing-preview-owner)") == "#f"

    # The reused ibuffer owns ordinary marks and moves the whole marked set.
    eval!(~s{(local-set-key* "*ibuffer*" "<f8>" "list-mark")})
    press(["<f8>", "<f8>"])
    assert eval!(~s{(length (list-marked "*ibuffer*" "*"))}) == "2"

    eval!(~s{(local-set-key* "*ibuffer*" "<f7>" "group-add")})
    press("<f7>")
    type(group)
    press("<f6>")

    assert eval!(~s{(buffer-in-group? "*zz-collected-one*" "#{group}")}) == "#t"
    assert eval!(~s{(buffer-in-group? "*zz-collected-two*" "#{group}")}) == "#t"
    refute eval!(~s{(buffer-in-group? "*zz-unrelated*" "#{group}")}) == "#t"

    # A later ordinary ibuffer open is wide again. The collected scope is
    # one invocation, not a filter that surprises the next invocation.
    eval!(~s{(run-command "ibuffer")})
    assert eval!(~s{(buffer-local "*ibuffer*" 'ibuffer-scope)}) == "#f"
    assert Buffer.text("*ibuffer*") =~ "*zz-unrelated*"
  end
end
