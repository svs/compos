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
      assert Editor.snapshot().minibuffer.prompt =~ "Delete 1 file(s)"
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

    test "dired lines carry perms/size/date columns", %{root: root} do
      {:ok, _} = Aimax.Core.Session.eval(~s{(dired-open "#{root}")})
      text = Buffer.text(root)
      assert text =~ ~r/^  -rw.*\d+ +[A-Z][a-z]{2} +\d+ \d{2}:\d{2} alpha\.txt$/m
      assert text =~ ~r/^  drwx.*subdir\/$/m
    end

    test "find-file prefills default-directory; // resets (Emacs rule)", %{root: root} do
      {:ok, _} = Aimax.Core.Session.eval(~s{(dired-open "#{root}")})
      press(["C-x", "C-f"])
      mb = Editor.snapshot().minibuffer
      assert mb.input == root <> "/"

      # typing an absolute path over the prefill: // rule takes over
      type(Path.join(root, "beta.txt"))
      press(["RET"])
      assert Editor.current_buffer() == Path.join(root, "beta.txt")
      assert Buffer.text(Editor.current_buffer()) == "B"
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
    assert %{prompt: "M-x ", candidates: candidates} = Editor.snapshot().minibuffer
    assert Enum.any?(candidates, &(&1.label == "other-window"))
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
    mb = Editor.snapshot().minibuffer
    assert mb.input == root <> "/re"
    assert mb.candidates |> Enum.map(& &1.label) |> Enum.sort() == ["readme.txt", "recipe.md"]

    type("a")
    press(["TAB"])
    assert Editor.snapshot().minibuffer.input == root <> "/readme.txt"

    press(["C-g"])

    # unique directory match: one TAB descends AND lists the contents
    press(["C-x", "C-f"])
    type(root <> "/su")
    press(["TAB"])
    mb = Editor.snapshot().minibuffer
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
    mb = Editor.snapshot().minibuffer
    assert Enum.map(mb.candidates, & &1.label) == ["alpha.txt", "subdir/"]

    # arrow onto subdir/, TAB inserts it and lists inside
    press(["C-n", "TAB"])
    mb = Editor.snapshot().minibuffer
    assert mb.input == root <> "/subdir/"
    assert Enum.map(mb.candidates, & &1.label) == ["inner.txt"]

    # arrow onto inner.txt (sel already 0; touch it), RET visits it directly
    press(["C-n", "RET"])
    assert Editor.current_buffer() == Path.join([root, "subdir", "inner.txt"])
    assert Buffer.text(Editor.current_buffer()) == "Z"

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
    assert Editor.snapshot().minibuffer.input == "split-window-below"
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
    refute Buffer.exists?(path)

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
    assert Editor.snapshot().minibuffer.prompt == "Find file: "
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
