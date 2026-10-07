defmodule Compos.ModeListTest do
  @moduledoc """
  A mode list is ibuffer over the buffers of one major mode. A filter reads
  the names at once and the text of every listed buffer in a task; the rows
  the text finds join when the task answers. The chat list is the mode list
  of chat-mode, so these run on it.
  """

  use Compos.Case, async: false
  alias Compos.Core.{Buffer, Editor}

  defp eventually(fun, tries \\ 150)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, tries) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, tries - 1)
        )
  end

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()
    Editor.set_window_buffer("*scratch*")

    for name <- ["*zz-ml-a*", "*zz-ml-b*", "*zz-ml-c*"] do
      Compos.Core.create_buffer(name, text: "transcript")
      Buffer.set_local(name, "mode-name", "chat-mode")
    end

    press(["C-x", "C-c"])

    eval!(~S"""
    (begin
      (define *zz-ml-view* (chat-list-buffer))
      (ibuffer-set-grouping! 'none *zz-ml-view*)
      (ibuffer-set-sort! 'name *zz-ml-view*))
    """)

    on_exit(fn ->
      eval!(~S"""
      (begin
        (advice-remove! 'mode-list--scan 'zz-search-gate)
        (chat-list-back!)
        (set! *mb-list-buffer* #f)
        (set! *mb-list-prompt* #f))
      """)

      Editor.minibuffer_close()

      for name <- ["*zz-ml-a*", "*zz-ml-b*", "*zz-ml-c*"],
          do: Compos.Core.kill_buffer(name)
    end)

    :ok
  end

  test "the chat list is the mode list of chat-mode" do
    assert eval!("(mode-list-of *zz-ml-view*)") == ~s("chat-mode")
    assert eval!("(buffer-local *zz-ml-view* 'mode-name)") == ~s("chat-list-mode")

    assert eval!(~S{(and (member "*zz-ml-a*" (mode-list-buffers "chat-mode")) #t)}) == "#t"
  end

  test "text-only matches arrive asynchronously" do
    Buffer.append("*zz-ml-c*", " hiddenneedle", source: :editor)
    press("/")
    press(String.graphemes("hiddenneedle"))
    assert eval!(~S{(plist-get (minibuffer-state) 'input)}) == ~s("hiddenneedle")
    eventually(fn -> eval!(~S{(list-current *zz-ml-view*)}) == ~s("*zz-ml-c*") end)
    assert eval!(~S{(chat-list-hit "*zz-ml-c*")}) =~ "hiddenneedle"
    press("C-g")
    assert eval!(~S{(list-query *zz-ml-view*)}) == ~s("hiddenneedle")
  end

  test "typing cancels a blocked text scan and rejects its old results" do
    Buffer.append("*zz-ml-c*", " hiddenneedle", source: :editor)

    eval!(~S"""
    (begin
      (define *zz-search-started* #f)
      (define *zz-search-release* #f)
      (advice-add! 'mode-list--scan 'before 'zz-search-gate
        (lambda (names text-of q cache)
          (set! *zz-search-started* q)
          (wait-until (lambda () *zz-search-release*) 2000))))
    """)

    press("/")
    press(String.graphemes("hiddenneedle"))
    eventually(fn -> eval!("*zz-search-started*") == ~s("hiddenneedle") end)
    eval!("(define *zz-old-search-task* *mode-list-task*)")
    # this key finishes while the worker is still held at its gate, and
    # the next filtered draw cancels the scan the old query started
    press("x")
    assert eval!(~S{(plist-get (minibuffer-state) 'input)}) == ~s("hiddenneedlex")
    eventually(fn -> eval!("(task-alive? *zz-old-search-task*)") == "#f" end)
    eval!("(set! *zz-search-release* #t)")
    eventually(fn -> eval!("(cadr *mode-list-search*)") == ~s("hiddenneedlex") end)
    assert eval!(~S{(filter string? (list-entries *zz-ml-view*))}) == "()"
    press("C-g")
  end

  test "name matches come before text matches" do
    Buffer.set_local("*zz-ml-c*", "chat-summary", "rankingneedle")
    Buffer.append("*zz-ml-a*", " rankingneedle", source: :editor)
    press("/")
    press(String.graphemes("rankingneedle"))
    eventually(fn -> eval!(~S{(chat-list-hit "*zz-ml-a*")}) != "#f" end)
    assert eval!(~S{(filter string? (list-entries *zz-ml-view*))}) == ~s{("*zz-ml-c*" "*zz-ml-a*")}
    press("C-g")
  end
end
