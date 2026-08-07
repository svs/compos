defmodule Aimax.SchemeOrgPrimsTest do
  use ExUnit.Case, async: true

  alias Aimax.Scheme

  defp run(src) do
    {:ok, val, _} = Scheme.eval_string(Scheme.new(), src)
    val
  end

  defp err(src) do
    {:error, msg} = Scheme.eval_string(Scheme.new(), src)
    msg
  end

  test "cond with else, test-only clauses, tail position" do
    assert run("(cond (#f 1) (#t 2) (else 3))") == 2
    assert run("(cond (#f 1) (else 3))") == 3
    assert run("(cond (#f 1))") == :void
    assert run("(cond (7))") == 7

    tail = """
    (define (f n) (cond ((= n 0) 'done) (else (f (- n 1)))))
    (f 100000)
    """

    assert run(tail) == {:sym, "done"}
  end

  test "when / unless" do
    assert run("(when #t 1 2)") == 2
    assert run("(when #f 1 2)") == :void
    assert run("(unless #f 5)") == 5
    assert run("(unless #t 5)") == :void
  end

  test "let* sees earlier bindings" do
    assert run("(let* ((a 1) (b (+ a 1)) (c (* b 2))) (+ a b c))") == 7
    assert run("(let* () 9)") == 9
  end

  test "integer arithmetic" do
    assert run("(modulo 7 3)") == 1
    assert run("(modulo -1 4)") == 3
    assert run("(remainder -1 4)") == -1
    assert run("(quotient 7 2)") == 3
    assert run("(min 3 1 2)") == 1
    assert run("(max 3 1 2)") == 3
    assert run("(abs -4)") == 4
  end

  test "member, sort, list-ref, iota, remove, assq" do
    assert run("(member 2 '(1 2 3))") == [2, 3]
    assert run("(member 9 '(1 2 3))") == false
    assert run("(sort '(3 1 2))") == [1, 2, 3]
    assert run("(sort '((2 \"b\") (1 \"a\")))") == [[1, "a"], [2, "b"]]
    assert run("(list-ref '(a b c) 1)") == {:sym, "b"}
    assert run("(iota 4)") == [0, 1, 2, 3]
    assert run("(remove (lambda (x) (> x 1)) '(0 1 2 3))") == [0, 1]
    assert run("(assq \"k\" '((\"k\" 1)))") == ["k", 1]
  end

  test "string additions" do
    assert run(~s{(string-index "hello" "ll")}) == 2
    assert run(~s{(string-index "hello" "zz")}) == false
    assert run(~s{(string-upcase "todo")}) == "TODO"
    assert run(~s{(string-downcase "DONE")}) == "done"
    assert run(~s{(string-trim "  x  ")}) == "x"
    assert run(~s{(string-repeat "*" 3)}) == "***"
  end

  test "byte-offset string ops handle UTF-8" do
    assert run(~s{(string-byte-length "héllo")}) == 6
    assert run(~s{(substring-bytes "héllo" 0 3)}) == "hé"
    assert err(~s{(substring-bytes "ab" 0 5)}) =~ "out of"
  end

  test "a builtin fed bad arguments raises a catchable Scheme error, not a raw crash" do
    # this exact shape once killed the editor Session GenServer
    assert err(~s{(string-prefix? "allow_always" #f)}) =~ "string-prefix?"
    assert err(~s{(+ 1 "two")}) =~ "+"
  end

  test "substring-bytes snaps mid-codepoint offsets to boundaries" do
    # "é" is bytes 1-2; offsets inside it must not produce invalid UTF-8
    # (stale marker state fed such a slice to the rope NIF and killed a
    # buffer process — snap down instead)
    assert run(~s{(substring-bytes "héllo" 2 6)}) == "éllo"
    assert run(~s{(substring-bytes "héllo" 0 2)}) == "h"
    assert run(~s{(substring-bytes "héllo" 2 2)}) == ""
  end
end
