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

  # DEL back over whatever the prompt holds, the way a user retypes
  defp clear_minibuffer do
    press(List.duplicate("DEL", String.length(Editor.snapshot().minibuffer.input)))
  end

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
      assert Editor.render_state().minibuffer.prompt =~ "delete 1 file"
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
      {:ok, filters} = Aimax.Core.Session.eval(~s{(buffer-local "#{root}" 'list-filters)})
      assert filters =~ "dot"
      {:ok, _} = Aimax.Core.Session.eval(~s{(begin (switch-to-buffer! "#{root}") (set-mode! "Dired"))})
      refute Buffer.text(root) =~ ".hidden"
      assert Buffer.text(root) =~ "alpha.txt"
    end

    # The listing was in the buffer and the window was blank: the buffer
    # kept 'render-mode "blocks" from the mode before it, and the client
    # draws blocks for a leaf that says "blocks". Both ends refuse now —
    # the list mode drops the local, and a leaf with no blocks says nil.
    test "a stale render-mode does not blank the listing", %{root: root} do
      {:ok, _} = Aimax.Core.Session.eval(~s{(dired-open "#{root}")})
      {:ok, _} = Aimax.Core.Session.eval(~s{(buffer-set-local! "#{root}" 'render-mode "blocks")})

      # the core stops calling it blocks the moment there are no blocks
      leaf = find_active_leaf(Editor.render_state().tree, Editor.snapshot().active)
      assert leaf.buffer == root
      assert leaf.render_mode == nil

      # and re-entering the mode drops the local outright
      {:ok, _} = Aimax.Core.Session.eval(~s{(set-mode! "Dired")})
      {:ok, "#f"} = Aimax.Core.Session.eval(~s{(buffer-local "#{root}" 'render-mode)})
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

    # the input names a directory, so the prompt holds the selection: the
    # first C-n lands on alpha.txt, the second on subdir/. TAB inserts it
    # and lists inside
    press(["C-n", "C-n", "TAB"])
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

  test "a mode hook can open a file rendered and read-only; C-x C-q gives back the source" do
    path = Path.join(System.tmp_dir!(), "aimax-html-#{System.unique_integer([:positive])}.html")
    File.write!(path, "<h1>Hi</h1>\n")
    on_exit(fn -> File.rm(path) end)

    # what a user config does: html-mode-hook renders and locks the buffer
    {:ok, _} =
      Aimax.Core.Session.eval(~s{(add-hook! 'html-mode-hook
                                   (lambda ()
                                     (buffer-set-local! (current-buffer) 'render-mode "html")
                                     (buffer-set-read-only! (current-buffer) #t)))})

    press(["C-x", "C-f"])
    type(path)
    press(["RET"])
    assert Editor.current_buffer() == path
    assert Buffer.get_local(path, "render-mode") == "html"
    assert Buffer.read_only?(path)

    # read-only means read-only: typing does not reach the file
    press(["x"])
    assert Buffer.text(path) == "<h1>Hi</h1>\n"

    # C-x C-q to edit: the render goes with it, so you see the bytes
    press(["C-x", "C-q"])
    refute Buffer.read_only?(path)
    refute Buffer.get_local(path, "render-mode")
    press(["x"])
    assert String.starts_with?(Buffer.text(path), "x<h1>")

    {:ok, _} =
      Aimax.Core.Session.eval(~s{(set! *hooks*
                                   (remove (lambda (h) (equal? (car h) 'html-mode-hook))
                                           *hooks*))})

    Aimax.Core.kill_buffer(path)
  end

  test "desktop: non-file buffers (chat) survive restore with content, mode, and keys", %{
    buf: buf
  } do
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

  test "completion keys are Scheme policy: a userland rebind works", %{buf: buf} do
    # C-j is unbound in the popup map; one local-set-key* makes it move
    {:ok, _} =
      Aimax.Core.Session.eval(~s{(local-set-key* " *completion*" "C-j" "completion-next")})

    type("hello helper")
    press(["RET"])
    type("he")
    press(["C-M-i", "C-j", "TAB"])
    assert Buffer.text(buf) == "hello helper\nhelper"
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

    # containers may hold the default now; the ring is reachable by name
    press(["C-x", "b"])
    type(b)
    press(["RET"])
    assert Editor.current_buffer() == b

    press(["C-x", "b"])
    type(c)
    press(["RET"])
    assert Editor.current_buffer() == c

    # killing current lands on MRU (b), not *scratch*
    press(["C-x", "k", "RET"])
    assert Editor.current_buffer() == b
  end

  describe "display-buffer & popper" do
    test "M-x shell opens as a right side popup; C-` toggles; q quits", %{buf: buf} do
      press(["M-x"])
      type("shell")
      press(["RET"])
      assert eventually(fn -> Aimax.Core.Proc.running?("*shell*") end)

      # the default display rule: a right side window taking 0.38 of the
      # frame, floating — the class and the share reach the client here
      state = Editor.render_state()
      assert %{type: :split, dir: :h, ratio: ratio} = state.tree
      assert_in_delta ratio, 0.62, 0.001
      assert Editor.current_buffer() == "*shell*"
      assert {:ok, ~s{"popup popup-right"}} =
               Aimax.Core.Session.eval(~s{(buffer-local "*shell*" 'window-class)})

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
      assert eventually(fn -> not Buffer.exists?(root) end)
      File.rm_rf!(root)
    end

    test "q walks out of nested dired buffers, it does not flip", %{buf: buf} do
      root = Path.join(System.tmp_dir!(), "aimax-q2-#{System.unique_integer([:positive])}")
      sub = Path.join(root, "sub")
      File.mkdir_p!(sub)
      {:ok, _} = Aimax.Core.Session.eval(~s{(dired-open "#{root}")})
      {:ok, _} = Aimax.Core.Session.eval(~s{(dired-open "#{sub}")})
      assert Editor.current_buffer() == sub

      # q kills the child listing: back to the parent, and it stays gone
      press(["q"])
      assert Editor.current_buffer() == root
      # q again leaves dired for good — no flip back to the child
      press(["q"])
      assert Editor.current_buffer() == buf
      File.rm_rf!(root)
    end

    test "q quits any read-only buffer, and the mode's own q still wins", %{buf: buf} do
      {:ok, _} =
        Aimax.Core.Session.eval(~s{(begin (buffer-create "*ro*")
                                          (switch-to-buffer! "*ro*")
                                          (buffer-set-read-only! "*ro*" #t))})

      assert Editor.current_buffer() == "*ro*"

      # nothing binds q here — the read-only keymap does
      press(["q"])
      assert Editor.current_buffer() == buf
      assert eventually(fn -> not Buffer.exists?("*ro*") end)

      # a writable buffer keeps q as text
      press(["q"])
      assert Editor.current_buffer() == buf
      assert String.contains?(Buffer.text(buf), "q")

      # the buffer's own map beats the read-only one
      {:ok, _} =
        Aimax.Core.Session.eval(~s{(begin (buffer-create "*ro2*")
                                          (switch-to-buffer! "*ro2*")
                                          (buffer-set-read-only! "*ro2*" #t)
                                          (local-set-key* "*ro2*" "q" "beginning-of-buffer"))})

      press(["q"])
      assert Editor.current_buffer() == "*ro2*"
      {:ok, _} = Aimax.Core.Session.eval(~s{(buffer-kill! "*ro2*")})
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
    # tokyo-night is define-theme-from aimax-dark: the override wins,
    # the unnamed face inherits
    assert faces["ts-keyword"]["fg"] == "#bb9af7"
    assert faces["warn"]["fg"] == "#e0af68"

    {:ok, _} = Aimax.Core.Session.eval(~s{(load-theme "catppuccin-mocha")})
    assert Editor.render_state().faces["default"]["bg"] == "#1e1e2e"

    # paper names its own syntax faces — a theme that omits them keeps
    # the previous theme's colors on screen
    {:ok, _} = Aimax.Core.Session.eval(~s{(load-theme "paper")})
    assert Editor.render_state().faces["ts-keyword"]["fg"] == "#26356b"

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

  test "TAB into a directory, then RET opens dired (not the first entry)" do
    root = Path.join(System.tmp_dir!(), "aimax-dir-#{System.unique_integer([:positive])}")
    sub = Path.join(root, "onlysub")
    File.mkdir_p!(sub)
    File.write!(Path.join(sub, "a.txt"), "a")
    File.write!(Path.join(sub, "b.txt"), "b")

    press(["C-x", "C-f"])
    type(root <> "/only")
    press(["TAB"])

    mb = Editor.render_state().minibuffer
    assert mb.input == sub <> "/"
    # the prompt holds the selection, so no candidate row is marked
    assert mb.prompt_sel
    refute Enum.any?(mb.candidates, & &1.selected)

    press(["RET"])
    assert Editor.current_buffer() == sub
    assert Buffer.get_local(sub, "mode-name") == "Dired"

    # C-n takes the selection back to the candidates: RET then means the file
    press(["C-x", "C-f"])
    type(root <> "/only")
    press(["TAB", "C-n", "RET"])
    assert Editor.current_buffer() == Path.join(sub, "a.txt")

    File.rm_rf!(root)
  end

  test "C-x C-f matches the mode a file would open in" do
    root = Path.join(System.tmp_dir!(), "aimax-fmode-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "sub"))
    File.write!(Path.join(root, "one.exs"), "x")
    File.write!(Path.join(root, "two.txt"), "y")

    press(["C-x", "C-f"])
    type(root <> "/")

    # the directory is the only Dired candidate, and "dired" alone finds it
    type("dired")
    assert Enum.map(Editor.render_state().minibuffer.candidates, & &1.label) == ["sub/"]

    # a size and a date are annotation too, and a term must never match them:
    # "aug" is a month, not a file
    clear_minibuffer()
    type(root <> "/aug")
    assert Editor.render_state().minibuffer.candidates == []

    clear_minibuffer()
    type(root <> "/elixir")
    press(["RET"])
    assert Editor.current_buffer() == Path.join(root, "one.exs")

    File.rm_rf!(root)
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

  test "C-x b matches the mode in the marginalia, not the name alone", %{buf: buf} do
    n = System.unique_integer([:positive])
    plain = "swm-plain-#{n}"
    prose = "swm-prose-#{n}"
    Aimax.Core.create_buffer(plain)
    Aimax.Core.create_buffer(prose)

    {:ok, _} =
      Aimax.Core.Session.eval("""
      (begin (switch-to-buffer! "#{prose}") (set-mode! "text-mode")
             (switch-to-buffer! "#{buf}"))
      """)

    # the mode is the annotation, and typing it finds the buffer
    press(["C-x", "b"])
    type("text-mode")
    labels = Enum.map(Editor.render_state().minibuffer.candidates, & &1.label)
    assert prose in labels
    refute plain in labels

    # only from the START of the mode: every mode name ends in "-mode", so a
    # term matching inside one would match every buffer there is
    clear_minibuffer()
    type("mode")
    refute prose in Enum.map(Editor.render_state().minibuffer.candidates, & &1.label)

    # orderless across both: one term matches the mode, the other the name
    clear_minibuffer()
    type("text-mode swm-prose")
    press(["RET"])
    assert Editor.current_buffer() == prose

    # a name still matches a name — the annotation only adds candidates
    press(["C-x", "b"])
    type(plain)
    press(["RET"])
    assert Editor.current_buffer() == plain
  end

  test "C-x b is history first: previous buffer defaults, containers ride under it" do
    n = System.unique_integer([:positive])
    m1 = "ct-a-#{n}"
    m2 = "ct-b-#{n}"
    home = "ct-home-#{n}"
    for b <- [m1, m2, home], do: Aimax.Core.create_buffer(b)

    {:ok, _} =
      Aimax.Core.Session.eval("""
      (begin (set-frame-local! 'current-group #f)
             (delete-other-windows!)
             (switch-to-buffer! "#{m1}")
             (switch-to-buffer! "#{m2}")
             (buffer-set-local! "#{m1}" 'group "ctgrp-#{n}")
             (buffer-set-local! "#{m2}" 'group "ctgrp-#{n}")
             (switch-to-buffer! "#{home}"))
      """)

    # pure history: the previous buffer is the default; groups have no
    # rows of their own — the buffer rows carry the group
    press(["C-x", "b"])
    mb = Editor.render_state().minibuffer
    labels = Enum.map(mb.candidates, & &1.label)
    assert hd(labels) == m2
    refute "[ctgrp-#{n}]" in labels
    assert mb.prompt =~ "default #{m2}"

    # RET is a BUFFER switch: one window changes, nothing else moves,
    # and the frame's group does not change
    press(["RET"])
    assert Editor.current_buffer() == m2
    assert length(Editor.list_windows()) == 1
    # a plain switch moves no windows, but the standing follows
    assert Aimax.Core.Session.eval("(frame-local 'current-group)") ==
             {:ok, ~s{"ctgrp-#{n}"}}

    # C-RET is the CONTEXT switch: the group's layout comes up with
    # point in the picked buffer, and the frame enters the group.
    # (Drop the snapshot the switcher just took, so the default
    # arrangement is what comes up.)
    press(["C-x", "b"])

    {:ok, _} =
      Aimax.Core.Session.eval(~s{(buffer-set-local! (group-chat "ctgrp-#{n}") 'group-layout #f)})

    type(m1)
    press(["C-RET"])
    assert Editor.current_buffer() == m1

    shown =
      Editor.list_windows() |> Enum.map(fn {_id, b} -> b end) |> Enum.sort()

    assert shown == Enum.sort([m1, m2])

    assert Aimax.Core.Session.eval("(frame-local 'current-group)") ==
             {:ok, ~s{"ctgrp-#{n}"}}

    {:ok, _} =
      Aimax.Core.Session.eval(
        "(begin (set-frame-local! 'current-group #f) (delete-other-windows!))"
      )
  end

  test "a group you switched to is a history row; its name finds it and its members" do
    n = System.unique_integer([:positive])
    m1 = "hs-a-#{n}"
    m2 = "hs-b-#{n}"
    home = "hs-home-#{n}"
    for x <- [m1, m2, home], do: Aimax.Core.create_buffer(x)

    {:ok, _} =
      Aimax.Core.Session.eval("""
      (begin (set-frame-local! 'current-group #f)
             (delete-other-windows!)
             (switch-to-buffer! "#{m1}")
             (switch-to-buffer! "#{m2}")
             (buffer-set-local! "#{m1}" 'group "hsgrp-#{n}")
             (buffer-set-local! "#{m2}" 'group "hsgrp-#{n}")
             (switch-to-group! "hsgrp-#{n}")
             (switch-to-buffer! "#{home}")
             ;; leave the context: the frame stands nowhere now, so the
             ;; group is history like anything else
             (set-frame-local! 'current-group #f))
      """)

    # the switch is itself a history entry: the group's card leads the
    # stream, above the members its restore bumped
    press(["C-x", "b"])
    labels = Enum.map(Editor.render_state().minibuffer.candidates, & &1.label)
    assert hd(labels) == "[hsgrp-#{n}]"

    # searching the group's name finds the card AND the members
    type("hsgrp-#{n}")
    labels = Enum.map(Editor.render_state().minibuffer.candidates, & &1.label)
    assert "[hsgrp-#{n}]" in labels
    assert m1 in labels
    assert m2 in labels
    press(["C-g"])

    # RET on the card returns to the group
    press(["C-x", "b"])
    press(["RET"])
    assert Aimax.Core.Session.eval("(frame-local 'current-group)") ==
             {:ok, ~s{"hsgrp-#{n}"}}

    assert Editor.current_buffer() in [m1, m2]

    {:ok, _} =
      Aimax.Core.Session.eval(
        "(begin (set-frame-local! 'current-group #f) (delete-other-windows!))"
      )
  end

  test "modeline-expand attaches the panel to the buffer itself" do
    n = System.unique_integer([:positive])
    b = "dash-#{n}"
    Aimax.Core.create_buffer(b)

    {:ok, _} =
      Aimax.Core.Session.eval("""
      (begin (set-frame-local! 'current-group #f)
             (delete-other-windows!)
             (switch-to-buffer! "#{b}")
             (buffer-append! "#{b}" "0123456789")
             (goto-char! 7)
             (buffer-set-local! "#{b}" 'group "dashgrp-#{n}"))
      """)

    # expanding changes NOTHING about where you are: same buffer, same
    # point — the panel is an attachment, not a place
    press(["C-x", "?"])
    assert Editor.current_buffer() == b
    assert Aimax.Core.Session.eval("(point)") == {:ok, "7"}
    assert Aimax.Core.Buffer.get_local(b, "modeline-expanded") == true

    blocks =
      inspect(Aimax.Core.Buffer.get_local(b, "modeline-dash-blocks"),
        limit: :infinity,
        printable_limit: :infinity
      )

    assert blocks =~ "dashgrp-#{n}"
    assert blocks =~ "companion"
    assert blocks =~ "lane"
    refute blocks =~ "all groups"

    # the same key detaches it; the buffer never noticed
    press(["C-x", "?"])
    assert Aimax.Core.Buffer.get_local(b, "modeline-expanded") in [nil, false]
    assert Editor.current_buffer() == b
    assert Aimax.Core.Session.eval("(point)") == {:ok, "7"}

    {:ok, _} = Aimax.Core.Session.eval("(delete-other-windows!)")
  end

  test "winner: a destroyed layout is one undo away; redo returns" do
    n = System.unique_integer([:positive])
    b = "wn-#{n}"
    Aimax.Core.create_buffer(b)

    {:ok, _} =
      Aimax.Core.Session.eval("""
      (begin (set-frame-local! 'current-group #f)
             (set-frame-local! 'winner-ring #f)
             (set-frame-local! 'winner-pos #f)
             (delete-other-windows!)
             (switch-to-buffer! "#{b}")
             (split-window! 'h 0.5))
      """)

    assert length(Editor.list_windows()) == 2

    # C-x 1 destroys the split; winner-undo brings it back
    press(["C-x", "1"])
    assert length(Editor.list_windows()) == 1
    press(["C-c", "<left>"])
    assert length(Editor.list_windows()) == 2

    # redo walks forward to the single window again
    press(["C-c", "<right>"])
    assert length(Editor.list_windows()) == 1
    {:ok, _} = Aimax.Core.Session.eval("(delete-other-windows!)")
  end

  test "winner: a group switch is one undo away" do
    n = System.unique_integer([:positive])
    m = "wg-a-#{n}"
    home = "wg-home-#{n}"
    for x <- [m, home], do: Aimax.Core.create_buffer(x)

    {:ok, _} =
      Aimax.Core.Session.eval("""
      (begin (set-frame-local! 'current-group #f)
             (set-frame-local! 'winner-ring #f)
             (set-frame-local! 'winner-pos #f)
             (buffer-set-local! "#{m}" 'group "wggrp-#{n}")
             (delete-other-windows!)
             (switch-to-buffer! "#{home}")
             (switch-to-group! "wggrp-#{n}"))
      """)

    assert Editor.current_buffer() == m

    # undo: back to the arrangement before the switch
    press(["C-c", "<left>"])
    assert Editor.current_buffer() == home

    {:ok, _} =
      Aimax.Core.Session.eval(
        "(begin (set-frame-local! 'current-group #f) (delete-other-windows!))"
      )
  end

  test "C-RET on a project buffer materializes the project as a group" do
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "pg-#{n}")
    File.mkdir_p!(Path.join(root, ".git"))
    f1 = Path.join(root, "one.txt")
    f2 = Path.join(root, "two.txt")
    File.write!(f1, "one")
    File.write!(f2, "two")
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, _} =
      Aimax.Core.Session.eval("""
      (begin (set-frame-local! 'current-group #f)
             (delete-other-windows!)
             (visit "#{f1}")
             (visit "#{f2}")
             (switch-to-buffer! "*scratch*"))
      """)

    press(["C-x", "b"])
    type("one.txt")
    press(["C-RET"])

    # the project's open buffers joined a group named by the root, and
    # the context came up arranged
    assert Aimax.Core.Session.eval(~s{(buffer-group "#{f1}")}) == {:ok, ~s{"#{root}"}}
    assert Aimax.Core.Session.eval(~s{(buffer-group "#{f2}")}) == {:ok, ~s{"#{root}"}}
    assert Editor.current_buffer() == f1

    shown = Editor.list_windows() |> Enum.map(fn {_id, b} -> b end) |> Enum.sort()
    assert shown == Enum.sort([f1, f2])

    {:ok, _} =
      Aimax.Core.Session.eval(
        "(begin (set-frame-local! 'current-group #f) (delete-other-windows!))"
      )
  end

  test "TAB completes the single remaining candidate" do
    n = System.unique_integer([:positive])
    b = "tabone-#{n}"
    Aimax.Core.create_buffer(b)

    press(["C-x", "b"])
    type("tabone-#{n}")
    press(["TAB"])
    assert Editor.render_state().minibuffer.input == b
    press(["RET"])
    assert Editor.current_buffer() == b
  end

  test "TAB locks the switcher to the one group the input names" do
    n = System.unique_integer([:positive])
    m1 = "lk-a-#{n}"
    m2 = "lk-b-#{n}"
    out = "lk-out-#{n}"
    for b <- [m1, m2, out], do: Aimax.Core.create_buffer(b)

    {:ok, _} =
      Aimax.Core.Session.eval("""
      (begin (switch-to-buffer! "#{m1}")
             (switch-to-buffer! "#{m2}")
             (buffer-set-local! "#{m1}" 'group "lkgrp-#{n}")
             (buffer-set-local! "#{m2}" 'group "lkgrp-#{n}")
             (switch-to-buffer! "#{out}"))
      """)

    press(["C-x", "b"])
    type("lkgrp-#{n}")
    press(["TAB"])

    mb = Editor.render_state().minibuffer
    assert mb.input == ""
    labels = Enum.map(mb.candidates, & &1.label)
    assert "[lkgrp-#{n}]" in labels
    assert m1 in labels
    assert m2 in labels
    refute out in labels
    press(["C-g"])
  end

  test "the TAB-locked pool leads with a container row carrying kind and chips" do
    n = System.unique_integer([:positive])
    m1 = "cc-a-#{n}"
    home = "cc-home-#{n}"
    for b <- [m1, home], do: Aimax.Core.create_buffer(b)

    {:ok, _} =
      Aimax.Core.Session.eval("""
      (begin (set-frame-local! 'current-group #f)
             (switch-to-buffer! "#{m1}")
             (buffer-set-local! "#{m1}" 'group "ccgrp-#{n}")
             (switch-to-buffer! "#{home}"))
      """)

    press(["C-x", "b"])
    # the open pool is pure history: no container rows
    refute Enum.any?(Editor.render_state().minibuffer.candidates, &(&1.label =~ "[ccgrp"))
    type("ccgrp-#{n}")
    press(["TAB"])
    c = Enum.find(Editor.render_state().minibuffer.candidates, &(&1.label == "[ccgrp-#{n}]"))
    assert c
    assert c.kind == "container"
    assert m1 in c.chips
    press(["C-g"])
  end

  test "RET on a name that matches nothing founds a group from the windows", %{buf: buf} do
    n = System.unique_integer([:positive])

    {:ok, _} =
      Aimax.Core.Session.eval(~s{(begin (delete-other-windows!) (switch-to-buffer! "#{buf}"))})

    press(["C-x", "b"])
    type("zzqxw-#{n}")
    press(["RET"])
    assert Aimax.Core.Session.eval(~s{(buffer-group "#{buf}")}) == {:ok, ~s{"zzqxw-#{n}"}}
    {:ok, _} = Aimax.Core.Session.eval(~s{(buffer-set-local! "#{buf}" 'group #f)})
  end

  test "the groups board lists a group; noise cycles and persists" do
    n = System.unique_integer([:positive])
    b = "gb-#{n}"
    Aimax.Core.create_buffer(b)

    {:ok, _} =
      Aimax.Core.Session.eval("""
      (begin (buffer-set-local! "#{b}" 'group "gbgrp-#{n}")
             (run-command "groups"))
      """)

    assert Editor.current_buffer() == "*groups*"
    assert Buffer.text("*groups*") =~ "gbgrp-#{n}"

    assert Aimax.Core.Session.eval(~s{(group-noise "gbgrp-#{n}")}) == {:ok, ~s{"quiet"}}
    {:ok, _} = Aimax.Core.Session.eval(~s{(group-noise-set! "gbgrp-#{n}" "loud")})
    assert Aimax.Core.Session.eval(~s{(group-noise "gbgrp-#{n}")}) == {:ok, ~s{"loud"}}

    assert {:ok, out} =
             Aimax.Core.Session.eval(~s{(if (member 'group-noise chat-identity-locals) #t #f)})

    assert out == "#t"
    press(["q"])
  end

  test "the ring toggles: C-x b RET goes back, and back again" do
    n = System.unique_integer([:positive])
    a = "rg-a-#{n}"
    b = "rg-b-#{n}"
    for x <- [a, b], do: Aimax.Core.create_buffer(x)

    {:ok, _} =
      Aimax.Core.Session.eval("""
      (begin (set-frame-local! 'current-group #f)
             (delete-other-windows!)
             (switch-to-buffer! "#{a}")
             (switch-to-buffer! "#{b}"))
      """)

    press(["C-x", "b"])
    assert Editor.render_state().minibuffer.prompt =~ "default #{a}"
    press(["RET"])
    assert Editor.current_buffer() == a

    press(["C-x", "b"])
    assert Editor.render_state().minibuffer.prompt =~ "default #{b}"
    press(["RET"])
    assert Editor.current_buffer() == b
  end

  test "C-x o records the focused window's buffer in the ring" do
    n = System.unique_integer([:positive])
    left = "wo-a-#{n}"
    right = "wo-b-#{n}"
    for x <- [left, right], do: Aimax.Core.create_buffer(x)

    {:ok, _} =
      Aimax.Core.Session.eval("""
      (begin (set-frame-local! 'current-group #f)
             (delete-other-windows!)
             (switch-to-buffer! "#{left}")
             (split-window! 'h 0.5)
             (other-window!)
             (switch-to-buffer! "#{right}")
             (other-window!))
      """)

    # focusing left last: left leads the ring
    assert {:ok, mru} = Aimax.Core.Session.eval("(buffer-list-mru)")
    assert mru =~ ~r/\A\("#{left}" "#{right}"/

    # C-x o focuses right: right leads now
    press(["C-x", "o"])
    assert {:ok, mru} = Aimax.Core.Session.eval("(buffer-list-mru)")
    assert mru =~ ~r/\A\("#{right}" "#{left}"/
    {:ok, _} = Aimax.Core.Session.eval("(delete-other-windows!)")
  end

  test "a group switch records the landed buffers in the ring" do
    n = System.unique_integer([:positive])
    m1 = "gr-a-#{n}"
    m2 = "gr-b-#{n}"
    home = "gr-home-#{n}"
    for x <- [m1, m2, home], do: Aimax.Core.create_buffer(x)

    {:ok, _} =
      Aimax.Core.Session.eval("""
      (begin (set-frame-local! 'current-group #f)
             (delete-other-windows!)
             (switch-to-buffer! "#{m1}")
             (switch-to-buffer! "#{m2}")
             (buffer-set-local! "#{m1}" 'group "grgrp-#{n}")
             (buffer-set-local! "#{m2}" 'group "grgrp-#{n}")
             (switch-to-buffer! "#{home}")
             (switch-to-group! "grgrp-#{n}")
             #t)
      """)

    # the landed buffer leads history; the other shown member is next;
    # home — where we came from — right after
    assert {:ok, mru} = Aimax.Core.Session.eval("(buffer-list-mru)")
    heads = mru |> String.trim_leading("(") |> String.split(" ") |> Enum.take(3)
    assert Enum.at(heads, 0) == ~s{"#{m2}"}
    assert ~s{"#{m1}"} in heads
    assert ~s{"#{home}"} in heads

    {:ok, _} =
      Aimax.Core.Session.eval("(begin (set-frame-local! 'current-group #f) (delete-other-windows!))")
  end

  test "a stale off-screen buffer catches up when the switcher shows it" do
    n = System.unique_integer([:positive])
    b = "st-#{n}"
    Aimax.Core.create_buffer(b)

    {:ok, _} =
      Aimax.Core.Session.eval("""
      (begin (set-frame-local! 'current-group #f)
             (delete-other-windows!)
             (buffer-set-local! "#{b}" 'probe-stale #t)
             (switch-to-buffer! "*scratch*"))
      """)

    {:ok, _} =
      Aimax.Core.Session.eval("""
      (on-buffer-shown!
        (lambda (buf)
          (when (buffer-local buf 'probe-stale)
            (buffer-set-local! buf 'probe-stale #f)
            (buffer-set-local! buf 'probe-caught #t))))
      """)

    press(["C-x", "b"])
    type(b)
    press(["RET"])
    assert Editor.current_buffer() == b
    assert Buffer.get_local(b, "probe-caught") == true
  end

  test "group-rename retags members and carries the identity" do
    n = System.unique_integer([:positive])
    m1 = "rn-a-#{n}"
    m2 = "rn-b-#{n}"
    for x <- [m1, m2], do: Aimax.Core.create_buffer(x)

    {:ok, _} =
      Aimax.Core.Session.eval("""
      (begin (set-frame-local! 'current-group "rngrp-#{n}")
             (buffer-set-local! "#{m1}" 'group "rngrp-#{n}")
             (buffer-set-local! "#{m2}" 'group "rngrp-#{n}")
             (group-meta-set! "rngrp-#{n}" "the renamed group")
             (group-rename! "rngrp-#{n}" "fresh-#{n}"))
      """)

    assert Aimax.Core.Session.eval(~s{(buffer-group "#{m1}")}) == {:ok, ~s{"fresh-#{n}"}}
    assert Aimax.Core.Session.eval(~s{(buffer-group "#{m2}")}) == {:ok, ~s{"fresh-#{n}"}}
    assert Aimax.Core.Session.eval(~s{(group-meta "fresh-#{n}")}) ==
             {:ok, ~s{"the renamed group"}}

    assert Aimax.Core.Session.eval("(frame-local 'current-group)") == {:ok, ~s{"fresh-#{n}"}}

    {:ok, _} = Aimax.Core.Session.eval("(set-frame-local! 'current-group #f)")
  end

  test "group-kill kills the members but keeps modified file buffers" do
    n = System.unique_integer([:positive])
    m1 = "gk-a-#{n}"
    m2 = "gk-b-#{n}"
    f = Path.join(System.tmp_dir!(), "gk-f-#{n}.txt")
    File.write!(f, "saved")
    on_exit(fn -> File.rm(f) end)

    for b <- [m1, m2], do: Aimax.Core.create_buffer(b)

    {:ok, _} =
      Aimax.Core.Session.eval("""
      (begin (visit "#{f}")
             (buffer-insert! "#{f}" 0 "unsaved ")
             (for-each (lambda (b) (buffer-set-local! b 'group "gkgrp-#{n}"))
                       (list "#{m1}" "#{m2}" "#{f}"))
             (group-kill! "gkgrp-#{n}"))
      """)

    refute Buffer.exists?(m1)
    refute Buffer.exists?(m2)
    assert Buffer.exists?(f)

    {:ok, _} =
      Aimax.Core.Session.eval(~s{(begin (buffer-mark-saved! "#{f}") (buffer-kill! "#{f}") #t)})
  end

  test "the layout restores as saved — no second-guessing" do
    n = System.unique_integer([:positive])
    m = "hl-a-#{n}"
    Aimax.Core.create_buffer(m)

    {:ok, out} =
      Aimax.Core.Session.eval("""
      (begin (set-frame-local! 'current-group #f)
             (buffer-set-local! "#{m}" 'group "hlgrp-#{n}")
             ;; poison: capture a layout showing only scratch, store it
             ;; as the group's own
             (delete-other-windows!)
             (switch-to-buffer! "*scratch*")
             (buffer-set-local! (group-chat "hlgrp-#{n}") 'group-layout (window-tree))
             (switch-to-group! "hlgrp-#{n}")
             (list (group-on-screen? "hlgrp-#{n}") (current-buffer)))
      """)

    assert out == ~s{(#t "#{m}")}

    {:ok, _} =
      Aimax.Core.Session.eval(
        "(begin (set-frame-local! 'current-group #f) (delete-other-windows!))"
      )
  end

  test "the groups board never becomes part of a group's layout" do
    n = System.unique_integer([:positive])
    m = "tb-#{n}"
    Aimax.Core.create_buffer(m)

    {:ok, _} =
      Aimax.Core.Session.eval("""
      (begin (set-frame-local! 'current-group #f)
             (delete-other-windows!)
             (switch-to-buffer! "#{m}")
             (buffer-set-local! "#{m}" 'group "tbgrp-#{n}")
             (group-layout-save! "tbgrp-#{n}")
             ;; poison attempt: the board opens beside the member and a
             ;; capture fires from the board — the guard must refuse
             (split-window! 'h 0.5)
             (other-window!)
             (run-command "groups")
             (group-layout-save-if-shown! "tbgrp-#{n}")
             ;; and an OLD poisoned snapshot prunes on the way back in
             (buffer-set-local! (group-chat "tbgrp-#{n}") 'group-layout (window-tree))
             (switch-to-buffer! "*scratch*")
             (delete-other-windows!)
             (switch-to-group! "tbgrp-#{n}")
             #t)
      """)

    shown = Editor.list_windows() |> Enum.map(fn {_id, b} -> b end)
    refute "*groups*" in shown
    assert m in shown

    {:ok, _} =
      Aimax.Core.Session.eval(
        "(begin (set-frame-local! 'current-group #f) (delete-other-windows!))"
      )
  end

  test "a killed file member comes back with content, not an empty shell" do
    n = System.unique_integer([:positive])
    f = Path.join(System.tmp_dir!(), "gs-#{n}.txt")
    File.write!(f, "the real content")
    on_exit(fn -> File.rm(f) end)
    home = "gs-home-#{n}"
    Aimax.Core.create_buffer(home)

    {:ok, _} =
      Aimax.Core.Session.eval("""
      (begin (set-frame-local! 'current-group #f)
             (delete-other-windows!)
             (visit "#{f}")
             (buffer-set-local! "#{f}" 'group "gsgrp-#{n}")
             (group-layout-save! "gsgrp-#{n}")
             (switch-to-buffer! "#{home}")
             (buffer-kill! "#{f}")
             (switch-to-group! "gsgrp-#{n}")
             #t)
      """)

    assert Editor.current_buffer() == f
    assert Aimax.Core.Buffer.text(f) == "the real content"

    {:ok, _} =
      Aimax.Core.Session.eval(
        ~s{(begin (buffer-kill! "#{f}") (set-frame-local! 'current-group #f) (delete-other-windows!))}
      )
  end

  test "a group's layout survives leave and restore" do
    n = System.unique_integer([:positive])
    m = "ly-a-#{n}"
    Aimax.Core.create_buffer(m)

    {:ok, out} =
      Aimax.Core.Session.eval("""
      (begin (delete-other-windows!)
             (switch-to-buffer! "#{m}")
             (buffer-set-local! "#{m}" 'group "lygrp-#{n}")
             (split-window! 'h 0.5)
             (group-layout-save! "lygrp-#{n}")
             (delete-other-windows!)
             (let ((one (length (window-list))))
               (window-tree-set! (group-layout "lygrp-#{n}"))
               (list one (length (window-list)))))
      """)

    assert out == "(1 2)"
    {:ok, _} = Aimax.Core.Session.eval("(delete-other-windows!)")
  end

  test "prompts with candidates open as a centered palette; line inputs do not" do
    press(["C-x", "b"])
    assert Editor.render_state().minibuffer.style == "palette"
    press(["C-g"])
    # M-x completes over commands, so it is a palette too
    press(["M-x"])
    assert Editor.render_state().minibuffer.style == "palette"
    press(["C-g"])
    # eval-expression has no candidates: it keeps the bottom bar
    press(["M-:"])
    assert Editor.render_state().minibuffer.style in [nil, false]
    press(["C-g"])
  end

  test "find-file opens the file into the current group" do
    n = System.unique_integer([:positive])
    f = Path.join(System.tmp_dir!(), "gf-#{n}.txt")
    File.write!(f, "hello")
    on_exit(fn -> File.rm(f) end)

    {:ok, _} =
      Aimax.Core.Session.eval("""
      (begin (buffer-create "gf-home-#{n}")
             (switch-to-buffer! "gf-home-#{n}")
             (buffer-set-local! "gf-home-#{n}" 'group "gf-grp-#{n}")
             (visit-in-group "#{f}" (buffer-group (current-buffer))))
      """)

    assert Aimax.Core.Session.eval(~s{(buffer-group "#{f}")}) == {:ok, ~s{"gf-grp-#{n}"}}
  end

  test "group metadata lives on the group chat and survives identity" do
    n = System.unique_integer([:positive])
    b = "gm-#{n}"
    Aimax.Core.create_buffer(b)

    {:ok, _} =
      Aimax.Core.Session.eval("""
      (begin (switch-to-buffer! "#{b}")
             (buffer-set-local! "#{b}" 'group "gm-grp-#{n}")
             (group-meta-set! "gm-grp-#{n}" "the demo group"))
      """)

    assert {:ok, ~s{"the demo group"}} =
             Aimax.Core.Session.eval(~s{(group-meta "gm-grp-#{n}")})

    # the standing rule: a chat local belongs to exactly one list
    assert {:ok, out} =
             Aimax.Core.Session.eval(~s{(if (member 'group-meta chat-identity-locals) #t #f)})

    assert out == "#t"
  end

  test "the project column narrows C-x b to the project's buffers" do
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "proj-#{n}")
    File.mkdir_p!(Path.join(root, ".git"))
    f1 = Path.join(root, "one.txt")
    f2 = Path.join(root, "two.txt")
    File.write!(f1, "one")
    File.write!(f2, "two")
    on_exit(fn -> File.rm_rf!(root) end)
    loose = "loose-#{n}"
    Aimax.Core.create_buffer(loose)

    {:ok, _} =
      Aimax.Core.Session.eval("""
      (begin (visit "#{f2}")
             (switch-to-buffer! "#{loose}")
             (visit "#{f1}"))
      """)

    # the project name is a marginalia column: typing it finds the
    # project's buffers and not the loose one
    press(["C-x", "b"])
    type("proj-#{n}")
    labels = Enum.map(Editor.render_state().minibuffer.candidates, & &1.label)
    assert f2 in labels
    refute loose in labels
    press(["C-g"])
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
      # C-x b RET on a NEW name founds a group now; an existing buffer switches
      Aimax.Core.create_buffer(other)
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

  # a markdown preview shows point and takes edits, so motion keys move
  # point; an html preview has no visible point, so they scroll instead
  test "motion keys move point in a markdown preview" do
    path = Path.join(System.tmp_dir!(), "aimax-prevmove-#{System.unique_integer([:positive])}.md")
    File.write!(path, "# Title\n\nbody\n")

    press(["C-x", "C-f"])
    type(path)
    press(["RET"])
    press(["C-c", "C-v"])
    assert Buffer.get_local(path, "render-mode") == "markdown"

    Buffer.goto(path, 0)
    press(["C-n"])
    assert Buffer.point(path) > 0
    Buffer.goto(path, 0)
    press(["<down>"])
    assert Buffer.point(path) > 0
    press(["<right>"])
    p = Buffer.point(path)
    press(["<left>"])
    assert Buffer.point(path) == p - 1

    press(["C-x", "1"])
    File.rm!(path)
  end

  # the click mapping: the clicked text node split at the caret finds its
  # spot in the source; smartened text falls back to the plain word run
  test "a preview click moves point to the clicked text" do
    path = Path.join(System.tmp_dir!(), "aimax-prevclick-#{System.unique_integer([:positive])}.md")
    File.write!(path, "# Title\n\nThe cursor should be visible.\n")

    press(["C-x", "C-f"])
    type(path)
    press(["RET"])
    press(["C-c", "C-v"])

    win = Editor.render_state() |> Map.get(:tree) |> Map.get(:id)

    {:ok, _} =
      Aimax.Core.Session.call_named("preview-goto!", [win, "The cursor sh", "ould be", "sh", "ould"])

    assert Buffer.point(path) == 22

    # the renderer smartened the text: the exact node misses, the word run hits
    Buffer.goto(path, 0)

    {:ok, _} =
      Aimax.Core.Session.call_named("preview-goto!", [win, "“cursor” sh", "ould", "sh", "ould"])

    assert Buffer.point(path) == 22

    press(["C-x", "1"])
    File.rm!(path)
  end

  test "motion keys still scroll an html preview" do
    path = Path.join(System.tmp_dir!(), "aimax-prevhtml-#{System.unique_integer([:positive])}.html")
    File.write!(path, "<h1>hi</h1>\n<p>body</p>\n")

    press(["C-x", "C-f"])
    type(path)
    press(["RET"])
    press(["C-c", "C-v"])
    assert Buffer.get_local(path, "render-mode") == "html"

    Buffer.goto(path, 0)
    press(["C-n"])
    assert Buffer.point(path) == 0

    press(["C-x", "1"])
    File.rm!(path)
  end
end
