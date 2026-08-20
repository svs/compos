defmodule Aimax.ListPerformanceTest do
  @moduledoc "Shared list rendering avoids source work during local UI changes."

  use ExUnit.Case, async: false

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp eval!(code) do
    {:ok, out} = Session.eval(code)
    out
  end

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()

    on_exit(fn ->
      Aimax.Core.kill_buffer("*zz-list-performance*")
      Editor.minibuffer_close()
    end)

    :ok
  end

  test "typing a local filter reuses rows and computes columns once per redraw" do
    eval!(~S"""
    (begin
      (define *zz-list-fetches* 0)
      (define *zz-list-columns* 0)
      (domain! 'ui)
      (effects! '(write))
      (define-command "zz-list-refresh"
        "Refresh the performance test list"
        (lambda () (list-refresh! "*zz-list-performance*")))
      (define-list-mode! "zz-list-performance-mode"
        (list
          'buffer "*zz-list-performance*"
          'rows (lambda (buf)
                  (set! *zz-list-fetches* (+ *zz-list-fetches* 1))
                  '("alpha" "beta" "gamma"))
          'columns (lambda (buf)
                     (set! *zz-list-columns* (+ *zz-list-columns* 1))
                     (list (list "name" #f)))
          'cells (lambda (buf row) (list row))
          'title (lambda (buf) "Performance")
          'no-marks #t
          'local-filter #t
          'keys '(("g" "zz-list-refresh"))))
      (list-mode-show! "zz-list-performance-mode"))
    """)

    assert eval!("*zz-list-fetches*") == "1"
    initial_columns = String.to_integer(eval!("*zz-list-columns*"))

    press("/")
    press("b")

    assert eval!("*zz-list-fetches*") == "1"
    assert String.to_integer(eval!("*zz-list-columns*")) == initial_columns + 1
    assert Buffer.text("*zz-list-performance*") =~ "beta"
    refute Buffer.text("*zz-list-performance*") =~ "alpha"

    press("RET")
    press("\\")

    assert eval!("*zz-list-fetches*") == "1"
    assert String.to_integer(eval!("*zz-list-columns*")) == initial_columns + 2
    assert Buffer.text("*zz-list-performance*") =~ "alpha"

    press("g")
    assert eval!("*zz-list-fetches*") == "2"
    assert String.to_integer(eval!("*zz-list-columns*")) == initial_columns + 3
  end

  test "a wake redraws cached rows; only an explicit open or g refetches" do
    eval!(~S"""
    (begin
      (define *zz-wake-fetches* 0)
      (domain! 'ui)
      (effects! '(write))
      (define-list-mode! "zz-list-wake-mode"
        (list
          'buffer "*zz-list-performance*"
          'rows (lambda (buf)
                  (set! *zz-wake-fetches* (+ *zz-wake-fetches* 1))
                  '("alpha" "beta"))
          'columns (lambda (buf) (list (list "name" #f)))
          'cells (lambda (buf row) (list row))
          'title (lambda (buf) "Wake")
          'no-marks #t))
      (list-mode-show! "zz-list-wake-mode"))
    """)

    # first open: exactly one fetch
    assert eval!("*zz-wake-fetches*") == "1"
    assert Buffer.text("*zz-list-performance*") =~ "alpha"

    # a wake re-runs the mode setup (this is what the buffer switcher's
    # preview and desktop restore do) — cached rows redraw, no fetch
    eval!(~S{(with-current-buffer "*zz-list-performance*" (lambda () (set-mode! "zz-list-wake-mode")))})
    assert eval!("*zz-wake-fetches*") == "1"
    assert Buffer.text("*zz-list-performance*") =~ "alpha"

    # an explicit re-open asks for current rows
    eval!(~S{(list-mode-show! "zz-list-wake-mode")})
    assert eval!("*zz-wake-fetches*") == "2"
  end
end
