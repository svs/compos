defmodule Compos.ListingWindowTest do
  use ExUnit.Case, async: false
  alias Compos.Core.{Editor, KeyDispatch, Session}

  defp eval!(code, frame) do
    {:ok, value} = Session.eval(code, frame)
    value
  end

  # a list leaves in two presses: the first takes the card down, the
  # second the list. The chat list is ibuffer over the chats, so it leaves
  # the same way.
  for {command, quit, card_press?} <- [
        {"ibuffer", "ibuffer-quit", true},
        {"ichat", "ibuffer-quit", true}
      ] do
    @command command
    @quit quit
    @card_press card_press?
    test "#{command} opens here with an inert card and retains the listing on quit" do
      previous = Editor.last_active_frame()
      {:ok, frame} = Editor.attach_frame(nil)

      try do
        eval!(
          """
          (define *lw-group* (group-record-create! "zz-listing-window"))
          (for-each (lambda (b)
            (test-buffer! b "source text")
            (buffer-move-to-group! b *lw-group*))
            '("*zz-lw-left*" "*zz-lw-right*"))
          (set-frame-local! 'current-group *lw-group*)
          (set-frame-local! 'pinned-group *lw-group*)
          (tile-windows! 'two-pane '("*zz-lw-left*" "*zz-lw-right*"))
          (select-window! (window-showing "*zz-lw-right*"))
          (window-set-point! (window-showing "*zz-lw-left*") 3)
          (define *lw-window* (active-window))
          (define *lw-ids* (map car (window-list)))
          (global-set-key "<f9>" "#{@command}")
          """,
          frame
        )

        KeyDispatch.handle_key(frame, "<f9>")
        assert eval!("(equal? (active-window) *lw-window*)", frame) == "#t"
        assert eval!("(equal? (map car (window-list)) *lw-ids*)", frame) == "#t"
        assert eval!("(equal? (frame-group) *lw-group*)", frame) == "#t"

        eval!(
          """
          (define *lw-view* (current-buffer))
          (listing-preview! *lw-view* "*zz-lw-left*")
          (define *lw-copy* (float-buffer))
          (local-set-key "<f10>" "#{@quit}")
          """,
          frame
        )

        assert eval!("(float-open?)", frame) == "#t"
        assert eval!("(window-point (window-showing \"*zz-lw-left*\"))", frame) == "3"
        assert eval!("(equal? (active-window) *lw-window*)", frame) == "#t"
        if @card_press do
          KeyDispatch.handle_key(frame, "<f10>")
          assert eval!("(equal? (current-buffer) *lw-view*)", frame) == "#t"
        end

        KeyDispatch.handle_key(frame, "<f10>")
        assert eval!("(current-buffer)", frame) == "\"*zz-lw-right*\""
        assert eval!("(buffer-known? *lw-copy*)", frame) == "#f"
        assert eval!("(buffer-known? *lw-view*)", frame) == "#t"
        assert eval!("(equal? (map car (window-list)) *lw-ids*)", frame) == "#t"
        KeyDispatch.handle_key(frame, "<f9>")
        assert eval!("(equal? (current-buffer) *lw-view*)", frame) == "#t"
      after
        eval!(
          """
          (when (boundp '*lw-view*) (listing-quit! *lw-view*))
          (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
            (append '("*zz-lw-left*" "*zz-lw-right*") (if (boundp '*lw-view*) (list *lw-view*) '())))
          (group-record-delete! *lw-group*)
          (global-unset-key "<f9>")
          """,
          frame
        )

        Editor.delete_frame(frame)
        Editor.select_frame(previous)
      end
    end
  end

  test "listing reuse chooses buffers by group, and selection visits the target group" do
    previous = Editor.last_active_frame()
    {:ok, frame} = Editor.attach_frame(nil)

    try do
      eval!(
        """
        (define *lw-a* (group-record-create! "zz-listing-a"))
        (define *lw-b* (group-record-create! "zz-listing-b"))
        (test-buffer! "*zz-lw-target*" "target")
        (buffer-move-to-group! "*zz-lw-target*" *lw-b*)
        (set-frame-local! 'current-group *lw-a*)
        (set-frame-local! 'pinned-group *lw-a*)
        (run-command "ibuffer")
        (define *lw-first* (current-buffer))
        (split-window! 'h 0.5)
        (other-window!)
        (define *lw-destination* (active-window))
        (run-command "ibuffer")
        """,
        frame
      )

      assert eval!("(equal? (current-buffer) *lw-first*)", frame) == "#t"
      assert eval!("(equal? (active-window) *lw-destination*)", frame) == "#t"
      eval!("(listing-visit! *lw-first* \"*zz-lw-target*\")", frame)
      assert eval!("(equal? (frame-group) *lw-b*)", frame) == "#t"
      assert eval!("(current-buffer)", frame) == "\"*zz-lw-target*\""
      eval!("(run-command \"ibuffer\") (define *lw-second* (current-buffer))", frame)
      assert eval!("(equal? *lw-first* *lw-second*)", frame) == "#f"
      # Mode identity survives even when the transient view registry is rebuilt.
      eval!(
        "(set! *ibuffer-views* (filter (lambda (v) (not (equal? (car v) *lw-second*))) *ibuffer-views*))",
        frame
      )

      assert eval!("(equal? (ibuffer-view) *lw-second*)", frame) == "#t"
      assert eval!("(equal? (buffer-group *lw-first*) *lw-a*)", frame) == "#t"
      assert eval!("(equal? (buffer-group *lw-second*) *lw-b*)", frame) == "#t"
    after
      eval!(
        """
        (for-each buffer-kill! (list *lw-first* *lw-second* "*zz-lw-target*"))
        (group-record-delete! *lw-a*) (group-record-delete! *lw-b*)
        """,
        frame
      )

      Editor.delete_frame(frame)
      Editor.select_frame(previous)
    end
  end

  # The chat picker is a table in the minibuffer, so it previews the way
  # the window form does: a card over its own window. The pane it was
  # invoked from is the user's and it keeps what it was showing.
  test "the chat picker previews in a card and leaves the invoking pane alone" do
    previous = Editor.last_active_frame()
    {:ok, frame} = Editor.attach_frame(nil)

    try do
      eval!(
        """
        (test-buffer! "*zz-lw-chat-home*" "home")
        (switch-to-buffer-here! "*zz-lw-chat-home*")
        (define *lw-chat-window* (active-window))
        """,
        frame
      )

      KeyDispatch.handle_key(frame, "C-x")
      KeyDispatch.handle_key(frame, "c")
      Process.sleep(400)

      assert eval!("(equal? (mb-list-target) *chat-prompt-buffer*)", frame) == "#t"
      assert eval!("(window-buffer *lw-chat-window*)", frame) == "\"*zz-lw-chat-home*\""

      # a test session need not hold a chat, so the row is named rather
      # than walked to: what is under test is where the preview lands
      eval!("(listing-preview! (mb-list-target) \"*zz-lw-chat-home*\")", frame)

      assert eval!("(float-open?)", frame) == "#t"
      assert eval!("(equal? (listing-preview-owner) (mb-list-target))", frame) == "#t"

      assert eval!(
               "(equal? (buffer-local (float-buffer) 'listing-preview-source) \"*zz-lw-chat-home*\")",
               frame
             ) == "#t"

      # the card is a copy over the list's own window, so the pane the
      # picker was invoked from still shows what it showed
      assert eval!("(window-buffer *lw-chat-window*)", frame) == "\"*zz-lw-chat-home*\""

      KeyDispatch.handle_key(frame, "C-g")
      assert eval!("(float-open?)", frame) == "#f"
      assert eval!("(window-buffer *lw-chat-window*)", frame) == "\"*zz-lw-chat-home*\""
    after
      eval!(
        """
        (when (minibuffer-state) (minibuffer-cancel!))
        (when (buffer-known? "*zz-lw-chat-home*") (buffer-kill! "*zz-lw-chat-home*"))
        """,
        frame
      )

      Editor.delete_frame(frame)
      Editor.select_frame(previous)
    end
  end

  test "C-x b previews in its destination pane and restores it on cancel" do
    previous = Editor.last_active_frame()
    {:ok, frame} = Editor.attach_frame(nil)

    try do
      eval!(
        """
        (test-buffer! "*zz-lw-prompt-source*" "source")
        (test-buffer! "*zz-lw-prompt-target*" "target")
        (switch-to-buffer-here! "*zz-lw-prompt-source*")
        (define *lw-prompt-window* (active-window))
        (window-set-point! *lw-prompt-window* 3)
        (define *lw-prompt-history* (window-prev-buffers *lw-prompt-window*))
        (global-set-key "<f9>" "ibuffer-prompt")
        """,
        frame
      )

      KeyDispatch.handle_key(frame, "C-x")
      KeyDispatch.handle_key(frame, "b")

      assert eval!(
               "(minibuffer-change! \"zz-lw-prompt-target\") (list-query *mb-list-buffer*)",
               frame
             ) == "\"\""

      Process.sleep(650)
      KeyDispatch.handle_key(frame, "<up>")
      Process.sleep(250)
      assert eval!("(listing-preview-owner)", frame) == "#f"
      assert eval!("(window-buffer *lw-prompt-window*)", frame) == "\"*zz-lw-prompt-target*\""
      # Minibuffer previews never create a floating card.
      eval!("(listing-preview! *mb-list-buffer* \"*zz-lw-prompt-target*\")", frame)
      assert eval!("(listing-preview-owner)", frame) == "#f"
      KeyDispatch.handle_key(frame, "C-g")
      assert eval!("(window-buffer *lw-prompt-window*)", frame) == "\"*zz-lw-prompt-source*\""
      assert eval!("(window-point *lw-prompt-window*)", frame) == "3"
      assert eval!("(equal? (window-prev-buffers *lw-prompt-window*) *lw-prompt-history*)", frame) == "#t"
      assert eval!("(float-open?)", frame) == "#f"
    after
      eval!(
        """
        (when (minibuffer-state) (minibuffer-cancel!))
        (for-each buffer-kill! '("*zz-lw-prompt-source*" "*zz-lw-prompt-target*"))
        (global-unset-key "<f9>")
        """,
        frame
      )

      Editor.delete_frame(frame)
      Editor.select_frame(previous)
    end
  end
end
