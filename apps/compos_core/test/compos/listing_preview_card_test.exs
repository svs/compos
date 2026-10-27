defmodule Compos.ListingPreviewCardTest do
  use ExUnit.Case, async: false
  alias Compos.Core.{Editor, KeyDispatch, Session}
  defp eval!(code, frame) do
    assert {:ok, result} = Session.eval(code, frame)
    result
  end
  test "sleeping generated views preview their saved text without running mode setup" do
    previous = Editor.last_active_frame()
    {:ok, frame} = Editor.attach_frame(nil)
    try do
      eval!(~S"""
      (test-buffer! "*zz-saved-preview-owner*" "owner")
      (test-buffer! "*zz-saved-preview-target*" "Saved generated detail")
      (define-mode "zz-preview-destructive-mode"
        (lambda () (error "Preview must not run this setup")))
      (buffer-set-local! "*zz-saved-preview-target*" 'mode-name "zz-preview-destructive-mode")
      (switch-to-buffer-here! "*zz-saved-preview-owner*")
      (buffer-sleep! "*zz-saved-preview-target*")
      (listing-preview! "*zz-saved-preview-owner*" "*zz-saved-preview-target*")
      """, frame)
      assert eval!(~S{(buffer-text (float-buffer))}, frame) == ~s("Saved generated detail")
      assert eval!(~S{(buffer-exists? "*zz-saved-preview-target*")}, frame) == "#f"
    after
      eval!(~S{(listing-preview-dismiss! "*zz-saved-preview-owner*")
        (buffer-kill! "*zz-saved-preview-owner*") (buffer-kill! "*zz-saved-preview-target*")}, frame)
      Editor.delete_frame(frame)
      Editor.select_frame(previous)
    end
  end

  test "crossing a group heading retains the preview and the next buffer updates it" do
    previous = Editor.last_active_frame()
    {:ok, frame} = Editor.attach_frame(nil)
    try do
      eval!(~S"""
      (test-buffer! "*zz-heading-home*" "home")
      (test-buffer! "*zz-heading-first*" "first")
      (test-buffer! "*zz-heading-next*" "next")
      (switch-to-buffer-here! "*zz-heading-home*")
      (run-command "ibuffer")
      (define *heading-owner* (current-buffer))
      (define *heading-rows* (list (ibuffer-table-heading "Section" "section" "separator"
                                  '("*zz-heading-next*")) "*zz-heading-next*"))
      (buffer-set-local! *heading-owner* 'list-source-entries *heading-rows*)
      (list-redraw! *heading-owner*)
      (listing-preview! *heading-owner* "*zz-heading-first*")
      (define *heading-copy* (float-buffer))
      (list-goto-index! *heading-owner* 0)
      """, frame)
      KeyDispatch.handle_key(frame, "<up>")
      assert eval!("(equal? (float-buffer) *heading-copy*)", frame) == "#t"
      assert eval!("(buffer-local *heading-copy* 'listing-preview-source)", frame) == ~s("*zz-heading-first*")
      KeyDispatch.handle_key(frame, "<down>")
      Process.sleep(250)
      assert eval!("(buffer-local (float-buffer) 'listing-preview-source)", frame) == ~s("*zz-heading-next*")
    after
      eval!(~S"""
      (listing-preview-dismiss! *heading-owner*)
      (for-each buffer-kill! (list "*zz-heading-home*" "*zz-heading-first*" "*zz-heading-next*" *heading-owner*))
      """, frame)
      Editor.delete_frame(frame)
      Editor.select_frame(previous)
    end
  end

  # Both listings preview with the same floating card. This drives
  # ibuffer's key handling; the chat list's card is covered by
  # the-row-at-point-previews-its-chat in chats-list-test.scm.
  for command <- ["ibuffer"] do
    @command command
    test "#{command} floats an isolated nonfocusable card and q only dismisses it" do
      previous = Editor.last_active_frame()
      {:ok, frame} = Editor.attach_frame(nil)
      try do
        eval!("""
        (test-buffer! "*zz-card-source*" "unchanged")
        (test-buffer! "*zz-card-target*" "Preview body <script>not executable</script>")
        (buffer-set-local! "*zz-card-target*" 'mode-name "chat-mode")
        (switch-to-buffer-here! "*zz-card-source*")
        (define *card-home* (active-window))
        (global-set-key "<f9>" "#{@command}")
        """, frame)
        KeyDispatch.handle_key(frame, "<f9>")
        eval!("""
        (define *card-owner* (window-buffer (active-window)))
        (buffer-set-locals! *card-owner* '(ibuffer-grouping none list-sort name))
        (list-set-query! *card-owner* "zz-card-target" #t)
        (ibuffer-goto-first-row! *card-owner*)
        (listing-preview! *card-owner* "*zz-card-target*")
        (define *card-copy* (float-buffer))
        """, frame)
        assert eval!("(equal? (active-window) *card-home*)", frame) == "#t"
        assert eval!("(buffer-read-only? *card-copy*)", frame) == "#t"
        assert eval!("(buffer-local *card-copy* 'window-class)", frame) =~ "listing-preview"
        assert eval!("(buffer-local *card-copy* 'window-style)", frame) =~ "--preview-source-window:"
        assert eval!("(buffer-local *card-copy* 'mode-name)", frame) == "\"chat-mode\""
        assert eval!("(buffer-local \"*zz-card-target*\" 'window-class)", frame) == "#f"
        KeyDispatch.handle_key(frame, "q")
        assert eval!("(equal? (current-buffer) *card-owner*)", frame) == "#t"
        assert eval!("(buffer-known? *card-copy*)", frame) == "#f"
        eval!("(listing-preview-schedule! *card-owner* \"*zz-card-target*\")", frame)
        Process.sleep(250)
        assert eval!("(float-open?)", frame) == "#f"
        if @command == "ibuffer" do
          # Even up at the first row is an explicit request to look again.
          KeyDispatch.handle_key(frame, "<up>")
          Process.sleep(250)
          assert eval!("(float-open?)", frame) == "#t"
          # C-c v turns previews off and on. p walks rows, as p does in
          # every list -- binding the toggle there switched previews off
          # for anyone who pressed p to go up a line.
          KeyDispatch.handle_key(frame, "C-c")
          KeyDispatch.handle_key(frame, "v")
          assert eval!("(float-open?)", frame) == "#f"
          KeyDispatch.handle_key(frame, "<up>")
          Process.sleep(250)
          assert eval!("(float-open?)", frame) == "#f"
          KeyDispatch.handle_key(frame, "C-c")
          KeyDispatch.handle_key(frame, "v")
          assert eval!("(float-open?)", frame) == "#t"
          KeyDispatch.handle_key(frame, "q")
        end
        KeyDispatch.handle_key(frame, "q")
        assert eval!("(current-buffer)", frame) == "\"*zz-card-source*\""
      after
        eval!("""
        (listing-preview-dismiss! *card-owner*)
        (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
          (list "*zz-card-source*" "*zz-card-target*" *card-owner*))
        (global-unset-key "<f9>")
        """, frame)
        Editor.delete_frame(frame)
        Editor.select_frame(previous)
      end
    end
  end
end
