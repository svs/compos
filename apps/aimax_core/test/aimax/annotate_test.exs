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

  test "annotate-mode builds the margin cards" do
    id = llm_warning()
    reader_note()
    eval!(~s[(enable-minor-mode! "#{@buf}" "annotate-mode")])

    assert Buffer.exists?("*margin*")
    blocks = eval!(~s[(annotate--margin-blocks "*margin*")])
    assert blocks =~ "margin · 2 annotations"
    assert blocks =~ "Overstated claim"
    assert blocks =~ "Keep, verbatim"
    # the selected card opens: body and action chips appear
    eval!(~s[(buffer-set-local! "#{@buf}" 'ann-selected "#{id}")])
    blocks = eval!(~s[(annotate--margin-blocks "*margin*")])
    assert blocks =~ "ann-card open"
    assert blocks =~ "ann:resolve:#{id}"
  end

  test "a margin click runs the verb" do
    id = llm_warning()
    eval!(~s[(enable-minor-mode! "#{@buf}" "annotate-mode")])
    eval!(~s[(annotate--click! "#{@buf}" "resolve" (annotate--find "#{@buf}" "#{id}"))])

    assert eval_s!(~s[(plist-get (annotate--find "#{@buf}" "#{id}") 'state)]) ==
             "resolved"
  end

  test "a reply joins the annotation's thread and the margin shows it" do
    id = llm_warning()
    eval!(~s[(enable-minor-mode! "#{@buf}" "annotate-mode")])
    eval!(~s[(buffer-set-local! "#{@buf}" 'ann-selected "#{id}")])
    eval!(~s[(annotate-reply! "#{@buf}" "#{id}" "Second this.")])

    assert eval!(
             ~s[(length (plist-get (annotate--find "#{@buf}" "#{id}") 'thread))]
           ) == "1"

    assert eval!(~s[(annotate--margin-blocks "*margin*")]) =~ "Second this."
  end

  test "the suggestion prompt carries the span, the context, and the ask" do
    llm_warning()

    prompt =
      eval_s!("""
      (let* ((a (car (buffer-annotations "#{@buf}")))
             (text (buffer-text "#{@buf}"))
             (at (annotate--locate text (annotate--line-bounds text) a)))
        (annotate--suggest-prompt "#{@buf}" a at))
      """)

    assert prompt =~ "delta"
    assert prompt =~ "gamma delta"
    assert prompt =~ "Overstated claim"
    assert prompt =~ "ONLY the replacement text"
  end

  test "a suggestion reply becomes the fix and y applies it" do
    id = llm_warning()
    eval!(~s{(annotate--suggest-apply! "#{@buf}" "#{id}" "delta" "  epsilon  ")})

    assert eval_s!(~s[(plist-get (annotate--find "#{@buf}" "#{id}") 'fix-new)]) ==
             "epsilon"

    eval!(~s[(run-command "annotate-list")])
    press("y")
    assert Buffer.text(@buf) =~ "gamma epsilon"
  end

  test "an empty suggestion reply changes nothing" do
    id = llm_warning()
    eval!(~s{(annotate--suggest-apply! "#{@buf}" "#{id}" "delta" "   ")})
    assert eval!(~s[(plist-get (annotate--find "#{@buf}" "#{id}") 'fix-new)]) == "#f"
  end

  test "annotate-margin-mode by hand redirects instead of hijacking the buffer" do
    eval!(~s[(run-command "annotate-margin-mode")])
    assert Buffer.get_local(@buf, "render-mode") == nil
  end

  test "turning annotate-mode off closes the margin window" do
    llm_warning()
    eval!(~s[(enable-minor-mode! "#{@buf}" "annotate-mode")])
    eval!(~s[(display-buffer-other-window! "*margin*")])
    eval!(~s[(disable-minor-mode! "#{@buf}" "annotate-mode")])
    assert eval!(~s[(window-showing "*margin*")]) == "#f"
  end

  test "annotations of a file buffer live in a file and load back" do
    fbuf = "/annotate-store-test/notes.txt"

    eval!("""
    (begin
      (buffer-create "#{fbuf}")
      (buffer-insert! "#{fbuf}" 0 "alpha beta\\ngamma delta\\n"))
    """)

    on_exit(fn ->
      {:ok, path} = Session.eval(~s[(annotate-store-file "#{fbuf}")])
      File.rm(String.trim(path, "\""))
      if Buffer.exists?(fbuf), do: Aimax.Core.kill_buffer(fbuf)
    end)

    eval_s!(~s{(annotate! "#{fbuf}" (quote (source "reader" severity "note"
              line 2 match "delta" title "Stored" who "you" when "now")))})

    path = eval_s!(~s[(annotate-store-file "#{fbuf}")])
    assert File.exists?(path)
    assert File.read!(path) =~ "Stored"

    # a fresh buffer with no locals reads the file back on mode enable
    eval!(~s[(buffer-set-local! "#{fbuf}" 'annotations (list))])
    eval!(~s[(enable-minor-mode! "#{fbuf}" "annotate-mode")])
    assert eval!(~s[(length (buffer-annotations "#{fbuf}"))]) == "1"

    # ids keep counting past the stored ones
    id =
      eval_s!(~s{(annotate! "#{fbuf}" (quote (source "reader" severity "note"
                line 1 match "beta" title "Second" who "you" when "now")))})

    assert id == "a2"
  end

  test "a non-file buffer has no store" do
    assert eval!(~s[(annotate-store-file "#{@buf}")]) == "#f"
  end

  test "the store keeps reader and llm annotations, never checker ones" do
    fbuf = "/annotate-store-test/checked.txt"

    eval!("""
    (begin
      (buffer-create "#{fbuf}")
      (buffer-insert! "#{fbuf}" 0 "alpha beta\\n"))
    """)

    on_exit(fn ->
      {:ok, path} = Session.eval(~s[(annotate-store-file "#{fbuf}")])
      File.rm(String.trim(path, "\""))
      if Buffer.exists?(fbuf), do: Aimax.Core.kill_buffer(fbuf)
    end)

    eval_s!(~s{(annotate! "#{fbuf}" (quote (source "check" severity "error"
              line 1 match "alpha" title "Diag" who "ts" when "live")))})

    eval_s!(~s{(annotate! "#{fbuf}" (quote (source "llm" severity "note"
              line 1 match "beta" title "Kept" who "claude" when "now")))})

    stored = File.read!(eval_s!(~s[(annotate-store-file "#{fbuf}")]))
    assert stored =~ "Kept"
    refute stored =~ "Diag"
  end

  test "a file inside a project stores its annotations in the project" do
    root = Path.join(System.tmp_dir!(), "annotate-repo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".git"))
    File.mkdir_p!(Path.join(root, "src"))
    fbuf = Path.join(root, "src/x.txt")
    on_exit(fn -> File.rm_rf!(root) end)

    eval!("""
    (begin
      (buffer-create "#{fbuf}")
      (buffer-insert! "#{fbuf}" 0 "alpha beta\\n"))
    """)

    on_exit(fn -> if Buffer.exists?(fbuf), do: Aimax.Core.kill_buffer(fbuf) end)

    assert eval_s!(~s[(annotate-store-file "#{fbuf}")]) ==
             Path.join(root, ".aimax/annotations/src%2Fx.txt.scm")

    eval_s!(~s{(annotate! "#{fbuf}" (quote (source "reader" severity "note"
              line 1 match "beta" title "In repo" who "you" when "now")))})

    assert File.read!(Path.join(root, ".aimax/annotations/src%2Fx.txt.scm")) =~
             "In repo"
  end

  test "a margin card click hands the focus back to the document" do
    id = reader_note()
    eval!(~s[(enable-minor-mode! "#{@buf}" "annotate-mode")])
    on_exit(fn -> if Buffer.exists?("*margin*"), do: Aimax.Core.kill_buffer("*margin*") end)

    # the margin refuses typing from its first frame, not only after restore
    assert eval!(~s[(buffer-read-only? "*margin*")]) == "#t"

    # the client focuses the clicked window before the handler runs —
    # reproduce that, then click the card
    eval!(~s[(unless (window-showing "*margin*")
               (display-buffer-other-window! "*margin*"))])
    eval!(~s[(select-window! (window-showing "*margin*"))])
    assert eval_s!(~s[(window-buffer (active-window))]) == "*margin*"

    Aimax.Core.SchemeAPI.block_click("*margin*", "ann:pick:#{id}")

    assert eventually(fn ->
             eval_s!(~s[(window-buffer (active-window))]) == @buf
           end)
  end

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true ->
        Process.sleep(50)
        eventually(fun, tries - 1)
    end
  end

  test "the mode help names annotate-add and its key" do
    eval!(~s[(enable-minor-mode! "#{@buf}" "annotate-mode")])
    eval!(~s[(run-command "describe-mode")])
    on_exit(fn -> if Buffer.exists?("*Help*"), do: Aimax.Core.kill_buffer("*Help*") end)

    help = Buffer.text("*Help*")
    assert help =~ "C-c ! a"
    assert help =~ "annotate-add"
    assert help =~ "Margin notes"
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
