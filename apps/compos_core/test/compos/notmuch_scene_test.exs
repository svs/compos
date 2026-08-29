defmodule Compos.NotmuchSceneTest do
  @moduledoc """
  The semantic scene path through real key dispatch.

  Notmuch policy stays in `priv/tests/notmuch-test.scm`. This test binds a
  test-only key to the production command and proves that GUI dispatch routes
  it by the scene's `show` role, without asserting the production binding.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.{KeyDispatch, Session}

  defp eval!(source) do
    {:ok, printed} = Session.eval(source)
    printed
  end

  setup do
    eval!(~S"""
    (begin
      (define *zz-notmuch-old-run* nm--run)
      (set! nm--run
        (lambda (args)
          (cond
            ((string-prefix? "search --output=tags" args)
             "unread\ninbox\n")
            ((string-prefix? "search" args)
             "[{\"thread\":\"zz-thread\",\"timestamp\":1786065644,\"date_relative\":\"Today\",\"matched\":1,\"total\":1,\"authors\":\"Alice\",\"subject\":\"Role routed mail\",\"query\":[\"id:zz-message\"],\"tags\":[\"inbox\"]},{\"thread\":\"zz-thread-2\",\"timestamp\":1785979244,\"date_relative\":\"Yesterday\",\"matched\":1,\"total\":1,\"authors\":\"Bob\",\"subject\":\"Reloaded selection\",\"query\":[\"id:zz-message-2\"],\"tags\":[\"inbox\"]}]")
            ((string-prefix? "show" args)
             "[[[{\"id\":\"zz-message\",\"match\":true,\"excluded\":false,\"filename\":[\"/tmp/zz-message\"],\"timestamp\":1786065644,\"date_relative\":\"Today\",\"tags\":[\"inbox\"],\"duplicate\":1,\"body\":[{\"id\":1,\"content-type\":\"text/plain\",\"content\":\"The routed body.\\n\"}],\"headers\":{\"Subject\":\"Role routed mail\",\"From\":\"Alice <alice@example.com>\",\"To\":\"reader@example.com\",\"Date\":\"Thu, 07 Aug 2026 06:50:44 +0530\"}},[]]]]")
            (else ""))))
      (for-each
        (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
        '("*notmuch*" "*mail*" "*chat:zz-notmuch-scene*"))
      (delete-other-windows!))
    """)

    on_exit(fn ->
      eval!(~S"""
      (begin
        (set! nm--run *zz-notmuch-old-run*)
        (let ((id (group-resolve-id "zz-notmuch-scene")))
          (when id (group-dissolve! id)))
        (set! *scenes*
          (remove (lambda (entry) (equal? (car entry) "zz-notmuch-scene")) *scenes*))
        (for-each
          (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
          '("*notmuch*" "*mail*" "*chat:zz-notmuch-scene*"))
        (delete-other-windows!))
      """)
    end)

    :ok
  end

  test "open routes to the scene's show role through key dispatch" do
    eval!(~S"""
    (begin
      (define-scene! "zz-notmuch-scene"
        '(h 0.32 (as index (ensure "*notmuch*" "notmuch-inbox"))
                 (as show (ensure "*mail*" "notmuch-show-current"))
                 (as chat group-chat)))
      (scene-open! "zz-notmuch-scene")
      (select-window! (scene-window 'index))
      (local-set-key "C-c C-9" "notmuch-open-thread"))
    """)

    KeyDispatch.handle_key("C-c")
    KeyDispatch.handle_key("C-9")

    assert eval!(~S|(current-buffer)|) == ~s{"*notmuch*"}
    assert eval!(~S|(active-window)|) == eval!(~S|(scene-window 'index)|)
    assert eval!(~S|(window-buffer (scene-window 'index))|) == ~s{"*notmuch*"}
    assert eval!(~S|(buffer-text (scene-buffer 'show))|) =~ "The routed body."
    assert eval!(~S|(window-buffer (scene-window 'chat))|) == ~s{"*chat:zz-notmuch-scene*"}
  end

  test "a mode key opens the tag menu and applies its selection" do
    eval!(~S"""
    (begin
      (run-command "notmuch-inbox")
      (local-set-key "C-c C-8" "notmuch-filter-by-tag"))
    """)

    KeyDispatch.handle_key("C-c")
    KeyDispatch.handle_key("C-8")

    assert eval!(~S|(minibuffer-selected)|) == ~s{"unread"}
    KeyDispatch.handle_key("RET")

    assert eval!(~S|(nm--query-of "*notmuch*")|) == ~s{"( tag:inbox ) and tag:unread"}
  end

  test "the highlighted row follows key dispatch and survives mode reload" do
    eval!(~S"""
    (begin
      (run-command "notmuch-inbox")
      (local-set-key "C-c C-7" "notmuch-next"))
    """)

    KeyDispatch.handle_key("C-c")
    KeyDispatch.handle_key("C-7")

    assert eval!(~S|(nm--th-id (nm--thread-at "*notmuch*"))|) == ~s{"zz-thread-2"}
    assert eval!(selected_row_overlay?()) == "#t"
    assert eval!(selected_row_covers_both_lines?()) == "#t"

    eval!(~S|(with-current-buffer "*notmuch*" (lambda () (set-mode! "notmuch-mode")))|)

    assert eval!(~S|(nm--th-id (nm--thread-at "*notmuch*"))|) == ~s{"zz-thread-2"}
    assert eval!(selected_row_overlay?()) == "#t"
    assert eval!(selected_row_covers_both_lines?()) == "#t"
  end

  defp selected_row_overlay? do
    ~S"""
    (let ((p (buffer-point "*notmuch*")))
      (pair?
        (filter
          (lambda (overlay)
            (and (equal? (list-ref overlay 2) "select")
                 (<= (car overlay) p)
                 (< p (cadr overlay))))
          (buffer-overlays "*notmuch*"))))
    """
  end

  defp selected_row_covers_both_lines? do
    ~S"""
    (let* ((text (buffer-text "*notmuch*"))
           (subject (string-index text "Reloaded selection"))
           (author (string-index text "Bob")))
      (pair?
        (filter
          (lambda (overlay)
            (and (equal? (list-ref overlay 2) "select")
                 (<= (car overlay) subject)
                 (< subject (cadr overlay))
                 (<= (car overlay) author)
                 (< author (cadr overlay))))
          (buffer-overlays "*notmuch*"))))
    """
  end
end
