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

  test "string escapes reach the bytes a protocol needs" do
    # \n and \t were already here; a line protocol needs CR, and a binary
    # one needs every byte. Without these a package cannot speak CRLF.
    assert run(~S|"a\nb"|) == "a\nb"
    assert run(~S|"a\tb"|) == "a\tb"
    assert run(~S|"a\rb"|) == "a\rb"
    assert run(~S|"a\r\nb"|) == "a\r\nb"
    assert run(~S|"\\"|) == "\\"
    assert run(~S|"a\"b"|) == ~s|a"b|
  end

  test "the hex escape yields one raw byte, NUL and high bytes included" do
    assert run(~S|"\x41;"|) == "A"
    assert run(~S|"\x00;"|) == <<0>>
    assert run(~S|"\xff;"|) == <<255>>
    assert run(~S|"\x00;Q\xff;"|) == <<0, ?Q, 255>>
    # uppercase digits and a codepoint above one byte
    assert run(~S|"\x0D;\x0A;"|) == "\r\n"
    assert run(~S|"\x3bb;"|) == "λ"
  end

  test "a hex escape without its terminator is an error, not a silent literal" do
    # The reader raises; eval_string answers with the message, like every
    # other error a caller can hit.
    assert {:error, _} = Scheme.eval_string(Scheme.new(), ~S|"\x41"|)
    assert {:error, _} = Scheme.eval_string(Scheme.new(), ~S|"\xzz;"|)
  end

  test "byte accessors read and build a binary protocol message" do
    assert run(~S|(string-byte "ABC" 0)|) == 65
    assert run(~S|(string-byte "ABC" 2)|) == 67
    assert run(~S|(string-byte "ABC" 9)|) == false
    assert run(~S|(string-bytes "AB")|) == [65, 66]
    assert run(~S|(string-bytes "ABCD" 1 3)|) == [66, 67]
    assert run(~S|(bytes->string (list 65 0 255))|) == <<65, 0, 255>>
  end

  test "integers cross the byte boundary both ways" do
    # a PostgreSQL Int32 length: big-endian by default
    assert run(~S|(bytes->integer "\x00;\x00;\x00;\x12;" 0 4)|) == 18
    assert run(~S|(bytes->integer "\x12;\x00;\x00;\x00;" 0 4 "little")|) == 18
    assert run(~S|(integer->bytes 18 4)|) == <<0, 0, 0, 18>>
    assert run(~S|(integer->bytes 18 4 "little")|) == <<18, 0, 0, 0>>
    # the round trip a length prefix actually needs
    assert run(~S|(bytes->integer (integer->bytes 99999 4) 0 4)|) == 99_999
  end

  test "a byte operation that cannot fit says so" do
    # eval errors come back as {:error, msg}; the run/1 helper matches :ok
    assert {:error, m1} = Scheme.eval_string(Scheme.new(), ~S|(integer->bytes 256 1)|)
    assert m1 =~ "does not fit"
    assert {:error, m2} = Scheme.eval_string(Scheme.new(), ~S|(bytes->integer "ab" 0 4)|)
    assert m2 =~ "out of"
    assert {:error, m3} = Scheme.eval_string(Scheme.new(), ~S|(bytes->string (list 300))|)
    assert m3 =~ "not a byte"
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
