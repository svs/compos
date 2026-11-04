defmodule Compos.ListPerformanceTest do
  @moduledoc "Shared list rendering avoids source work during local UI changes."

  use Compos.Case, async: false

  alias Compos.Core.{Buffer, Editor}

  setup do
    Editor.minibuffer_close()
    Compos.TestHelpers.one_window!()

    on_exit(fn ->
      Compos.Core.kill_buffer("*zz-list-performance*")
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
    eval!(
      ~S{(with-current-buffer "*zz-list-performance*" (lambda () (set-mode! "zz-list-wake-mode")))}
    )

    assert eval!("*zz-wake-fetches*") == "1"
    assert Buffer.text("*zz-list-performance*") =~ "alpha"

    # an explicit re-open asks for current rows
    eval!(~S{(list-mode-show! "zz-list-wake-mode")})
    assert eval!("*zz-wake-fetches*") == "2"
  end

  test "semantic rows compute cells once and repeated queries do no work" do
    eval!(~S"""
    (begin
      (define *zz-render-cells* 0)
      (define-list-mode! "zz-render-cells-mode"
        (list 'buffer "*zz-list-performance*"
              'rows (lambda (buf) '("alpha" "beta" "gamma"))
              'columns (lambda (buf) '(("name" #f)))
              'cells (lambda (buf row)
                       (set! *zz-render-cells* (+ *zz-render-cells* 1))
                       (list row))
              'composml-fields (lambda (buf row) '("name"))
              'match (lambda (buf row q) (completion-match? row q 'substring))
              'title (lambda (buf) "Cells")
              'no-marks #t 'local-filter #t))
      (list-mode-show! "zz-render-cells-mode")
      (set! *zz-render-cells* 0)
      (list-redraw! "*zz-list-performance*"))
    """)

    assert eval!("*zz-render-cells*") == "3"
    assert length(Buffer.get_local("*zz-list-performance*", "render-records")) == 3

    eval!(~S{(list-set-query! "*zz-list-performance*" "beta")})
    assert eval!("*zz-render-cells*") == "4"
    eval!(~S{(list-set-query! "*zz-list-performance*" "beta")})
    assert eval!("*zz-render-cells*") == "4"
    assert Buffer.text("*zz-list-performance*") =~ "beta"
    refute Buffer.text("*zz-list-performance*") =~ "alpha"
  end

  test "a scope-changing query fetches and draws just once" do
    eval!(~S"""
    (begin
      (define *zz-scope-fetches* 0)
      (define *zz-scope-draws* 0)
      (define-list-mode! "zz-scope-mode"
        (list 'buffer "*zz-list-performance*"
              'rows (lambda (buf)
                      (set! *zz-scope-fetches* (+ *zz-scope-fetches* 1))
                      (if (equal? (list-query buf) "") '("alpha") '("alpha" "beta")))
              'columns (lambda (buf) '(("name" #f)))
              'cells (lambda (buf row) (list row))
              'title (lambda (buf)
                       (set! *zz-scope-draws* (+ *zz-scope-draws* 1)) "Scope")
              'match (lambda (buf row q) (completion-match? row q 'substring))
              'no-marks #t 'local-filter #t))
      (list-mode-show! "zz-scope-mode")
      (set! *zz-scope-draws* 0)
      (list-set-query! "*zz-list-performance*" "b" #t))
    """)

    assert eval!("*zz-scope-fetches*") == "2"
    assert eval!("*zz-scope-draws*") == "1"
    assert Buffer.text("*zz-list-performance*") =~ "beta"
    eval!(~S{(list-set-query! "*zz-list-performance*" "be")})
    assert eval!("*zz-scope-fetches*") == "2"
    assert eval!("*zz-scope-draws*") == "2"
  end

  test "incremental filtering reuses candidates and cells, but backspace and refresh widen" do
    eval!(~S"""
    (begin
      (define *zz-match-calls* 0)
      (define *zz-filter-cells* 0)
      (define-list-mode! "zz-incremental-mode"
        (list 'buffer "*zz-list-performance*"
              'rows (lambda (buf) '("apple" "apricot" "banana" "berry"))
              'columns (lambda (buf) '(("name" 20)))
              'cells (lambda (buf row)
                       (set! *zz-filter-cells* (+ *zz-filter-cells* 1)) (list row))
              'match (lambda (buf row q)
                       (set! *zz-match-calls* (+ *zz-match-calls* 1))
                       (completion-match? row q 'substring))
              'title (lambda (buf) "Incremental")
              'no-marks #t 'local-filter #t 'incremental-filter #t))
      (list-mode-show! "zz-incremental-mode")
      (set! *zz-match-calls* 0)
      (set! *zz-filter-cells* 0))
    """)

    press("/")
    press("a")
    assert eval!("*zz-match-calls*") == "4"
    assert eval!("*zz-filter-cells*") == "0"
    press("p")
    assert eval!("*zz-match-calls*") == "7"
    assert eval!("*zz-filter-cells*") == "0"
    assert eval!(~S{(list-entries "*zz-list-performance*")}) == ~s{("apple" "apricot")}
    press("p")
    assert eval!("*zz-match-calls*") == "9"
    assert eval!(~S{(list-entries "*zz-list-performance*")}) == ~s{("apple")}
    eval!(~S{(list-set-query! "*zz-list-performance*" "b")})
    assert eval!("*zz-match-calls*") == "13"
    assert eval!(~S{(list-entries "*zz-list-performance*")}) == ~s{("banana" "berry")}
    eval!(~S{(list-refresh! "*zz-list-performance*")})
    assert eval!("*zz-match-calls*") == "17"
    assert eval!("*zz-filter-cells*") == "4"
  end
end
