defmodule Compos.ChatListReturnTest do
  use ExUnit.Case, async: false
  alias Compos.Core.{Editor, KeyDispatch, Session}

  for {grouped, duplicate} <- [{false, false}, {true, false}, {true, true}] do
    @grouped grouped
    @duplicate duplicate
    test "chat-list-quit restores the invoking frame (grouped=#{grouped}, duplicate=#{duplicate})" do
      previous = Editor.last_active_frame()
      {:ok, frame} = Editor.attach_frame(nil)

      try do
        assert {:ok, _} =
                 Session.eval(
                   """
                   (define *return-test-group* #{if @grouped, do: "(group-record-create! \"zz-return-origin\")", else: "#f"})
                   (define *return-test-buffers* '("*zz-return-a*" "*zz-return-b*" "*zz-return-past-a*" "*zz-return-past-b*"))
                   (for-each (lambda (b)
                     (test-buffer! b "one\\ntwo\\nthree\\nfour\\n")
                     (buffer-move-to-group! b *return-test-group*)) *return-test-buffers*)
                   (set! *group-current-inhibit* #t)
                   (set-frame-local! 'current-group *return-test-group*)
                   (set-frame-local! 'pinned-group *return-test-group*)
                   (begin
                     (tile-windows! 'two-pane '("*zz-return-a*" "#{if @duplicate, do: "*zz-return-a*", else: "*zz-return-b*"}"))
                     (let ((ws (map car (window-list))))
                       (set-window-prev-buffers! (car ws) '("*zz-return-past-a*"))
                       (set-window-prev-buffers! (cadr ws) '("*zz-return-past-b*"))
                       (set-window-restore! (car ws) '(other "*zz-return-past-a*" #f))
                       (window-mode-preference! (cadr ws) "text-mode")
                       (window-set-point! (car ws) 2)
                       (window-set-point! (cadr ws) 6)
                       (select-window! (cadr ws))))
                   (layout-target-set! 'two-pane)
                   (set! *group-current-inhibit* #f)
                   (define *return-test-tree* (window-tree))
                   (define *return-test-points* (map (lambda (r) (window-point (car r))) (window-list)))
                   (global-set-key "<f9>" "chat-list")
                   """,
                   frame
                 )

        KeyDispatch.handle_key(frame, "<f9>")
        assert {:ok, "#f"} = Session.eval("(frame-local 'chat-list-return)", frame)
        # Re-entry must keep the invoking window's original predecessor.
        assert {:ok, _} =
                 Session.eval(
                   """
                   (run-command "chat-list")
                   (local-set-key "<f10>" "ibuffer-quit")
                   """,
                   frame
                 )

        KeyDispatch.handle_key(frame, "<f10>")
        assert {:ok, expected_tree} = Session.eval("*return-test-tree*", frame)
        assert {:ok, ^expected_tree} = Session.eval("(window-tree)", frame)

        assert {:ok, "#t"} =
                 Session.eval(
                   "(equal? (map (lambda (r) (window-point (car r))) (window-list)) *return-test-points*)",
                   frame
                 )

        assert {:ok, "#t"} = Session.eval("(equal? (frame-group) *return-test-group*)", frame)
        assert {:ok, "#t"} = Session.eval("(equal? (group-pinned) *return-test-group*)", frame)
        assert {:ok, "two-pane"} = Session.eval("(layout-target)", frame)

        assert {:ok, "#t"} =
                 Session.eval("(equal? (active-window) (car (cadr (window-list))))", frame)

        assert {:ok, "\"text-mode\""} = Session.eval("(window-mode-preference (active-window))", frame)

        assert {:ok, "other"} =
                 Session.eval("(car (window-restore (car (car (window-list)))))", frame)

        assert {:ok, _} = Session.eval("(run-command \"ibuffer-quit\")", frame)
        assert {:ok, expected_tree} = Session.eval("*return-test-tree*", frame)
        assert {:ok, ^expected_tree} = Session.eval("(window-tree)", frame)
      after
        Session.eval(
          """
          (set-frame-local! 'chat-list-return #f)
          (for-each buffer-kill! *return-test-buffers*)
          (when *return-test-group* (group-record-delete! *return-test-group*))
          (global-unset-key "<f9>")
          """,
          frame
        )

        Editor.delete_frame(frame)
        Editor.select_frame(previous)
      end
    end
  end

  test "chat-list returns through each invoking frame's own history" do
    previous = Editor.last_active_frame()
    {:ok, first} = Editor.attach_frame(nil)
    {:ok, second} = Editor.attach_frame(nil)
    frames = [first, second]

    try do
      expected =
        for {frame, n} <- Enum.with_index(frames) do
          assert {:ok, _} =
                   Session.eval(
                     """
                     (buffer-create "*zz-return-frame-#{n}*")
                     (switch-to-buffer-here! "*zz-return-frame-#{n}*")
                     (set-frame-local! 'pinned-group #f)
                     (set-frame-local! 'current-group #f)
                     (global-set-key "<f9>" "chat-list")
                     """,
                     frame
                   )

          {:ok, tree} = Session.eval("(window-tree)", frame)
          KeyDispatch.handle_key(frame, "<f9>")
          {frame, tree}
        end

      for {frame, tree} <- expected do
        assert {:ok, _} = Session.eval("(local-set-key \"<f10>\" \"ibuffer-quit\")", frame)
        KeyDispatch.handle_key(frame, "<f10>")
        assert {:ok, ^tree} = Session.eval("(window-tree)", frame)
      end
    after
      for {frame, n} <- Enum.with_index(frames) do
        Session.eval("(buffer-kill! \"*zz-return-frame-#{n}*\")", frame)
        Editor.delete_frame(frame)
      end

      Editor.select_frame(previous)
    end
  end
end
