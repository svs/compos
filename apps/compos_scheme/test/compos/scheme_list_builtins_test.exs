defmodule Compos.Scheme.ListBuiltinsTest do
  use ExUnit.Case, async: true

  alias Compos.Scheme

  defp run(src) do
    {:ok, val, _} = Scheme.eval_string(Scheme.new(), src)
    val
  end

  test "map applies a closure or a builtin to each element" do
    assert run("(map (lambda (x) (* x 2)) '(1 2 3))") == [2, 4, 6]
    assert run("(map car '((1 a) (2 b)))") == [1, 2]
    assert run("(map car '())") == []
  end

  test "filter and remove split a list on the predicate's truthiness" do
    assert run("(filter (lambda (x) (> x 1)) '(1 2 3))") == [2, 3]
    assert run("(remove (lambda (x) (> x 1)) '(1 2 3))") == [1]
    # any value but false counts as true
    assert run("(filter (lambda (x) (assoc x '((1 a)))) '(1 2))") == [1]
    assert run("(remove (lambda (x) (assoc x '((1 a)))) '(1 2))") == [2]
  end

  test "for-each runs in order and returns true" do
    assert run("""
           (define acc '())
           (for-each (lambda (x) (set! acc (cons x acc))) '(1 2 3))
           (list (for-each car '()) acc)
           """) == [true, [3, 2, 1]]
  end

  test "fold reduces from the left with the accumulator first" do
    assert run("(fold (lambda (acc x) (cons x acc)) '() '(1 2 3))") == [3, 2, 1]
    assert run("(fold + 0 '(1 2 3))") == 6
  end

  test "assoc returns the first pair with the key and skips non-pairs" do
    assert run("(assoc 2 '((1 a) (2 b) (2 c)))") == [2, {:sym, "b"}]
    assert run("(assoc 'k '(x (k 1)))") == [{:sym, "k"}, 1]
    assert run("(assoc 3 '((1 a)))") == false
    assert run("(assq 'a '((a 1)))") == [{:sym, "a"}, 1]
  end

  test "plist-get reads a flat plist and answers false past an odd tail" do
    assert run("(plist-get '(a 1 b 2) 'b)") == 2
    assert run("(plist-get '(a 1 b) 'b)") == false
    assert run("(plist-get '() 'b)") == false
    assert {:error, _} = Scheme.eval_string(Scheme.new(), "(plist-get #f 'b)")
  end

  test "a predicate error reaches the caller as a Scheme error" do
    assert {:error, msg} = Scheme.eval_string(Scheme.new(), "(filter (lambda (x) (car x)) '(1))")
    assert msg =~ "car"
  end

  test "the store threads through: a closure called by map keeps its state" do
    assert run("""
           (define n 0)
           (define (tick x) (set! n (+ n 1)) n)
           (list (map tick '(a b c)) n)
           """) == [[1, 2, 3], 3]
  end
end
