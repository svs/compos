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

  test "cons onto a non-list names the tail instead of a clause error" do
    assert run("(cons 1 '(2))") == [1, 2]

    assert {:error, message} = Scheme.eval_string(Scheme.new(), "(cons 'k #f)")
    assert message =~ "cons: the tail must be a list, not #f"
  end

  test "assoc returns the first pair with the key and skips non-pairs" do
    assert run("(assoc 2 '((1 a) (2 b) (2 c)))") == [2, {:sym, "b"}]
    assert run("(assoc 'k '(x (k 1)))") == [{:sym, "k"}, 1]
    assert run("(assoc 3 '((1 a)))") == false
    assert run("(assq 'a '((a 1)))") == [{:sym, "a"}, 1]
  end

  test "plist-get reads a flat plist and answers false past an odd tail or a non-list" do
    assert run("(plist-get '(a 1 b 2) 'b)") == 2
    assert run("(plist-get '(a 1 b) 'b)") == false
    assert run("(plist-get '() 'b)") == false
    # a missing lookup hands #f on; the caller never guards it
    assert run("(plist-get #f 'b)") == false
    assert run("(plist-get (plist-get '(a 1) 'z) 'b)") == false
  end

  test "alist-put replaces an entry and steps over an empty one" do
    assert run("(alist-put '((a 1) () (b 2)) 'b 3)") == [[{:sym, "b"}, 3], [{:sym, "a"}, 1], []]
    assert run("(alist-get '(() (b 2)) 'b)") == 2
    assert run("(alist-delete '(() (b 2)) 'b)") == [[]]
  end

  test "sh-quote makes one word of any string" do
    assert run(~S[(sh-quote "a b")]) == "'a b'"
    assert run(~S[(sh-quote "it's")]) == ~S['it'\''s']
    assert run(~S[(sh-quote "")]) == "''"
  end

  test "plist-put replaces a pair in place of growing the plist" do
    assert run("(plist-put '(a 1 b 2) 'b 3)") == [{:sym, "b"}, 3, {:sym, "a"}, 1]
    assert run("(plist-put '() 'b 3)") == [{:sym, "b"}, 3]
    assert run("(plist-put #f 'b 3)") == [{:sym, "b"}, 3]
    assert run("(plist-get (plist-put '(a 1 b 2) 'b 3) 'b)") == 3
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

  test "the shared string and list helpers" do
    assert run(~s{(string-replace "a-b-c" "-" "+")}) == "a+b+c"
    assert run(~s{(string-replace #f "-" "+")}) == ""

    assert run(~S{(html-escape "<a href=\"x\">&</a>")}) ==
             "&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;"

    assert run(~s{(html-escape 3)}) == ""
    assert run(~s{(first-line "  one \ntwo")}) == "one"
    assert run(~s{(first-line #f)}) == ""
    assert run(~s{(file-name-nondirectory "/a/b/c.txt")}) == "c.txt"
    assert run(~s{(file-name-nondirectory "/a/b/")}) == ""
    assert run(~s{(file-name-nondirectory "plain")}) == "plain"
    assert run("(take '(1 2 3) 2)") == [1, 2]
    assert run("(take '(1) 5)") == [1]
    assert run("(alist-put '((a 1) (b 2)) 'a 3)") == [[{:sym, "a"}, 3], [{:sym, "b"}, 2]]
    assert run("(alist-get '((a 1)) 'a)") == 1
    assert run("(alist-get '((a 1)) 'z)") == false
    assert run("(alist-delete '((a 1) (b 2)) 'a)") == [[{:sym, "b"}, 2]]
  end
end
