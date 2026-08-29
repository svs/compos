defmodule Compos.SchemeParamsTest do
  @moduledoc """
  Executable spec for elisp-style parameter lists: `&optional` / `&rest`.
  Missing optionals bind #f; &rest binds a (possibly empty) list.
  """

  use ExUnit.Case, async: true

  alias Compos.Scheme

  defp run(src) do
    {:ok, val, _} = Scheme.eval_string(Scheme.new(), src)
    val
  end

  defp err(src) do
    {:error, msg} = Scheme.eval_string(Scheme.new(), src)
    msg
  end

  describe "&optional" do
    test "supplied and missing optionals" do
      assert run("((lambda (a &optional b) (list a b)) 1 2)") == [1, 2]
      assert run("((lambda (a &optional b) (list a b)) 1)") == [1, false]
      assert run("((lambda (a &optional b c) (list a b c)) 1 2)") == [1, 2, false]
      assert run("((lambda (&optional a b) (list a b)))") == [false, false]
    end

    test "elisp default-value idiom via or" do
      assert run("((lambda (a &optional b) (+ a (or b 10))) 1)") == 11
      assert run("((lambda (a &optional b) (+ a (or b 10))) 1 2)") == 3
    end

    test "too many args still errors" do
      assert err("((lambda (a &optional b) a) 1 2 3)") =~ "arity mismatch"
      assert err("((lambda (a &optional b) a) 1 2 3)") =~ "at most 2"
    end

    test "too few required errors with at-least phrasing" do
      assert err("((lambda (a b &optional c) a) 1)") =~ "at least 2"
    end
  end

  describe "&rest" do
    test "rest collects remainder, empty allowed" do
      assert run("((lambda (a &rest r) (list a r)) 1 2 3)") == [1, [2, 3]]
      assert run("((lambda (a &rest r) (list a r)) 1)") == [1, []]
      assert run("((lambda (&rest r) r))") == []
      assert run("((lambda (&rest r) r) 1 2 3 4 5)") == [1, 2, 3, 4, 5]
    end

    test "combined &optional and &rest" do
      assert run("((lambda (a &optional b &rest r) (list a b r)) 1)") == [1, false, []]
      assert run("((lambda (a &optional b &rest r) (list a b r)) 1 2)") == [1, 2, []]
      assert run("((lambda (a &optional b &rest r) (list a b r)) 1 2 3 4)") == [1, 2, [3, 4]]
    end

    test "define sugar carries markers" do
      assert run("(define (f a &optional b &rest r) (list a b r)) (f 1 2 3)") == [1, 2, [3]]
      assert run("(define (f &rest r) (length r)) (f 1 2 3)") == 3
    end

    test "works through apply" do
      assert run("(apply (lambda (a &rest r) (list a r)) (list 1 2 3))") == [1, [2, 3]]
      assert run("(apply (lambda (&optional a) a) (list))") == false
    end

    test "closures over rest args behave" do
      assert run("""
             (define (adder &rest ns)
               (lambda (x) (+ x (apply + ns))))
             ((adder 1 2 3) 10)
             """) == 16
    end
  end

  describe "malformed parameter lists" do
    test "&rest arity of the marker itself" do
      assert err("(lambda (a &rest) a)") =~ "&rest"
      assert err("(lambda (a &rest r s) a)") =~ "&rest"
      assert err("(lambda (&rest &rest) 1)") =~ "&rest"
    end

    test "&optional twice" do
      assert err("(lambda (a &optional b &optional c) a)") =~ "&optional"
    end
  end

  describe "unchanged fixed-arity behaviour" do
    test "exact arity error message preserved" do
      assert err("((lambda (a b) a) 1)") == "arity mismatch: expected 2, got 1"
      assert err("((lambda (a b) a) 1 2 3)") == "arity mismatch: expected 2, got 3"
    end

    test "named let still iterates" do
      assert run("(let loop ((i 0) (acc 0)) (if (= i 5) acc (loop (+ i 1) (+ acc i))))") == 10
    end

    test "procedure? and printing" do
      assert run("(procedure? (lambda (a &rest r) a))") == true
      assert Compos.Scheme.Printer.print(run("(lambda (a &optional b &rest r) a)")) ==
               "#<procedure (a &optional b &rest r)>"
    end
  end
end
