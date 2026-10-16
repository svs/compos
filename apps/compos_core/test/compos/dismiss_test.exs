defmodule Compos.DismissTest do
  use ExUnit.Case, async: false
  alias Compos.Core.{Editor, KeyDispatch, Session}

  defp eval!(code, frame) do
    assert {:ok, result} = Session.eval(code, frame)
    result
  end

  setup do
    previous = Editor.last_active_frame()
    {:ok, frame} = Editor.attach_frame(nil)

    eval!(
      """
      (customize-set! 'autolayout-mode #f) (layout-target-set! #f)
      (set-frame-local! 'current-group #f)
      (for-each (lambda (b)
                  (buffer-create b) (buffer-append! b "read me\n")
                  (buffer-set-read-only! b #t))
                '("zz-dismiss-parent" "zz-dismiss-child" "zz-dismiss-grandchild" "zz-dismiss-hidden" "zz-dismiss-under"))
      (switch-to-buffer-here! "zz-dismiss-parent")
      (set-window-prev-buffers! (active-window) '())
      (define-command "zz-dismiss-parent-back"
        (lambda () (buffer-set-local! "zz-dismiss-parent" 'back-called #t)))
      (local-set-key "q" "zz-dismiss-parent-back")
      """,
      frame
    )

    on_exit(fn ->
      Session.eval(
        """
        (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
          '("zz-dismiss-grandchild" "zz-dismiss-child" "zz-dismiss-hidden" "zz-dismiss-parent" "zz-dismiss-under"))
        """,
        frame
      )

      Editor.delete_frame(frame)
      Editor.select_frame(previous)
    end)

    %{frame: frame}
  end

  for command <- ["dismiss-buffer", "quit-window", "dired-quit"] do
    @command command
    test "#{command} skips foreign predecessors", %{frame: f} do
      eval!("""
      (define zz-dismiss-group (group-ensure-record! "zz-dismiss-home"))
      (define zz-dismiss-away (group-ensure-record! "zz-dismiss-away"))
      (buffer-add-group! "zz-dismiss-parent" zz-dismiss-group)
      (buffer-add-group! "zz-dismiss-child" zz-dismiss-group)
      (buffer-add-group! "zz-dismiss-under" zz-dismiss-away)
      (switch-to-buffer-here! "zz-dismiss-child")
      (buffer-child! "zz-dismiss-parent" "zz-dismiss-child")
      (set-frame-local! 'current-group zz-dismiss-group)
      (set-window-prev-buffers! (active-window)
        '("zz-dismiss-under" "zz-dismiss-parent"))
      (local-set-key "<f9>" "#{@command}")
      """, f)
      KeyDispatch.handle_key(f, "<f9>")
      assert eval!("(current-buffer)", f) == ~s("zz-dismiss-parent")
      assert eval!("(window-prev-buffers (active-window))", f) == "()"
      assert eval!(~s{(buffer-known? "zz-dismiss-under")}, f) == "#t"
    end

    test "#{command} preserves the last window with only foreign history", %{frame: f} do
      eval!("""
      (define zz-dismiss-group (group-ensure-record! "zz-dismiss-home"))
      (define zz-dismiss-away (group-ensure-record! "zz-dismiss-away"))
      (buffer-add-group! "zz-dismiss-parent" zz-dismiss-group)
      (buffer-add-group! "zz-dismiss-child" zz-dismiss-group)
      (buffer-add-group! "zz-dismiss-under" zz-dismiss-away)
      (switch-to-buffer-here! "zz-dismiss-child")
      (buffer-child! "zz-dismiss-parent" "zz-dismiss-child")
      (set-frame-local! 'current-group zz-dismiss-group)
      (set-window-prev-buffers! (active-window) '("zz-dismiss-under"))
      (local-set-key "<f9>" "#{@command}")
      """, f)
      KeyDispatch.handle_key(f, "<f9>")
      assert eval!("(current-buffer)", f) == ~s("zz-dismiss-child")
      assert eval!(~s{(buffer-known? "zz-dismiss-child")}, f) == "#t"
    end
  end

  test "ungrouped application history cannot enter a group", %{frame: f} do
    eval!("""
    (define zz-dismiss-group (group-ensure-record! "zz-dismiss-home"))
    (buffer-add-group! "zz-dismiss-parent" zz-dismiss-group)
    (buffer-add-group! "zz-dismiss-child" zz-dismiss-group)
    (let ((g (buffer-group "zz-dismiss-under")))
      (when g (buffer-remove-group! "zz-dismiss-under" g)))
    (buffer-set-local! "zz-dismiss-under" 'special #t)
    (switch-to-buffer-here! "zz-dismiss-child")
    (buffer-child! "zz-dismiss-parent" "zz-dismiss-child")
    (set-frame-local! 'current-group zz-dismiss-group)
    (set-window-prev-buffers! (active-window)
      '("zz-dismiss-under" "zz-dismiss-parent"))
    (local-set-key "<f9>" "dismiss-buffer")
    """, f)
    KeyDispatch.handle_key(f, "<f9>")
    assert eval!("(current-buffer)", f) == ~s("zz-dismiss-parent")
  end

  test "first entry into a group does not inherit the departing pane history", %{frame: f} do
    eval!("""
    (define zz-dismiss-group (group-ensure-record! "zz-dismiss-first-entry"))
    (define zz-dismiss-away (group-ensure-record! "zz-dismiss-first-away"))
    (buffer-add-group! "zz-dismiss-parent" zz-dismiss-group)
    (buffer-add-group! "zz-dismiss-under" zz-dismiss-away)
    (switch-to-buffer-here! "zz-dismiss-under")
    (set-frame-local! 'current-group zz-dismiss-away)
    (switch-to-group! zz-dismiss-group)
    """, f)
    assert eval!("(window-prev-buffers (active-window))", f) == "()"
    assert eval!("(current-buffer)", f) == ~s("zz-dismiss-parent")
  end

  test "an exhausted child pane closes without borrowing its parent", %{frame: f} do
    eval!("""
    (split-window! 'h 0.5) (other-window!)
    (switch-to-buffer-here! "zz-dismiss-child")
    (buffer-child! "zz-dismiss-parent" "zz-dismiss-child")
    (set-window-prev-buffers! (active-window) '())
    (local-set-key "<f9>" "dismiss-buffer")
    """, f)
    KeyDispatch.handle_key(f, "<f9>")
    assert eval!("(map cadr (window-list))", f) == ~s{("zz-dismiss-parent")}
    assert eval!(~s{(buffer-known? "zz-dismiss-child")}, f) == "#f"
  end

  test "restoring a group removes foreign history and return records", %{frame: f} do
    eval!("""
    (define zz-dismiss-group (group-ensure-record! "zz-dismiss-home"))
    (define zz-dismiss-away (group-ensure-record! "zz-dismiss-away"))
    (buffer-add-group! "zz-dismiss-parent" zz-dismiss-group)
    (buffer-add-group! "zz-dismiss-child" zz-dismiss-group)
    (buffer-add-group! "zz-dismiss-under" zz-dismiss-away)
    (switch-to-buffer-here! "zz-dismiss-child")
    (set-frame-local! 'current-group zz-dismiss-group)
    (set-window-prev-buffers! (active-window)
      '("zz-dismiss-under" "zz-dismiss-parent"))
    (set-window-restore! (active-window) '(other "zz-dismiss-under" #f))
    (group-layout-save! zz-dismiss-group)
    (switch-to-group! zz-dismiss-away)
    (switch-to-group! zz-dismiss-group)
    """, f)
    assert eval!("(window-prev-buffers (active-window))", f) == ~s{("zz-dismiss-parent")}
    assert eval!("(window-restore (active-window))", f) == "#f"
  end

  test "a mode declares dismissal without naming its quit command", %{frame: f} do
    eval!(
      """
      (define-mode "zz-dismiss-view-mode" (lambda () #t))
      (mode-dismissible! "zz-dismiss-view-mode")
      (mode-keys! "zz-dismiss-view-mode" '(("q" "zz-dismiss-parent-back")))
      (set-mode! "zz-dismiss-view-mode")
      (dismiss-sync-visible!)
      """, f)
    assert eval!(~s{(buffer-dismissible? "zz-dismiss-parent")}, f) == "#t"
    assert eval!(~s{(minor-mode-on? "zz-dismiss-parent" "dismiss-mode")}, f) == "#t"
    KeyDispatch.handle_key(f, "q")
    assert eval!(~s{(buffer-local "zz-dismiss-parent" 'back-called)}, f) == "#t"
    eval!(~s{(set-mode! "fundamental-mode") (local-set-key "q" "zz-dismiss-parent-back") (dismiss-sync-visible!)}, f)
    assert eval!(~s{(buffer-dismissible? "zz-dismiss-parent")}, f) == "#f"
  end

  test "dismissal unwinds nested children before the parent's command", %{frame: f} do
    eval!(
      """
      (switch-to-buffer! "zz-dismiss-child")
      (buffer-child! "zz-dismiss-parent" "zz-dismiss-child")
      (switch-to-buffer! "zz-dismiss-grandchild")
      (buffer-child! "zz-dismiss-child" "zz-dismiss-grandchild")
      """,
      f
    )

    KeyDispatch.handle_key(f, "q")
    assert eval!("(current-buffer)", f) == ~s("zz-dismiss-child")
    assert eval!("(buffer-known? \"zz-dismiss-grandchild\")", f) == "#f"
    KeyDispatch.handle_key(f, "q")
    assert eval!("(current-buffer)", f) == ~s("zz-dismiss-parent")
    assert eval!("(buffer-known? \"zz-dismiss-child\")", f) == "#f"
    assert eval!("(buffer-local \"zz-dismiss-parent\" 'back-called)", f) == "#f"
    KeyDispatch.handle_key(f, "q")
    assert eval!("(buffer-local \"zz-dismiss-parent\" 'back-called)", f) == "#t"
  end

  test "parent dismisses a visible child before a newer hidden child", %{frame: f} do
    eval!(
      """
      (split-window! 'h 0.5) (other-window!)
      (switch-to-buffer-here! "zz-dismiss-under")
      (switch-to-buffer! "zz-dismiss-child")
      (buffer-child! "zz-dismiss-parent" "zz-dismiss-child")
      (buffer-child! "zz-dismiss-parent" "zz-dismiss-hidden")
      (select-window! (window-showing "zz-dismiss-parent"))
      """,
      f
    )

    KeyDispatch.handle_key(f, "q")
    assert eval!("(map cadr (window-list))", f) == ~s{("zz-dismiss-parent" "zz-dismiss-under")}
    assert eval!("(current-buffer)", f) == ~s("zz-dismiss-parent")
    assert eval!("(buffer-known? \"zz-dismiss-hidden\")", f) == "#t"
    KeyDispatch.handle_key(f, "q")
    assert eval!("(buffer-known? \"zz-dismiss-hidden\")", f) == "#f"
    assert eval!("(buffer-local \"zz-dismiss-parent\" 'back-called)", f) == "#f"
    KeyDispatch.handle_key(f, "q")
    assert eval!("(buffer-local \"zz-dismiss-parent\" 'back-called)", f) == "#t"
  end

  test "dismissal restores a transient predecessor already visible elsewhere", %{frame: f} do
    eval!(
      """
      (buffer-set-local! "zz-dismiss-parent" 'special #t)
      (split-window! 'h 0.5) (other-window!)
      (switch-to-buffer! "zz-dismiss-child")
      (buffer-child! "zz-dismiss-parent" "zz-dismiss-child")
      """,
      f
    )

    KeyDispatch.handle_key(f, "q")
    assert eval!("(map cadr (window-list))", f) == ~s{("zz-dismiss-parent" "zz-dismiss-parent")}
  end

  test "the table a prompt stands in front of is not a reading surface", %{frame: f} do
    # C-x b is the minibuffer's own form: a prompt line with the buffer
    # table behind it. The table is read-only and its mode gives it q,
    # which is what a reading surface is made of — but it is part of the
    # prompt, and the prompt closes with C-g. A Reading bar there offers a
    # q that means nothing.
    eval!(~s{(run-command "ibuffer-prompt")}, f)

    assert eval!(~s{(and (minibuffer-state) #t)}, f) == "#t"
    assert eval!(~s{(buffer-dismissible? " *buffers*")}, f) == "#f"
    assert eval!(~s{(buffer-local " *buffers*" 'dismissible)}, f) == "#f"
    assert eval!(~s{(minor-mode-on? " *buffers*" "dismiss-mode")}, f) == "#f"

    eval!(~s{(minibuffer-cancel!)}, f)
  end

  test "writable buffers keep typing q even when they own a child", %{frame: f} do
    eval!(
      """
      (local-set-key "q" "self-insert-command")
      (buffer-set-read-only! "zz-dismiss-parent" #f)
      (buffer-child! "zz-dismiss-parent" "zz-dismiss-child")
      (goto-char! 0)
      """,
      f
    )

    KeyDispatch.handle_key(f, "q")
    assert eval!("(buffer-text \"zz-dismiss-parent\")", f) == ~s("qread me\\n")
    assert eval!("(buffer-known? \"zz-dismiss-child\")", f) == "#t"
  end

  test "cursor policy survives mode restoration and caret browsing toggles", %{frame: f} do
    eval!(
      """
      (switch-to-buffer! "zz-dismiss-child")
      (buffer-child! "zz-dismiss-parent" "zz-dismiss-child")
      """,
      f
    )

    assert Editor.render_state(f).tree.dismissible
    refute Editor.render_state(f).tree.cursor_visible
    eval!("(run-command \"caret-browsing-mode\")", f)
    assert Editor.render_state(f).tree.cursor_visible
    eval!("(restore-buffer-runtime! \"zz-dismiss-child\")", f)
    assert eval!("(buffer-parent \"zz-dismiss-child\")", f) == ~s("zz-dismiss-parent")
    assert Editor.render_state(f).tree.cursor_visible
    eval!("(run-command \"caret-browsing-mode\")", f)
    refute Editor.render_state(f).tree.cursor_visible
  end

  test "a dismissible mode that navigates by point keeps its cursor", %{frame: f} do
    eval!(
      """
      (define-mode "zz-point-mode" (lambda () (buffer-set-read-only! (current-buffer) #t)))
      (dismiss-keep-caret! "zz-point-mode")
      (switch-to-buffer! "zz-dismiss-child")
      (buffer-child! "zz-dismiss-parent" "zz-dismiss-child")
      (with-current-buffer "zz-dismiss-child" (lambda () (set-mode! "zz-point-mode")))
      """,
      f
    )

    assert Editor.render_state(f).tree.dismissible
    assert Editor.render_state(f).tree.cursor_visible

    # the default is applied once, so the reader's toggle still answers
    eval!("(run-command \"caret-browsing-mode\")", f)
    eval!("(dismiss-sync-visible!)", f)
    refute Editor.render_state(f).tree.cursor_visible
  end

  test "browse-mode is one of the modes that keep their cursor", %{frame: f} do
    assert eval!(~s{(if (member "browse-mode" *dismiss-caret-modes*) #t #f)}, f) == "#t"
  end

  test "killing a child and reusing its name does not adopt the new buffer", %{frame: f} do
    eval!(
      """
      (buffer-child! "zz-dismiss-parent" "zz-dismiss-child")
      (buffer-kill! "zz-dismiss-child") (buffer-create "zz-dismiss-child")
      """,
      f
    )

    assert eval!("(buffer-children \"zz-dismiss-parent\")", f) == "()"
    assert eval!("(buffer-parent \"zz-dismiss-child\")", f) == "#f"
  end

  test "ownership rejects cycles", %{frame: f} do
    eval!("(buffer-child! \"zz-dismiss-parent\" \"zz-dismiss-child\")", f)

    assert {:error, _} =
             Session.eval("(buffer-child! \"zz-dismiss-child\" \"zz-dismiss-parent\")", f)

    assert eval!("(buffer-parent \"zz-dismiss-child\")", f) == ~s("zz-dismiss-parent")
  end

  test "visible-first dismissal leaves hidden grandchildren reachable", %{frame: f} do
    eval!("""
    (split-window! 'h 0.5) (other-window!)
    (switch-to-buffer! "zz-dismiss-child")
    (buffer-child! "zz-dismiss-parent" "zz-dismiss-child")
    (buffer-child! "zz-dismiss-child" "zz-dismiss-grandchild")
    (select-window! (window-showing "zz-dismiss-parent"))
    """, f)
    KeyDispatch.handle_key(f, "q")
    assert eval!("(buffer-known? \"zz-dismiss-child\")", f) == "#f"
    assert eval!("(buffer-parent \"zz-dismiss-grandchild\")", f) == ~s("zz-dismiss-parent")
    KeyDispatch.handle_key(f, "q")
    assert eval!("(buffer-known? \"zz-dismiss-grandchild\")", f) == "#f"
    assert eval!("(buffer-local \"zz-dismiss-parent\" 'back-called)", f) == "#f"
  end

  test "a child visible only in another frame does not consume the parent's q", %{frame: f} do
    eval!("(buffer-child! \"zz-dismiss-parent\" \"zz-dismiss-child\")", f)
    {:ok, other} = Editor.attach_frame(nil)
    on_exit(fn -> Editor.delete_frame(other) end)
    eval!("(switch-to-buffer-here! \"zz-dismiss-child\")", other)
    KeyDispatch.handle_key(f, "q")
    assert eval!("(buffer-local \"zz-dismiss-parent\" 'back-called)", f) == "#t"
    assert eval!("(current-buffer)", other) == ~s("zz-dismiss-child")
    assert eval!("(buffer-known? \"zz-dismiss-child\")", f) == "#t"
  end

  test "rename preserves reciprocal ownership and mode runtime restoration", %{frame: f} do
    on_exit(fn ->
      Session.eval("""
      (when (buffer-known? "zz-dismiss-renamed") (buffer-kill! "zz-dismiss-renamed"))
      """, f)
    end)
    eval!("""
    (buffer-child! "zz-dismiss-parent" "zz-dismiss-child")
    (rename-buffer! "zz-dismiss-parent" "zz-dismiss-renamed")
    (restore-buffer-runtime! "zz-dismiss-child")
    """, f)
    assert eval!("(buffer-parent \"zz-dismiss-child\")", f) == ~s("zz-dismiss-renamed")
    assert eval!("(buffer-children \"zz-dismiss-renamed\")", f) == ~s{("zz-dismiss-child")}
  end
end
