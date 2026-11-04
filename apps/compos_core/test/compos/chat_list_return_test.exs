defmodule Compos.ChatListReturnTest do
  use ExUnit.Case, async: false
  alias Compos.Core.{Editor, Session}

  # The panes model holds a buffer in one window only, so the frame a
  # chat-list leaves has two different buffers side by side.
  for grouped <- [false, true] do
    @grouped grouped
    test "chat-list-quit restores the invoking frame (grouped=#{grouped})" do
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
                     (panes-tile! 'two-pane '("*zz-return-a*" "*zz-return-b*"))
                     (let ((ws (map car (window-list))))
                       (set-window-prev-buffers! (car ws) '("*zz-return-past-a*"))
                       (set-window-prev-buffers! (cadr ws) '("*zz-return-past-b*"))
                       (set-window-restore! (car ws) '(other "*zz-return-past-a*" #f))
                       (window-mode-preference! (cadr ws) "text-mode")
                       (window-set-point! (car ws) 2)
                       (window-set-point! (cadr ws) 6)
                       (select-window! (cadr ws))))
                   (panes-choose-layout! 'two-pane)
                   (set! *group-current-inhibit* #f)
                   (define *return-test-tree* (list (window-list) (active-window)))
                   (define *return-test-points* (map (lambda (r) (window-point (car r))) (window-list)))
                   """,
                   frame
                 )

        assert {:ok, _} = Session.eval(~s{(run-command "chat-list")}, frame)
        # Re-entry must keep the invoking window's original predecessor.
        assert {:ok, _} = Session.eval(~s{(run-command "chat-list")}, frame)
        assert {:ok, _} = Session.eval(~s{(run-command "ibuffer-quit")}, frame)
        assert {:ok, expected_tree} = Session.eval("*return-test-tree*", frame)
        assert {:ok, ^expected_tree} = Session.eval("(list (window-list) (active-window))", frame)

        assert {:ok, "#t"} =
                 Session.eval(
                   "(equal? (map (lambda (r) (window-point (car r))) (window-list)) *return-test-points*)",
                   frame
                 )

        assert {:ok, "#t"} = Session.eval("(equal? (frame-group) *return-test-group*)", frame)
        assert {:ok, "#t"} = Session.eval("(equal? (group-pinned) *return-test-group*)", frame)
        assert {:ok, "two-pane"} = Session.eval("(panes-current-layout)", frame)

        assert {:ok, "#t"} =
                 Session.eval("(equal? (active-window) (car (cadr (window-list))))", frame)

        assert {:ok, "\"text-mode\""} = Session.eval("(window-mode-preference (active-window))", frame)

        assert {:ok, "other"} =
                 Session.eval("(car (window-restore (car (car (window-list)))))", frame)

        assert {:ok, _} = Session.eval("(run-command \"ibuffer-quit\")", frame)
        assert {:ok, expected_tree} = Session.eval("*return-test-tree*", frame)
        assert {:ok, ^expected_tree} = Session.eval("(list (window-list) (active-window))", frame)
      after
        Session.eval(
          """
          (for-each buffer-kill! *return-test-buffers*)
          (when *return-test-group* (group-record-delete! *return-test-group*))
          """,
          frame
        )

        Editor.delete_frame(frame)
        Editor.select_frame(previous)
      end
    end
  end
end
