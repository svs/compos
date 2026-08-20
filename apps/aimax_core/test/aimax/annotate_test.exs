defmodule Aimax.AnnotateTest do
  @moduledoc """
  The annotation layer, driven through the same key path the GUI uses.
  The 'annotations buffer-local is the model; overlays and the
  *annotations* list are projections. docs/ANNOTATIONS.md is the design.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  @buf "annotate-test.txt"
  @list "*annotations*"
  @text "alpha beta\ngamma delta\nepsilon zeta\n"

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  # Session.eval returns the PRINTED value: strings keep their quotes,
  # numbers print bare. eval_s! unwraps one printed string.
  defp eval!(code) do
    {:ok, v} = Session.eval(code)
    v
  end

  defp eval_s!(code), do: eval!(code) |> String.trim("\"")

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()

    eval!("""
    (begin
      (buffer-create "#{@buf}")
      (switch-to-buffer! "#{@buf}")
      (buffer-insert! "#{@buf}" 0 "alpha beta\\ngamma delta\\nepsilon zeta\\n"))
    """)

    on_exit(fn ->
      for b <- [@list, @buf] do
        if Buffer.exists?(b), do: Aimax.Core.kill_buffer(b)
      end
    end)

    :ok
  end

  defp add(spec) do
    eval_s!(~s[(annotate! "#{@buf}" (quote #{spec}))])
  end

  defp llm_warning do
    add(~s[(source "llm" severity "warning" line 2 match "delta"
            title "Overstated claim" who "claude" when "now")])
  end

  defp reader_note do
    add(~s[(source "reader" severity "note" line 3 match "zeta"
            title "Keep, verbatim" who "Ada R." when "Wed")])
  end

  defp fix_ann do
    add(~s[(source "llm" severity "suggestion" line 1 match "beta"
            title "Rename" who "claude" when "now"
            fix-old "beta" fix-new "betta")])
  end

  test "annotate! paints an overlay on the matched text" do
    llm_warning()
    # "alpha beta\n" is 11 bytes; "delta" sits at 17..22
    assert {17, 22, "ann-llm"} in Buffer.overlays(@buf)
  end

  test "a resolved annotation paints nothing" do
    id = llm_warning()
    eval!(~s[(annotate--update! "#{@buf}" "#{id}" 'state "resolved")])
    eval!(~s[(annotate--paint! "#{@buf}")])
    assert Buffer.overlays(@buf) == []
  end

  test "relocate follows the text through an edit above" do
    llm_warning()
    eval!(~s[(buffer-insert! "#{@buf}" 0 "intro\\n")])
    eval!(~s[(annotate--relocate! "#{@buf}")])
    eval!(~s[(annotate--paint! "#{@buf}")])

    assert eval!(~s[(plist-get (car (buffer-annotations "#{@buf}")) 'line)]) == "3"
    assert {23, 28, "ann-llm"} in Buffer.overlays(@buf)
  end

  test "annotate-clear! drops one source and keeps the rest" do
    llm_warning()
    reader_note()
    eval!(~s[(annotate-clear! "#{@buf}" "llm")])
    assert eval!(~s[(length (buffer-annotations "#{@buf}"))]) == "1"
  end

  test "M-n steps to the annotation and selects it" do
    eval!(~s[(enable-minor-mode! "#{@buf}" "annotate-mode")])
    llm_warning()
    press("M-n")
    assert Buffer.point(@buf) == 17
    assert Buffer.get_local(@buf, "ann-selected") != nil
    assert {17, 22, "ann-selected"} in Buffer.overlays(@buf)
  end

  test "the list shows the rows and <left>/<right> change the tab" do
    llm_warning()
    reader_note()
    eval!(~s[(run-command "annotate-list")])
    assert Editor.current_buffer() == @list

    text = Buffer.text(@list)
    assert text =~ "Overstated claim"
    assert text =~ "Keep, verbatim"
    assert text =~ "[all 2]"

    # all -> errors: the warning stays, the note goes
    press("<right>")
    text = Buffer.text(@list)
    assert text =~ "[errors 1]"
    assert text =~ "Overstated claim"
    refute text =~ "Keep, verbatim"

    # errors -> claude
    press("<right>")
    assert Buffer.text(@list) =~ "[claude 1]"

    # and back
    press(["<left>", "<left>"])
    assert Buffer.text(@list) =~ "[all 2]"
  end

  test "r resolves and reopens the row at point" do
    id = llm_warning()
    eval!(~s[(run-command "annotate-list")])

    press("r")
    assert eval_s!(~s[(plist-get (annotate--find "#{@buf}" "#{id}") 'state)]) ==
             "resolved"

    press("r")
    assert eval_s!(~s[(plist-get (annotate--find "#{@buf}" "#{id}") 'state)]) ==
             "open"
  end

  test "y applies the suggested fix and resolves the annotation" do
    id = fix_ann()
    eval!(~s[(run-command "annotate-list")])
    press("y")

    assert Buffer.text(@buf) =~ "alpha betta"
    assert eval_s!(~s[(plist-get (annotate--find "#{@buf}" "#{id}") 'state)]) ==
             "resolved"
  end

  test "y reports a stale fix instead of editing" do
    fix_ann()
    eval!(~s[(buffer-delete-range! "#{@buf}" 6 4)])
    eval!(~s[(run-command "annotate-list")])
    press("y")
    assert Buffer.text(@buf) =~ "alpha \ngamma"
  end

  test "d dismisses the row for this session" do
    llm_warning()
    reader_note()
    eval!(~s[(run-command "annotate-list")])
    press("d")
    assert eval!(~s[(length (annotate-visible "#{@buf}"))]) == "1"
    assert eval!(~s[(length (buffer-annotations "#{@buf}"))]) == "2"
  end

  test "the check source reports tree-sitter ERROR nodes" do
    langs = eval!("(ts-langs)")

    if langs =~ ~s("json") do
      eval!("""
      (begin
        (buffer-set-local! "#{@buf}" 'ts-lang "json")
        (buffer-delete-range! "#{@buf}" 0 #{byte_size(@text)})
        (buffer-insert! "#{@buf}" 0 "[1,,]\\n"))
      """)

      eval!(~s[(annotate--check! "#{@buf}")])

      assert eval_s!(~s[(plist-get (car (buffer-annotations "#{@buf}")) 'source)]) ==
               "check"
    end
  end
end
