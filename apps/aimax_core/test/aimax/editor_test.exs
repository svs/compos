defmodule Aimax.EditorTest do
  @moduledoc "Drives the editor purely through key events — the same path the GUI uses."

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(str), do: str |> String.graphemes() |> press()

  defp fresh_buffer do
    name = "test-#{System.unique_integer([:positive])}"
    # reset editor state a failed test may have left behind
    Editor.minibuffer_close()
    Editor.completion_dismiss()
    Editor.set_pending([])
    Editor.set_echo("")
    Editor.delete_other_windows()
    Editor.set_window_buffer(name)
    name
  end

  defp echo, do: Editor.snapshot().echo

  setup do
    {:ok, buf: fresh_buffer()}
  end

  test "eval-last-sexp evals the sexp before point (C-x C-e)", %{buf: _buf} do
    type("(+ 1 (* 2 3))")
    press(["C-x", "C-e"])
    assert echo() == "=> 7"

    # atom before point (with trailing whitespace)
    type(" 42 ")
    press(["C-x", "C-e"])
    assert echo() == "=> 42"

    # strings containing parens don't break the scan
    type(" (string-append \"a)\" \"b\")")
    press(["C-x", "C-e"])
    assert echo() == "=> \"a)b\""
  end

  test "eval-buffer and eval-region commands", %{buf: buf} do
    type("(define eval-test-x 20)\n(+ eval-test-x 2)")
    Aimax.Core.Session.run_command("eval-buffer")
    assert echo() == "=> 22"

    # region over just the define: evals only that
    Buffer.set_mark(buf, 0)
    Buffer.goto(buf, 23)
    Aimax.Core.Session.run_command("eval-region")
    assert echo() == "=> "
  end

  test "self-insert, newline, backspace", %{buf: buf} do
    type("hey")
    press(["RET"])
    type("yo!")
    press(["DEL"])
    assert Buffer.text(buf) == "hey\nyo"
    assert Buffer.point(buf) == 6
  end

  test "motion keys", %{buf: buf} do
    type("abc")
    press(["RET"])
    type("defgh")
    press(["C-a"])
    assert Buffer.point(buf) == 4
    press(["C-p", "C-e"])
    assert Buffer.point(buf) == 3
    press(["<down>", "<left>", "<left>"])
    assert Buffer.point(buf) == 5
    press(["M-<"])
    assert Buffer.point(buf) == 0
    press(["M->"])
    assert Buffer.point(buf) == 9
  end

  test "kill-line and yank", %{buf: buf} do
    type("kill me")
    press(["C-a", "C-k"])
    assert Buffer.text(buf) == ""
    press(["C-y", "C-y"])
    assert Buffer.text(buf) == "kill mekill me"
  end

  test "undo amalgamates typed runs; chain-break undo = redo (Emacs model)", %{buf: buf} do
    type("hello")
    type(" world")
    # 11 consecutive self-inserts = one amalgamated undo step
    press(["C-/"])
    assert Buffer.text(buf) == ""

    # break the chain with any other command, then undo = redo
    press(["C-f"])
    press(["C-/"])
    assert Buffer.text(buf) == "hello world"

    # continue the run: undoes the redo
    press(["C-/"])
    assert Buffer.text(buf) == ""
  end

  test "undo separate edits step by step", %{buf: buf} do
    type("ab")
    press(["RET"])
    type("cd")
    press(["C-/"])
    assert Buffer.text(buf) == "ab\n"
    press(["C-/"])
    assert Buffer.text(buf) == "ab"
    press(["C-/"])
    assert Buffer.text(buf) == ""
  end

  test "word motion and kill", %{buf: buf} do
    type("foo bar_baz qux")
    press(["M-<", "M-f"])
    assert Buffer.point(buf) == 3
    press(["M-f"])
    assert Buffer.point(buf) == 11
    press(["M-b"])
    assert Buffer.point(buf) == 4

    # kill-word from point 4 kills "bar_baz"
    press(["M-d"])
    assert Buffer.text(buf) == "foo  qux"
    press(["C-y"])
    assert Buffer.text(buf) == "foo bar_baz qux"

    # backward-kill-word
    press(["M->", "M-DEL"])
    assert Buffer.text(buf) == "foo bar_baz "
  end

  test "transpose-chars", %{buf: buf} do
    type("ab")
    press(["C-t"])
    assert Buffer.text(buf) == "ba"
  end

  test "goal column survives short lines", %{buf: buf} do
    type("longline")
    press(["RET"])
    type("x")
    press(["RET"])
    type("alsolong")
    press(["M-<", "C-e"])
    assert Buffer.point(buf) == 8
    press(["C-n"])
    # clamped to short line
    assert Buffer.point(buf) == 10
    press(["C-n"])
    # column restored on the long line
    assert Buffer.point(buf) == 11 + 8
  end

  test "yank-pop rotates the kill ring", %{buf: buf} do
    type("first")
    press(["C-a", "C-SPC", "C-e", "C-w"])
    type("second")
    press(["C-a", "C-SPC", "C-e", "C-w"])
    assert Buffer.text(buf) == ""

    press(["C-y"])
    assert Buffer.text(buf) == "second"
    press(["M-y"])
    assert Buffer.text(buf) == "first"

    # the ring is global (other tests' kills included): a full rotation
    # comes back around to the most recent kill
    n = Aimax.Core.Editor.kill_size()
    press(List.duplicate("M-y", n - 1))
    assert Buffer.text(buf) == "second"
  end

  test "TAB indents, goto-line jumps", %{buf: buf} do
    press(["TAB"])
    assert Buffer.text(buf) == "  "
    type("one")
    press(["RET"])
    type("two")
    press(["RET"])
    type("three")

    press(["M-g", "g"])
    type("2")
    press(["RET"])
    assert Buffer.point(buf) == 6
  end

  test "modes: auto-mode by extension shows in state; hooks fire on save" do
    path = Path.join(System.tmp_dir!(), "aimax-mode-#{System.unique_integer([:positive])}.md")
    File.write!(path, "# hi")

    {:ok, _} =
      Aimax.Core.Session.eval("""
      (add-hook! 'after-save-hook (lambda () (message "saved-hook-ran")))
      """)

    press(["C-x", "C-f"])
    type(path)
    press(["RET"])
    assert Editor.current_buffer() == path

    leaf = find_active_leaf(Editor.render_state().tree, Editor.snapshot().active)
    assert leaf.mode == "text-mode"

    press(["C-x", "C-s"])
    assert Buffer.text("*messages*") =~ "saved-hook-ran"
    File.rm!(path)
  end

  defp find_active_leaf(%{type: :leaf} = leaf, _id), do: leaf

  defp find_active_leaf(%{type: :split, children: c}, id) do
    Enum.find_value(c, fn child ->
      case child do
        %{type: :leaf, id: ^id} -> child
        %{type: :split} -> find_active_leaf(child, id)
        _ -> nil
      end
    end)
  end

  test "mark, kill-region, yank, copy, exchange", %{buf: buf} do
    type("hello world")
    # mark at bol, point after "hello" -> region "hello"
    press(["C-a", "C-SPC"])
    press(["C-f", "C-f", "C-f", "C-f", "C-f"])
    press(["C-w"])
    assert Buffer.text(buf) == " world"

    press(["M->", "C-y"])
    assert Buffer.text(buf) == " worldhello"

    # copy does not delete
    press(["C-a", "C-SPC", "C-e", "M-w"])
    assert Buffer.text(buf) == " worldhello"
    press(["C-y"])
    assert Buffer.text(buf) == " worldhello worldhello"

    # exchange point and mark
    press(["C-SPC", "C-a", "C-x", "C-x"])
    assert Buffer.point(buf) == Aimax.Core.Buffer.byte_size(buf)
  end

  test "isearch forward finds, C-g restores, RET accepts", %{buf: buf} do
    type("alpha beta gamma beta")
    press(["M-<"])

    # search "beta", cancel -> point restored to 0
    press(["C-s"])
    type("beta")
    assert Buffer.point(buf) == 10
    assert Buffer.mark(buf) == 6
    press(["C-g"])
    assert Buffer.point(buf) == 0
    assert Buffer.mark(buf) == nil

    # search and accept
    press(["C-s"])
    type("gamma")
    press(["RET"])
    assert Buffer.point(buf) == 16
    assert Buffer.mark(buf) == nil
  end

  test "isearch backward", %{buf: buf} do
    type("one two one")
    press(["C-r"])
    type("one")
    # nearest match before point; point lands at match start
    assert Buffer.point(buf) == 8
    press(["RET"])
  end

  test "read-only buffers block typing but not programmatic writes", %{buf: buf} do
    type("locked")
    {:ok, _} = Aimax.Core.Session.eval(~s{(buffer-set-read-only! "#{buf}" #t)})

    type("x")
    assert Buffer.text(buf) == "locked"
    assert echo() == "Buffer is read-only"

    press(["DEL"])
    assert Buffer.text(buf) == "locked"

    {:ok, _} = Aimax.Core.Session.eval(~s{(buffer-append! "#{buf}" "+prog")})
    assert Buffer.text(buf) == "locked+prog"
  end

  test "buffer-local keymaps shadow global, only in their buffer", %{buf: buf} do
    other = "local-#{System.unique_integer([:positive])}"
    Aimax.Core.create_buffer(other)

    {:ok, _} =
      Aimax.Core.Session.eval("""
      (define-command "test-local-hello" (lambda () (message "local!")))
      (local-set-key "z" "test-local-hello")
      """)

    # bound in current buffer: z runs the command
    press(["z"])
    assert Buffer.text(buf) == ""
    assert echo() == "local!"

    # not bound elsewhere: z self-inserts
    Editor.set_window_buffer(other)
    press(["z"])
    assert Buffer.text(other) == "z"
  end

  describe "ibuffer" do
    test "lists, filters by mode, flags and kills" do
      on_exit(fn ->
        for b <- ["*zz-ib-a*", "*zz-ib-b*", "*ibuffer*"], do: Aimax.Core.kill_buffer(b)
        Editor.delete_other_windows()
      end)

      {:ok, _} = Aimax.Core.Session.eval(~s{(begin
        (buffer-create "*zz-ib-a*")
        (buffer-set-local! "*zz-ib-a*" 'mode-name "zz-mode")
        (buffer-create "*zz-ib-b*")
        (run-command "ibuffer"))})

      assert Editor.current_buffer() == "*ibuffer*"
      assert Buffer.read_only?("*ibuffer*")
      text = Buffer.text("*ibuffer*")
      assert text =~ "*zz-ib-a*"
      assert text =~ "zz-mode"

      # narrow to one major mode; the header names the filter
      {:ok, _} = Aimax.Core.Session.eval(~s{(ibuffer-filter-push! (list "mode" "zz-mode"))})
      text = Buffer.text("*ibuffer*")
      assert text =~ "*zz-ib-a*"
      refute text =~ "*zz-ib-b*"
      assert text =~ "mode:zz-mode"

      # still narrowed to zz-mode: the only line is *zz-ib-a* — flag + kill
      {:ok, _} = Aimax.Core.Session.eval("(begin (goto-char! 0) (next-line!) (beginning-of-line!))")
      assert {:ok, ~s{"*zz-ib-a*"}} = Aimax.Core.Session.eval("(ibuffer-current)")
      press(["d", "x"])
      refute Aimax.Core.Buffer.exists?("*zz-ib-a*")

      # RET lands the selection in the window ibuffer was opened from
      {:ok, _} = Aimax.Core.Session.eval(~s{(begin
        (list-filter-clear! "*ibuffer*")
        (ibuffer-filter-push! (list "name" "zz-ib"))
        (goto-char! 0) (next-line!) (beginning-of-line!))})
      assert {:ok, ~s{"*zz-ib-b*"}} = Aimax.Core.Session.eval("(ibuffer-current)")
      press(["RET"])
      assert Editor.current_buffer() == "*zz-ib-b*"
    end

    test "n/p preview the highlighted buffer in the home window" do
      on_exit(fn ->
        for b <- ["*zz-pv-a*", "*zz-pv-b*", "*ibuffer*"], do: Aimax.Core.kill_buffer(b)
        Editor.delete_other_windows()
      end)

      {:ok, _} = Aimax.Core.Session.eval(~s{(begin
        (buffer-create "*zz-pv-a*")
        (buffer-create "*zz-pv-b*")
        (delete-other-windows!)
        (switch-to-buffer! "*zz-pv-a*")
        (run-command "ibuffer")
        (buffer-set-local! "*ibuffer*" 'ibuffer-filters '())
        (ibuffer-filter-push! (list "name" "zz-pv"))
        (goto-char! 0) (next-line!) (beginning-of-line!))})

      assert Editor.current_buffer() == "*ibuffer*"
      home = window_of("*zz-pv-a*")
      assert home

      # first entry is highlighted; n moves to the second and previews it
      press(["n"])
      assert {:ok, ~s{"*zz-pv-b*"}} = Aimax.Core.Session.eval("(ibuffer-current)")
      assert buffer_in(home) == "*zz-pv-b*"
      # point stays in the list
      assert Editor.current_buffer() == "*ibuffer*"

      press(["p"])
      assert buffer_in(home) == "*zz-pv-a*"

      # arrows are the gesture people actually use — same preview
      press(["<down>"])
      assert buffer_in(home) == "*zz-pv-b*"
      press(["<up>"])
      assert buffer_in(home) == "*zz-pv-a*"
    end
  end

  defp window_of(buffer) do
    {:ok, wins} = Aimax.Core.Session.eval("(window-list)")
    wins
    |> then(fn s -> Regex.scan(~r/\((\d+) "([^"]+)"\)/, s) end)
    |> Enum.find_value(fn [_, id, b] -> if b == buffer, do: String.to_integer(id) end)
  end

  defp buffer_in(win_id) do
    {:ok, wins} = Aimax.Core.Session.eval("(window-list)")
    wins
    |> then(fn s -> Regex.scan(~r/\((\d+) "([^"]+)"\)/, s) end)
    |> Enum.find_value(fn [_, id, b] -> if String.to_integer(id) == win_id, do: b end)
  end

  describe "dired (pure Scheme userland)" do
    setup do
      root = Path.join(System.tmp_dir!(), "aimax-dired-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "subdir"))
      File.write!(Path.join(root, "alpha.txt"), "A")
      File.write!(Path.join(root, "beta.txt"), "B")
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end

    test "listing, navigation, visiting files and dirs", %{root: root} do
      {:ok, _} = Aimax.Core.Session.eval(~s{(dired-open "#{root}")})
      assert Editor.current_buffer() == root
      assert Buffer.read_only?(root)

      text = Buffer.text(root)
      assert text =~ "alpha.txt"
      assert text =~ "beta.txt"
      assert text =~ "subdir/"

      # point starts on "..", n n -> beta.txt line (sorted: alpha, beta, subdir)
      press(["n"])
      {:ok, entry} = Aimax.Core.Session.eval("(dired-entry)")
      assert entry == inspect("alpha.txt")

      # RET visits the file
      press(["RET"])
      assert Editor.current_buffer() == Path.join(root, "alpha.txt")
      assert Buffer.text(Editor.current_buffer()) == "A"

      # back to dired, descend into subdir via RET
      {:ok, _} = Aimax.Core.Session.eval(~s{(dired-open "#{root}")})
      press(["n", "n", "n"])
      press(["RET"])
      assert Editor.current_buffer() == Path.join(root, "subdir")

      # ^ goes back up
      press(["^"])
      assert Editor.current_buffer() == root
    end

    test "marks: d flags, x executes with confirmation; m/u; + mkdir", %{root: root} do
      {:ok, _} = Aimax.Core.Session.eval(~s{(dired-open "#{root}")})

      # point on "..": n -> alpha.txt; d flags it (D mark, advances)
      press(["n", "d"])
      assert Buffer.text(root) =~ ~r/^D .*alpha\.txt$/m

      # m marks beta, u unmarks it again
      press(["m"])
      assert Buffer.text(root) =~ ~r/^\* .*beta\.txt$/m
      press(["p", "u"])
      refute Buffer.text(root) =~ ~r/^\* /m

      # x executes the flagged deletion after confirmation
      press(["x"])
      assert Editor.render_state().minibuffer.prompt =~ "Delete 1 file(s)"
      type("yes")
      press(["RET"])
      refute File.exists?(Path.join(root, "alpha.txt"))
      refute Buffer.text(root) =~ "alpha.txt"

      # + creates a directory
      press(["+"])
      type("newdir")
      press(["RET"])
      assert File.dir?(Path.join(root, "newdir"))
      assert Buffer.text(root) =~ "newdir/"
    end

    test "filters narrow the listing, persist as a local, and restore-run", %{root: root} do
      File.write!(Path.join(root, "notes.scm"), ";;")
      File.write!(Path.join(root, ".hidden"), "h")

      {:ok, _} = Aimax.Core.Session.eval(~s{(dired-open "#{root}")})

      # / e narrows to one extension; header names the active filter
      press(["/", "e"])
      type("scm")
      press(["RET"])
      text = Buffer.text(root)
      assert text =~ "notes.scm"
      refute text =~ "alpha.txt"
      assert text =~ "ext:scm"

      # type filter stacks: directories only — nothing matches both
      {:ok, _} = Aimax.Core.Session.eval(~s{(dired-filter-push! (list "type" "dir"))})
      refute Buffer.text(root) =~ "notes.scm"

      # pop restores the previous narrowing
      press(["/", "p"])
      assert Buffer.text(root) =~ "notes.scm"

      # dotfiles toggle and clear
      press(["/", "/"])
      assert Buffer.text(root) =~ ".hidden"
      press(["/", "."])
      refute Buffer.text(root) =~ ".hidden"

      # the stack lives in a serializable local, and the registered mode
      # reapplies it: this is exactly what desktop restore runs
      {:ok, filters} = Aimax.Core.Session.eval(~s{(buffer-local "#{root}" 'dired-filters)})
      assert filters =~ "dot"
      {:ok, _} = Aimax.Core.Session.eval(~s{(begin (switch-to-buffer! "#{root}") (set-mode! "Dired"))})
      refute Buffer.text(root) =~ ".hidden"
      assert Buffer.text(root) =~ "alpha.txt"
    end

    test "dired lines carry perms/size/date columns", %{root: root} do
      {:ok, _} = Aimax.Core.Session.eval(~s{(dired-open "#{root}")})
      text = Buffer.text(root)
      assert text =~ ~r/^  -rw.*\d+ +[A-Z][a-z]{2} +\d+ \d{2}:\d{2} alpha\.txt$/m
      assert text =~ ~r/^  drwx.*subdir\/$/m
    end

    test "find-file prefills default-directory; // resets (Emacs rule)", %{root: root} do
      {:ok, _} = Aimax.Core.Session.eval(~s{(dired-open "#{root}")})
      press(["C-x", "C-f"])
      mb = Editor.render_state().minibuffer
      assert mb.input == root <> "/"

      # typing an absolute path over the prefill: // rule takes over
      type(Path.join(root, "beta.txt"))
      press(["RET"])
      assert Editor.current_buffer() == Path.join(root, "beta.txt")
      assert Buffer.text(Editor.current_buffer()) == "B"
    end

    test "find-file DEL at a directory boundary kills one component", %{root: root} do
      {:ok, _} = Aimax.Core.Session.eval(~s{(dired-open "#{root}")})
      press(["C-x", "C-f"])
      assert Editor.render_state().minibuffer.input == root <> "/"

      press(["DEL"])
      assert Editor.render_state().minibuffer.input ==
               (root |> Path.dirname()) <> "/"

      # mid-name it's still one char at a time
      type("ab")
      press(["DEL"])
      assert Editor.render_state().minibuffer.input ==
               (root |> Path.dirname()) <> "/a"

      press(["C-g"])
    end
  end

  test "llm primitive: async completion drives a scheme handler", %{buf: buf} do
    Application.put_env(:aimax_core, :llm_request_fun, fn prompt -> {:ok, "ECHO: " <> prompt} end)
    on_exit(fn -> Application.delete_env(:aimax_core, :llm_request_fun) end)

    {:ok, _} =
      Aimax.Core.Session.eval("""
      (llm "hi there" (lambda (r) (buffer-append! "#{buf}" r)))
      """)

    assert eventually(fn -> Buffer.text(buf) == "ECHO: hi there" end)
  end

  test "M-| pipes the region through the llm into *llm*", %{buf: buf} do
    Application.put_env(:aimax_core, :llm_request_fun, fn prompt ->
      {:ok, prompt |> String.split("\n") |> List.last() |> String.upcase()}
    end)

    on_exit(fn -> Application.delete_env(:aimax_core, :llm_request_fun) end)

    type("shout this")
    press(["C-SPC", "C-a"])
    press(["M-|"])
    type("upcase it")
    press(["RET"])

    assert eventually(fn ->
             Buffer.exists?("*llm*") and Buffer.text("*llm*") =~ "SHOUT THIS"
           end)

    assert Buffer.text(buf) == "shout this"
  end

  test "shell: process output streams into buffer, RET sends line" do
    buf = "*proc-test-#{System.unique_integer([:positive])}*"
    {:ok, _} = Aimax.Core.Session.eval(~s{(start-process! "#{buf}" "cat")})
    Editor.set_window_buffer(buf)

    # wait for process to be up, then type a line and hit RET (comint send)
    assert Aimax.Core.Proc.running?(buf)
    type("hello-comint")
    press(["RET"])

    # cat echoes it back (plus the pty echo) — poll until it lands
    assert eventually(fn -> Buffer.text(buf) =~ "hello-comint" end)

    Aimax.Core.Proc.kill(buf)
    assert eventually(fn -> not Aimax.Core.Proc.running?(buf) end)
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

  test "set-face-attribute! lands in render_state faces" do
    {:ok, _} = Aimax.Core.Session.eval(~s{(set-face-attribute! 'modeline 'bg "#ff0000" 'fg "#000")})
    assert Editor.render_state().faces["modeline"] == %{"bg" => "#ff0000", "fg" => "#000"}
  end

  test "unbound keys echo, don't crash", %{buf: buf} do
    press(["C-c", "C-q"])
    assert echo() =~ "undefined"
    assert Buffer.text(buf) == ""
  end

  test "prefix key shows pending" do
    press(["C-x"])
    assert Editor.snapshot().pending == ["C-x"]
    assert echo() == "C-x-"
    press(["C-g"])
  end

  test "M-x runs a command by name", %{buf: buf} do
    press(["M-x"])
    assert %{prompt: "M-x "} = Editor.render_state().minibuffer
    type("other-window")
    assert %{candidates: candidates} = Editor.render_state().minibuffer
    assert Enum.any?(candidates, &(&1.label == "other-window"))
    press(List.duplicate("DEL", String.length("other-window")))
    type("end-of-buffer")
    press(["RET"])
    assert Editor.snapshot().minibuffer == nil
    # command ran: no error echo
    refute echo() =~ "undefined"
    assert Buffer.point(buf) == 0
  end

  test "find-file TAB filename completion completes and descends directories" do
    root = Path.join(System.tmp_dir!(), "aimax-fc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "subdir"))
    File.write!(Path.join(root, "readme.txt"), "x")
    File.write!(Path.join(root, "recipe.md"), "y")
    File.write!(Path.join([root, "subdir", "inner.txt"]), "z")

    press(["C-x", "C-f"])
    type(root <> "/re")
    press(["TAB"])
    # common prefix of readme.txt + recipe.md is "re"; candidates narrowed
    mb = Editor.render_state().minibuffer
    assert mb.input == root <> "/re"
    assert mb.candidates |> Enum.map(& &1.label) |> Enum.sort() == ["readme.txt", "recipe.md"]

    type("a")
    press(["TAB"])
    assert Editor.render_state().minibuffer.input == root <> "/readme.txt"

    press(["C-g"])

    # unique directory match: one TAB descends AND lists the contents
    press(["C-x", "C-f"])
    type(root <> "/su")
    press(["TAB"])
    mb = Editor.render_state().minibuffer
    assert mb.input == root <> "/subdir/"
    assert Enum.map(mb.candidates, & &1.label) == ["inner.txt"]
    press(["C-g"])

    File.rm_rf!(root)
  end

  test "file prompt: live candidates while typing, arrow+TAB inserts, arrow+RET visits" do
    root = Path.join(System.tmp_dir!(), "aimax-nav-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "subdir"))
    File.write!(Path.join(root, "alpha.txt"), "A")
    File.write!(Path.join([root, "subdir", "inner.txt"]), "Z")

    press(["C-x", "C-f"])
    type(root <> "/")

    # candidates appeared live, no TAB needed
    mb = Editor.render_state().minibuffer
    assert Enum.map(mb.candidates, & &1.label) == ["alpha.txt", "subdir/"]

    # arrow onto subdir/, TAB inserts it and lists inside
    press(["C-n", "TAB"])
    mb = Editor.render_state().minibuffer
    assert mb.input == root <> "/subdir/"
    assert Enum.map(mb.candidates, & &1.label) == ["inner.txt"]

    # arrow onto inner.txt (sel already 0; touch it), RET visits it directly
    press(["C-n", "RET"])
    assert Editor.current_buffer() == Path.join([root, "subdir", "inner.txt"])
    assert Buffer.text(Editor.current_buffer()) == "Z"

    File.rm_rf!(root)
  end

  test "find-file offers the current buffer's directory, inherited or by name" do
    root = Path.join(System.tmp_dir!(), "aimax-dd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "alpha.txt"), "A")

    # a file buffer answers with its own directory
    {:ok, _} = Aimax.Core.Session.eval(~s{(visit "#{Path.join(root, "alpha.txt")}")})
    press(["C-x", "C-f"])
    assert Editor.render_state().minibuffer.input == root <> "/"
    press(["C-g"])

    # a buffer with no file inherits the directory it was created in
    {:ok, _} =
      Aimax.Core.Session.eval(
        ~s{(begin (buffer-create "*dd-child*") (switch-to-buffer! "*dd-child*"))}
      )

    press(["C-x", "C-f"])
    assert Editor.render_state().minibuffer.input == root <> "/"
    press(["C-g"])

    # a path-shaped name is a directory too, even with no file behind it
    {:ok, _} =
      Aimax.Core.Session.eval(~s{(switch-to-buffer! "#{Path.join(root, "never-opened.txt")}")})

    press(["C-x", "C-f"])
    assert Editor.render_state().minibuffer.input == root <> "/"
    press(["C-g"])

    File.rm_rf!(root)
  end

  test "find-file filters orderless; unique match opens on RET" do
    root = Path.join(System.tmp_dir!(), "aimax-of-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "HANDOFF.html"), "<h1>hi</h1>")
    File.write!(Path.join(root, "notes.md"), "# notes")
    File.write!(Path.join(root, "code.ex"), "defmodule A do\nend\n")

    press(["C-x", "C-f"])
    type(root <> "/")
    # substring, not prefix: "html" finds HANDOFF.html
    type("html")
    mb = Editor.render_state().minibuffer
    assert Enum.map(mb.candidates, & &1.label) == ["HANDOFF.html"]

    # unique match: RET opens it without arrowing
    press(["RET"])
    assert Editor.current_buffer() == Path.join(root, "HANDOFF.html")

    # non-unique filter still lets you create a new file by typing a name
    press(["C-x", "C-f"])
    type(root <> "/brand-new.txt")
    press(["RET"])
    assert Editor.current_buffer() == Path.join(root, "brand-new.txt")

    File.rm_rf!(root)
  end

  test "RET takes the highlighted first candidate without arrowing" do
    root = Path.join(System.tmp_dir!(), "aimax-sel-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "alpha.txt"), "A")
    File.write!(Path.join(root, "april.txt"), "B")

    press(["C-x", "C-f"])
    # "a" matches both files: first is highlighted, list is NOT unique
    type(root <> "/a")
    mb = Editor.render_state().minibuffer
    assert [%{label: "alpha.txt", selected: true}, %{label: "april.txt"}] = mb.candidates

    # no C-n: the highlighted candidate is what RET must open
    press(["RET"])
    assert Editor.current_buffer() == Path.join(root, "alpha.txt")

    File.rm_rf!(root)
  end

  test "M-RET confirms the typed input literally despite matches" do
    root = Path.join(System.tmp_dir!(), "aimax-lit-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "foo-bar.txt"), "X")

    press(["C-x", "C-f"])
    # "foo.txt" fuzzy-matches foo-bar.txt, so RET would open that —
    # M-RET must create the literally typed file instead
    type(root <> "/foo.txt")
    mb = Editor.render_state().minibuffer
    assert [%{label: "foo-bar.txt"} | _] = mb.candidates

    press(["M-RET"])
    assert Editor.current_buffer() == Path.join(root, "foo.txt")

    File.rm_rf!(root)
  end

  test "find-file on a directory opens dired" do
    root = Path.join(System.tmp_dir!(), "aimax-ffd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "x.txt"), "x")

    press(["C-x", "C-f"])
    type(root)
    press(["RET"])

    assert Editor.current_buffer() == root
    assert Buffer.read_only?(root)
    assert Buffer.text(root) =~ "x.txt"

    File.rm_rf!(root)
  end

  test "M-x tab completion" do
    press(["M-x"])
    type("split-window-b")
    press(["TAB"])
    assert Editor.render_state().minibuffer.input == "split-window-below"
    press(["C-g"])
  end

  test "minibuffer v2: fuzzy filter, C-n selection, RET runs selected" do
    Editor.delete_other_windows()
    press(["M-x"])
    type("splitwindow")

    mb = Editor.render_state().minibuffer
    assert mb.total == 2
    assert [%{label: "split-window-below", selected: true}, %{label: "split-window-right"}] = mb.candidates

    press(["C-n"])
    assert Editor.render_state().minibuffer.sel == 1
    press(["RET"])

    assert %{type: :split, dir: :h} = Editor.render_state().tree
    press(["C-x", "1"])
  end

  test "exact match ranks above longer prefix matches (paper vs paper-night)" do
    {:ok, _} =
      Aimax.Core.Session.eval("""
      (minibuffer-read "Rank: " (list "paper-night" "paper" "wallpaper")
        (lambda (x) (message x)))
      """)

    type("paper")
    mb = Editor.render_state().minibuffer
    assert Enum.map(mb.candidates, & &1.label) == ["paper", "paper-night", "wallpaper"]
    assert hd(mb.candidates).selected

    press(["RET"])
    assert echo() == "paper"
  end

  test "tree-sitter: elixir mode enables highlighting, sexp nav works" do
    path = Path.join(System.tmp_dir!(), "aimax-ts-#{System.unique_integer([:positive])}.exs")
    File.write!(path, "defmodule Foo do\n  def bar do\n    [1, 2, 3]\n  end\nend\n")

    press(["C-x", "C-f"])
    type(path)
    press(["RET"])
    assert Editor.current_buffer() == path
    assert Buffer.get_local(path, "ts-lang") == "elixir"
    assert Buffer.get_local(path, "mode-name") == "elixir-mode"

    # highlight spans exist and include a keyword scope
    spans = Aimax.Core.TS.ts_highlight("elixir", Buffer.text(path))
    assert Enum.any?(spans, fn {_, _, scope} -> scope == "keyword" end)

    # C-M-f moves over successive sexps: symbol, then alias (Emacs-style)
    press(["M-<", "C-M-f"])
    assert Buffer.point(path) == 9
    press(["C-M-f"])
    assert Buffer.point(path) == 13

    # C-M-u from inside the list goes to an enclosing structure start
    {:ok, _} = Aimax.Core.Session.eval("(goto-char! 36)")
    press(["C-M-u"])
    assert Buffer.point(path) < 36

    File.rm!(path)
  end

  test "modes are M-x commands; (load path) evaluates a scheme file", %{buf: buf} do
    press(["M-x"])
    type("elixir-mode")
    press(["RET"])
    assert Buffer.get_local(buf, "mode-name") == "elixir-mode"
    assert Buffer.get_local(buf, "ts-lang") == "elixir"

    lib = Path.join(System.tmp_dir!(), "aimax-lib-#{System.unique_integer([:positive])}.scm")
    File.write!(lib, ~s{(define-command "from-lib" (lambda () (message "lib loaded!")))})
    {:ok, _} = Aimax.Core.Session.eval(~s{(load "#{lib}")})

    press(["M-x"])
    type("from-lib")
    press(["RET"])
    assert echo() == "lib loaded!"
    File.rm!(lib)
  end

  test "dired RET visit runs auto-mode (elixir file gets highlighting)" do
    root = Path.join(System.tmp_dir!(), "aimax-dm-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "code.ex"), "defmodule X do\nend\n")

    {:ok, _} = Aimax.Core.Session.eval(~s{(dired-open "#{root}")})
    press(["n", "RET"])

    path = Path.join(root, "code.ex")
    assert Editor.current_buffer() == path
    assert Buffer.get_local(path, "mode-name") == "elixir-mode"
    assert Buffer.get_local(path, "ts-lang") == "elixir"

    File.rm_rf!(root)
  end

  test "desktop: editor state survives save/restore" do
    path = Path.join(System.tmp_dir!(), "aimax-desk-#{System.unique_integer([:positive])}.ex")
    File.write!(path, "defmodule Desk do\nend\n")

    # open the file, set a point, split, load a theme face
    press(["C-x", "C-f"])
    type(path)
    press(["RET"])
    press(["C-f", "C-f", "C-f"])
    press(["C-x", "3"])
    {:ok, _} = Aimax.Core.Session.eval(~s{(set-face-attribute! 'desk-test 'fg "#123456")})

    assert :ok = Aimax.Core.Desktop.save_now()

    # wreck the state: single window on scratch, kill the file buffer
    press(["C-x", "1"])
    Editor.set_window_buffer("*scratch*")
    Aimax.Core.kill_buffer(path)
    assert eventually(fn -> not Buffer.exists?(path) end)

    assert :ok = Aimax.Core.Desktop.restore_now()

    # buffer is back with point, mode, the split, and the face
    assert Buffer.exists?(path)
    assert Buffer.point(path) == 3
    assert Buffer.get_local(path, "mode-name") == "elixir-mode"
    assert %{type: :split, dir: :h} = Editor.render_state().tree
    assert Editor.render_state().faces["desk-test"] == %{"fg" => "#123456"}
    assert Editor.current_buffer() == path

    press(["C-x", "1"])
    File.rm!(path)
  end

  test "desktop: preview-mode and hand-set modes survive restore" do
    path = Path.join(System.tmp_dir!(), "aimax-desk-#{System.unique_integer([:positive])}.md")
    File.write!(path, "# Title\n\nbody\n")

    press(["C-x", "C-f"])
    type(path)
    press(["RET"])
    press(["C-c", "C-v"])
    assert Buffer.get_local(path, "render-mode") == "markdown"
    {:ok, _} = Aimax.Core.Session.eval(~s{(set-mode! "rust-mode")})
    assert Buffer.get_local(path, "ts-lang") == "rust"

    assert :ok = Aimax.Core.Desktop.save_now()

    Editor.set_window_buffer("*scratch*")
    Aimax.Core.kill_buffer(path)
    assert eventually(fn -> not Buffer.exists?(path) end)

    assert :ok = Aimax.Core.Desktop.restore_now()

    # auto-mode would have said text-mode; the saved state wins
    assert Buffer.get_local(path, "mode-name") == "rust-mode"
    assert Buffer.get_local(path, "ts-lang") == "rust"
    assert Buffer.get_local(path, "render-mode") == "markdown"

    File.rm!(path)
  end

  test "desktop: non-file buffers (chat) survive restore with content, mode, and keys", %{buf: buf} do
    companion = "*chat:#{buf}*"
    on_exit(fn -> Aimax.Core.kill_buffer(companion) end)

    press(["M-x"])
    type("chat")
    press(["RET"])
    assert Editor.current_buffer() == companion
    type("remember me")
    point = Buffer.point(companion)

    assert :ok = Aimax.Core.Desktop.save_now()

    Editor.set_window_buffer("*scratch*")
    Aimax.Core.kill_buffer(companion)
    assert eventually(fn -> not Buffer.exists?(companion) end)

    assert :ok = Aimax.Core.Desktop.restore_now()

    assert Buffer.exists?(companion)
    assert Buffer.text(companion) =~ "remember me"
    assert Buffer.point(companion) == point
    assert Buffer.get_local(companion, "mode-name") == "chat-mode"

    # the mode setup reinstalled the local keymap: C-c m prompts for a model
    Editor.set_window_buffer(companion)
    press(["C-c", "m"])
    assert Editor.snapshot().minibuffer.prompt =~ "Model"
    press(["C-g"])
  end

  test "completion-at-point: dabbrev popup, selection, accept, refilter", %{buf: buf} do
    type("hello helper")
    press(["RET"])
    type("he")

    press(["C-M-i"])
    comp = Editor.render_state().completion
    assert comp != nil
    assert Enum.map(comp.candidates, & &1.label) == ["hello", "helper"]
    assert hd(comp.candidates).selected

    # C-n selects helper; TAB accepts, replacing the prefix
    press(["C-n", "TAB"])
    assert Editor.snapshot().completion == nil
    assert Buffer.text(buf) == "hello helper\nhelper"

    # typing while popup is open refilters
    press(["RET"])
    type("hel")
    press(["C-M-i"])
    type("p")
    comp = Editor.render_state().completion
    assert Enum.map(comp.candidates, & &1.label) == ["helper"]
    press(["RET"])
    assert Buffer.text(buf) =~ "helper\nhelper"

    # C-g dismisses without inserting
    press(["RET"])
    type("he")
    press(["C-M-i", "C-g"])
    assert Editor.snapshot().completion == nil
  end

  test "capf: buffer-local sources take precedence (the LSP plug point)", %{buf: buf} do
    {:ok, _} =
      Aimax.Core.Session.eval("""
      (buffer-set-local! "#{buf}" 'capf-sources
        (list (lambda () (list (point) (point) (list (list "from-lsp" "lsp"))))))
      """)

    press(["C-M-i"])
    comp = Editor.render_state().completion
    assert [%{label: "from-lsp", hint: "lsp"}] = comp.candidates
    press(["C-g"])
  end

  describe "viewport windowing" do
    setup %{buf: buf} do
      Editor.set_total_rows(10)
      for i <- 1..100, do: Buffer.append(buf, "line #{i}\n")
      Buffer.goto(buf, 0)
      on_exit(fn -> Editor.set_total_rows(40) end)
      :ok
    end

    test "renders only the visible slice; auto-follows point", %{buf: buf} do
      leaf = find_active_leaf(Editor.render_state().tree, Editor.snapshot().active)
      assert leaf.top == 0
      assert leaf.rows == 10
      assert leaf.total_lines == 101

      # point to the end: viewport follows
      press(["M->"])
      leaf = find_active_leaf(Editor.render_state().tree, Editor.snapshot().active)
      assert leaf.top == 101 - 10
      assert Buffer.point(buf) > 0
    end

    test "C-v pages down, M-v pages back, C-l recenters", %{buf: buf} do
      press(["C-v"])
      # 8 lines down; lines 1-9 are 7 bytes ("line N\n")
      assert Buffer.point(buf) == 8 * 7

      press(["M-v"])
      assert Buffer.point(buf) == 0

      {:ok, _} = Aimax.Core.Session.eval("(goto-char! 400)")
      press(["C-l"])
      leaf = find_active_leaf(Editor.render_state().tree, Editor.snapshot().active)
      # byte 400 sits on 0-based line 51; centered top = 51 - rows/2
      assert leaf.top == 46
    end

    test "manual scroll holds until a key re-follows point" do
      Editor.scroll_active(50)
      leaf = find_active_leaf(Editor.render_state().tree, Editor.snapshot().active)
      assert leaf.top == 50

      # a key breaks the override; point (line 0) pulls the view back
      press(["C-f"])
      leaf = find_active_leaf(Editor.render_state().tree, Editor.snapshot().active)
      assert leaf.top == 0
    end

    test "display-line-numbers-mode toggles the flag" do
      press(["M-x"])
      type("display-line-numbers-mode")
      press(["RET"])
      leaf = find_active_leaf(Editor.render_state().tree, Editor.snapshot().active)
      assert leaf.line_numbers == false

      press(["M-x"])
      type("display-line-numbers-mode")
      press(["RET"])
      leaf = find_active_leaf(Editor.render_state().tree, Editor.snapshot().active)
      assert leaf.line_numbers == true
    end
  end

  test "C-x k defaults to killing the current buffer", %{buf: buf} do
    type("doomed")
    press(["C-x", "k"])
    mb = Editor.render_state().minibuffer
    assert mb.prompt =~ "default #{buf}"
    press(["RET"])

    assert eventually(fn -> not Buffer.exists?(buf) end)
    # MRU semantics: we land on the most recently used OTHER buffer
    assert Editor.current_buffer() != buf
    assert Buffer.exists?(Editor.current_buffer())
  end

  test "buffer ring: C-x b defaults to previous buffer; kill lands on MRU", %{buf: a} do
    b = "ring-b-#{System.unique_integer([:positive])}"
    c = "ring-c-#{System.unique_integer([:positive])}"
    Editor.set_window_buffer(a)
    Editor.set_window_buffer(b)
    Editor.set_window_buffer(c)

    # default is the buffer we just left: b
    press(["C-x", "b"])
    assert Editor.render_state().minibuffer.prompt =~ "default #{b}"
    press(["RET"])
    assert Editor.current_buffer() == b

    # toggle back
    press(["C-x", "b", "RET"])
    assert Editor.current_buffer() == c

    # killing current lands on MRU (b), not *scratch*
    press(["C-x", "k", "RET"])
    assert Editor.current_buffer() == b
  end

  describe "display-buffer & popper" do
    test "M-x shell opens as a bottom popup; C-` toggles; q quits", %{buf: buf} do
      press(["M-x"])
      type("shell")
      press(["RET"])
      assert eventually(fn -> Aimax.Core.Proc.running?("*shell*") end)

      # popup: two windows, bottom one active showing *shell*, ~30% rows
      state = Editor.render_state()
      assert %{type: :split, dir: :v, ratio: 0.7} = state.tree
      assert Editor.current_buffer() == "*shell*"

      # C-` closes the popup, back to a single window on our buffer
      press(["C-`"])
      assert %{type: :leaf} = Editor.render_state().tree
      assert Editor.current_buffer() == buf

      # C-` reopens the same popup buffer
      press(["C-`"])
      assert Editor.current_buffer() == "*shell*"

      # q (via quit-window) closes it too... shell is editable, use M-x
      press(["M-x"])
      type("quit-window")
      press(["RET"])
      assert %{type: :leaf} = Editor.render_state().tree
      Aimax.Core.Proc.kill("*shell*")
    end

    test "dired q quits back to the previous buffer", %{buf: buf} do
      root = Path.join(System.tmp_dir!(), "aimax-q-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      {:ok, _} = Aimax.Core.Session.eval(~s{(dired-open "#{root}")})
      assert Editor.current_buffer() == root

      press(["q"])
      assert Editor.current_buffer() == buf
      File.rm_rf!(root)
    end

    test "s-arrows move between windows, S-arrows walk buffer history", %{buf: _buf} do
      press(["C-x", "3"])
      active = Editor.snapshot().active
      press(["s-<right>"])
      assert Editor.snapshot().active != active
      press(["s-<left>"])
      assert Editor.snapshot().active == active
      # geometry, not tree order: no window above in a pure h-split
      press(["s-<up>"])
      assert Editor.snapshot().active == active
      # 2x2-ish grid: split the left pane below, then windmove down and back
      press(["C-x", "2"])
      press(["s-<down>"])
      below = Editor.snapshot().active
      refute below == active
      press(["s-<up>"])
      assert Editor.snapshot().active == active
      # from top-left, right must reach the full-height right pane
      press(["s-<right>"])
      refute Editor.snapshot().active in [active, below]
      press(["C-x", "1"])

      # S-<left> = previously used buffer; repeats go deeper, not toggle
      a = fresh_buffer()
      m = fresh_buffer()
      press(["S-<left>"])
      assert Editor.current_buffer() == a
      press(["S-<left>"])
      refute Editor.current_buffer() in [a, m]
      press(["S-<right>", "S-<right>"])
      assert Editor.current_buffer() == m

      # s-S-arrows carry the buffer into the neighbor pane, focus follows
      press(["C-x", "3"])
      other = "swap-#{System.unique_integer([:positive])}"
      press(["C-x", "o"])
      Editor.set_window_buffer(other)
      right_win = Editor.snapshot().active
      press(["s-S-<left>"])
      assert Editor.current_buffer() == other
      refute Editor.snapshot().active == right_win
      assert Editor.list_windows() |> Enum.map(fn {_, b} -> b end) == [other, m]
      press(["C-x", "1"])
    end

    test "scroll-other-window scrolls the inactive window", %{buf: buf} do
      for i <- 1..100, do: Buffer.append(buf, "row #{i}\n")
      press(["C-x", "3"])

      # find the other (inactive) window id
      active = Editor.snapshot().active
      {other_id, _} = Editor.list_windows() |> Enum.find(fn {id, _} -> id != active end)

      press(["C-M-v"])
      other_leaf = find_leaf_by_id(Editor.render_state().tree, other_id)
      assert other_leaf.top > 0

      press(["C-x", "1"])
    end
  end

  defp find_leaf_by_id(%{type: :leaf, id: id} = leaf, id), do: leaf
  defp find_leaf_by_id(%{type: :leaf}, _id), do: nil

  defp find_leaf_by_id(%{type: :split, children: c}, id),
    do: Enum.find_value(c, &find_leaf_by_id(&1, id))

  test "chat opens the group companion; RET sends, reply appends", %{buf: buf} do
    companion = "*chat:#{buf}*"

    # chat routes through the tool loop by default (chat-use-tools)
    Application.put_env(:aimax_core, :llm_chat_fun, fn %{messages: [%{content: prompt} | _]} ->
      assert prompt =~ "what is 6*7"
      # NOT a bare number: the fixture buffer is named test-<counter>, and
      # a reply of "42" matched the digits of its own name in the help card
      # — the wait below passed before the turn had rendered anything
      {:ok,
       %{"stop_reason" => "end_turn", "content" => [%{"type" => "text", "text" => "six times seven"}]}}
    end)

    on_exit(fn ->
      Application.delete_env(:aimax_core, :llm_chat_fun)
      Aimax.Core.kill_buffer(companion)
    end)

    press(["M-x"])
    type("chat")
    press(["RET"])
    # one chat interface: C-c c is the group companion, rich from birth
    assert Editor.current_buffer() == companion
    assert Buffer.get_local(companion, "render-mode") == "agent"
    assert Buffer.text(companion) =~ "companion · #{buf}"

    type("what is 6*7")
    press(["RET"])

    assert eventually(fn -> Buffer.text(companion) =~ "six times seven" end)
    assert eventually(fn -> Buffer.text(companion) =~ ">>> you: what is 6*7" end)
    press(["C-x", "1"])
  end

  test "an empty model reply leaves a visible placeholder, not a blank turn", %{buf: buf} do
    companion = "*chat:#{buf}*"

    Application.put_env(:aimax_core, :llm_chat_fun, fn _ ->
      {:ok, %{"stop_reason" => "end_turn", "content" => []}}
    end)

    on_exit(fn ->
      Application.delete_env(:aimax_core, :llm_chat_fun)
      Aimax.Core.kill_buffer(companion)
    end)

    press(["M-x"])
    type("chat")
    press(["RET"])
    type("hello?")
    press(["RET"])

    assert eventually(fn -> Buffer.text(companion) =~ "(no reply" end)
    press(["C-x", "1"])
  end

  test "C-x b previews the highlighted buffer in the invoking window; C-g restores it", %{buf: buf} do
    other = "zz-cxb-#{System.unique_integer([:positive])}"
    {:ok, _} = Aimax.Core.Session.eval(~s{(begin (buffer-create "#{other}") #t)})
    on_exit(fn -> Aimax.Core.kill_buffer(other) end)

    win = Editor.active_window()
    shown = fn -> Enum.find_value(Editor.list_windows(), fn {id, b} -> if id == win, do: b end) end

    # type enough to filter to `other`: the refilter previews it live
    press(["C-x", "b"])
    assert Editor.snapshot().minibuffer
    type("zz-cxb")
    assert Aimax.Core.Session.eval("(minibuffer-selected)") == {:ok, ~s{"#{other}"}}
    assert shown.() == other

    # C-g restores the displaced buffer; the buffer ring is untouched
    press(["C-g"])
    refute Editor.snapshot().minibuffer
    assert shown.() == buf
    assert {:ok, first} = Aimax.Core.Session.eval("(car (car (buffer-candidates)))")
    refute first == ~s{"#{other}"}

    # RET actually switches
    press(["C-x", "b"])
    type("zz-cxb")
    press(["RET"])
    assert shown.() == other
    assert Editor.current_buffer() == other
  end

  test "openai models run the tool loop like every other model", %{buf: buf} do
    companion = "*chat:#{buf}*"
    type("Dear hiring manager")

    {:ok, before} = Aimax.Core.Session.eval("(llm-model)")
    parent = self()

    Application.put_env(:aimax_core, :llm_chat_fun, fn req ->
      send(parent, {:chat, req})
      {:ok, %{"stop_reason" => "end_turn", "content" => [%{"text" => "ok then"}]}}
    end)

    on_exit(fn ->
      Application.delete_env(:aimax_core, :llm_chat_fun)
      Aimax.Core.Session.eval("(set-llm-model! #{before})")
      Aimax.Core.kill_buffer(companion)
    end)

    {:ok, _} = Aimax.Core.Session.eval(~s{(set-llm-model! "openai:gpt-5.6-test")})

    press(["C-c", "w"])
    assert Editor.current_buffer() == companion
    type("draft a reply")
    press(["RET"])

    assert eventually(fn -> Buffer.text(companion) =~ "ok then" end)
    assert_received {:chat, req}
    # all chats work the same: tools attached, pull-model preamble in the
    # system prompt — the provider difference is translated at the wire
    assert Enum.any?(req.tools, &(&1.name == "eval-scheme"))
    assert req.system =~ "buffer-text"
    refute req.system =~ "Dear hiring manager"
    # the message carries what the user typed, not the document
    prompt = req.messages |> List.last() |> Map.get(:content)
    assert prompt =~ "draft a reply"
    press(["C-x", "1"])
  end

  test "C-c w opens a writing companion chat linked to the document", %{buf: buf} do
    companion = "*chat:#{buf}*"
    type("Roses are red")

    Application.put_env(:aimax_core, :llm_chat_fun, fn %{messages: messages, system: system} ->
      # the per-send system preamble names the document and the pull tools
      assert system =~ "writing companion"
      assert system =~ ~s{"#{buf}"}
      assert system =~ "buffer-text"
      # the turn itself is what the user typed
      assert messages |> List.last() |> Map.get(:content) =~ "make it rhyme"
      {:ok, %{"stop_reason" => "end_turn", "content" => [%{"type" => "text", "text" => "try violets"}]}}
    end)

    on_exit(fn ->
      Application.delete_env(:aimax_core, :llm_chat_fun)
      Aimax.Core.kill_buffer(companion)
    end)

    press(["C-c", "w"])
    assert Editor.current_buffer() == companion
    assert length(Editor.list_windows()) == 2
    # the group is the tag: doc and chat both carry it, nothing points anywhere
    assert Buffer.get_local(buf, "group") == buf
    assert Buffer.get_local(companion, "group") == buf
    assert Buffer.get_local(companion, "mode-name") == "chat-mode"

    # rich surface from birth: agent renderer + help meta card + input marker
    assert Buffer.get_local(companion, "render-mode") == "agent"
    assert Buffer.text(companion) =~ "companion · #{buf}"
    assert Buffer.text(companion) =~ ">>> you:"

    type("make it rhyme")
    press(["RET"])
    assert eventually(fn -> Buffer.text(companion) =~ "try violets" end)

    # the transcript is block-modeled like an agent thread
    kinds = Buffer.get_local(companion, "agent-blocks") |> Enum.map(&Enum.at(&1, 2))
    assert "meta" in kinds
    assert "user" in kinds
    assert "prose" in kinds
    refute "waiting" in kinds

    # companion chats keep their doc-derived name — no auto-title rename
    assert Buffer.exists?(companion)

    # C-c w toggles sides: companion -> doc -> companion, no new splits
    press(["C-c", "w"])
    assert Editor.current_buffer() == buf
    press(["C-c", "w"])
    assert Editor.current_buffer() == companion
    assert length(Editor.list_windows()) == 2

    press(["C-x", "1"])
  end

  test "C-c RET talks to the companion without leaving the document", %{buf: buf} do
    companion = "*chat:#{buf}*"
    type("A koan about ropes.")

    Application.put_env(:aimax_core, :llm_chat_fun, fn %{messages: messages} ->
      assert messages |> List.last() |> Map.get(:content) =~ "tighten this up"
      {:ok, %{"stop_reason" => "end_turn", "content" => [%{"type" => "text", "text" => "knot bad"}]}}
    end)

    on_exit(fn ->
      Application.delete_env(:aimax_core, :llm_chat_fun)
      Aimax.Core.kill_buffer(companion)
    end)

    point = Buffer.point(buf)
    press(["C-c", "RET"])
    assert Editor.snapshot().minibuffer.prompt == "Ask #{buf}: "
    type("tighten this up")
    press(["RET"])

    # pane opened, prompt became a turn, reply landed — focus never left the doc
    assert eventually(fn -> Buffer.text(companion) =~ "knot bad" end)
    assert Editor.current_buffer() == buf
    assert Buffer.point(buf) == point
    assert length(Editor.list_windows()) == 2

    press(["C-x", "1"])
  end

  test "C-c w in a groupless (legacy) chat adopts a document", %{buf: buf} do
    legacy = "*llm:legacy*"
    on_exit(fn -> Aimax.Core.kill_buffer(legacy) end)

    type("Draft about ropes.")

    # a groupless chat only comes from an old desktop — recreate one by hand
    {:ok, _} =
      Aimax.Core.Session.eval(~s{(begin
        (buffer-create "#{legacy}")
        (switch-to-buffer! "#{legacy}")
        (set-mode! "chat-mode"))})

    assert Editor.current_buffer() == legacy

    # C-c w in an unlinked chat asks which buffer to accompany (MRU-first)
    press(["C-c", "w"])
    assert Editor.snapshot().minibuffer.prompt == "Companion for buffer: "
    press(["RET"])

    assert Buffer.get_local(legacy, "group") == buf
    assert Buffer.get_local(buf, "group") == buf
    assert Editor.current_buffer() == legacy

    # C-c w from the doc refocuses the adopted chat
    press(["C-c", "w"])
    assert Editor.current_buffer() == buf
    press(["C-c", "w"])
    assert Editor.current_buffer() == legacy

    press(["C-x", "1"])
  end

  test "buffer groups: C-c g tags members, C-c q talks to the group's one chat",
       %{buf: buf} do
    notes = "notes-#{System.unique_integer([:positive])}"
    chat = "*chat:proj*"
    type("defmodule Rope do end")

    Application.put_env(:aimax_core, :llm_chat_fun, fn %{system: system} ->
      # the per-send preamble enumerates the whole group, not one document
      assert system =~ ~s{group "proj"}
      assert system =~ ~s{"#{buf}"}
      assert system =~ ~s{"#{notes}"}
      assert system =~ "buffer-text"
      {:ok, %{"stop_reason" => "end_turn", "content" => [%{"type" => "text", "text" => "aye"}]}}
    end)

    on_exit(fn ->
      Application.delete_env(:aimax_core, :llm_chat_fun)
      Aimax.Core.kill_buffer(chat)
      Aimax.Core.kill_buffer(notes)
    end)

    # C-c g founds the group from the code buffer, then the notes join it
    press(["C-c", "g"])
    assert Editor.snapshot().minibuffer.prompt == "Group: "
    type("proj")
    press(["RET"])
    assert Buffer.get_local(buf, "group") == "proj"

    {:ok, _} = Aimax.Core.Session.eval(~s{(buffer-create "#{notes}")})
    Editor.set_window_buffer(notes)
    press(["C-c", "g"])
    type("proj")
    press(["RET"])
    assert Buffer.get_local(notes, "group") == "proj"

    # C-c q in a grouped buffer routes to the group chat, focus stays put
    point = Buffer.point(notes)
    press(["C-c", "q"])
    assert Editor.snapshot().minibuffer.prompt == "Ask proj: "
    type("thoughts?")
    press(["RET"])

    assert eventually(fn -> Buffer.text(chat) =~ "aye" end)
    assert Buffer.get_local(chat, "group") == "proj"
    assert Editor.current_buffer() == notes
    assert Buffer.point(notes) == point
    assert length(Editor.list_windows()) == 2

    # a second ask reuses the same conversation
    press(["C-c", "q"])
    type("more?")
    press(["RET"])
    assert eventually(fn ->
             length(String.split(Buffer.text(chat), "aye")) == 3
           end)

    # C-c w hops chat -> most recent work buffer and back
    Editor.set_window_buffer(chat)
    {:ok, _} = Aimax.Core.Session.eval(~s{(set-mode! "chat-mode")})
    press(["C-c", "w"])
    assert Editor.current_buffer() == notes
    press(["C-c", "w"])
    assert Editor.current_buffer() == chat

    # kill the chat: nothing dangles, the next ask remakes it in the group
    press(["C-x", "1"])
    Aimax.Core.kill_buffer(chat)
    Editor.set_window_buffer(notes)
    press(["C-c", "q"])
    type("again?")
    press(["RET"])
    assert eventually(fn ->
             Buffer.exists?(chat) && Buffer.text(chat) =~ "aye"
           end)
    assert Buffer.get_local(chat, "group") == "proj"

    press(["C-x", "1"])
  end

  test "legacy companion-of pointers migrate to group tags on mode setup", %{buf: buf} do
    chat = "*old-companion*"
    {:ok, _} = Aimax.Core.Session.eval(~s{(buffer-create "#{chat}")})
    Buffer.set_local(chat, "companion-of", buf)

    on_exit(fn -> Aimax.Core.kill_buffer(chat) end)

    Editor.set_window_buffer(chat)
    {:ok, _} = Aimax.Core.Session.eval(~s{(set-mode! "chat-mode")})

    # both ends now carry the tag; the pointer is only read as a fallback
    assert Buffer.get_local(chat, "group") == buf
    assert Buffer.get_local(buf, "group") == buf
  end

  test "C-c q founds a group and asks its one chat from the minibuffer", %{buf: buf} do
    companion = "*chat:#{buf}*"

    Application.put_env(:aimax_core, :llm_chat_fun, fn %{messages: [%{content: prompt} | _]} ->
      assert prompt =~ "what is 6*7"

      # NOT a bare number: the fixture buffer is named test-<counter>, and
      # a reply of "42" matched the digits of its own name in the help card
      # — the wait below passed before the turn had rendered anything
      {:ok,
       %{"stop_reason" => "end_turn", "content" => [%{"type" => "text", "text" => "six times seven"}]}}
    end)

    on_exit(fn ->
      Application.delete_env(:aimax_core, :llm_chat_fun)
      Aimax.Core.kill_buffer(companion)
    end)

    press(["C-c", "q"])
    assert Editor.snapshot().minibuffer.prompt == "Ask #{buf}: "
    type("what is 6*7")
    press(["RET"])

    # the question became a turn in the group's one chat; point stayed put
    assert eventually(fn -> Buffer.text(companion) =~ "six times seven" end)
    assert eventually(fn -> Buffer.text(companion) =~ "what is 6*7" end)
    assert Editor.current_buffer() == buf

    press(["C-x", "1"])
  end

  test "set-llm-model! changes the model" do
    {:ok, before} = Aimax.Core.Session.eval("(llm-model)")
    {:ok, _} = Aimax.Core.Session.eval(~s{(set-llm-model! "luna-5.6")})
    assert {:ok, ~s{"luna-5.6"}} = Aimax.Core.Session.eval("(llm-model)")
    {:ok, _} = Aimax.Core.Session.eval("(set-llm-model! #{before})")
  end

  test "both surfaces share one engine: popup narrows orderless too", %{buf: buf} do
    type("transformation transducer")
    press(["RET"])
    type("tra")
    press(["C-M-i"])
    assert Enum.map(Editor.render_state().completion.candidates, & &1.label) ==
             ["transducer", "transformation"]

    # typing narrows the OPEN popup in place (no source re-query), orderless:
    # "tras" is a subsequence of transformation only... use "nsd" for transducer
    type("nsd")
    assert Enum.map(Editor.render_state().completion.candidates, & &1.label) == ["transducer"]

    press(["RET"])
    assert Buffer.text(buf) =~ "transducer\ntransducer"
  end

  test "orderless: space-separated terms match in any order" do
    press(["M-x"])
    type("window split")
    mb = Editor.render_state().minibuffer
    labels = Enum.map(mb.candidates, & &1.label)
    assert "split-window-below" in labels
    assert "split-window-right" in labels
    press(["C-g"])
  end

  test "which-key panel appears for pending prefix" do
    press(["C-x"])
    wk = Editor.render_state().which_key
    assert %{key: "b", command: "switch-to-buffer"} in wk
    assert %{key: "C-f", command: "find-file"} in wk
    press(["C-g"])
    assert Editor.render_state().which_key == nil
  end

  test "themes are pure scheme: load-theme sets semantic faces" do
    {:ok, _} = Aimax.Core.Session.eval(~s{(load-theme "tokyo-night")})
    faces = Editor.render_state().faces
    assert faces["default"]["bg"] == "#1a1b26"
    assert faces["accent"]["fg"] == "#7aa2f7"

    {:ok, _} = Aimax.Core.Session.eval(~s{(load-theme "catppuccin-mocha")})
    assert Editor.render_state().faces["default"]["bg"] == "#1e1e2e"

    # restore
    {:ok, _} = Aimax.Core.Session.eval(~s{(load-theme "aimax-dark")})
  end

  test "key-for-command reverse lookup" do
    {:ok, printed} = Aimax.Core.Session.eval(~s{(key-for-command "find-file")})
    assert printed == inspect("C-x C-f")
  end

  test "C-g quits the minibuffer" do
    press(["C-x", "C-f"])
    assert Editor.render_state().minibuffer.prompt == "Find file: "
    press(["C-g"])
    assert Editor.snapshot().minibuffer == nil
    assert echo() == "Quit"
  end

  test "find-file and save-buffer round-trip" do
    path = Path.join(System.tmp_dir!(), "aimax-e2e-#{System.unique_integer([:positive])}.txt")
    File.write!(path, "on disk")

    press(["C-x", "C-f"])
    type(path)
    press(["RET"])

    assert Editor.current_buffer() == path
    assert Buffer.text(path) == "on disk"

    press(["M->"])
    type(" + edited")
    press(["C-x", "C-s"])

    assert File.read!(path) == "on disk + edited"
    assert echo() =~ "Wrote"
    File.rm!(path)
  end

  test "switch-to-buffer via C-x b", %{buf: buf} do
    other = "other-#{System.unique_integer([:positive])}"
    Aimax.Core.create_buffer(other)

    press(["C-x", "b"])
    type(other)
    press(["RET"])
    assert Editor.current_buffer() == other

    press(["C-x", "b"])
    type(buf)
    press(["RET"])
    assert Editor.current_buffer() == buf
  end

  test "M-: eval-expression echoes result" do
    press(["M-:"])
    type("(+ 20 22)")
    press(["RET"])
    assert echo() == "42"
  end

  describe "tiling windows" do
    test "split below/right builds a tree, C-x o cycles, C-x 1/0 collapse", %{buf: buf} do
      press(["C-x", "2"])
      press(["C-x", "3"])

      state = Editor.render_state()
      assert %{type: :split, dir: :v, children: [%{type: :split, dir: :h}, _]} = state.tree

      ids = collect_ids(state.tree)
      assert length(ids) == 3

      active_before = Editor.snapshot().active
      press(["C-x", "o"])
      assert Editor.snapshot().active != active_before

      # all windows show the same buffer initially
      assert state.tree |> collect_buffers() |> Enum.uniq() == [buf]

      press(["C-x", "1"])
      assert %{type: :leaf} = Editor.render_state().tree

      press(["C-x", "0"])
      assert echo() =~ "sole window"
    end

    test "windows can show different buffers", %{buf: buf} do
      other = "win-#{System.unique_integer([:positive])}"
      press(["C-x", "3"])
      press(["C-x", "o"])
      press(["C-x", "b"])
      type(other)
      press(["RET"])

      buffers = Editor.render_state().tree |> collect_buffers() |> Enum.sort()
      assert buffers == Enum.sort([buf, other])
      press(["C-x", "1"])
    end
  end

  defp collect_ids(%{type: :leaf, id: id}), do: [id]
  defp collect_ids(%{type: :split, children: c}), do: Enum.flat_map(c, &collect_ids/1)

  defp collect_buffers(%{type: :leaf, buffer: b}), do: [b]
  defp collect_buffers(%{type: :split, children: c}), do: Enum.flat_map(c, &collect_buffers/1)
end

defmodule Aimax.MinibufferEditingTest do
  @moduledoc "The minibuffer is a buffer: real editing commands work in prompts."

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(str), do: str |> String.graphemes() |> press()
  defp input, do: Editor.render_state().minibuffer.input

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()
    Editor.set_window_buffer("mb-edit-#{System.unique_integer([:positive])}")
    press(["M-x"])
    assert Editor.render_state().minibuffer
    on_exit(fn -> Editor.minibuffer_close() end)
    :ok
  end

  test "point motion and mid-input insertion" do
    type("firword")
    press(["C-b", "C-b", "C-b", "C-b"])
    type("st-")
    assert input() == "first-word"

    press(["C-a"])
    type(">")
    assert input() == ">first-word"

    press(["C-e"])
    type("<")
    assert input() == ">first-word<"
  end

  test "M-DEL kills a word, C-y yanks into the prompt" do
    type("hello world")
    press(["M-DEL"])
    assert input() == "hello "

    # kill ring content yanks into the minibuffer
    press(["C-y"])
    assert input() == "hello world"
  end

  test "DEL deletes at point, not just at the end" do
    type("abc")
    press(["C-b"])
    press(["DEL"])
    assert input() == "ac"
  end

  test "current_buffer routes back to the window after close" do
    win = Editor.render_state() |> Map.get(:tree) |> then(& &1.buffer)
    assert Editor.current_buffer() == Editor.minibuf_name()
    press(["C-g"])
    assert Editor.current_buffer() == win
    assert Buffer.text(Editor.minibuf_name()) == ""
  end
end
