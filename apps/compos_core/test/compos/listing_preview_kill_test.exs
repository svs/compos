defmodule Compos.ListingPreviewKillTest do
  use ExUnit.Case, async: false
  alias Compos.Core.{Editor, KeyDispatch, Session}
  defp eval!(code, frame) do
    assert {:ok, value} = Session.eval(code, frame)
    value
  end
  test "k kills the selected original, refreshes the listing and removes its preview" do
    previous = Editor.last_active_frame()
    {:ok, frame} = Editor.attach_frame(nil)
    try do
      eval!("""
      (test-buffer! "*zz-preview-kill-home*" "home")
      (test-buffer! "*zz-preview-kill-target*" "target")
      (test-buffer! "*zz-preview-kill-target-next*" "next")
      (switch-to-buffer-here! "*zz-preview-kill-home*")
      (run-command "ibuffer")
      (define *pk-list* (current-buffer))
      (buffer-set-locals! *pk-list* '(ibuffer-grouping none ibuffer-sort name))
      (list-set-query! *pk-list* "zz-preview-kill-target" #t)
      (ibuffer-goto-first-row! *pk-list*)
      (listing-preview! *pk-list* "*zz-preview-kill-target*")
      (define *pk-copy* (float-buffer))
      """, frame)
      KeyDispatch.handle_key(frame, "k")
      assert eval!("(buffer-known? \"*zz-preview-kill-target*\")", frame) == "#f"
      assert eval!("(member \"*zz-preview-kill-target*\" (list-entries *pk-list*))", frame) == "#f"
      assert eval!("(equal? (current-buffer) *pk-list*)", frame) == "#t"
      assert eval!("(buffer-known? *pk-copy*)", frame) == "#f"
      for _ <- 1..100, eval!("(float-open?)", frame) == "#f", do: Process.sleep(10)
      assert eval!("(list-current *pk-list*)", frame) == "\"*zz-preview-kill-target-next*\""
      assert eval!("(buffer-local (float-buffer) 'listing-preview-source)", frame) ==
               "\"*zz-preview-kill-target-next*\""
    after
      eval!("""
      (when (boundp '*pk-list*) (listing-preview-dismiss! *pk-list*))
      (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
        '("*zz-preview-kill-home*" "*zz-preview-kill-target*" "*zz-preview-kill-target-next*"))
      (when (boundp '*pk-list*) (buffer-kill! *pk-list*))
      """, frame)
      Editor.delete_frame(frame)
      Editor.select_frame(previous)
    end
  end
end
