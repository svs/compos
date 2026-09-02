defmodule Compos.IbufferTest do
  @moduledoc "The traditional ibuffer table remains separate from the modal switcher."

  use ExUnit.Case

  alias Compos.Core.{Buffer, Editor, KeyDispatch, Session}

  defp eval!(code) do
    {:ok, value} = Session.eval(code)
    value
  end

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(text), do: text |> String.graphemes() |> press()

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
    assert text =~ "Buffers"
    assert text =~ "buffer"
    assert text =~ "SIZE"
    assert text =~ "MODE"
    assert text =~ "GROUP"
    assert text =~ "FILE"
    assert text =~ "d flag"
    assert text =~ "x execute"
    assert text =~ "*zz-ibuffer-a*"
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
    # the key bar sits under the headline, above the column labels
    [headline, keys, labels | _rows] = String.split(text, "\n")
    assert keys =~ "RET visit"

    assert headline =~
             ~r/^Buffers  \d+ buffers · \d+ modified · grouped by group · name order$/

    assert labels =~ "BUFFER"
    assert labels =~ "DETAILS"
    # compact omits the rule lines; a group section's "── name" is not one
    refute text =~ ~r/^\s*─+\s*$/m
    refute labels =~ "SIZE"
    refute labels =~ "GROUP"
    assert text =~ ~r/\*zz-ibuffer-a\*\s+0 · example/
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
    assert text =~ "── in this group"
    assert text =~ "── #{foreign}"
    assert text =~ "── ungrouped"
    assert text =~ ~r/^3 buffers · 0 modified · grouped by group · name order/m
    assert :binary.match(text, "in this group") < :binary.match(text, "*zz-ibuffer-a*")
    assert :binary.match(text, "*zz-ibuffer-a*") < :binary.match(text, foreign)
    assert :binary.match(text, foreign) < :binary.match(text, "*zz-ibuffer-b*")
    assert :binary.match(text, "*zz-ibuffer-b*") < :binary.match(text, "ungrouped")
    assert :binary.match(text, "ungrouped") < :binary.match(text, "*zz-ibuffer-c*")
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
    assert narrowed =~ "── #{foreign}"
    refute narrowed =~ "ungrouped"
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
    assert text =~ "grouped by group · name order"
    assert :binary.match(text, "*zz-ibuffer-a*") < :binary.match(text, "*zz-ibuffer-b*")
  end

  test "keyboard-quit dismisses scoped ibuffer and restores the covered layout" do
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

    before = eval!("(window-tree)")

    eval!(~s{(ibuffer-open-buffers! (list "*zz-collected-one*"))})
    assert Editor.current_buffer() == "*ibuffer*"
    assert eval!("(popup-open?)") == "#t"
    refute eval!("(window-tree)") == before

    press("C-g")

    assert eval!("(popup-open?)") == "#f"
    assert eval!("(window-tree)") == before
    assert Editor.current_buffer() == "*zz-unrelated*"
  end

  test "keyboard-quit restores ibuffer layout after runtime popup state is lost" do
    eval!(~s{(begin
      (buffer-create "*zz-ibuffer-a*")
      (buffer-create "*zz-ibuffer-b*")
      (buffer-create "*zz-collected-one*")
      (switch-to-buffer! "*zz-ibuffer-a*")
      (split-window! 'h 0.58)
      (other-window!)
      (switch-to-buffer! "*zz-ibuffer-b*"))})

    before = eval!("(window-tree)")
    eval!(~s{(ibuffer-open-buffers! (list "*zz-collected-one*"))})

    # A daemon restart loses frame locals. The popup buffer keeps the opaque
    # pre-popup layout, and its restored window keeps the popup class.
    eval!(~s{(begin
      (set-frame-local! 'popup-window #f)
      (set-frame-local! 'popup-buffer #f)
      (set-frame-local! 'popup-return #f)
      (set-frame-local! 'popup-work #f)
      (set-frame-local! 'popup-layout #f))})

    press("C-g")

    assert eval!("(popup-open?)") == "#f"
    assert eval!("(window-tree)") == before
    assert Editor.current_buffer() == "*zz-ibuffer-b*"
  end

  test "d flags a row and x kills it through key dispatch" do
    eval!(~s{(begin
      (buffer-create "*zz-ibuffer-a*")
      (buffer-create "*zz-ibuffer-b*")
      (switch-to-buffer! "*zz-ibuffer-a*")
      (run-command "ibuffer")
      (list-filter-clear! "*ibuffer*")
      (ibuffer-filter-push! (list "match" "zz-ibuffer-b"))
      (list-goto-first-entry "*ibuffer*"))})

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

    # The first scoped row previews in the source window immediately.
    assert eval!("(window-list)") =~ "*zz-collected"

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
