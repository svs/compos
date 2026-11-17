defmodule Compos.SchemeCaptureTest do
  @moduledoc """
  A closure keeps only the locals its body reads.

  A lexical closure holds its locals by value. Before this rule it held
  every local in scope, so a closure made in a loop held the accumulator
  of that loop. A list of N such closures was a term of size 2^N for each
  walk, copy, and send. An imenu index of 34 rows froze a key for 30 seconds.
  """

  use ExUnit.Case, async: true

  alias Compos.Scheme

  defp eval!(interp \\ Scheme.new(), src) do
    {:ok, value, interp} = Scheme.eval_string(interp, src)
    {value, interp}
  end

  @rows """
  (define (rows n)
    (let loop ((i 0) (out '()))
      (if (= i n)
          (reverse out)
          (loop (+ i 1) (cons (let ((k i)) (lambda () k)) out)))))
  """

  test "a closure made in a loop does not hold the accumulator of the loop" do
    {_, interp} = eval!(@rows)
    {rows, _} = eval!(interp, "(rows 18)")

    # each closure that held the list before it gave more than 2^18 words
    assert :erts_debug.flat_size(rows) < 20_000
  end

  test "the closures of the loop still answer their own value" do
    {_, interp} = eval!(@rows)
    assert {[0, 1, 2, 3, 4], _} = eval!(interp, "(map (lambda (f) (f)) (rows 5))")
  end

  test "a closure reads a local of the function that made it" do
    {_, interp} = eval!("(define (adder n) (lambda (x) (+ x n)))")
    assert {7, _} = eval!(interp, "((adder 3) 4)")
  end

  test "a closure inside a closure reads a local of the outermost function" do
    {_, interp} = eval!("(define (outer a) (let ((b 10)) (lambda (c) (lambda (d) (+ a b c d)))))")
    assert {1111, _} = eval!(interp, "(((outer 1000) 100) 1)")
  end

  test "a closure reads the named let it was made in" do
    src = """
    (define (count-down n)
      (let loop ((i n) (out '()))
        (if (= i 0)
            (reverse out)
            (loop (- i 1) (cons (lambda () (if (procedure? loop) i #f)) out)))))
    """

    {_, interp} = eval!(src)
    assert {[3, 2, 1], _} = eval!(interp, "(map (lambda (f) (f)) (count-down 3))")
  end

  test "a parameter that shadows an outer local wins inside the closure" do
    {_, interp} = eval!("(define (shadow x) (lambda (x) (* x 2)))")
    assert {10, _} = eval!(interp, "((shadow 1) 5)")
  end

  test "a let inside the closure does not take a local of the same slot outside" do
    src = """
    (define (pair a)
      (let ((b (+ a 1)))
        (lambda () (let ((c (+ a b))) (list a b c)))))
    """

    {_, interp} = eval!(src)
    assert {[1, 2, 3], _} = eval!(interp, "((pair 1))")
  end
end
