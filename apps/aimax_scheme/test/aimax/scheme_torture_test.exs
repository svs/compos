defmodule Aimax.SchemeTortureTest do
  @moduledoc "The 'test the shit out of it' suite: semantics, edge cases, error paths."

  use ExUnit.Case, async: true

  alias Aimax.Scheme
  alias Aimax.Scheme.Reader

  defp run(src) do
    {:ok, val, _} = Scheme.eval_string(Scheme.new(), src)
    val
  end

  defp err(src) do
    {:error, msg} = Scheme.eval_string(Scheme.new(), src)
    msg
  end

  describe "reader" do
    test "numbers: negatives, floats, not-quite-numbers" do
      assert Reader.read_all("-5") == [-5]
      assert Reader.read_all("-5.25") == [-5.25]
      assert Reader.read_all("1e3") == [1.0e3]
      assert Reader.read_all("-") == [{:sym, "-"}]
      assert Reader.read_all("1+") == [{:sym, "1+"}]
    end

    test "symbols with scheme-typical characters" do
      for s <- ~w(-> list->string set-car! null? <= string=? *global* /) do
        assert Reader.read_all(s) == [{:sym, s}]
      end
    end

    test "string escapes" do
      assert Reader.read_all(~S{"a\"b\\c\nd\te"}) == ["a\"b\\c\nd\te"]
    end

    test "comments, whitespace, multiple top-level forms" do
      assert Reader.read_all("""
             ; leading comment
             (+ 1 ; inline
                2)
             foo ;; trailing
             """) == [[{:sym, "+"}, 1, 2], {:sym, "foo"}]
    end

    test "nested quotes" do
      assert Reader.read_all("''a") == [
               [{:sym, "quote"}, [{:sym, "quote"}, {:sym, "a"}]]
             ]

      assert Reader.read_all("'(1 '(2))") == [
               [{:sym, "quote"}, [1, [{:sym, "quote"}, [2]]]]
             ]
    end

    test "deep nesting round-trips" do
      depth = 2_000
      src = String.duplicate("(", depth) <> "x" <> String.duplicate(")", depth)
      [form] = Reader.read_all(src)
      assert form |> Stream.iterate(&hd/1) |> Enum.at(depth) == {:sym, "x"}
    end

    test "reader errors" do
      assert_raise Reader.Error, ~r/unterminated string/, fn -> Reader.read_all(~S{"abc}) end
      assert_raise Reader.Error, ~r/unterminated list/, fn -> Reader.read_all("(1 2") end
      assert_raise Reader.Error, ~r/unexpected \)/, fn -> Reader.read_all(")") end
      assert_raise Reader.Error, ~r/end of input/, fn -> Reader.read_all("'") end
    end

    test "utf8 in strings and symbols" do
      assert Reader.read_all(~s{"héllo ✓"}) == ["héllo ✓"]
      assert Reader.read_all("λ") == [{:sym, "λ"}]
    end
  end

  describe "semantics" do
    test "only #f is falsy — 0, empty string, empty list are truthy" do
      assert run(~s{(if 0 "yes" "no")}) == "yes"
      assert run(~s{(if "" "yes" "no")}) == "yes"
      assert run(~s{(if '() "yes" "no")}) == "yes"
      assert run(~s{(if #f "yes" "no")}) == "no"
    end

    test "lexical shadowing" do
      assert run("""
             (define x 1)
             (define (f x) (+ x 10))
             (list (f 100) x)
             """) == [110, 1]

      assert run("(let ((x 1)) (let ((x 2)) x))") == 2
      assert run("(let ((x 1)) (let ((x (+ x 1))) x))") == 2
    end

    test "two closures share one captured environment" do
      assert run("""
             (define (make-cell)
               (let ((v 0))
                 (list (lambda () v) (lambda (nv) (set! v nv)))))
             (define cell (make-cell))
             (define get (car cell))
             (define put (cadr cell))
             (put 42)
             (get)
             """) == 42
    end

    test "closures capture creation env, not call env" do
      assert run("""
             (define x 10)
             (define (capture) (lambda () x))
             (define f (capture))
             (let ((x 99)) (f))
             """) == 10
    end

    test "mutual recursion via late binding" do
      assert run("""
             (define (my-even? n) (if (= n 0) #t (my-odd? (- n 1))))
             (define (my-odd? n) (if (= n 0) #f (my-even? (- n 1))))
             (my-even? 10001)
             """) == false
    end

    test "mutual recursion is tail-call safe at depth" do
      assert run("""
             (define (a n) (if (= n 0) 'done-a (b (- n 1))))
             (define (b n) (if (= n 0) 'done-b (a (- n 1))))
             (a 200000)
             """) == {:sym, "done-a"}
    end

    test "tail position in if/begin/let/and/or all TCO" do
      assert run("""
             (define (loop n)
               (if (= n 0)
                   'ok
                   (begin 'side-effect (let ((m (- n 1))) (and #t (or #f (loop m)))))))
             (loop 100000)
             """) == {:sym, "ok"}
    end

    test "and/or return values, short-circuit" do
      assert run("(and)") == true
      assert run("(or)") == false
      assert run("(and 1 2)") == 2
      assert run("(or #f 'x 'y)") == {:sym, "x"}
      # side effect must not run
      assert run("""
             (define ran #f)
             (or 'hit (set! ran #t))
             ran
             """) == false
    end

    test "begin returns last, evaluates in order" do
      assert run("""
             (define log '())
             (begin (set! log (cons 1 log)) (set! log (cons 2 log)) log)
             """) == [2, 1]
    end

    test "named let iterates tail-recursively" do
      assert run("""
             (let loop ((i 0) (acc 0))
               (if (= i 100000) acc (loop (+ i 1) (+ acc i))))
             """) == 4_999_950_000
    end

    test "higher-order: apply, procedures as values" do
      assert run("(apply + '(1 2 3))") == 6
      assert run("(apply (lambda (a b) (* a b)) '(6 7))") == 42
      assert run("((car (list + *)) 2 3)") == 5
      assert run("(procedure? car)") == true
      assert run("(procedure? 'car)") == false
    end

    test "define inside body is local" do
      assert run("""
             (define (f)
               (define local 5)
               (+ local 1))
             (f)
             """) == 6

      assert err("""
             (define (f) (define local 5) local)
             (f)
             local
             """) =~ "unbound"
    end
  end

  describe "prelude" do
    test "fold/for-each/assoc" do
      assert run("(fold (lambda (acc x) (cons x acc)) '() '(1 2 3))") == [3, 2, 1]

      assert run("""
             (define sum 0)
             (for-each (lambda (x) (set! sum (+ sum x))) '(1 2 3 4))
             sum
             """) == 10

      assert run("(assoc 'b '((a 1) (b 2)))") == [{:sym, "b"}, 2]
      assert run("(assoc 'z '((a 1)))") == false
    end

    test "map with closure over mutable state" do
      assert run("""
             (define n 0)
             (map (lambda (x) (set! n (+ n 1)) (* x n)) '(10 10 10))
             """) == [10, 20, 30]
    end

    test "string utilities" do
      assert run(~s{(split-lines "a\\nb\\nc")}) == ["a", "b", "c"]
      assert run(~s{(string-join (list "a" "b") "-")}) == "a-b"
      assert run(~s{(substring "hello" 1 3)}) == "el"
    end
  end

  describe "error paths" do
    test "arity mismatch" do
      assert err("((lambda (a b) a) 1)") =~ "arity"
    end

    test "calling a non-function" do
      assert err("(5 1 2)") =~ "not a function"
    end

    test "set! of unbound variable" do
      assert err("(set! nope 1)") =~ "unbound"
    end

    test "(error ...) surfaces" do
      assert err(~s{(error "custom" "failure")}) =~ "custom failure"
    end

    test "car/cdr of empty list is an error, not a crash" do
      assert {:error, _} = Scheme.eval_string(Scheme.new(), "(car '())")
      assert {:error, _} = Scheme.eval_string(Scheme.new(), "(cdr '())")
    end

    test "failed eval: the local tier rolls back, the shared tier persists" do
      interp = Scheme.new()
      {:ok, _, interp} = Scheme.eval_string(interp, "(define safe 1)")

      # unflushed (local-tier) global: the failing eval's store is discarded
      {:error, _} = Scheme.eval_string(interp, "(begin (define t1 2) (boom))")
      assert {:error, _} = Scheme.eval_string(interp, "t1")

      # flushed (shared-tier) global: a define writes through at once and
      # stays, as in Emacs — the editor session runs in this regime
      interp = Scheme.flush(interp)
      {:error, _} = Scheme.eval_string(interp, "(begin (define t2 2) (boom))")
      assert {:ok, 2, _} = Scheme.eval_string(interp, "t2")
      assert {:ok, 1, _} = Scheme.eval_string(interp, "safe")
    end
  end

  describe "host interop" do
    test "store-aware primitives can call back into scheme" do
      twice = fn [f, x], store ->
        {v1, store} = Aimax.Scheme.Eval.apply_fn(f, [x], store)
        Aimax.Scheme.Eval.apply_fn(f, [v1], store)
      end

      interp = Scheme.new(primitives: %{"call-twice" => twice})
      {:ok, val, _} = Scheme.eval_string(interp, "(call-twice (lambda (n) (* n 3)) 2)")
      assert val == 18
    end

    test "scheme closures are callable from elixir" do
      interp = Scheme.new()
      {:ok, f, interp} = Scheme.eval_string(interp, "(lambda (a b) (+ a b))")
      assert {:ok, 7, _} = Scheme.call(interp, f, [3, 4])
    end
  end
end
