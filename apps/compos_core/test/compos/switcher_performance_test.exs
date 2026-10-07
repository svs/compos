defmodule Compos.SwitcherPerformanceTest do
  use Compos.Case, async: false
  alias Compos.Core.{Buffer, Editor}

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())
  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    Editor.set_window_buffer("*scratch*")

    on_exit(fn ->
      eval!(~S"""
      (begin
        (advice-remove! 'list-render! 'zz-perf)
        (advice-remove! 'chat-list-rows 'zz-perf)
        (advice-remove! 'list-refresh! 'zz-perf)
        (advice-remove! 'dashboard--sync! 'zz-perf)
        (chat-list-search-reset!)
        (when (window-showing "*chat-list*") (chat-list-back!))
        (set! *mb-list-buffer* #f)
        (set! *mb-list-prompt* #f))
      """)

      Editor.minibuffer_close()
      Editor.delete_other_windows()
      Editor.set_window_buffer("*scratch*")

      for name <- ["*zz-perf-chat*", "*zz-perf-hidden*", "*chat-list*", "*switch*"],
          do: Compos.Core.kill_buffer(name)

      eval!(
        ~S{(when (group-record-by-name "zz-perf-group") (group-record-delete! "zz-perf-group"))}
      )
    end)

    :ok
  end

  test "chat search starts at three characters and backspacing expands results" do
    Compos.Core.create_buffer("*zz-perf-chat*", text: "uniquequartz transcript")
    Buffer.set_local("*zz-perf-chat*", "mode-name", "chat-mode")
    eval!("(chat-list-search-reset!)")
    assert eval!(~S{(chat-list-search-hits "un")}) == "()"
    assert eval!(~S{(map car (chat-list-search-hits "uni"))}) =~ "*zz-perf-chat*"
    assert eval!(~S{(chat-list-search-hits "uniquequartz-no-match")}) == "()"
    assert eval!(~S{(map car (chat-list-search-hits "uniquequartz"))}) =~ "*zz-perf-chat*"
  end

  test "C-x c filtering coalesces a burst and reuses the widened source" do
    Compos.Core.create_buffer("*zz-perf-chat*", text: "zzperformance")
    Buffer.set_local("*zz-perf-chat*", "mode-name", "chat-mode")
    press(["C-x", "c"])

    eval!(~S"""
    (begin
      (define *zz-perf-draws* 0)
      (define *zz-perf-fetches* 0)
      (advice-add! 'list-render! 'before 'zz-perf
        (lambda (buf fetch)
          (when (equal? buf " *chats*")
            (set! *zz-perf-draws* (+ *zz-perf-draws* 1)))))
      (advice-add! 'mode-list-rows 'before 'zz-perf
        (lambda (buf) (set! *zz-perf-fetches* (+ *zz-perf-fetches* 1)))))
    """)

    press(["z", "z"])
    assert eval!(~S{(plist-get (minibuffer-state) 'input)}) == ~s("zz")
    eventually(fn -> eval!("*zz-perf-draws*") == "1" end)
    # the prompt widened its source when it opened, before the advice went
    # on, so the burst proving reuse is the one that fetches nothing
    assert eval!("*zz-perf-fetches*") == "0"
    press("DEL")
    eventually(fn -> eval!("*zz-perf-draws*") == "2" end)
    assert eval!("*zz-perf-fetches*") == "0"
    assert Buffer.text(" *chats*") =~ "zz-perf-chat"
  end

  test "repeating the buffer preview preserves its scroll position" do
    Compos.Core.create_buffer("*zz-perf-hidden*", text: String.duplicate("line\n", 200))
    Editor.set_window_buffer("*zz-perf-hidden*")
    win = Editor.active_window()
    Editor.scroll_window(win, 50)
    before = Editor.render_state().tree
    eval!(~s{
      (begin
        (buffer-create "*zz-perf-chat*")
        (buffer-set-local! "*zz-perf-chat*" 'ibuffer-prompt-home-window #{win})
        (ibuffer-preview! "*zz-perf-chat*" "*zz-perf-hidden*"))
    })
    after_preview = Editor.render_state().tree
    assert after_preview.top == before.top
    assert after_preview.manual == before.manual
  end

  test "membership changes do not redraw a hidden switcher" do
    Compos.Core.create_buffer("*switch*", text: "hidden table")

    eval!(~S"""
    (begin
      (define *zz-hidden-refreshes* 0)
      (advice-add! 'list-refresh! 'before 'zz-perf
        (lambda (buf) (set! *zz-hidden-refreshes* (+ *zz-hidden-refreshes* 1))))
      (switch--membership-hook!))
    """)

    assert eval!("*zz-hidden-refreshes*") == "0"
    assert Buffer.text("*switch*") == "hidden table"
  end

  test "moving a hidden buffer defers its dashboard until shown" do
    Compos.Core.create_buffer("*zz-perf-hidden*", text: "work")

    eval!(~S"""
    (begin
      (define *zz-hidden-dashboards* 0)
      (advice-add! 'dashboard--sync! 'before 'zz-perf
        (lambda (buf)
          (when (equal? buf "*zz-perf-hidden*")
            (set! *zz-hidden-dashboards* (+ *zz-hidden-dashboards* 1)))))
      (buffer-move-to-group! "*zz-perf-hidden*" "zz-perf-group"))
    """)

    assert eval!("*zz-hidden-dashboards*") == "0"
    assert Buffer.get_local("*zz-perf-hidden*", "group-display-dirty") == true
    assert eval!(~S{(buffer-in-group? "*zz-perf-hidden*" "zz-perf-group")}) == "#t"
    Editor.set_window_buffer("*zz-perf-hidden*")
    eval!("(windows-shown-catchup!)")
    assert eval!("*zz-hidden-dashboards*") == "1"
    eval!("(windows-shown-catchup!)")
    assert eval!("*zz-hidden-dashboards*") == "1"
  end
end
