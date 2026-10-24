defmodule Compos.ChosenPaneTest do
  use ExUnit.Case, async: false
  alias Compos.Core.{Editor, KeyDispatch, Session}
  defp eval!(code, frame) do
    assert {:ok, value} = Session.eval(code, frame)
    value
  end
  for action <- ["RET", "s-RET", "C-x o", "C-x b"] do
    @action action
    test "listing #{@action} places the real buffer and dismisses its copy" do
      previous = Editor.last_active_frame()
      {:ok, frame} = Editor.attach_frame(nil)
      try do
        eval!("""
        (test-buffer! "*zz-chosen-left*" "left")
        (test-buffer! "*zz-chosen-detail*" "detail")
        (with-current-buffer "*zz-chosen-detail*" (lambda () (set-mode! "amazon-detail-mode")))
        (panes-tile! 'two-pane '("*zz-chosen-left*" "*zz-chosen-detail*"))
        (define *chosen-first* (car (car (window-list))))
        (define *chosen-detail* (window-showing "*zz-chosen-detail*"))
        (select-window! *chosen-first*)
        (run-command "ibuffer")
        (define *chosen-list* (current-buffer))
        (buffer-set-locals! *chosen-list* '(ibuffer-grouping none ibuffer-sort name))
        (list-set-query! *chosen-list* "zz-chosen-detail" #t)
        (ibuffer-goto-first-row! *chosen-list*)
        (listing-preview! *chosen-list* "*zz-chosen-detail*")
        """, frame)
        for key <- String.split(@action), do: KeyDispatch.handle_key(frame, key)
        if @action == "C-x b" do
          eval!("(minibuffer-change! \"zz-chosen-detail\")", frame)
          Process.sleep(400)
          KeyDispatch.handle_key(frame, "RET")
        end
        assert eval!("(current-buffer)", frame) == "\"*zz-chosen-detail*\""
        assert eval!("(float-open?)", frame) == "#f"
        assert eval!("(equal? (active-window) *chosen-detail*)", frame) == "#t"
        if @action in ["RET", "C-x b"] do
          assert eval!("(equal? (car (car (window-list))) *chosen-detail*)", frame) == "#t"
          KeyDispatch.handle_key(frame, "q")
          assert eval!("(equal? (current-buffer) *chosen-list*)", frame) == "#t"
        else
          assert eval!("(equal? (car (car (window-list))) *chosen-first*)", frame) == "#t"
        end
      after
        eval!("""
        (when (boundp '*chosen-list*) (listing-preview-dismiss! *chosen-list*))
        (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
          (list "*zz-chosen-left*" "*zz-chosen-detail*" *chosen-list*))
        """, frame)
        Editor.delete_frame(frame)
        Editor.select_frame(previous)
      end
    end
  end

end
