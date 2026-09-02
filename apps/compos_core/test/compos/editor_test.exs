defmodule Compos.EditorTest do
  @moduledoc "Drives the editor purely through key events — the same path the GUI uses."

  use ExUnit.Case

  alias Compos.Core.{Buffer, Editor, KeyDispatch}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(str), do: str |> String.graphemes() |> press()

  # A verb by its name. Which key reaches it is a preference that moves.
  defp run(command) do
    {:ok, _} = Compos.Core.Session.eval(~s[(run-command "#{command}")])
  end

  # A chat gets a runtime on its first send, on the connector it names or
  # the default. The default is claude-code, which is a subprocess this
  # test env does not have — so the send went nowhere and no reply ever
  # came. "api" is the in-process connector, and :llm_chat_fun is its
  # seam: the stub these tests install.
  defp use_api_connector! do
    {:ok, before} = Compos.Core.Session.eval("*default-connector*")
    {:ok, _} = Compos.Core.Session.eval(~s{(set! *default-connector* "api")})
    on_exit(fn -> Compos.Core.Session.eval(~s{(set! *default-connector* #{before})}) end)
  end

  defp fresh_buffer do
    name = "test-#{System.unique_integer([:positive])}"
    # reset editor state a failed test may have left behind. The frame's
    # group is part of that state: a test that entered a group leaves the
    # next one starting inside it, and a buffer born in a group is not the
    # groupless buffer the next test asked for.
    Compos.Core.Session.eval(
      "(begin (set-frame-local! 'current-group #f) (set-frame-local! 'previous-group #f))"
    )
    Editor.minibuffer_close()
    Editor.completion_dismiss()
    Editor.set_pending([])
    Editor.set_echo("")
    Editor.delete_other_windows()
    Editor.set_window_buffer(name)
    name
  end

  defp echo, do: Editor.snapshot().echo

  # A group's name can change; its ID cannot. Run CODE that answers a
  # group ID and return the raw ID, so a test can name the group by
  # identity for the rest of its body.
  defp group_id!(code) do
    {:ok, quoted} = Compos.Core.Session.eval(code)
    id = String.trim(quoted, "\"")
    assert String.starts_with?(id, "grp:"), "expected a group ID, got #{quoted}"
    id
  end

  # The group a buffer belongs to, as an ID, or nil. The legacy 'group
  # buffer-local no longer answers: a work buffer holds 'group-ids and a
  # chat holds one 'group-id.
  defp buffer_group(name) do
    {:ok, quoted} = Compos.Core.Session.eval(~s{(buffer-group "#{name}")})
    if quoted == "#f", do: nil, else: String.trim(quoted, "\"")
  end

  # Is NAME a member of the group called GROUP? A buffer can hold several
  # memberships, and buffer-group answers only the first — so a test that
  # asks "is it in this group" must ask that, not "which group is it in".
  # A project group another test founded put itself first and the reader
  # saw the wrong name.
  defp in_group?(name, group) do
    {:ok, quoted} = Compos.Core.Session.eval(~s{(buffer-in-group? "#{name}" "#{group}")})
    quoted == "#t"
  end

  # The display name a group ID currently carries.
  defp group_name(id) do
    {:ok, quoted} = Compos.Core.Session.eval(~s{(group-name "#{id}")})
    if quoted == "#f", do: nil, else: String.trim(quoted, "\"")
  end

  defp evict(name) do
    :ok = Buffer.checkpoint_now(name)
    [{pid, _}] = Registry.lookup(Compos.Core.BufferRegistry, name)
    :ok = DynamicSupervisor.terminate_child(Compos.Core.BufferSupervisor, pid)
    assert eventually(fn -> not Buffer.exists?(name) end)
  end

  # DEL back over whatever the prompt holds, the way a user retypes
  # the minibuffer switcher survives for the surfaces that can only draw a
  # prompt (a browser page); these tests drive it directly
  defp open_switch_prompt do
    {:ok, _} = Compos.Core.Session.eval(~s[(run-command "switch-to-buffer-prompt")])
  end

  # Open a switcher by its own command, never by a key. A binding is a
  # preference and it moves: C-x b named the modal switcher until the
  # group-aware prompt took it, and every test that pressed it failed the
  # same night, each one reporting a *switch* buffer that nobody opened.
  # A test that says which switcher it means cannot fail that way.
  defp open_modal_switcher do
    {:ok, _} = Compos.Core.Session.eval(~s[(run-command "switch-to-buffer")])
  end

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
    Compos.Core.Session.run_command("eval-buffer")
    assert echo() == "=> 22"

    # region over just the define: evals only that
    Buffer.set_mark(buf, 0)
    Buffer.goto(buf, 23)
    Compos.Core.Session.run_command("eval-region")
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

  test "line motion treats embedded images as atomic", %{buf: buf} do
    image = "https://images.example/avatar.jpg"
    text = "abc\n" <> image <> "\nxyz"
    type(text)

    image_start = 4
    image_end = image_start + byte_size(image)
    Buffer.set_overlays(buf, :test, [{image_start, image_end, "img-embed"}])

    Buffer.goto(buf, image_start)
    assert Buffer.forward_char(buf) == image_end
    assert Buffer.backward_char(buf) == image_start

    Buffer.goto(buf, 2)
    assert Buffer.next_line(buf) == image_end
    assert Buffer.next_line(buf) == image_end + 1 + 2
    assert Buffer.previous_line(buf) == image_start
    assert Buffer.previous_line(buf) == 2
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
    n = Compos.Core.Editor.kill_size()
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
    path = Path.join(System.tmp_dir!(), "compos-mode-#{System.unique_integer([:positive])}.md")
    File.write!(path, "# hi")

    {:ok, _} =
      Compos.Core.Session.eval("""
      (add-hook! 'after-save-hook (lambda () (message "saved-hook-ran")))
      """)

    press(["C-x", "C-f"])
    type(path)
    press(["RET"])
    assert Editor.current_buffer() == path

    leaf = find_active_leaf(Editor.render_state().tree, Editor.snapshot().active)
    assert leaf.mode == "morg-mode"

    press(["C-x", "C-s"])
    assert elem(Compos.Core.Session.eval("(messages-text)"), 1) =~ "saved-hook-ran"
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
    assert Buffer.point(buf) == Compos.Core.Buffer.byte_size(buf)
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

  test "C-s repeats the search, wraps, and C-r turns it around", %{buf: buf} do
    type("alpha beta gamma beta delta beta")
    press(["M-<"])

    press(["C-s"])
    type("beta")
    # first match: point at its end, mark at its start
    assert Buffer.point(buf) == 10
    assert Buffer.mark(buf) == 6

    press(["C-s"])
    assert Buffer.point(buf) == 21
    press(["C-s"])
    assert Buffer.point(buf) == 32

    # past the last match the search wraps to the first
    press(["C-s"])
    assert Buffer.point(buf) == 10
    assert echo() == "Search wrapped"

    # C-r turns the same search around
    press(["C-r"])
    assert Buffer.point(buf) == 6
    assert Buffer.mark(buf) == 10

    press(["RET"])
    assert Buffer.mark(buf) == nil
  end

  test "an empty C-s repeats the last search", %{buf: buf} do
    type("one two one")
    press(["M-<"])

    press(["C-s"])
    type("two")
    press(["RET"])
    assert Buffer.point(buf) == 7

    press(["M-<", "C-s", "C-s"])
    assert Buffer.point(buf) == 7
    press(["RET"])
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
    {:ok, _} = Compos.Core.Session.eval(~s{(buffer-set-read-only! "#{buf}" #t)})

    type("x")
    assert Buffer.text(buf) == "locked"
    assert echo() == "Buffer is read-only"

    press(["DEL"])
    assert Buffer.text(buf) == "locked"

    {:ok, _} = Compos.Core.Session.eval(~s{(buffer-append! "#{buf}" "+prog")})
    assert Buffer.text(buf) == "locked+prog"
  end

  test "buffer-local keymaps shadow global, only in their buffer", %{buf: buf} do
    other = "local-#{System.unique_integer([:positive])}"
    Compos.Core.create_buffer(other)

    {:ok, _} =
      Compos.Core.Session.eval("""
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

  describe "the modal switcher" do
    test "lists with the buffer annotation, narrows by mode, C-k kills, RET visits" do
      on_exit(fn ->
        for b <- ["*zz-ib-a*", "*zz-ib-b*", "*switch*"], do: Compos.Core.kill_buffer(b)
        Editor.delete_other_windows()
      end)

      {:ok, _} = Compos.Core.Session.eval(~s{(begin
        (buffer-create "*zz-ib-a*")
        (buffer-set-local! "*zz-ib-a*" 'mode-name "zz-mode")
        (buffer-create "*zz-ib-b*"))})

      # ibuffer was the same modal list for a while (edb89bf) and is its
      # own table again (584f308). This test is about the modal switcher,
      # so it opens the modal switcher. ibuffer_test.exs owns the table.
      open_modal_switcher()

      assert Editor.current_buffer() == "*switch*"
      assert Buffer.read_only?("*switch*")
      text = Buffer.text("*switch*")
      assert text =~ "*zz-ib-a*"
      assert text =~ "zz-mode"

      # typing IS the filter: the mode name narrows, the chip names it
      type("zz-mode")
      text = Buffer.text("*switch*")
      assert text =~ "*zz-ib-a*"
      refute text =~ "*zz-ib-b*"
      assert text =~ "/zz-mode"

      # the only row is *zz-ib-a* — C-k kills it now, no flag needed
      assert {:ok, ~s{"*zz-ib-a*"}} =
               Compos.Core.Session.eval(~s{(car (list-current "*switch*"))})

      press(["C-k"])
      refute Compos.Core.Buffer.exists?("*zz-ib-a*")

      # RET lands the selection in the window the switcher was opened from
      press(List.duplicate("DEL", 7))
      type("zz-ib")

      assert {:ok, ~s{"*zz-ib-b*"}} =
               Compos.Core.Session.eval(~s{(car (list-current "*switch*"))})

      press(["RET"])
      assert Editor.current_buffer() == "*zz-ib-b*"
    end

    # One buffer joins a group where it stands; the switcher adds a set.
    # The prompt offers the groups that exist and "New group" first, so
    # this founds one and reads the membership back.
    test "the marked buffers add to a group as one act" do
      on_exit(fn ->
        for b <- ["*zz-gr-a*", "*zz-gr-b*", "*switch*"], do: Compos.Core.kill_buffer(b)
        Editor.delete_other_windows()
      end)

      # no group the frame stands in or just left: with a default, that
      # group leads the candidates and RET joins it
      {:ok, _} = Compos.Core.Session.eval(~s{(begin
        (buffer-create "*zz-gr-a*")
        (buffer-create "*zz-gr-b*")
        (set-frame-local! 'current-group #f)
        (set-frame-local! 'previous-group #f))})

      open_modal_switcher()
      type("zz-gr")

      # the verbs by name: a key in this list is a preference and moves
      run("switch-mark")
      run("switch-mark")
      run("group-add")

      assert Editor.render_state().minibuffer.prompt =~ "Add buffers to group"

      # the "New group" row founds one, and the next prompt takes its
      # name; a default group may lead the candidates, so name the row
      type("New group")
      press(["RET"])
      assert Editor.render_state().minibuffer.prompt =~ "New destination group"
      type("zz-crew")
      press(["RET"])

      a = buffer_group("*zz-gr-a*")
      b = buffer_group("*zz-gr-b*")
      assert a, "*zz-gr-a* joined no group"
      assert b == a, "the two marked buffers landed in different groups"
      assert group_name(a) == "zz-crew"

      # the act ends the marks, and the annotation says the group
      assert Buffer.text("*switch*") =~ "zz-crew"
      refute Buffer.text("*switch*") =~ ~r/^\* /m
      press(["ESC"])
    end

    test "typing and the arrows preview the highlighted buffer in the home window" do
      on_exit(fn ->
        for b <- ["*zz-pv-a*", "*zz-pv-b*", "*switch*"], do: Compos.Core.kill_buffer(b)
        Editor.delete_other_windows()
      end)

      {:ok, _} = Compos.Core.Session.eval(~s{(begin
        (buffer-create "*zz-pv-b*")
        (buffer-create "*zz-pv-a*")
        (delete-other-windows!)
        (switch-to-buffer! "*zz-pv-a*")
        #t)})

      home = window_of("*zz-pv-a*")
      assert home
      open_modal_switcher()
      assert Editor.current_buffer() == "*switch*"
      type("zz-pv")

      # *zz-pv-a* is standing, so the one row left is *zz-pv-b*, and the
      # narrowing previewed it into the home window already
      assert {:ok, ~s{"*zz-pv-b*"}} =
               Compos.Core.Session.eval(~s{(car (list-current "*switch*"))})

      assert buffer_in(home) == "*zz-pv-b*"
      # point stays in the list
      assert Editor.current_buffer() == "*switch*"

      # the arrows walk the rows; the preview follows the highlight
      press(["<down>"])
      assert Editor.current_buffer() == "*switch*"
      press(["<up>"])
      assert buffer_in(home) == "*zz-pv-b*"

      press(["ESC"])
      assert buffer_in(home) == "*zz-pv-a*"
    end
  end

  defp window_of(buffer) do
    {:ok, wins} = Compos.Core.Session.eval("(window-list)")

    wins
    |> then(fn s -> Regex.scan(~r/\((\d+) "([^"]+)"\)/, s) end)
    |> Enum.find_value(fn [_, id, b] -> if b == buffer, do: String.to_integer(id) end)
  end

  defp buffer_in(win_id) do
    {:ok, wins} = Compos.Core.Session.eval("(window-list)")

    wins
    |> then(fn s -> Regex.scan(~r/\((\d+) "([^"]+)"\)/, s) end)
    |> Enum.find_value(fn [_, id, b] -> if String.to_integer(id) == win_id, do: b end)
  end

  describe "dired (pure Scheme userland)" do
    setup do
      root = Path.join(System.tmp_dir!(), "compos-dired-#{System.unique_integer([:positive])}")
      trash = root <> "-trash"
      File.mkdir_p!(Path.join(root, "subdir"))
      File.write!(Path.join(root, "alpha.txt"), "A")
      File.write!(Path.join(root, "beta.txt"), "B")
      Application.put_env(:compos_core, :trash_dir, trash)

      on_exit(fn ->
        Application.delete_env(:compos_core, :trash_dir)
        File.rm_rf!(root)
        File.rm_rf!(trash)
      end)

      {:ok, root: root, trash: trash}
    end

    test "listing, navigation, visiting files and dirs", %{root: root} do
      {:ok, _} = Compos.Core.Session.eval(~s{(dired-open "#{root}")})
      assert Editor.current_buffer() == root
      assert Buffer.read_only?(root)

      text = Buffer.text(root)
      assert text =~ "alpha.txt"
      assert text =~ "beta.txt"
      assert text =~ "subdir/"

      # point starts on "..", n n -> beta.txt line (sorted: alpha, beta, subdir)
      press(["n"])
      {:ok, entry} = Compos.Core.Session.eval("(dired-entry)")
      assert entry == inspect("alpha.txt")

      # RET previews the file without moving focus or point from Dired.
      {:ok, dired_window} = Compos.Core.Session.eval("(active-window)")
      press(["RET"])
      assert Editor.current_buffer() == root
      assert Buffer.text(Path.join(root, "alpha.txt")) == "A"
      assert {:ok, ^dired_window} = Compos.Core.Session.eval("(active-window)")
      assert {:ok, current_entry} = Compos.Core.Session.eval("(dired-entry)")
      assert current_entry == inspect("alpha.txt")
      assert {:ok, ^dired_window} = Compos.Core.Session.eval(~s{(window-showing "#{root}")})

      assert {:ok, file_window} =
               Compos.Core.Session.eval(~s{(window-showing "#{Path.join(root, "alpha.txt")}")})

      refute file_window == dired_window

      # Directories still navigate in the selected Dired window.
      {:ok, _} = Compos.Core.Session.eval(~s{(dired-open "#{root}")})
      press(["n", "n", "n"])
      press(["RET"])
      assert Editor.current_buffer() == Path.join(root, "subdir")

      # ^ goes back up
      press(["^"])
      assert Editor.current_buffer() == root
    end

    test "C-RET visits in the current group, falling back to the Dired group", %{root: root} do
      current = "zz-dired-current-#{System.unique_integer([:positive])}"
      dired = "zz-dired-buffer-#{System.unique_integer([:positive])}"
      current_id = group_id!(~s{(group-record-create! "#{current}")})
      dired_id = group_id!(~s{(group-record-create! "#{dired}")})

      {:ok, _} = Compos.Core.Session.eval(~s{(set-frame-local! 'current-group "#{dired_id}")})
      run("dired")
      {:ok, _} = Compos.Core.Session.eval(~s{(minibuffer-change! "#{root}")})
      press(["RET"])
      assert in_group?(root, dired_id)

      # A current frame group has priority over the Dired buffer's membership.
      {:ok, _} = Compos.Core.Session.eval(~s{(set-frame-local! 'current-group "#{current_id}")})
      press(["n", "C-RET"])
      assert in_group?(Path.join(root, "alpha.txt"), current_id)
      refute in_group?(Path.join(root, "alpha.txt"), dired_id)

      # With no current frame group, the listing's own group supplies context.
      {:ok, _} = Compos.Core.Session.eval(~s{(switch-to-buffer! "#{root}")})
      {:ok, _} = Compos.Core.Session.eval("(set-frame-local! 'current-group #f)")
      press(["n", "C-RET"])
      assert in_group?(Path.join(root, "beta.txt"), dired_id)
    end

    test "dired-visit prefers the Dired buffer group to the frame group", %{root: root} do
      frame = "zz-dired-frame-#{System.unique_integer([:positive])}"
      dired = "zz-dired-source-#{System.unique_integer([:positive])}"
      frame_id = group_id!(~s{(group-record-create! "#{frame}")})
      dired_id = group_id!(~s{(group-record-create! "#{dired}")})

      {:ok, _} = Compos.Core.Session.eval(~s{(set-frame-local! 'current-group "#{dired_id}")})
      run("dired")
      {:ok, _} = Compos.Core.Session.eval(~s{(minibuffer-change! "#{root}")})
      press(["RET"])
      assert in_group?(root, dired_id)

      # Dired is a transient surface. Another visible group can remain the
      # frame context, but the Dired buffer is the more specific source.
      {:ok, _} = Compos.Core.Session.eval(~s{(set-frame-local! 'current-group "#{frame_id}")})
      press(["n", "RET"])

      assert in_group?(Path.join(root, "alpha.txt"), dired_id)
      refute in_group?(Path.join(root, "alpha.txt"), frame_id)
    end

    test "marks: d flags, x executes with confirmation; m/u; + mkdir", %{
      root: root,
      trash: trash
    } do
      {:ok, _} = Compos.Core.Session.eval(~s{(dired-open "#{root}")})

      # point on "..": n -> alpha.txt; d flags it (D mark, advances)
      press(["n", "d"])
      assert Buffer.text(root) =~ ~r/^D .*alpha\.txt/m

      # m marks beta, u unmarks it again
      press(["m"])
      assert Buffer.text(root) =~ ~r/^\* .*beta\.txt/m
      press(["p", "u"])
      refute Buffer.text(root) =~ ~r/^\* /m

      # x executes the flagged deletion after confirmation
      press(["x"])
      assert Editor.render_state().minibuffer.prompt =~ "trash 1 file"
      type("yes")
      press(["RET"])
      refute File.exists?(Path.join(root, "alpha.txt"))
      assert File.read!(Path.join(trash, "alpha.txt")) == "A"
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

      {:ok, _} = Compos.Core.Session.eval(~s{(dired-open "#{root}")})

      # / narrows as you type; the header reads back what you typed
      press(["/"])
      type("scm")
      text = Buffer.text(root)
      assert text =~ "notes.scm"
      refute text =~ "alpha.txt"
      assert text =~ "/scm"
      press(["RET"])
      assert Buffer.text(root) =~ "notes.scm"

      # the filters stack: directories only — nothing matches both
      {:ok, _} = Compos.Core.Session.eval(~s{(dired-filter-push! (list "type" "dir"))})
      refute Buffer.text(root) =~ "notes.scm"

      # \ widens by one, back to the previous narrowing
      press(["\\"])
      assert Buffer.text(root) =~ "notes.scm"

      # dotfiles toggle, and \ again drops the last text filter
      press(["\\"])
      assert Buffer.text(root) =~ ".hidden"
      press(["."])
      refute Buffer.text(root) =~ ".hidden"

      # the stack lives in a serializable local, and the registered mode
      # reapplies it: this is exactly what desktop restore runs
      {:ok, filters} = Compos.Core.Session.eval(~s{(buffer-local "#{root}" 'list-filters)})
      assert filters =~ "dot"

      {:ok, _} =
        Compos.Core.Session.eval(~s{(begin (switch-to-buffer! "#{root}") (set-mode! "Dired"))})

      refute Buffer.text(root) =~ ".hidden"
      assert Buffer.text(root) =~ "alpha.txt"
    end

    # `/` matches the whole row — the line you see AND the marginalia the
    # file prompts show beside the same name. So the mode a file opens in
    # narrows the listing without a filter of its own.
    test "/ matches the marginalia too, and C-g puts the listing back", %{root: root} do
      File.write!(Path.join(root, "notes.scm"), ";;")

      {:ok, _} = Compos.Core.Session.eval(~s{(dired-open "#{root}")})

      # scheme-mode is nowhere in the line: it is what the annotator says
      press(["/"])
      type("scheme-mode")
      text = Buffer.text(root)
      assert text =~ "notes.scm"
      refute text =~ "alpha.txt"

      # C-g drops the live narrowing and restores what was there
      press(["C-g"])
      assert Buffer.text(root) =~ "alpha.txt"

      # RET keeps it while the listing lives, as one serializable local
      press(["/"])
      type("scheme-mode")
      press(["RET"])
      {:ok, filters} = Compos.Core.Session.eval(~s{(buffer-local "#{root}" 'list-filters)})
      assert filters =~ "match"
      refute Buffer.text(root) =~ "alpha.txt"

      # opening the listing again starts WIDE: the query answered a question
      # you asked that time, and a list you open must show what it holds
      {:ok, _} =
        Compos.Core.Session.eval(~s{(begin (switch-to-buffer! "#{root}") (set-mode! "Dired"))})

      assert Buffer.text(root) =~ "alpha.txt"
      # point lands on a row, not on the header: ".." leads every listing
      assert {:ok, ~s{".."}} = Compos.Core.Session.eval(~s{(dired-entry)})

      # a directory reads as Dired wherever it is listed, so the word finds
      # every directory — and ".." is one of them
      press(["/"])
      type("Dired")
      press(["RET"])
      text = Buffer.text(root)
      assert text =~ "subdir/"
      refute text =~ "alpha.txt"
    end

    # The query is ONE filter and the input IS it: `/` reopens holding
    # what the list already shows, and emptying the input removes it.
    # Before this, every `/` stacked another layer and nothing you typed
    # could take one off.
    test "/ edits the live query, and an empty input removes it", %{root: root} do
      File.write!(Path.join(root, "notes.scm"), ";;")

      {:ok, _} = Compos.Core.Session.eval(~s{(dired-open "#{root}")})

      press(["/"])
      type("scm")
      press(["RET"])
      assert {:ok, ~s{"scm"}} = Compos.Core.Session.eval(~s{(list-query "#{root}")})

      # the prompt opens on the query it already has
      press(["/"])
      assert Editor.render_state().minibuffer.input == "scm"

      # editing replaces the query — it does not stack a second one
      press(["DEL"])
      type("h")
      {:ok, filters} = Compos.Core.Session.eval(~s{(buffer-local "#{root}" 'list-filters)})
      assert filters == ~s{(("match" "sch"))}

      # emptying the input removes the filter outright
      press(["DEL", "DEL", "DEL"])
      assert {:ok, "()"} = Compos.Core.Session.eval(~s{(buffer-local "#{root}" 'list-filters)})
      assert Buffer.text(root) =~ "alpha.txt"

      press(["RET"])
      assert {:ok, ~s{""}} = Compos.Core.Session.eval(~s{(list-query "#{root}")})
    end

    # You type, and then you select. The filter prompt offers no candidates
    # of its own, so its arrows move the rows of the listing behind it, and
    # RET closes the prompt on the row you chose. Before this, <down> did
    # nothing and every narrowing left you on the first match.
    test "the arrows move the listing while the filter prompt is open", %{root: root} do
      File.write!(Path.join(root, "notes.scm"), ";;")
      File.write!(Path.join(root, "notes2.scm"), ";;")

      {:ok, _} = Compos.Core.Session.eval(~s{(dired-open "#{root}")})

      press(["/"])
      type("notes")
      row = fn -> Compos.Core.Session.eval(~s{(list-current "#{root}")}) end
      # a narrowing lands on the first row, and ".." leads every listing
      assert {:ok, ~s{".."}} = row.()

      press(["<down>"])
      assert {:ok, ~s{"notes.scm"}} = row.()

      press(["<down>"])
      assert {:ok, ~s{"notes2.scm"}} = row.()

      press(["<up>"])
      assert {:ok, ~s{"notes.scm"}} = row.()

      # C-n and C-p move the same rows
      press(["C-n"])
      assert {:ok, ~s{"notes2.scm"}} = row.()
      press(["C-p"])
      assert {:ok, ~s{"notes.scm"}} = row.()

      # RET keeps the narrowing AND the row the arrows chose
      press(["RET"])
      refute Editor.render_state().minibuffer
      assert {:ok, ~s{"notes.scm"}} = Compos.Core.Session.eval(~s{(dired-entry)})
      assert {:ok, ~s{"notes"}} = Compos.Core.Session.eval(~s{(list-query "#{root}")})
    end

    # A prompt that HAS candidates keeps its own arrows: the fallback above
    # must never steal them from a palette.
    test "a candidate prompt keeps its own arrows", %{root: root} do
      {:ok, _} = Compos.Core.Session.eval(~s{(dired-open "#{root}")})
      press(["/"])
      press(["C-g"])

      {:ok, _} =
        Compos.Core.Session.eval(
          ~s{(minibuffer-read "Pick: " (list (list "one" "") (list "two" "")) (lambda (v) v))}
        )

      press(["<down>"])
      assert {:ok, ~s{"two"}} = Compos.Core.Session.eval("(minibuffer-selected)")
      press(["C-g"])
    end

    # The listing was in the buffer and the window was blank: the buffer
    # kept 'render-mode "blocks" from the mode before it, and the client
    # draws blocks for a leaf that says "blocks". Both ends refuse now —
    # the list mode drops the local, and a leaf with no blocks says nil.
    test "a stale render-mode does not blank the listing", %{root: root} do
      {:ok, _} = Compos.Core.Session.eval(~s{(dired-open "#{root}")})
      {:ok, _} = Compos.Core.Session.eval(~s{(buffer-set-local! "#{root}" 'render-mode "blocks")})

      # the core stops calling it blocks the moment there are no blocks
      leaf = find_active_leaf(Editor.render_state().tree, Editor.snapshot().active)
      assert leaf.buffer == root
      assert leaf.render_mode == nil

      # and re-entering the mode drops the local outright
      {:ok, _} = Compos.Core.Session.eval(~s{(set-mode! "Dired")})
      {:ok, "#f"} = Compos.Core.Session.eval(~s{(buffer-local "#{root}" 'render-mode)})
      assert Buffer.text(root) =~ "alpha.txt"
    end

    test "dired rows carry name/size/date/perms columns under their labels", %{root: root} do
      {:ok, _} = Compos.Core.Session.eval(~s{(dired-open "#{root}")})
      text = Buffer.text(root)
      # the labels name the columns, and a row fills them in that order
      assert text =~ ~r/NAME .*SIZE +MODIFIED +PERMS +VC$/m
      # the icon leads the row: a file wears its mode's, a directory Dired's
      assert text =~ ~r/ +alpha\.txt .*\d+ +[A-Z][a-z]{2} +\d+ \d{2}:\d{2} +-rw/m
      assert text =~ ~r/ +subdir\/ .*drwx/m
      # the key bar says what the list does
      assert text =~ "RET visit"
    end

    test "rename refuses the parent row", %{root: root} do
      {:ok, _} = Compos.Core.Session.eval(~s{(dired-open "#{root}")})

      run("dired-rename")

      refute Editor.render_state().minibuffer
      assert echo() == "Select a file, not the parent row"
      assert File.dir?(Path.dirname(root))
    end

    test "structured entries preserve exact bytes and symlinks", %{root: root} do
      exact = Path.join(root, "exact.bin")
      link = Path.join(root, "alpha-link")
      unicode_dir = Path.join(root, "café")
      File.mkdir_p!(unicode_dir)
      File.write!(exact, :binary.copy("x", 1537))
      File.ln_s!("alpha.txt", link)

      {:ok, entries} = Compos.Core.Session.eval(~s{(directory-entries "#{root}")})
      assert entries =~ ~s{bytes 1537}
      assert entries =~ ~s{type "symlink"}

      assert {:ok, inspect(unicode_dir <> "/")} ==
               Compos.Core.Session.eval(~s{(path-directory "#{unicode_dir}/file.txt")})

      {:ok, _} = Compos.Core.Session.eval(~s{(dired-open "#{root}")})
      assert Buffer.text(root) =~ ~r/alpha-link .*lrw/

      {:ok, _} =
        Compos.Core.Session.eval(~s{(dired-filter-push! (list "type" "link"))})

      assert Buffer.text(root) =~ "alpha-link"
      refute Buffer.text(root) =~ "alpha.txt"

      press(["n", "d", "x"])
      assert Editor.render_state().minibuffer.prompt =~ "trash 1 file"
      type("yes")
      press(["RET"])

      assert {:error, :enoent} = File.lstat(link)
      assert File.read!(Path.join(root, "alpha.txt")) == "A"
    end

    test "an unreadable path is an error view, not an empty directory", %{root: root} do
      missing = Path.join(root, "missing")
      {:ok, _} = Compos.Core.Session.eval(~s{(dired-open "#{missing}")})

      assert Buffer.text(missing) =~ "error:"
      assert Buffer.text(missing) =~ "missing"
    end

    test "sorting, copying, chmod, and links use Dired commands", %{root: root} do
      File.write!(Path.join(root, "largest.bin"), :binary.copy("z", 10_000))
      {:ok, _} = Compos.Core.Session.eval(~s{(dired-open "#{root}")})

      run("dired-sort-cycle")

      assert {:ok, ~s{"alpha.txt"}} =
               Compos.Core.Session.eval(~s{(cadr (buffer-local "#{root}" 'list-source-entries))})

      run("dired-sort-reverse")

      assert {:ok, ~s{"largest.bin"}} =
               Compos.Core.Session.eval(~s{(cadr (buffer-local "#{root}" 'list-source-entries))})

      run("dired-dirs-first")

      assert {:ok, ~s{"subdir/"}} =
               Compos.Core.Session.eval(~s{(cadr (buffer-local "#{root}" 'list-source-entries))})

      {:ok, _} = Compos.Core.Session.eval(~s{(dired-open "#{root}")})
      {:ok, _} = Compos.Core.Session.eval(~s{(list-set-query! "#{root}" "alpha.txt")})
      press(["n"])
      run("dired-copy")
      type(Path.join(root, "alpha-copy.txt"))
      press(["RET"])
      assert File.read!(Path.join(root, "alpha-copy.txt")) == "A"

      run("dired-chmod")
      type("600")
      press(["RET"])
      assert Bitwise.band(File.stat!(Path.join(root, "alpha.txt")).mode, 0o777) == 0o600

      run("dired-symlink")
      type(Path.join(root, "alpha-command-link"))
      press(["RET"])

      assert File.read_link!(Path.join(root, "alpha-command-link")) ==
               Path.join(root, "alpha.txt")
    end

    test "Git status handles spaces, Unicode, renames, and directory aggregation", %{root: root} do
      git = fn args ->
        {_out, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
      end

      File.mkdir_p!(Path.join(root, "café"))
      File.write!(Path.join(root, "café/inside.txt"), "before")
      git.(["init", "-q", "-b", "main"])
      git.(["add", "-A"])

      git.([
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@example.com",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "-q",
        "-m",
        "initial"
      ])

      File.rename!(Path.join(root, "beta.txt"), Path.join(root, "renamed name.txt"))
      git.(["add", "-A"])
      File.write!(Path.join(root, "alpha.txt"), "changed")
      File.write!(Path.join(root, "新 file.txt"), "new")
      File.write!(Path.join(root, "café/inside.txt"), "after")

      {:ok, _} = Compos.Core.Session.eval(~s{(dired-open "#{root}")})
      text = Buffer.text(root)

      assert text =~ ~r/alpha\.txt .*modified/
      assert text =~ ~r/renamed name\.txt .*renamed/
      assert text =~ ~r/新 file\.txt .*untracked/
      assert text =~ ~r/café\/ .*modified/
      assert text =~ "⎇ main"
    end

    test "a visible Dired buffer follows filesystem changes", %{root: root} do
      {:ok, _} = Compos.Core.Session.eval(~s{(dired-open "#{root}")})

      assert {:ok, "#t"} =
               Compos.Core.Session.eval(~s{(buffer-local "#{root}" 'dired-watch-armed)})

      assert {:ok, watched} = Compos.Core.Session.eval("(watched-paths)")
      assert watched =~ root
      refute {:ok, "#f"} == Compos.Core.Session.eval(~s{(window-showing "#{root}")})

      path = Path.join(root, "appeared.txt")
      File.write!(path, "new")
      state = :sys.get_state(Compos.Core.Watch)

      {backend, ^root} =
        Enum.find(state.pids, fn {_pid, watched_root} -> watched_root == root end)

      send(Compos.Core.Watch, {:file_event, backend, {path, [:modified]}})

      assert eventually(fn -> Buffer.text(root) =~ "appeared.txt" end)
    end

    test "find-file prefills default-directory; // resets (Emacs rule)", %{root: root} do
      {:ok, _} = Compos.Core.Session.eval(~s{(dired-open "#{root}")})
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
      {:ok, _} = Compos.Core.Session.eval(~s{(dired-open "#{root}")})
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
    Application.put_env(:compos_core, :llm_request_fun, fn prompt -> {:ok, "ECHO: " <> prompt} end)
    on_exit(fn -> Application.delete_env(:compos_core, :llm_request_fun) end)

    {:ok, _} =
      Compos.Core.Session.eval("""
      (llm "hi there" (lambda (r) (buffer-append! "#{buf}" r)))
      """)

    assert eventually(fn -> Buffer.text(buf) == "ECHO: hi there" end)
  end

  test "M-o sends the whole document and inserts a faced response below point", %{buf: buf} do
    parent = self()

    Application.put_env(:compos_core, :llm_chat_fun, fn req ->
      send(parent, {:llm_prompt, req})

      {:ok,
       %{
         "stop_reason" => "end_turn",
         "content" => [%{"type" => "text", "text" => "A useful continuation."}]
       }}
    end)

    on_exit(fn -> Application.delete_env(:compos_core, :llm_chat_fun) end)

    type("The complete document is context.")

    {:ok, _} =
      Compos.Core.Session.eval(~s{(buffer-set-local! "#{buf}" 'llm-model "openai:test-writer")})

    press(["M-o"])

    assert_receive {:llm_prompt, req}
    assert req.model == "openai:test-writer"
    # the editor bridge rides every LLM surface (mcp.scm chat-presets-of),
    # so an inline completion holds the same tools a chat does
    assert "act" in Enum.map(req.tools, & &1.name)
    assert "eval-scheme" in Enum.map(req.tools, & &1.name)
    assert [%{content: "The complete document is context."}] = req.messages
    assert "llm-mode" in Buffer.get_local(buf, "minor-modes")

    assert eventually(fn ->
             Buffer.text(buf) ==
               "The complete document is context.\n\nA useful continuation.\n"
           end)

    # llm-mode owns one session for the buffer. A completed turn leaves it
    # idle for the next M-o; disabling the mode detaches that runtime.
    session_id = Buffer.get_local(buf, "llm-session-id")
    assert String.starts_with?(session_id, "inline-")
    assert eventually(fn -> Compos.Core.Agent.info(session_id).status == :idle end)

    assert eventually(fn ->
             Enum.any?(Buffer.overlays(buf), fn {start, finish, face} ->
               face == "llm-response" and
                 binary_part(Buffer.text(buf), start, finish - start) ==
                   "A useful continuation."
             end)
           end)

    assert [[start, finish]] = Buffer.get_local(buf, "llm-responses")
    assert binary_part(Buffer.text(buf), start, finish - start) == "A useful continuation."

    :ok = Buffer.clear_overlays(buf)
    assert Buffer.overlays(buf) == []
    {:ok, _} = Compos.Core.Session.eval(~s{(llm-mode--sync-ranges! "#{buf}")})
    assert [[^start, ^finish]] = Buffer.get_local(buf, "llm-responses")
    {:ok, _} = Compos.Core.Session.eval(~s{(llm-mode--apply! "#{buf}")})
    assert Enum.any?(Buffer.overlays(buf), fn {_s, _e, face} -> face == "llm-response" end)

    {:ok, _} = Compos.Core.Session.eval(~s{(disable-minor-mode! "#{buf}" "llm-mode")})
    refute session_id in Compos.Core.Agent.list()

    # Vertical crossing is client-side in Markdown mode: the overlay's exact
    # range is embedded in the preview block instead of remapping next-line.
  end

  test "C-c b opens one shared backend/model/effort menu in chat and llm modes", %{buf: buf} do
    {:ok, _} = Compos.Core.Session.eval(~s{(enable-minor-mode! "#{buf}" "llm-mode")})
    assert {"C-c b", "llm-configure"} in Editor.local_keys(buf)

    {:ok, _} = Compos.Core.Session.eval(~s{(set-mode! "chat-mode")})
    {:ok, _} = Compos.Core.Session.eval(~s{(buffer-set-local! "#{buf}" 'agent-connector "api")})
    assert {"C-c b", "llm-configure"} in Editor.local_keys(buf)

    press(["C-c", "b"])
    assert Editor.current_buffer() == buf
    menu = Editor.render_state().transient
    assert menu.title == "Configure this buffer's language model"

    assert Enum.map(hd(menu.groups).items, & &1.description) ==
             ["Backend", "Model", "Effort", "Presets", "Tools"]

    # The command modal uses its normal interaction: RET invokes the selected row.
    press(["RET"])
    backend_menu = Editor.render_state().minibuffer
    assert backend_menu.prompt == "Backend: "
    assert %{label: "api", hint: "current" <> _, selected: true} = hd(backend_menu.candidates)
    assert Enum.any?(backend_menu.candidates, &(&1.label == "codex-app-server"))

    # C-g closes the infix prompt and leaves the transient active.
    press(["C-g"])
    assert Editor.render_state().minibuffer == nil
    assert Editor.render_state().transient != nil
    press(["C-g"])
    assert Editor.render_state().transient == nil
  end

  test "M-| pipes the region through the llm into *llm*", %{buf: buf} do
    Application.put_env(:compos_core, :llm_request_fun, fn prompt ->
      {:ok, prompt |> String.split("\n") |> List.last() |> String.upcase()}
    end)

    on_exit(fn -> Application.delete_env(:compos_core, :llm_request_fun) end)

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
    {:ok, _} = Compos.Core.Session.eval(~s{(start-process! "#{buf}" "cat")})
    Editor.set_window_buffer(buf)

    # wait for process to be up, then type a line and hit RET (comint send)
    assert Compos.Core.Proc.running?(buf)
    type("hello-comint")
    press(["RET"])

    # cat echoes it back (plus the pty echo) — poll until it lands
    assert eventually(fn -> Buffer.text(buf) =~ "hello-comint" end)

    Compos.Core.Proc.kill(buf)
    assert eventually(fn -> not Compos.Core.Proc.running?(buf) end)
  end

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(50)
        eventually(fun, tries - 1)
    end
  end

  test "set-face-attribute! lands in render_state faces" do
    {:ok, _} =
      Compos.Core.Session.eval(~s{(set-face-attribute! 'modeline 'bg "#ff0000" 'fg "#000")})

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

  test "M-x reports an invalid typed command without leaking an internal match error" do
    press(["M-x"])
    Editor.minibuffer_set_input("rest\\")
    press(["RET"])

    assert echo() == "minibuffer-confirm: undefined command: rest\\"
  end

  test "M-x buffer-rename renames the current buffer and refuses a taken name", %{buf: old} do
    renamed = "renamed-#{System.unique_integer([:positive])}"
    taken = "taken-#{System.unique_integer([:positive])}"
    {:ok, _} = Compos.Core.create_buffer(taken, text: "occupied")

    on_exit(fn ->
      for name <- [old, renamed, taken], Buffer.exists?(name), do: Compos.Core.kill_buffer(name)
    end)

    press(["M-x"])
    type("buffer-rename")
    press(["RET"])
    expected_prompt = "Rename buffer #{old} to: "
    assert %{prompt: ^expected_prompt} = Editor.render_state().minibuffer

    type(renamed)
    press(["RET"])

    assert Editor.current_buffer() == renamed
    refute Buffer.exists?(old)
    assert echo() == "Renamed buffer #{old} to #{renamed}"

    press(["M-x"])
    type("buffer-rename")
    press(["RET"])
    type(taken)
    press(["RET"])

    assert Editor.current_buffer() == renamed
    assert Buffer.text(taken) == "occupied"
    assert echo() == "Buffer #{taken} already exists"
  end

  test "a window with no buffer cannot kill the editor through the history", %{buf: buf} do
    pid = Process.whereis(Editor)

    # a window can hold `false` where a buffer name belongs. The history
    # used to take it, and mru-list then raised inside Editor.handle_call:
    # the Editor died and every buffer lost its local keymap, so RET in a
    # chat stopped sending.
    :sys.replace_state(pid, fn state -> %{state | mru: [false | state.mru]} end)

    assert is_list(Editor.mru_all())
    assert Process.whereis(Editor) == pid

    # real entries still land, in order, in both shapes
    :sys.replace_state(pid, fn state -> %{state | mru: [buf]} end)
    Editor.mru_note_group("g")
    Editor.set_window_buffer(buf)

    assert Editor.mru_all() == [["buffer", buf], ["group", "g"]]
    assert Process.whereis(Editor) == pid
  end

  test "find-file TAB filename completion completes and descends directories" do
    root = Path.join(System.tmp_dir!(), "compos-fc-#{System.unique_integer([:positive])}")
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
    root = Path.join(System.tmp_dir!(), "compos-nav-#{System.unique_integer([:positive])}")
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
    root = Path.join(System.tmp_dir!(), "compos-dd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "alpha.txt"), "A")

    # a file buffer answers with its own directory
    {:ok, _} = Compos.Core.Session.eval(~s{(visit "#{Path.join(root, "alpha.txt")}")})
    press(["C-x", "C-f"])
    assert Editor.render_state().minibuffer.input == root <> "/"
    press(["C-g"])

    # a buffer with no file inherits the directory it was created in
    {:ok, _} =
      Compos.Core.Session.eval(
        ~s{(begin (buffer-create "*dd-child*") (switch-to-buffer! "*dd-child*"))}
      )

    press(["C-x", "C-f"])
    assert Editor.render_state().minibuffer.input == root <> "/"
    press(["C-g"])

    # a path-shaped name is a directory too, even with no file behind it
    {:ok, _} =
      Compos.Core.Session.eval(~s{(switch-to-buffer! "#{Path.join(root, "never-opened.txt")}")})

    press(["C-x", "C-f"])
    assert Editor.render_state().minibuffer.input == root <> "/"
    press(["C-g"])

    File.rm_rf!(root)
  end

  test "find-file filters orderless; unique match opens on RET" do
    root = Path.join(System.tmp_dir!(), "compos-of-#{System.unique_integer([:positive])}")
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
    root = Path.join(System.tmp_dir!(), "compos-sel-#{System.unique_integer([:positive])}")
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
    root = Path.join(System.tmp_dir!(), "compos-lit-#{System.unique_integer([:positive])}")
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
    root = Path.join(System.tmp_dir!(), "compos-ffd-#{System.unique_integer([:positive])}")
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

    assert [%{label: "split-window-below", selected: true}, %{label: "split-window-right"}] =
             mb.candidates

    press(["C-n"])
    assert Editor.render_state().minibuffer.sel == 1
    press(["RET"])

    assert %{type: :split, dir: :h} = Editor.render_state().tree
    press(["C-x", "1"])
  end

  test "exact match ranks above longer prefix matches (paper vs paper-night)" do
    {:ok, _} =
      Compos.Core.Session.eval("""
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
    path = Path.join(System.tmp_dir!(), "compos-ts-#{System.unique_integer([:positive])}.exs")
    File.write!(path, "defmodule Foo do\n  def bar do\n    [1, 2, 3]\n  end\nend\n")

    press(["C-x", "C-f"])
    type(path)
    press(["RET"])
    assert Editor.current_buffer() == path
    assert Buffer.get_local(path, "ts-lang") == "elixir"
    assert Buffer.get_local(path, "mode-name") == "elixir-mode"

    # highlight spans exist and include a keyword scope
    spans = Compos.Core.TS.ts_highlight("elixir", Buffer.text(path))
    assert Enum.any?(spans, fn {_, _, scope} -> scope == "keyword" end)

    # C-M-f moves over successive sexps: symbol, then alias (Emacs-style)
    press(["M-<", "C-M-f"])
    assert Buffer.point(path) == 9
    press(["C-M-f"])
    assert Buffer.point(path) == 13

    # C-M-u from inside the list goes to an enclosing structure start
    {:ok, _} = Compos.Core.Session.eval("(goto-char! 36)")
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

    lib = Path.join(System.tmp_dir!(), "compos-lib-#{System.unique_integer([:positive])}.scm")
    File.write!(lib, ~s{(define-command "from-lib" (lambda () (message "lib loaded!")))})
    {:ok, _} = Compos.Core.Session.eval(~s{(load "#{lib}")})

    press(["M-x"])
    type("from-lib")
    press(["RET"])
    assert echo() == "lib loaded!"
    File.rm!(lib)
  end

  test "dired RET visit runs auto-mode (elixir file gets highlighting)" do
    root = Path.join(System.tmp_dir!(), "compos-dm-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "code.ex"), "defmodule X do\nend\n")

    {:ok, _} = Compos.Core.Session.eval(~s{(dired-open "#{root}")})
    press(["n", "RET"])

    # RET previews the file and keeps the focus in Dired. What this test is
    # about is the visit behind the preview: the buffer it opens runs
    # auto-mode, so the file arrives with its own mode and grammar.
    path = Path.join(root, "code.ex")
    assert Editor.current_buffer() == root
    assert Buffer.exists?(path)
    assert Buffer.get_local(path, "mode-name") == "elixir-mode"
    assert Buffer.get_local(path, "ts-lang") == "elixir"

    File.rm_rf!(root)
  end

  test "desktop: editor state survives save/restore" do
    path = Path.join(System.tmp_dir!(), "compos-desk-#{System.unique_integer([:positive])}.ex")
    File.write!(path, "defmodule Desk do\nend\n")

    # open the file, set a point, split, load a theme face
    press(["C-x", "C-f"])
    type(path)
    press(["RET"])
    press(["C-f", "C-f", "C-f"])
    press(["C-x", "3"])
    {:ok, _} = Compos.Core.Session.eval(~s{(set-face-attribute! 'desk-test 'fg "#123456")})

    assert :ok = Compos.Core.Desktop.save_now()

    # wreck the state: single window on scratch, kill the file buffer
    press(["C-x", "1"])
    Editor.set_window_buffer("*scratch*")
    evict(path)

    assert :ok = Compos.Core.Desktop.restore_now()

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
    path = Path.join(System.tmp_dir!(), "compos-desk-#{System.unique_integer([:positive])}.md")
    File.write!(path, "# Title\n\nbody\n")

    press(["C-x", "C-f"])
    type(path)
    press(["RET"])
    # a visited Morg file opens in writing-mode with the preview on
    assert Buffer.get_local(path, "render-mode") == "markdown"
    assert "preview-mode" in Buffer.get_local(path, "minor-modes")
    {:ok, _} = Compos.Core.Session.eval(~s{(set-mode! "rust-mode")})
    assert Buffer.get_local(path, "ts-lang") == "rust"

    assert :ok = Compos.Core.Desktop.save_now()

    Editor.set_window_buffer("*scratch*")
    evict(path)

    assert :ok = Compos.Core.Desktop.restore_now()

    # auto-mode would have said text-mode; the saved state wins
    assert Buffer.get_local(path, "mode-name") == "rust-mode"
    assert Buffer.get_local(path, "ts-lang") == "rust"
    assert Buffer.get_local(path, "render-mode") == "markdown"
    assert "preview-mode" in Buffer.get_local(path, "minor-modes")

    File.rm!(path)
  end

  test "preview-mode and read-only-mode are independent" do
    path = Path.join(System.tmp_dir!(), "compos-html-#{System.unique_integer([:positive])}.html")
    File.write!(path, "<h1>Hi</h1>\n")
    on_exit(fn -> File.rm(path) end)

    press(["C-x", "C-f"])
    type(path)
    press(["RET"])
    assert Editor.current_buffer() == path

    press(["C-c", "C-v"])
    assert Buffer.get_local(path, "render-mode") == "html"
    assert "preview-mode" in Buffer.get_local(path, "minor-modes")
    refute Buffer.read_only?(path)

    press(["C-x", "C-q"])
    assert Buffer.read_only?(path)
    assert Buffer.get_local(path, "render-mode") == "html"
    assert "preview-mode" in Buffer.get_local(path, "minor-modes")

    press(["C-x", "C-q"])
    refute Buffer.read_only?(path)
    assert Buffer.get_local(path, "render-mode") == "html"
    assert "preview-mode" in Buffer.get_local(path, "minor-modes")

    press(["C-c", "C-v"])
    refute Buffer.get_local(path, "render-mode")
    refute "preview-mode" in Buffer.get_local(path, "minor-modes")
    refute Buffer.read_only?(path)

    Compos.Core.kill_buffer(path)
  end

  test "desktop: non-file buffers (chat) survive restore with content, mode, and keys", %{
    buf: buf
  } do
    companion = "*chat:#{buf}*"
    on_exit(fn -> Compos.Core.kill_buffer(companion) end)

    press(["M-x"])
    type("chat")
    press(["RET"])
    assert Editor.current_buffer() == companion
    type("remember me")
    point = Buffer.point(companion)

    assert :ok = Compos.Core.Desktop.save_now()

    Editor.set_window_buffer("*scratch*")
    evict(companion)

    assert :ok = Compos.Core.Desktop.restore_now()

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
      Compos.Core.Session.eval(~s{(local-set-key* " *completion*" "C-j" "completion-next")})

    type("hello helper")
    press(["RET"])
    type("he")
    press(["C-M-i", "C-j", "TAB"])
    assert Buffer.text(buf) == "hello helper\nhelper"
  end

  test "capf: buffer-local sources take precedence (the LSP plug point)", %{buf: buf} do
    {:ok, _} =
      Compos.Core.Session.eval("""
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

      {:ok, _} = Compos.Core.Session.eval("(goto-char! 400)")
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

  test "buffer ring: the switcher reaches a buffer by name; kill lands on MRU", %{buf: a} do
    b = "ring-b-#{System.unique_integer([:positive])}"
    c = "ring-c-#{System.unique_integer([:positive])}"
    Editor.set_window_buffer(a)
    Editor.set_window_buffer(b)
    Editor.set_window_buffer(c)

    # containers may hold the default now; the ring is reachable by name
    open_modal_switcher()
    type(b)
    press(["RET"])
    assert Editor.current_buffer() == b

    open_modal_switcher()
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
      assert eventually(fn -> Compos.Core.Terminal.running?("*shell*") end)

      # the default display rule: a right side window taking one third of the
      # frame, floating — the class and the share reach the client here
      state = Editor.render_state()
      assert %{type: :split, dir: :h, ratio: ratio} = state.tree
      assert_in_delta ratio, 2 / 3, 0.001
      assert Editor.current_buffer() == "*shell*"
      assert Buffer.get_local("*shell*", "render-mode") == "terminal"
      assert Buffer.read_only?("*shell*")

      assert {:ok, ~s{"popup popup-right"}} =
               Compos.Core.Session.eval(~s{(buffer-local "*shell*" 'window-class)})

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
      Compos.Core.Terminal.kill("*shell*")
    end

    test "C-u M-x opencode chooses a group and opens its persistent terminal", %{buf: buf} do
      n = System.unique_integer([:positive])
      group = "opencode-#{n}"
      opencode = "*opencode:#{group}*"
      dir = Path.join(System.tmp_dir!(), "opencode cwd #{n}")
      File.mkdir_p!(dir)

      {:ok, old_command} = Compos.Core.Session.eval("*opencode-command*")

      on_exit(fn ->
        Compos.Core.Terminal.kill(opencode)
        if Buffer.exists?(opencode), do: Compos.Core.kill_buffer(opencode)
        Compos.Core.Session.eval(~s{(set! *opencode-command* #{old_command})})
        Compos.Core.Session.eval(~s{(set-frame-local! 'current-group #f)})
        Compos.Core.Session.eval(~s{(group-record-delete! "#{group}")})
        File.rm_rf!(dir)
      end)

      {:ok, _} =
        Compos.Core.Session.eval("""
        (begin
          (set! *opencode-command*
            "exec /bin/sh -c 'printf OPENCODE_READY; sleep 30'")
          (buffer-set-local! "#{buf}" 'default-directory "#{dir}")
          (let ((id (group-record-create! "#{group}")))
            (buffer-add-group! "#{buf}" id)
            (set-frame-local! 'current-group id)))
        """)

      press(["C-u", "M-x"])
      type("opencode")
      press(["RET"])
      assert Editor.snapshot().minibuffer.prompt == "Open OpenCode in group: "

      type(group)
      press(["RET"])

      assert eventually(fn -> Compos.Core.Terminal.running?(opencode) end)
      assert Editor.current_buffer() == opencode
      assert Buffer.get_local(opencode, "mode-name") == "term-mode"
      assert Buffer.get_local(opencode, "render-mode") == "terminal"
      assert Buffer.get_local(opencode, "default-directory") == dir
      assert Buffer.get_local(opencode, "terminal-command") =~ "cd -- '#{dir}'"
      assert eventually(fn -> Buffer.text(opencode) =~ "OPENCODE_READY" end)
      assert in_group?(opencode, group)

      assert {:ok, ~s{"opencode"}} =
               Compos.Core.Session.eval(~s{(buffer-group-role "#{opencode}" "#{group}")})
    end

    test "popup-buffer summons any buffer and the toggle dismisses it", %{buf: buf} do
      target = "popup-any-#{System.unique_integer([:positive])}"
      Compos.Core.create_buffer(target)

      press(["M-x"])
      type("popup-buffer")
      press(["RET"])
      type(target)
      press(["RET"])

      assert Editor.current_buffer() == target

      assert {:ok, ~s{"popup popup-right"}} =
               Compos.Core.Session.eval(~s{(buffer-local "#{target}" 'window-class)})

      press(["C-`"])
      assert Editor.current_buffer() == buf
      assert %{type: :leaf} = Editor.render_state().tree
      {:ok, _} = Compos.Core.Session.eval(~s{(buffer-kill! "#{target}")})
    end

    test "the default popup moves to the bottom on a compact frame", %{buf: buf} do
      target = "popup-compact-#{System.unique_integer([:positive])}"
      Compos.Core.create_buffer(target)
      Editor.set_window_cols(%{Editor.active_window() => 80})

      press(["M-x"])
      type("popup-buffer")
      press(["RET"])
      type(target)
      press(["RET"])

      assert %{type: :split, dir: :v, ratio: ratio} = Editor.render_state().tree
      assert_in_delta ratio, 2 / 3, 0.001

      assert {:ok, ~s{"popup popup-bottom"}} =
               Compos.Core.Session.eval(~s{(buffer-local "#{target}" 'window-class)})

      press(["C-`"])
      assert Editor.current_buffer() == buf
      Editor.set_window_cols(%{})
      {:ok, _} = Compos.Core.Session.eval(~s{(buffer-kill! "#{target}")})
    end

    # A popup is a visit, not a move: closing it puts you back in the
    # window you left, in the buffer it showed, at the point you left.
    test "a popup returns the window, the buffer and point", %{buf: buf} do
      other = "test-other-#{System.unique_integer([:positive])}"
      {:ok, _} = Compos.Core.Session.eval(~s{(buffer-create "#{other}")})
      Buffer.insert(other, "one\ntwo\nthree\n")

      # two windows: the popup must come back to the RIGHT one, and the
      # right one is not the first in the tree
      press(["C-x", "3"])
      press(["C-x", "o"])
      {:ok, _} = Compos.Core.Session.eval(~s{(switch-to-buffer! "#{other}")})
      Buffer.goto(other, 4)
      {:ok, from} = Compos.Core.Session.eval("(active-window)")

      {:ok, _} = Compos.Core.Session.eval(~s{(display-buffer "*Messages*")})
      assert Editor.current_buffer() == "*Messages*"

      # something displaces the window we came from while the popup is up
      # (an ibuffer preview does exactly this)
      {:ok, _} =
        Compos.Core.Session.eval(~s{(let ((me (active-window))) (select-window! #{from})
                  (switch-to-buffer! "#{buf}") (select-window! me))})

      Compos.Core.Session.run_command("quit-window")

      assert {:ok, ^from} = Compos.Core.Session.eval("(active-window)")
      assert Editor.current_buffer() == other
      assert Buffer.point(other) == 4

      Editor.delete_other_windows()
      {:ok, _} = Compos.Core.Session.eval(~s{(buffer-kill! "#{other}")})
    end

    # The frame local dies with the daemon; the floating class comes back
    # with the desktop. So a restored popup must be found by its class,
    # or displaying its buffer splits the frame a SECOND time and the
    # layout grows a pane every time you open the list.
    test "a popup with no frame local is still the popup, not a new split", %{buf: buf} do
      {:ok, _} = Compos.Core.Session.eval(~s{(display-buffer "*Messages*")})
      assert %{type: :split} = Editor.render_state().tree
      {:ok, w} = Compos.Core.Session.eval("(active-window)")

      # this is what a restore leaves behind: the class, and no local
      {:ok, _} = Compos.Core.Session.eval("(set-frame-local! 'popup-window #f)")
      assert {:ok, ^w} = Compos.Core.Session.eval("(popup-window)")
      assert {:ok, "#t"} = Compos.Core.Session.eval("(popup-open?)")

      # displaying it again reuses that window instead of splitting
      {:ok, _} = Compos.Core.Session.eval(~s{(display-buffer "*Messages*")})

      assert %{type: :split, children: [%{type: :leaf}, %{type: :leaf}]} =
               Editor.render_state().tree

      press(["C-`"])
      assert %{type: :leaf} = Editor.render_state().tree
      assert Editor.current_buffer() == buf
    end

    # popper's toggle from outside the popup dismisses it and leaves your
    # focus where it is — you never went in, so there is nothing to return
    test "C-` from another window closes the popup without moving focus", %{buf: buf} do
      press(["C-x", "3"])
      {:ok, from} = Compos.Core.Session.eval("(active-window)")

      {:ok, _} = Compos.Core.Session.eval(~s{(display-buffer "*Messages*")})
      {:ok, _} = Compos.Core.Session.eval("(select-window! #{from})")
      assert Editor.current_buffer() == buf

      press(["C-`"])
      assert {:ok, ^from} = Compos.Core.Session.eval("(active-window)")
      assert Editor.current_buffer() == buf
      Editor.delete_other_windows()
    end

    # C-x 0 in the popup closes the popup: same window, same return
    test "C-x 0 inside a popup returns where the popup came from", %{buf: buf} do
      press(["C-x", "3"])
      press(["C-x", "o"])
      {:ok, from} = Compos.Core.Session.eval("(active-window)")

      {:ok, _} = Compos.Core.Session.eval(~s{(display-buffer "*Messages*")})
      assert Editor.current_buffer() == "*Messages*"

      press(["C-x", "0"])
      assert {:ok, ^from} = Compos.Core.Session.eval("(active-window)")
      assert Editor.current_buffer() == buf

      # and it stopped floating, or it would float in an ordinary window
      assert {:ok, "#f"} =
               Compos.Core.Session.eval(~s{(buffer-local "*Messages*" 'window-class)})

      Editor.delete_other_windows()
    end

    test "dired q quits back to the previous buffer", %{buf: buf} do
      root = Path.join(System.tmp_dir!(), "compos-q-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      {:ok, _} = Compos.Core.Session.eval(~s{(dired-open "#{root}")})
      assert Editor.current_buffer() == root

      press(["q"])
      assert Editor.current_buffer() == buf
      assert eventually(fn -> not Buffer.exists?(root) end)
      File.rm_rf!(root)
    end

    test "q walks out of nested dired buffers, it does not flip", %{buf: buf} do
      root = Path.join(System.tmp_dir!(), "compos-q2-#{System.unique_integer([:positive])}")
      sub = Path.join(root, "sub")
      File.mkdir_p!(sub)
      {:ok, _} = Compos.Core.Session.eval(~s{(dired-open "#{root}")})
      {:ok, _} = Compos.Core.Session.eval(~s{(dired-open "#{sub}")})
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
        Compos.Core.Session.eval(~s{(begin (buffer-create "*ro*")
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
        Compos.Core.Session.eval(~s{(begin (buffer-create "*ro2*")
                                          (switch-to-buffer! "*ro2*")
                                          (buffer-set-read-only! "*ro2*" #t)
                                          (local-set-key* "*ro2*" "q" "beginning-of-buffer"))})

      press(["q"])
      assert Editor.current_buffer() == "*ro2*"
      {:ok, _} = Compos.Core.Session.eval(~s{(buffer-kill! "*ro2*")})
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
    Application.put_env(:compos_core, :llm_chat_fun, fn %{messages: [%{content: prompt} | _]} ->
      assert prompt =~ "what is 6*7"
      # NOT a bare number: the fixture buffer is named test-<counter>, and
      # a reply of "42" matched the digits of its own name in the help card
      # — the wait below passed before the turn had rendered anything
      {:ok,
       %{
         "stop_reason" => "end_turn",
         "content" => [%{"type" => "text", "text" => "six times seven"}]
       }}
    end)

    on_exit(fn ->
      Application.delete_env(:compos_core, :llm_chat_fun)
      Compos.Core.kill_buffer(companion)
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

    Application.put_env(:compos_core, :llm_chat_fun, fn _ ->
      {:ok, %{"stop_reason" => "end_turn", "content" => []}}
    end)

    on_exit(fn ->
      Application.delete_env(:compos_core, :llm_chat_fun)
      Compos.Core.kill_buffer(companion)
    end)

    press(["M-x"])
    type("chat")
    press(["RET"])
    type("hello?")
    press(["RET"])

    assert eventually(fn -> Buffer.text(companion) =~ "(no reply" end)
    press(["C-x", "1"])
  end

  test "C-x b previews the highlighted buffer in the invoking window; C-g restores it", %{
    buf: buf
  } do
    other = "zz-cxb-#{System.unique_integer([:positive])}"
    {:ok, _} = Compos.Core.Session.eval(~s{(begin (buffer-create "#{other}") #t)})
    on_exit(fn -> Compos.Core.kill_buffer(other) end)

    win = Editor.active_window()

    shown = fn ->
      Enum.find_value(Editor.list_windows(), fn {id, b} -> if id == win, do: b end)
    end

    # type enough to filter to `other`: the refilter previews it live
    open_switch_prompt()
    assert Editor.snapshot().minibuffer
    type("zz-cxb")
    assert Compos.Core.Session.eval("(minibuffer-selected)") == {:ok, ~s{"#{other}"}}
    assert shown.() == other

    # C-g restores the displaced buffer; the buffer ring is untouched
    press(["C-g"])
    refute Editor.snapshot().minibuffer
    assert shown.() == buf
    assert {:ok, first} = Compos.Core.Session.eval("(car (car (buffer-candidates)))")
    refute first == ~s{"#{other}"}

    # RET actually switches
    open_switch_prompt()
    type("zz-cxb")
    press(["RET"])
    assert shown.() == other
    assert Editor.current_buffer() == other
  end

  test "openai models run the tool loop like every other model", %{buf: buf} do
    companion = "*chat:#{buf}*"
    type("Dear hiring manager")

    {:ok, before} = Compos.Core.Session.eval("(llm-model)")
    parent = self()

    Application.put_env(:compos_core, :llm_chat_fun, fn req ->
      send(parent, {:chat, req})
      {:ok, %{"stop_reason" => "end_turn", "content" => [%{"text" => "ok then"}]}}
    end)

    on_exit(fn ->
      Application.delete_env(:compos_core, :llm_chat_fun)
      Compos.Core.Session.eval("(set-llm-model! #{before})")
      Compos.Core.kill_buffer(companion)
    end)

    {:ok, _} = Compos.Core.Session.eval(~s{(set-llm-model! "openai:gpt-5.6-test")})

    press(["C-c", "w"])
    assert Editor.current_buffer() == companion

    {:ok, _} =
      Compos.Core.Session.eval(~s{(buffer-set-local! "#{companion}" 'chat-presets '(compos))})

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

    Application.put_env(:compos_core, :llm_chat_fun, fn %{messages: messages, system: system} ->
      # the per-send system preamble names the document and the pull tools
      assert system =~ "writing companion"
      assert system =~ ~s{"#{buf}"}
      assert system =~ "buffer-text"
      # the turn itself is what the user typed
      assert messages |> List.last() |> Map.get(:content) =~ "make it rhyme"

      {:ok,
       %{"stop_reason" => "end_turn", "content" => [%{"type" => "text", "text" => "try violets"}]}}
    end)

    on_exit(fn ->
      Application.delete_env(:compos_core, :llm_chat_fun)
      Compos.Core.kill_buffer(companion)
    end)

    press(["C-c", "w"])
    assert Editor.current_buffer() == companion
    assert length(Editor.list_windows()) == 2
    # the group is the tag: doc and chat both carry it, nothing points anywhere
    assert group_name(buffer_group(buf)) == buf
    assert buffer_group(companion) == buffer_group(buf)
    assert Buffer.get_local(companion, "mode-name") == "chat-mode"

    # rich surface from birth: agent renderer + help meta card + an input at the mark
    assert Buffer.get_local(companion, "render-mode") == "agent"
    assert Buffer.text(companion) =~ "companion · #{buf}"
    assert Buffer.get_local(companion, "agent-saved-mark") == Buffer.byte_size(companion)

    type("make it rhyme")
    press(["RET"])
    assert eventually(fn -> Buffer.text(companion) =~ "try violets" end)

    # the transcript is block-modeled like an agent thread (the prose
    # block reveals at turn end, after the streamed text lands)
    kinds = fn -> Buffer.get_local(companion, "agent-blocks") |> Enum.map(&Enum.at(&1, 2)) end
    assert eventually(fn -> "prose" in kinds.() end)
    assert "meta" in kinds.()
    assert "user" in kinds.()
    refute "waiting" in kinds.()

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

    Application.put_env(:compos_core, :llm_chat_fun, fn %{messages: messages} ->
      assert messages |> List.last() |> Map.get(:content) =~ "tighten this up"

      {:ok,
       %{"stop_reason" => "end_turn", "content" => [%{"type" => "text", "text" => "knot bad"}]}}
    end)

    on_exit(fn ->
      Application.delete_env(:compos_core, :llm_chat_fun)
      Compos.Core.kill_buffer(companion)
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
    on_exit(fn -> Compos.Core.kill_buffer(legacy) end)

    type("Draft about ropes.")

    # a groupless chat only comes from an old desktop — recreate one by hand.
    # Groupless means groupless: a buffer born while the frame is inside a
    # group joins it, and the chat is then that group's, with its name.
    {:ok, _} =
      Compos.Core.Session.eval(~s{(begin
        (set-frame-local! 'current-group #f)
        (buffer-create "#{legacy}")
        (switch-to-buffer! "#{legacy}")
        (set-mode! "chat-mode"))})

    assert Editor.current_buffer() == legacy

    # C-c w in an unlinked chat asks which buffer to accompany (MRU-first)
    press(["C-c", "w"])
    assert Editor.snapshot().minibuffer.prompt == "Companion for buffer: "
    press(["RET"])

    assert group_name(buffer_group(buf)) == buf

    # Adoption gives the chat a group, and a chat is named for where it
    # lives: the old name was invented before that rule, so the chat is
    # re-derived once and takes the group's name.
    # Adoption puts the chat in the document's group and focuses it. The
    # chat may also be re-named for that group — a chat is named for where
    # it lives, and a name invented before that rule is derived once — so
    # the test follows the buffer, not the old name. chat-name-test.scm
    # owns the naming policy.
    adopted = Editor.current_buffer()
    assert Compos.Core.Buffer.exists?(adopted)
    assert buffer_group(adopted) == buffer_group(buf)

    # C-c w from the doc refocuses the adopted chat. The re-derive can land
    # between these presses, so read the chat back rather than remembering
    # a name: what must hold is that the toggle returns to the group's chat.
    press(["C-c", "w"])
    assert Editor.current_buffer() == buf
    press(["C-c", "w"])
    back = Editor.current_buffer()
    refute back == buf
    assert buffer_group(back) == buffer_group(buf)

    press(["C-x", "1"])
  end

  test "buffer groups: C-c g tags members, C-c q talks to the group's one chat",
       %{buf: buf} do
    notes = "notes-#{System.unique_integer([:positive])}"
    # a unique name: the prompt completes over every live group, and a
    # group another test left behind would answer to a shared prefix
    group = "proj-#{System.unique_integer([:positive])}"
    chat = "*chat:#{group}*"
    type("defmodule Rope do end")

    # the stub runs in a Task, so an assertion here can never fail the
    # test. Send the prompt back and assert in the test process instead.
    test_pid = self()

    Application.put_env(:compos_core, :llm_chat_fun, fn %{system: system} ->
      send(test_pid, {:system, system})
      {:ok, %{"stop_reason" => "end_turn", "content" => [%{"type" => "text", "text" => "aye"}]}}
    end)

    on_exit(fn ->
      Application.delete_env(:compos_core, :llm_chat_fun)
      Compos.Core.kill_buffer(chat)
      Compos.Core.kill_buffer(notes)
    end)

    use_api_connector!()

    # C-c g founds the group from the code buffer, then the notes join it
    press(["C-c", "g"])
    assert Editor.snapshot().minibuffer.prompt =~ ~r/^Add buffers to group/
    type(group)
    press(["RET"])
    assert in_group?(buf, group)

    {:ok, _} = Compos.Core.Session.eval(~s{(buffer-create "#{notes}")})
    Editor.set_window_buffer(notes)
    press(["C-c", "g"])
    type(group)
    press(["RET"])
    assert in_group?(notes, group)

    # C-c q in a grouped buffer routes to the group chat, focus stays put
    point = Buffer.point(notes)
    press(["C-c", "q"])
    assert Editor.snapshot().minibuffer.prompt == "Ask #{group}: "
    type("thoughts?")
    press(["RET"])

    assert eventually(fn -> Buffer.text(chat) =~ "aye" end)

    # the per-send preamble enumerates the whole group, not one document
    assert_receive {:system, system}, 5_000
    assert system =~ ~s{group "#{group}"}
    assert system =~ ~s{"#{buf}"}
    assert system =~ ~s{"#{notes}"}

    assert in_group?(chat, group)
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
    {:ok, _} = Compos.Core.Session.eval(~s{(set-mode! "chat-mode")})
    press(["C-c", "w"])
    assert Editor.current_buffer() == notes
    press(["C-c", "w"])
    assert Editor.current_buffer() == chat

    # kill the chat: nothing dangles, the next ask remakes it in the group
    press(["C-x", "1"])
    Compos.Core.kill_buffer(chat)
    Editor.set_window_buffer(notes)
    press(["C-c", "q"])
    type("again?")
    press(["RET"])

    assert eventually(fn ->
             Buffer.exists?(chat) && Buffer.text(chat) =~ "aye"
           end)

    assert in_group?(chat, group)

    press(["C-x", "1"])
  end

  test "C-c g defaults to the last visited group; RET pulls a stray buffer in", %{buf: buf} do
    g = "grp-#{System.unique_integer([:positive])}"
    stray = "stray-#{System.unique_integer([:positive])}"
    other = "other-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      for b <- ["*chat:#{g}*", stray, other], do: Compos.Core.kill_buffer(b)
    end)

    # stand in a group, then drift to an ungrouped buffer
    _id =
      group_id!("""
      (let ((id (group-record-create! "#{g}")))
        (buffer-add-group! "#{buf}" id)
        (switch-to-group! id)
        id)
      """)

    Editor.set_window_buffer(stray)

    # the prompt names the default; a bare RET joins it
    press(["C-c", "g"])
    assert Editor.snapshot().minibuffer.prompt == "Add buffers to group (default #{g}): "
    press(["RET"])
    assert group_name(buffer_group(stray)) == g

    # a typed name wins over the default and founds a new group
    new_g = "founded-#{System.unique_integer([:positive])}"
    Editor.set_window_buffer(other)
    press(["C-c", "g"])
    type(new_g)
    press(["RET"])
    assert group_name(buffer_group(other)) == new_g

    # from inside the group itself there is no self-default
    press(["C-c", "g"])
    prompt = Editor.snapshot().minibuffer.prompt
    refute prompt =~ new_g
    press(["C-g"])
  end

  test "legacy companion-of pointers migrate to group tags on mode setup", %{buf: buf} do
    chat = "*old-companion*"
    {:ok, _} = Compos.Core.Session.eval(~s{(buffer-create "#{chat}")})
    Buffer.set_local(chat, "companion-of", buf)

    on_exit(fn -> Compos.Core.kill_buffer(chat) end)

    Editor.set_window_buffer(chat)
    {:ok, _} = Compos.Core.Session.eval(~s{(set-mode! "chat-mode")})

    # both ends now carry the tag; the pointer is only read as a fallback
    assert group_name(buffer_group(buf)) == buf
    assert buffer_group(chat) == buffer_group(buf)
  end

  test "C-c q founds a group and asks its one chat from the minibuffer", %{buf: buf} do
    companion = "*chat:#{buf}*"

    Application.put_env(:compos_core, :llm_chat_fun, fn %{messages: [%{content: prompt} | _]} ->
      assert prompt =~ "what is 6*7"

      # NOT a bare number: the fixture buffer is named test-<counter>, and
      # a reply of "42" matched the digits of its own name in the help card
      # — the wait below passed before the turn had rendered anything
      {:ok,
       %{
         "stop_reason" => "end_turn",
         "content" => [%{"type" => "text", "text" => "six times seven"}]
       }}
    end)

    on_exit(fn ->
      Application.delete_env(:compos_core, :llm_chat_fun)
      Compos.Core.kill_buffer(companion)
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
    {:ok, before} = Compos.Core.Session.eval("(llm-model)")
    {:ok, _} = Compos.Core.Session.eval(~s{(set-llm-model! "luna-5.6")})
    assert {:ok, ~s{"luna-5.6"}} = Compos.Core.Session.eval("(llm-model)")
    {:ok, _} = Compos.Core.Session.eval("(set-llm-model! #{before})")
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

  # The panel must offer what the map holds. Naming a production prefix
  # here would send this test red the day somebody binds something under
  # it — C-x C-g is a group prefix now — which is a preference changing
  # and not a bug in which-key. So the test binds its own prefix and
  # reads the map back.
  test "the which-key panel offers the pending prefix's own bindings" do
    {:ok, _} =
      Compos.Core.Session.eval("""
      (begin
        (define-command "zz-wk-one" "A dummy for the which-key panel" (lambda () #t))
        (define-command "zz-wk-two" "Another dummy" (lambda () #t))
        (global-set-key "<f9> a" "zz-wk-one")
        (global-set-key "<f9> b" "zz-wk-two"))
      """)

    on_exit(fn ->
      Compos.Core.Session.eval(~s[(begin (global-unset-key "<f9> a") (global-unset-key "<f9> b"))])
    end)

    press(["<f9>"])
    wk = Editor.render_state().which_key
    assert is_list(wk) and wk != [], "a pending prefix drew no panel"

    # a panel row can name a whole sequence under the prefix, so the
    # lookup takes the keys apart the same way the map holds them
    for %{key: key, command: command} <- wk do
      seq = Enum.map_join(String.split(key, " ", trim: true), " ", &~s{"#{&1}"})

      assert {:ok, ~s{"#{command}"}} ==
               Compos.Core.Session.eval(~s{(key-binding (list "<f9>" #{seq}))}),
             "the panel offers <f9> #{key} => #{command}; the map does not agree"
    end

    press(["C-g"])
    assert Editor.render_state().which_key == nil
  end

  test "the which-key panel groups modifiers and sorts each group alphabetically", %{buf: buf} do
    {:ok, _} =
      Compos.Core.Session.eval("""
      (begin
        (local-set-key* "#{buf}" "<f9> z" "forward-char")
        (local-set-key* "#{buf}" "<f9> a" "backward-char")
        (local-set-key* "#{buf}" "<f9> C-z" "forward-char")
        (local-set-key* "#{buf}" "<f9> C-a" "backward-char")
        (local-set-key* "#{buf}" "<f9> C-A" "beginning-of-line")
        (local-set-key* "#{buf}" "<f9> M-z" "forward-char")
        (local-set-key* "#{buf}" "<f9> M-a" "backward-char")
        (local-set-key* "#{buf}" "<f9> Z" "end-of-line")
        (local-set-key* "#{buf}" "<f9> A" "beginning-of-line")
        (local-set-key* "#{buf}" "<f9> s-a" "beginning-of-buffer"))
      """)

    press(["<f9>"])

    test_keys = ["a", "z", "C-a", "C-z", "C-A", "M-a", "M-z", "A", "Z", "s-a"]

    ordered =
      Editor.render_state().which_key
      |> Enum.filter(&(&1.key in test_keys))
      |> Enum.map(fn item -> {item.modifier_label, item.modifiers, item.key} end)

    assert ordered == [
             {"Unmodified", [], "a"},
             {"Unmodified", [], "z"},
             {"Control", ["C"], "C-a"},
             {"Control", ["C"], "C-z"},
             {"Control + Shift", ["C", "S"], "C-A"},
             {"Meta", ["M"], "M-a"},
             {"Meta", ["M"], "M-z"},
             {"Shift", ["S"], "A"},
             {"Shift", ["S"], "Z"},
             {"Super", ["s"], "s-a"}
           ]

    press(["C-g"])
  end

  test "themes are pure scheme: load-theme sets semantic faces" do
    {:ok, _} = Compos.Core.Session.eval(~s{(load-theme "tokyo-night")})
    faces = Editor.render_state().faces
    assert faces["default"]["bg"] == "#1a1b26"
    assert faces["accent"]["fg"] == "#7aa2f7"
    # tokyo-night is define-theme-from compos-dark: the override wins,
    # the unnamed face inherits
    assert faces["ts-keyword"]["fg"] == "#bb9af7"
    assert faces["warn"]["fg"] == "#e0af68"

    {:ok, _} = Compos.Core.Session.eval(~s{(load-theme "catppuccin-mocha")})
    assert Editor.render_state().faces["default"]["bg"] == "#1e1e2e"

    # paper names its own syntax faces — a theme that omits them keeps
    # the previous theme's colors on screen
    {:ok, _} = Compos.Core.Session.eval(~s{(load-theme "paper")})
    assert Editor.render_state().faces["ts-keyword"]["fg"] == "#26356b"

    # restore
    {:ok, _} = Compos.Core.Session.eval(~s{(load-theme "compos-dark")})
  end

  test "defface! declares a default that the theme beats" do
    {:ok, _} = Compos.Core.Session.eval(~s{(load-theme "paper-night")})

    # a package reload re-declares its faces at load time; the theme's
    # color must hold, or the dark theme turns light after every reload
    {:ok, _} = Compos.Core.Session.eval(~s{(defface! 'nm-author 'fg "#26356b")})
    assert Editor.render_state().faces["nm-author"]["fg"] == "#9fb0ea"

    # a face that no theme names takes the package default
    {:ok, _} = Compos.Core.Session.eval(~s{(defface! 'tt-gauge 'fg "#111111")})
    assert Editor.render_state().faces["tt-gauge"]["fg"] == "#111111"

    # a theme that names the face wins
    {:ok, _} =
      Compos.Core.Session.eval(~s{(define-theme "tt-theme" (list (list 'tt-gauge 'fg "#eeeeee")))})

    {:ok, _} = Compos.Core.Session.eval(~s{(load-theme "tt-theme")})
    assert Editor.render_state().faces["tt-gauge"]["fg"] == "#eeeeee"

    # the next theme leaves the face alone, so the default returns
    {:ok, _} = Compos.Core.Session.eval(~s{(load-theme "paper-night")})
    assert Editor.render_state().faces["tt-gauge"]["fg"] == "#111111"

    # restore
    {:ok, _} = Compos.Core.Session.eval(~s{(load-theme "compos-dark")})
  end

  test "key-for-command reverse lookup" do
    {:ok, printed} = Compos.Core.Session.eval(~s{(key-for-command "find-file")})
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
    path = Path.join(System.tmp_dir!(), "compos-e2e-#{System.unique_integer([:positive])}.txt")
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

  test "C-x C-s adopts a pathless buffer whose name is a path, without a prompt" do
    path = Path.join(System.tmp_dir!(), "compos-adopt-#{System.unique_integer([:positive])}.txt")
    Editor.set_window_buffer(path)
    type("adopted")
    press(["C-x", "C-s"])

    assert Editor.snapshot().minibuffer == nil
    assert File.read!(path) == "adopted"
    assert echo() =~ "Wrote"
    # the name became the buffer's path, and auto-mode applied
    assert Buffer.path(path) == path
    assert Buffer.get_local(path, "mode-name") == "text-mode"

    type(" again")
    press(["C-x", "C-s"])
    assert File.read!(path) == "adopted again"
    File.rm!(path)
  end

  test "C-x C-w prompts and the buffer becomes the written file", %{buf: buf} do
    type("hello")
    path = Path.join(System.tmp_dir!(), "compos-w-#{System.unique_integer([:positive])}.txt")

    press(["C-x", "C-w"])
    assert Editor.render_state().minibuffer.prompt =~ "Write #{buf} to file:"

    assert String.ends_with?(Editor.render_state().minibuffer.input, "/#{buf}")

    clear_minibuffer()
    type(path)
    press(["RET"])

    assert File.read!(path) == "hello"
    assert Editor.current_buffer() == path
    refute Buffer.exists?(buf)
    File.rm!(path)
  end

  test "write-file proposes the buffer name with its mode extension" do
    buf = "*pdf text or image*"
    Editor.set_window_buffer(buf)
    {:ok, _} = Compos.Core.Session.eval(~s{(buffer-set-local! "#{buf}" 'mode-name "chat-mode")})

    run("write-file")

    assert String.ends_with?(
             Editor.render_state().minibuffer.input,
             "/pdf text or image.chat"
           )

    press(["C-g"])
  end

  test "TAB into a directory, then RET opens dired (not the first entry)" do
    root = Path.join(System.tmp_dir!(), "compos-dir-#{System.unique_integer([:positive])}")
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
    root = Path.join(System.tmp_dir!(), "compos-fmode-#{System.unique_integer([:positive])}")
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

  test "switch-to-buffer moves the window to the buffer you name", %{buf: buf} do
    other = "other-#{System.unique_integer([:positive])}"
    Compos.Core.create_buffer(other)

    open_modal_switcher()
    type(other)
    press(["RET"])
    assert Editor.current_buffer() == other

    open_modal_switcher()
    type(buf)
    press(["RET"])
    assert Editor.current_buffer() == buf
  end

  test "C-x b matches the mode in the marginalia, not the name alone", %{buf: buf} do
    n = System.unique_integer([:positive])
    plain = "swm-plain-#{n}"
    prose = "swm-prose-#{n}"
    Compos.Core.create_buffer(plain)
    Compos.Core.create_buffer(prose)

    {:ok, _} =
      Compos.Core.Session.eval("""
      (begin (switch-to-buffer! "#{prose}") (set-mode! "text-mode")
             (switch-to-buffer! "#{buf}"))
      """)

    # the mode is the annotation, and typing it finds the buffer
    open_switch_prompt()
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
    open_switch_prompt()
    type(plain)
    press(["RET"])
    assert Editor.current_buffer() == plain
  end

  test "the switch prompt is history first: previous buffer defaults, containers ride under it" do
    n = System.unique_integer([:positive])
    m1 = "ct-a-#{n}"
    m2 = "ct-b-#{n}"
    home = "ct-home-#{n}"
    for b <- [m1, m2, home], do: Compos.Core.create_buffer(b)

    id =
      group_id!("""
      (let ((id (group-record-create! "ctgrp-#{n}")))
        (set-frame-local! 'current-group #f)
        (delete-other-windows!)
        (switch-to-buffer! "#{m1}")
        (switch-to-buffer! "#{m2}")
        (buffer-add-group! "#{m1}" id)
        (buffer-add-group! "#{m2}" id)
        (switch-to-buffer! "#{home}")
        id)
      """)

    # pure history: the previous buffer is the default; groups have no
    # rows of their own — the buffer rows carry the group
    open_switch_prompt()
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
    assert Compos.Core.Session.eval("(frame-local 'current-group)") == {:ok, ~s{"#{id}"}}

    # C-RET is the CONTEXT switch: the group's layout comes up with
    # point in the picked buffer, and the frame enters the group.
    # (Drop the snapshot the switcher just took, so the default
    # arrangement is what comes up.)
    open_switch_prompt()

    {:ok, _} = Compos.Core.Session.eval(~s{(group-record-update! "#{id}" 'layout #f)})

    type(m1)
    press(["C-RET"])
    assert Editor.current_buffer() == m1

    shown =
      Editor.list_windows() |> Enum.map(fn {_id, b} -> b end) |> Enum.sort()

    assert shown == Enum.sort([m1, m2])

    assert Compos.Core.Session.eval("(frame-local 'current-group)") == {:ok, ~s{"#{id}"}}

    {:ok, _} =
      Compos.Core.Session.eval(
        "(begin (set-frame-local! 'current-group #f) (delete-other-windows!))"
      )
  end

  test "a board that covers a group's pane cannot lose its layout" do
    n = System.unique_integer([:positive])
    m1 = "cv-a-#{n}"
    m2 = "cv-b-#{n}"
    other = "cv-c-#{n}"
    board = "cv-board-#{n}"
    a = "cvgrp-#{n}"
    b = "cvother-#{n}"
    for x <- [m1, m2, other], do: Compos.Core.create_buffer(x)

    # group A stands in two windows, and it has never saved a layout
    {:ok, _} =
      Compos.Core.Session.eval("""
      (begin (set-frame-local! 'current-group #f)
             (buffer-set-local! "#{m1}" 'group "#{a}")
             (buffer-set-local! "#{m2}" 'group "#{a}")
             (buffer-set-local! "#{other}" 'group "#{b}")
             (group-chat "#{a}")
             (group-chat "#{b}")
             (buffer-set-local! (group-chat "#{a}") 'group-layout #f)
             (delete-other-windows!)
             (switch-to-buffer! "#{m1}")
             (split-window! 'h 0.5)
             (other-window!)
             (switch-to-buffer! "#{m2}")
             (set-frame-local! 'current-group "#{a}"))
      """)

    assert Compos.Core.Session.eval(~s{(group-layout "#{a}")}) == {:ok, "#f"}

    # a board takes a pane — every listing reaches a window through
    # display-buffer — and the arrangement it covers goes on record
    # before it does
    {:ok, _} =
      Compos.Core.Session.eval("""
      (begin (buffer-create "#{board}")
             (buffer-set-local! "#{board}" 'transient #t)
             (display-buffer "#{board}"))
      """)

    assert board in (Editor.list_windows() |> Enum.map(fn {_id, x} -> x end))
    refute Compos.Core.Session.eval(~s{(group-layout "#{a}")}) == {:ok, "#f"}

    # leave from the board — the buffer you act from is not a member, so
    # nothing else can capture the layout — then come back
    {:ok, _} = Compos.Core.Session.eval(~s{(switch-to-group! "#{b}")})
    {:ok, _} = Compos.Core.Session.eval(~s{(switch-to-group! "#{a}")})

    shown = Editor.list_windows() |> Enum.map(fn {_id, x} -> x end) |> Enum.sort()
    assert shown == Enum.sort([m1, m2])

    {:ok, _} =
      Compos.Core.Session.eval(
        "(begin (set-frame-local! 'current-group #f) (delete-other-windows!))"
      )
  end

  test "a group you switched to is a history row; its name finds it and its members" do
    n = System.unique_integer([:positive])
    m1 = "hs-a-#{n}"
    m2 = "hs-b-#{n}"
    home = "hs-home-#{n}"
    for x <- [m1, m2, home], do: Compos.Core.create_buffer(x)

    id =
      group_id!("""
      (let ((id (group-record-create! "hsgrp-#{n}")))
        (set-frame-local! 'current-group #f)
        (delete-other-windows!)
        (switch-to-buffer! "#{m1}")
        (switch-to-buffer! "#{m2}")
        (buffer-add-group! "#{m1}" id)
        (buffer-add-group! "#{m2}" id)
        (switch-to-group! id)
        (switch-to-buffer! "#{home}")
        ;; leave the context: the frame stands nowhere now, so the
        ;; group is history like anything else
        (set-frame-local! 'current-group #f)
        id)
      """)

    # the switch is itself a history entry: the group's card leads the
    # stream, above the members its restore bumped
    open_switch_prompt()
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
    open_switch_prompt()
    press(["RET"])

    # a group's name can change and its ID cannot, so the frame stands in
    # the ID and the test reads the name off it
    assert Compos.Core.Session.eval("(frame-local 'current-group)") == {:ok, ~s{"#{id}"}}
    assert group_name(id) == "hsgrp-#{n}"

    assert Editor.current_buffer() in [m1, m2]

    {:ok, _} =
      Compos.Core.Session.eval(
        "(begin (set-frame-local! 'current-group #f) (delete-other-windows!))"
      )
  end

  test "modeline-expand attaches the panel to the buffer itself" do
    n = System.unique_integer([:positive])
    b = "dash-#{n}"
    Compos.Core.create_buffer(b)

    {:ok, _} =
      Compos.Core.Session.eval("""
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
    assert Compos.Core.Session.eval("(point)") == {:ok, "7"}
    assert Compos.Core.Buffer.get_local(b, "modeline-expanded") == true

    blocks =
      inspect(Compos.Core.Buffer.get_local(b, "modeline-dash-blocks"),
        limit: :infinity,
        printable_limit: :infinity
      )

    assert blocks =~ "dashgrp-#{n}"
    assert blocks =~ "companion"
    assert blocks =~ "lane"
    refute blocks =~ "all groups"

    # the same key detaches it; the buffer never noticed
    press(["C-x", "?"])
    assert Compos.Core.Buffer.get_local(b, "modeline-expanded") in [nil, false]
    assert Editor.current_buffer() == b
    assert Compos.Core.Session.eval("(point)") == {:ok, "7"}

    {:ok, _} = Compos.Core.Session.eval("(delete-other-windows!)")
  end

  test "winner: a destroyed layout is one undo away; redo returns" do
    n = System.unique_integer([:positive])
    b = "wn-#{n}"
    Compos.Core.create_buffer(b)

    {:ok, _} =
      Compos.Core.Session.eval("""
      (begin (set-frame-local! 'current-group #f)
             (set-frame-local! 'winner-ring #f)
             (set-frame-local! 'winner-pos #f)
             (delete-other-windows!)
             (switch-to-buffer! "#{b}")
             (split-window! 'h 0.5))
      """)

    assert length(Editor.list_windows()) == 2

    # C-x 1 destroys the split; winner-previous brings it back.
    press(["C-x", "1"])
    assert length(Editor.list_windows()) == 1
    run("winner-previous")
    assert length(Editor.list_windows()) == 2

    # winner-next walks forward to the single window again.
    run("winner-next")
    assert length(Editor.list_windows()) == 1
    {:ok, _} = Compos.Core.Session.eval("(delete-other-windows!)")
  end

  test "winner: a group switch is one undo away" do
    n = System.unique_integer([:positive])
    m = "wg-a-#{n}"
    home = "wg-home-#{n}"
    for x <- [m, home], do: Compos.Core.create_buffer(x)

    {:ok, _} =
      Compos.Core.Session.eval("""
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
    run("winner-previous")
    assert Editor.current_buffer() == home

    {:ok, _} =
      Compos.Core.Session.eval(
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
      Compos.Core.Session.eval("""
      (begin (set-frame-local! 'current-group #f)
             (delete-other-windows!)
             (visit "#{f1}")
             (visit "#{f2}")
             (switch-to-buffer! "*scratch*"))
      """)

    open_group_switcher()
    type("one.txt")
    press(["C-RET"])

    # the project's open buffers joined a group named by the root, and
    # the context came up arranged
    # C-RET founds the group, so look up the ID the root name now holds;
    # both files must carry that one identity
    id = group_id!(~s{(group-resolve-id "#{root}")})
    assert Compos.Core.Session.eval(~s{(buffer-group "#{f1}")}) == {:ok, ~s{"#{id}"}}
    assert Compos.Core.Session.eval(~s{(buffer-group "#{f2}")}) == {:ok, ~s{"#{id}"}}
    assert Editor.current_buffer() == f1

    shown = Editor.list_windows() |> Enum.map(fn {_id, b} -> b end) |> Enum.sort()
    assert shown == Enum.sort([f1, f2])

    {:ok, _} =
      Compos.Core.Session.eval(
        "(begin (set-frame-local! 'current-group #f) (delete-other-windows!))"
      )
  end

  test "TAB completes the single remaining candidate" do
    n = System.unique_integer([:positive])
    b = "tabone-#{n}"
    Compos.Core.create_buffer(b)

    open_switch_prompt()
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
    for b <- [m1, m2, out], do: Compos.Core.create_buffer(b)

    {:ok, _} =
      Compos.Core.Session.eval("""
      (begin (switch-to-buffer! "#{m1}")
             (switch-to-buffer! "#{m2}")
             (buffer-set-local! "#{m1}" 'group "lkgrp-#{n}")
             (buffer-set-local! "#{m2}" 'group "lkgrp-#{n}")
             (switch-to-buffer! "#{out}"))
      """)

    open_switch_prompt()
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
    for b <- [m1, home], do: Compos.Core.create_buffer(b)

    {:ok, _} =
      Compos.Core.Session.eval("""
      (begin (set-frame-local! 'current-group #f)
             (switch-to-buffer! "#{m1}")
             (buffer-set-local! "#{m1}" 'group "ccgrp-#{n}")
             (switch-to-buffer! "#{home}"))
      """)

    open_switch_prompt()
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
      Compos.Core.Session.eval(~s{(begin (delete-other-windows!) (switch-to-buffer! "#{buf}"))})

    # switch-visit founds a group named the narrowing when no row matches.
    # The group-aware prompt does not: it only switches.
    open_modal_switcher()
    type("zzqxw-#{n}")
    press(["RET"])

    id = buffer_group(buf)
    assert id, "#{buf} joined no group"
    assert group_name(id) == "zzqxw-#{n}"
    {:ok, _} = Compos.Core.Session.eval(~s{(buffer-move-to-group! "#{buf}" #f)})
  end

  test "the groups board lists a group; noise cycles and persists" do
    n = System.unique_integer([:positive])
    b = "gb-#{n}"
    Compos.Core.create_buffer(b)

    {:ok, _} =
      Compos.Core.Session.eval("""
      (begin (buffer-set-local! "#{b}" 'group "gbgrp-#{n}")
             (run-command "groups"))
      """)

    assert Editor.current_buffer() == "*groups*"
    assert Buffer.text("*groups*") =~ "gbgrp-#{n}"

    assert Compos.Core.Session.eval(~s{(group-noise "gbgrp-#{n}")}) == {:ok, ~s{"quiet"}}
    {:ok, _} = Compos.Core.Session.eval(~s{(group-noise-set! "gbgrp-#{n}" "loud")})
    assert Compos.Core.Session.eval(~s{(group-noise "gbgrp-#{n}")}) == {:ok, ~s{"loud"}}

    assert {:ok, out} =
             Compos.Core.Session.eval(~s{(if (member 'group-noise chat-identity-locals) #t #f)})

    assert out == "#t"
    press(["q"])
  end

  test "the group switcher orders buffers by the invoking window's history" do
    n = System.unique_integer([:positive])
    first = "wh-first-#{n}"
    last = "wh-last-#{n}"
    home = "wh-home-#{n}"
    noise = "wh-noise-#{n}"

    for buf <- [first, last, home, noise], do: Compos.Core.create_buffer(buf)

    {:ok, original} =
      Compos.Core.Session.eval("""
      (let ((id (group-record-create! "wh-group-#{n}")))
        (set-frame-local! 'current-group id)
        (delete-other-windows!)
        (buffer-add-group! "#{first}" id)
        (buffer-add-group! "#{last}" id)
        (buffer-add-group! "#{home}" id)
        (switch-to-buffer! "#{first}")
        (switch-to-buffer! "#{last}")
        (switch-to-buffer! "#{home}")
        (let ((window (active-window)))
          (split-window! 'h 0.5)
          (other-window!)
          (switch-to-buffer! "#{first}")
          (switch-to-buffer! "#{noise}")
          window))
      """)

    {:ok, _} = Compos.Core.Session.eval("(select-window! #{original})")

    assert {:ok, history} =
             Compos.Core.Session.eval(
               "(let ((layout (window-tree))) (window-tree-set! layout) (window-buffer-history))"
             )

    assert history =~ ~r/\A\("#{last}" "#{first}"/

    open_group_switcher()

    labels =
      Editor.render_state().minibuffer.candidates
      |> Enum.map(& &1.label)
      |> Enum.filter(&(&1 in [first, last, noise]))

    assert labels == [last, first, noise]

    press(["C-g"])
    {:ok, _} = Compos.Core.Session.eval("(delete-other-windows!)")
  end

  test "the ring toggles: C-x b RET goes back, and back again" do
    n = System.unique_integer([:positive])
    a = "rg-a-#{n}"
    b = "rg-b-#{n}"
    for x <- [a, b], do: Compos.Core.create_buffer(x)

    {:ok, _} =
      Compos.Core.Session.eval("""
      (begin (set-frame-local! 'current-group #f)
             (delete-other-windows!)
             (switch-to-buffer! "#{a}")
             (switch-to-buffer! "#{b}"))
      """)

    open_switch_prompt()
    assert Editor.render_state().minibuffer.prompt =~ "default #{a}"
    press(["RET"])
    assert Editor.current_buffer() == a

    open_switch_prompt()
    assert Editor.render_state().minibuffer.prompt =~ "default #{b}"
    press(["RET"])
    assert Editor.current_buffer() == b
  end

  test "C-x o records the focused window's buffer in the ring" do
    n = System.unique_integer([:positive])
    left = "wo-a-#{n}"
    right = "wo-b-#{n}"
    for x <- [left, right], do: Compos.Core.create_buffer(x)

    {:ok, _} =
      Compos.Core.Session.eval("""
      (begin (set-frame-local! 'current-group #f)
             (delete-other-windows!)
             (switch-to-buffer! "#{left}")
             (split-window! 'h 0.5)
             (other-window!)
             (switch-to-buffer! "#{right}")
             (other-window!))
      """)

    # focusing left last: left leads the ring
    assert {:ok, mru} = Compos.Core.Session.eval("(buffer-list-mru)")
    assert mru =~ ~r/\A\("#{left}" "#{right}"/

    # C-x o focuses right: right leads now
    press(["C-x", "o"])
    assert {:ok, mru} = Compos.Core.Session.eval("(buffer-list-mru)")
    assert mru =~ ~r/\A\("#{right}" "#{left}"/
    {:ok, _} = Compos.Core.Session.eval("(delete-other-windows!)")
  end

  test "a group switch records the landed buffers in the ring" do
    n = System.unique_integer([:positive])
    m1 = "gr-a-#{n}"
    m2 = "gr-b-#{n}"
    home = "gr-home-#{n}"
    for x <- [m1, m2, home], do: Compos.Core.create_buffer(x)

    {:ok, _} =
      Compos.Core.Session.eval("""
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
    assert {:ok, mru} = Compos.Core.Session.eval("(buffer-list-mru)")
    heads = mru |> String.trim_leading("(") |> String.split(" ") |> Enum.take(3)
    assert Enum.at(heads, 0) == ~s{"#{m2}"}
    assert ~s{"#{m1}"} in heads
    assert ~s{"#{home}"} in heads

    {:ok, _} =
      Compos.Core.Session.eval(
        "(begin (set-frame-local! 'current-group #f) (delete-other-windows!))"
      )
  end

  test "a stale off-screen buffer catches up when the switcher shows it" do
    n = System.unique_integer([:positive])
    b = "st-#{n}"
    Compos.Core.create_buffer(b)

    {:ok, _} =
      Compos.Core.Session.eval("""
      (begin (set-frame-local! 'current-group #f)
             (delete-other-windows!)
             (buffer-set-local! "#{b}" 'probe-stale #t)
             (switch-to-buffer! "*scratch*"))
      """)

    {:ok, _} =
      Compos.Core.Session.eval("""
      (on-buffer-shown!
        (lambda (buf)
          (when (buffer-local buf 'probe-stale)
            (buffer-set-local! buf 'probe-stale #f)
            (buffer-set-local! buf 'probe-caught #t))))
      """)

    open_modal_switcher()
    type(b)
    press(["RET"])
    assert Editor.current_buffer() == b
    assert Buffer.get_local(b, "probe-caught") == true
  end

  test "group-rename retags members and carries the identity" do
    n = System.unique_integer([:positive])
    m1 = "rn-a-#{n}"
    m2 = "rn-b-#{n}"
    for x <- [m1, m2], do: Compos.Core.create_buffer(x)

    # Found the group once and hold its ID. The name is the one thing
    # this test changes, so every later reference names the ID.
    id =
      group_id!("""
      (let ((id (group-record-create! "rngrp-#{n}")))
        (buffer-add-group! "#{m1}" id)
        (buffer-add-group! "#{m2}" id)
        (delete-other-windows!)
        (switch-to-buffer! "#{m1}")
        (group-meta-set! id "the renamed group")
        (group-rename! id "fresh-#{n}")
        id)
      """)

    # the rename moves the name; the ID and both memberships stay put
    assert Compos.Core.Session.eval(~s{(buffer-group "#{m1}")}) == {:ok, ~s{"#{id}"}}
    assert Compos.Core.Session.eval(~s{(buffer-group "#{m2}")}) == {:ok, ~s{"#{id}"}}
    assert Compos.Core.Session.eval("(frame-local 'current-group)") == {:ok, ~s{"#{id}"}}

    # only the display name and the metadata answer to the new name
    assert Compos.Core.Session.eval(~s{(group-name "#{id}")}) == {:ok, ~s{"fresh-#{n}"}}
    assert Compos.Core.Session.eval(~s{(group-meta "#{id}")}) == {:ok, ~s{"the renamed group"}}

    {:ok, _} = Compos.Core.Session.eval("(set-frame-local! 'current-group #f)")
  end

  test "group-kill kills the members but keeps modified file buffers" do
    n = System.unique_integer([:positive])
    m1 = "gk-a-#{n}"
    m2 = "gk-b-#{n}"
    f = Path.join(System.tmp_dir!(), "gk-f-#{n}.txt")
    File.write!(f, "saved")
    on_exit(fn -> File.rm(f) end)

    for b <- [m1, m2], do: Compos.Core.create_buffer(b)

    {:ok, _} =
      Compos.Core.Session.eval("""
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
      Compos.Core.Session.eval(~s{(begin (buffer-mark-saved! "#{f}") (buffer-kill! "#{f}") #t)})
  end

  test "the layout restores as saved — no second-guessing" do
    n = System.unique_integer([:positive])
    m = "hl-a-#{n}"
    Compos.Core.create_buffer(m)

    {:ok, out} =
      Compos.Core.Session.eval("""
      (begin (set-frame-local! 'current-group #f)
             (buffer-set-local! "#{m}" 'group "hlgrp-#{n}")
             (delete-other-windows!)
             (switch-to-buffer! "#{m}")
             (group-layout-save! "hlgrp-#{n}")
             (switch-to-buffer! "*scratch*")
             ;; the member's tag drifts (killed elsewhere, retagged...)
             (buffer-set-local! "#{m}" 'group #f)
             (switch-to-group! "hlgrp-#{n}")
             (map (lambda (w) (car (cdr w))) (window-list)))
      """)

    # the saved arrangement comes back even though the tag drifted
    assert out == ~s{("#{m}")}

    {:ok, _} =
      Compos.Core.Session.eval(
        "(begin (set-frame-local! 'current-group #f) (delete-other-windows!))"
      )
  end

  test "a killed file member comes back with content, not an empty shell" do
    n = System.unique_integer([:positive])
    f = Path.join(System.tmp_dir!(), "gs-#{n}.txt")
    File.write!(f, "the real content")
    on_exit(fn -> File.rm(f) end)
    home = "gs-home-#{n}"
    Compos.Core.create_buffer(home)

    {:ok, _} =
      Compos.Core.Session.eval("""
      (let ((id (group-record-create! "gsgrp-#{n}")))
        (set-frame-local! 'current-group #f)
        (delete-other-windows!)
        (visit "#{f}")
        (buffer-add-group! "#{f}" id)
        (group-layout-save! id)
        (switch-to-buffer! "#{home}")
        (buffer-kill! "#{f}")
        (switch-to-group! id)
        #t)
      """)

    assert Editor.current_buffer() == f
    assert Compos.Core.Buffer.text(f) == "the real content"

    {:ok, _} =
      Compos.Core.Session.eval(
        ~s{(begin (buffer-kill! "#{f}") (set-frame-local! 'current-group #f) (delete-other-windows!))}
      )
  end

  test "a group's layout survives leave and restore" do
    n = System.unique_integer([:positive])
    m = "ly-a-#{n}"
    Compos.Core.create_buffer(m)

    {:ok, out} =
      Compos.Core.Session.eval("""
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
    {:ok, _} = Compos.Core.Session.eval("(delete-other-windows!)")
  end

  test "a completion prompt keeps the bottom bar; only the switcher floats" do
    # the switcher asks for the centered palette by name
    open_switch_prompt()
    assert Editor.render_state().minibuffer.style == "palette"
    press(["C-g"])
    # M-x completes over commands and still keeps the bottom bar, like Emacs
    press(["M-x"])
    assert Editor.render_state().minibuffer.style in [nil, false]
    press(["C-g"])
    # eval-expression has no candidates: it keeps the bottom bar too
    press(["M-:"])
    assert Editor.render_state().minibuffer.style in [nil, false]
    press(["C-g"])
  end

  test "find-file opens the file into the current group" do
    n = System.unique_integer([:positive])
    f = Path.join(System.tmp_dir!(), "gf-#{n}.txt")
    File.write!(f, "hello")
    on_exit(fn -> File.rm(f) end)

    id =
      group_id!("""
      (let ((id (group-record-create! "gf-grp-#{n}")))
        (set-frame-local! 'current-group #f)
        (buffer-create "gf-home-#{n}")
        (switch-to-buffer! "gf-home-#{n}")
        (buffer-add-group! "gf-home-#{n}" id)
        (visit-in-group "#{f}" (buffer-group (current-buffer)))
        id)
      """)

    assert Compos.Core.Session.eval(~s{(buffer-group "#{f}")}) == {:ok, ~s{"#{id}"}}
  end

  test "group metadata lives on the group chat and survives identity" do
    n = System.unique_integer([:positive])
    b = "gm-#{n}"
    Compos.Core.create_buffer(b)

    {:ok, _} =
      Compos.Core.Session.eval("""
      (begin (switch-to-buffer! "#{b}")
             (buffer-set-local! "#{b}" 'group "gm-grp-#{n}")
             (group-meta-set! "gm-grp-#{n}" "the demo group"))
      """)

    assert {:ok, ~s{"the demo group"}} =
             Compos.Core.Session.eval(~s{(group-meta "gm-grp-#{n}")})

    # the standing rule: a chat local belongs to exactly one list
    assert {:ok, out} =
             Compos.Core.Session.eval(~s{(if (member 'group-meta chat-identity-locals) #t #f)})

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
    Compos.Core.create_buffer(loose)

    {:ok, _} =
      Compos.Core.Session.eval("""
      (begin (visit "#{f2}")
             (switch-to-buffer! "#{loose}")
             (visit "#{f1}"))
      """)

    # the project name is a marginalia column: typing it finds the
    # project's buffers and not the loose one
    open_switch_prompt()
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
    test "frame width is reconstructed from measured pane columns" do
      Editor.set_window_cols(%{})
      assert Editor.frame_cols() == 100

      Editor.split(:h, 2 / 3)

      measurements =
        Map.new(Editor.window_rects(), fn [id, _buffer, _x, _y, width, _height] ->
          {id, round(180 * width)}
        end)

      Editor.set_window_cols(measurements)
      assert Editor.frame_cols() == 180
      Editor.delete_other_windows()
      Editor.set_window_cols(%{})
    end

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
      # this test is about the windows, so it takes the plainest switcher:
      # the modal one previews into the window it was opened from, which is
      # a second thing happening to the layout under test
      Compos.Core.create_buffer(other)
      press(["C-x", "3"])
      press(["C-x", "o"])
      open_group_switcher()
      type(other)
      press(["RET"])

      buffers = Editor.render_state().tree |> collect_buffers() |> Enum.sort()
      assert buffers == Enum.sort([buf, other])
      press(["C-x", "1"])
    end

    test "named tilers make exact thirds and one undo restores the prior layout", %{buf: buf} do
      n = System.unique_integer([:positive])
      second = "tile-second-#{n}"
      third = "tile-third-#{n}"
      fourth = "tile-fourth-#{n}"
      for name <- [second, third, fourth], do: Compos.Core.create_buffer(name)

      {:ok, _} =
        Compos.Core.Session.eval("""
        (begin (delete-other-windows!)
               (switch-to-buffer! "#{buf}")
               (split-window! 'h 0.7)
               (other-window!)
               (switch-to-buffer! "#{second}")
               (split-window! 'h 0.8)
               (other-window!)
               (switch-to-buffer! "#{third}")
               (set-frame-local! 'winner-ring #f)
               (set-frame-local! 'winner-pos #f))
        """)

      press(["M-x"])
      type("window-layout-columns")
      press(["RET"])

      columns = Editor.render_state().tree

      assert %{
               type: :split,
               dir: :h,
               ratio: first,
               children: [_, %{type: :split, dir: :h, ratio: second_ratio}]
             } = columns

      assert_in_delta first, 1 / 3, 0.001
      assert_in_delta second_ratio, 1 / 2, 0.001

      press(["M-x"])
      type("window-layout-main-right")
      press(["RET"])

      assert %{
               type: :split,
               dir: :h,
               ratio: main,
               children: [_, %{type: :split, dir: :v, ratio: stack}]
             } = Editor.render_state().tree

      assert_in_delta main, 2 / 3, 0.001
      assert_in_delta stack, 1 / 2, 0.001

      press(["M-x"])
      type("winner-undo")
      press(["RET"])
      assert layout_shape(Editor.render_state().tree) == layout_shape(columns)

      {:ok, _} =
        Compos.Core.Session.eval(
          ~s{(tile-windows! 'grid (list "#{buf}" "#{second}" "#{third}" "#{fourth}"))}
        )

      assert %{
               type: :split,
               dir: :h,
               ratio: grid,
               children: [
                 %{type: :split, dir: :v, ratio: upper},
                 %{type: :split, dir: :v, ratio: lower}
               ]
             } = Editor.render_state().tree

      assert_in_delta grid, 1 / 2, 0.001
      assert_in_delta upper, 1 / 2, 0.001
      assert_in_delta lower, 1 / 2, 0.001

      {:ok, _} = Compos.Core.Session.eval("(delete-other-windows!)")

      for name <- [second, third, fourth],
          do: Compos.Core.Session.eval(~s{(buffer-kill! "#{name}")})
    end

    test "window layout selection previews and restores the layout on cancel", %{buf: buf} do
      second = "layout-preview-second-#{System.unique_integer([:positive])}"
      third = "layout-preview-third-#{System.unique_integer([:positive])}"
      for name <- [second, third], do: Compos.Core.create_buffer(name)

      {:ok, _} =
        Compos.Core.Session.eval("""
        (begin (delete-other-windows!)
               (switch-to-buffer! "#{buf}")
               (split-window! 'h 0.7)
               (other-window!)
               (switch-to-buffer! "#{second}")
               (split-window! 'v 0.6)
               (other-window!)
               (switch-to-buffer! "#{third}"))
        """)

      before = Editor.render_state().tree
      run("window-layout")
      type("columns")

      assert Editor.render_state().tree != before
      press(["C-g"])
      assert layout_shape(Editor.render_state().tree) == layout_shape(before)

      for name <- [second, third],
          do: Compos.Core.Session.eval(~s{(buffer-kill! "#{name}")})
    end

    test "three columns pulls the next buffers from the MRU ring", %{buf: buf} do
      second = "three-columns-second-#{System.unique_integer([:positive])}"
      third = "three-columns-third-#{System.unique_integer([:positive])}"
      for name <- [second, third], do: Compos.Core.create_buffer(name)

      # Creating a buffer does not make it recent: it joins the ring behind
      # everything already selected, *scratch* included. Select each one and
      # come back, so the ring holds what this test says it holds.
      for name <- [second, third, buf],
          do: Compos.Core.Session.eval(~s{(switch-to-buffer! "#{name}")})

      run("window-layout-columns")

      assert Editor.render_state().tree |> collect_buffers() |> Enum.sort() ==
               Enum.sort([buf, second, third])

      for name <- [second, third],
          do: Compos.Core.Session.eval(~s{(buffer-kill! "#{name}")})
    end

    test "adaptive layout command follows the measured frame width", %{buf: buf} do
      n = System.unique_integer([:positive])
      second = "adaptive-second-#{n}"
      third = "adaptive-third-#{n}"
      for name <- [second, third], do: Compos.Core.create_buffer(name)

      {:ok, _} =
        Compos.Core.Session.eval("""
        (begin (delete-other-windows!)
               (switch-to-buffer! "#{buf}")
               (split-window! 'h 0.7)
               (other-window!)
               (switch-to-buffer! "#{second}")
               (split-window! 'h 0.8)
               (other-window!)
               (switch-to-buffer! "#{third}"))
        """)

      measure_frame = fn total ->
        Map.new(Editor.window_rects(), fn [id, _buffer, _x, _y, width, _height] ->
          {id, max(1, round(total * width))}
        end)
        |> Editor.set_window_cols()
      end

      measure_frame.(80)
      press(["M-x"])
      type("window-layout-adaptive")
      press(["RET"])

      assert %{
               type: :split,
               dir: :v,
               ratio: compact_main,
               children: [_, %{type: :split, dir: :h}]
             } = Editor.render_state().tree

      assert_in_delta compact_main, 2 / 3, 0.001

      measure_frame.(240)
      press(["M-x"])
      type("window-layout-adaptive")
      press(["RET"])

      assert %{
               type: :split,
               dir: :h,
               ratio: first,
               children: [_, %{type: :split, dir: :h, ratio: second_ratio}]
             } = Editor.render_state().tree

      assert_in_delta first, 1 / 3, 0.001
      assert_in_delta second_ratio, 1 / 2, 0.001

      Editor.delete_other_windows()
      Editor.set_window_cols(%{})

      for name <- [second, third],
          do: Compos.Core.Session.eval(~s{(buffer-kill! "#{name}")})
    end

    test "adaptive layout preserves every ordinary visible window", %{buf: buf} do
      n = System.unique_integer([:positive])
      second = "adaptive-duplicate-#{n}"
      replaced = "adaptive-replaced-#{n}"
      shell = "*shell* ordinary #{n}"
      for name <- [second, replaced, shell], do: Compos.Core.create_buffer(name)

      {:ok, _} =
        Compos.Core.Session.eval("""
        (begin
          (buffer-set-local! "#{shell}" 'window-class #f)
          (tile-windows! 'grid
            (list "#{buf}" "#{second}" "#{replaced}" "#{shell}"))
          (select-window! (window-showing "#{replaced}"))
          (switch-to-buffer! "#{second}")
          (select-window! (window-showing "#{buf}")))
        """)

      before = Editor.render_state().tree |> collect_buffers() |> Enum.sort()
      assert before == Enum.sort([buf, second, second, shell])

      press(["M-x"])
      type("window-layout")
      press(["RET"])
      type("adaptive")
      press(["RET"])

      after_layout = Editor.render_state().tree |> collect_buffers() |> Enum.sort()
      assert after_layout == before
      assert length(Editor.list_windows()) == 4
      assert {:ok, "#f"} = Compos.Core.Session.eval(~s{(buffer-local "#{shell}" 'window-class)})

      Editor.delete_other_windows()

      for name <- [second, replaced, shell],
          do: Compos.Core.Session.eval(~s{(buffer-kill! "#{name}")})
    end
  end

  defp collect_ids(%{type: :leaf, id: id}), do: [id]
  defp collect_ids(%{type: :split, children: c}), do: Enum.flat_map(c, &collect_ids/1)

  defp collect_buffers(%{type: :leaf, buffer: b}), do: [b]
  defp collect_buffers(%{type: :split, children: c}), do: Enum.flat_map(c, &collect_buffers/1)

  defp layout_shape(%{type: :leaf, buffer: buffer}), do: {:leaf, buffer}

  defp layout_shape(%{type: :split, dir: dir, ratio: ratio, children: children}) do
    {:split, dir, ratio, Enum.map(children, &layout_shape/1)}
  end
end

defmodule Compos.MinibufferEditingTest do
  @moduledoc "The minibuffer is a buffer: real editing commands work in prompts."

  use ExUnit.Case

  alias Compos.Core.{Buffer, Editor, KeyDispatch}

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

  # A writable preview takes edits, so motion keys move through its source.
  test "motion keys move point in a markdown preview" do
    path = Path.join(System.tmp_dir!(), "compos-prevmove-#{System.unique_integer([:positive])}.md")
    File.write!(path, "# Title\n\nbody\n")

    press(["C-x", "C-f"])
    type(path)
    press(["RET"])
    # a visited Morg file opens in writing-mode with the preview on
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

  test "motion keys move through a writable html preview" do
    path =
      Path.join(System.tmp_dir!(), "compos-prevhtml-#{System.unique_integer([:positive])}.html")

    File.write!(path, "<h1>hi</h1>\n<p>body</p>\n")

    press(["C-x", "C-f"])
    type(path)
    press(["RET"])
    press(["C-c", "C-v"])
    assert Buffer.get_local(path, "render-mode") == "html"

    Buffer.goto(path, 0)
    press(["C-n"])
    assert Buffer.point(path) > 0

    press(["C-x", "1"])
    File.rm!(path)
  end
end
