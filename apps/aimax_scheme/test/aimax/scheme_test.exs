defmodule Aimax.SchemeTest do
  use ExUnit.Case, async: true

  alias Aimax.Scheme

  defp run(src) do
    {:ok, val, _} = Scheme.eval_string(Scheme.new(), src)
    val
  end

  test "arithmetic and comparison" do
    assert run("(+ 1 2 3)") == 6
    assert run("(- 10 3 2)") == 5
    assert run("(* 2 3.5)") == 7.0
    assert run("(< 1 2 3)") == true
    assert run("(= 2 2)") == true
  end

  test "define, lambda, closures share state via set!" do
    src = """
    (define (make-counter)
      (let ((n 0))
        (lambda () (set! n (+ n 1)) n)))
    (define c (make-counter))
    (c) (c) (c)
    """

    assert run(src) == 3
  end

  test "recursion is tail-call safe" do
    src = """
    (define (loop n acc) (if (= n 0) acc (loop (- n 1) (+ acc 1))))
    (loop 100000 0)
    """

    assert run(src) == 100_000
  end

  test "prelude: map / filter / fold" do
    assert run("(map (lambda (x) (* x x)) '(1 2 3))") == [1, 4, 9]
    assert run("(filter (lambda (x) (> x 1)) '(0 1 2 3))") == [2, 3]
    assert run("(fold + 0 '(1 2 3 4))") == 10
  end

  test "strings and symbols" do
    assert run(~s{(string-append "a" "b" "c")}) == "abc"
    assert run(~s{(string-contains? "hello" "ell")}) == true
    assert run("(symbol->string 'foo)") == "foo"
    assert run("'foo") == {:sym, "foo"}
  end

  test "string-edit-distance is the Levenshtein distance" do
    assert run(~s{(string-edit-distance "kitten" "sitting")}) == 3
    assert run(~s{(string-edit-distance "" "abc")}) == 3
    assert run(~s{(string-edit-distance "abc" "")}) == 3
    assert run(~s{(string-edit-distance "same" "same")}) == 0
    assert run(~s{(string-edit-distance "forward-line!" "forward-line")}) == 1
  end

  test "quote, let, and/or" do
    assert run("'(1 2 3)") == [1, 2, 3]
    assert run("(let ((a 1) (b 2)) (+ a b))") == 3
    assert run("(and 1 2 3)") == 3
    assert run("(or #f 7)") == 7
    assert run("(and #f (error \"never\"))") == false
  end

  test "host primitives injection and register/2" do
    interp = Scheme.new(primitives: %{"shout" => fn [s] -> String.upcase(s) end})
    {:ok, val, interp} = Scheme.eval_string(interp, ~s{(shout "hey")})
    assert val == "HEY"

    interp = Scheme.register(interp, %{"twice" => fn [n] -> n * 2 end})
    {:ok, val, _} = Scheme.eval_string(interp, "(twice 21)")
    assert val == 42
  end

  test "errors are returned, not raised" do
    assert {:error, msg} = Scheme.eval_string(Scheme.new(), "(nope 1)")
    assert msg =~ "unbound"
    assert {:error, _} = Scheme.eval_string(Scheme.new(), "(car '())")
    assert {:error, _} = Scheme.eval_string(Scheme.new(), "(+ 1")
  end

  test "printer round-trips" do
    assert Scheme.print(run("'(1 \"a\" foo #t)")) == ~s{(1 "a" foo #t)}
  end
end
