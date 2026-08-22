defmodule Aimax.SchemeReaderTest do
  use ExUnit.Case, async: true

  alias Aimax.Scheme
  alias Aimax.Scheme.{Printer, Reader}

  defp read(src), do: Reader.read_all(src)
  defp read1(src), do: src |> Reader.read_all() |> hd()
  defp run(src), do: (fn {:ok, v, _} -> v end).(Scheme.eval_string(Scheme.new(), src))
  defp show(src), do: Printer.print(run(src))
  defp err(src), do: (fn {:error, m} -> m end).(Scheme.eval_string(Scheme.new(), src))

  defp sym(s), do: {:sym, s}

  describe "atoms" do
    test "integers, floats, and signs" do
      assert read("0 -5 +7 3.5 -2.25 1e3 1.5e-2") == [0, -5, 7, 3.5, -2.25, 1.0e3, 1.5e-2]
    end

    test "a token that is not a number is a symbol" do
      for s <- ["-", "+", "...", "1+", "a1", "set!", "string->list", "<=?", "x.y", "1/2"] do
        assert read(s) == [sym(s)], "expected #{s} to read as a symbol"
      end
    end

    test "booleans, long and short" do
      assert read("#t #f #true #false") == [true, false, true, false]
    end

    test "radix prefixes" do
      assert read("#x1f #X1F #b1010 #o17 #d42") == [31, 31, 10, 15, 42]
      assert read("#x-ff #b+11") == [-255, 3]
    end

    test "a bad radix body names its line and column" do
      assert_raise Reader.Error, ~r/line 1, column 1: bad number #xZZ/, fn -> read("#xZZ") end
      assert_raise Reader.Error, ~r/bad number #x/, fn -> read("#x") end
    end

    test "an unknown # syntax is an error, not a symbol" do
      assert_raise Reader.Error, ~r/unknown # syntax #foo/, fn -> read("#foo") end
    end

    test "|bar symbols| take any characters in the name" do
      assert read("|a b|") == [sym("a b")]
      assert read(~S{|a\|b|}) == [sym("a|b")]
      assert read(~S{|a\\b|}) == [sym("a\\b")]
      assert read("|(1 2)|") == [sym("(1 2)")]
      assert read("|a| |b|") == [sym("a"), sym("b")]
    end

    test "an unterminated |symbol| is an error" do
      assert_raise Reader.Error, ~r/unterminated \|symbol\|/, fn -> read("|abc") end
    end

    test "unicode passes through" do
      assert read("λ") == [sym("λ")]
      assert read(~s{"héllo ✓"}) == ["héllo ✓"]
    end
  end

  describe "strings" do
    test "the classic escapes" do
      assert read(~S{"a\"b\\c\nd\te\rf"}) == ["a\"b\\c\nd\te\rf"]
      assert read(~S{"\a\b\0"}) == [<<7, 8, 0>>]
    end

    test "\\x41; is a hex codepoint" do
      assert read(~S{"a\x41;b"}) == ["aAb"]
      assert read(~S{"\x3bb;"}) == ["λ"]
    end

    # regexes live in strings, and doubling every backslash makes them unreadable
    test "an unknown escape keeps the backslash and the character" do
      assert read(~S{"^\*+ "}) == [~S{^\*+ }]
      assert read(~S{"\d+\s"}) == [~S{\d+\s}]
      assert read(~S{"\x"}) == [~S{\x}]
      assert read(~S{"\xzz"}) == [~S{\xzz}]
    end

    test "a backslash before a newline folds the line break away" do
      assert read("\"a\\\n     b\"") == ["ab"]
    end

    test "a literal newline stays in the string" do
      assert read("\"a\nb\"") == ["a\nb"]
    end

    test "an unterminated string names its line and column" do
      assert_raise Reader.Error, ~r/line 1, column 5: unterminated string/, fn ->
        read(~S{abc "def})
      end
    end
  end

  describe "characters" do
    test "one plain character" do
      assert read("#\\a #\\Z #\\7 #\\λ") == [{:char, ?a}, {:char, ?Z}, {:char, ?7}, {:char, ?λ}]
    end

    test "named characters" do
      assert read("#\\space #\\newline #\\tab #\\return") == [
               {:char, ?\s},
               {:char, ?\n},
               {:char, ?\t},
               {:char, ?\r}
             ]

      assert read("#\\nul #\\null #\\alarm #\\backspace #\\escape #\\delete #\\rubout") == [
               {:char, 0},
               {:char, 0},
               {:char, 7},
               {:char, 8},
               {:char, 27},
               {:char, 127},
               {:char, 127}
             ]
    end

    test "names are case insensitive" do
      assert read("#\\Space #\\NEWLINE") == [{:char, ?\s}, {:char, ?\n}]
    end

    test "#\\xNN is a hex codepoint" do
      assert read("#\\x41 #\\x3bb") == [{:char, ?A}, {:char, ?λ}]
    end

    test "a delimiter is itself a character" do
      assert read("#\\( #\\) #\\; #\\' #\\\"") == [
               {:char, ?(},
               {:char, ?)},
               {:char, ?;},
               {:char, ?'},
               {:char, ?"}
             ]
    end

    test "a character stops at the next delimiter" do
      assert read("(#\\a #\\b)") == [[{:char, ?a}, {:char, ?b}]]
      assert read("'#\\a") == [[sym("quote"), {:char, ?a}]]
    end

    test "an unknown name is an error" do
      assert_raise Reader.Error, ~r/unknown character name #\\nope/, fn -> read("#\\nope") end
      assert_raise Reader.Error, ~r/unterminated character literal/, fn -> read("#\\") end
    end
  end

  describe "comments" do
    test "a line comment runs to the newline" do
      assert read("1 ; two\n3") == [1, 3]
      assert read("; only a comment") == []
    end

    test "a block comment nests" do
      assert read("#| a |# 7") == [7]
      assert read("#| a #| b |# c |# 7") == [7]
      assert read("#|a|#7") == [7]
      assert read("(1 #| two |# 3)") == [[1, 3]]
    end

    test "a block comment counts the lines it covers" do
      assert_raise Reader.Error, ~r/line 3, column 2: unexpected \)/, fn ->
        read("#| one\ntwo |#\n )")
      end
    end

    test "an unterminated block comment is an error" do
      assert_raise Reader.Error, ~r/unterminated block comment/, fn -> read("#| a") end
      assert_raise Reader.Error, ~r/unterminated block comment/, fn -> read("#| a #| b |#") end
    end

    test "#; drops the next form" do
      assert read("#;(a b) c") == [sym("c")]
      assert read("(1 #;2 3)") == [[1, 3]]
      assert read("(1 #;(2 3) 4)") == [[1, 4]]
      assert read("#;#;1 2 3") == [3]
      assert read("(a . #;junk b)") == [[sym("a") | sym("b")]]
    end
  end

  describe "quote and friends" do
    test "the four prefixes" do
      assert read("'a") == [[sym("quote"), sym("a")]]
      assert read("`a") == [[sym("quasiquote"), sym("a")]]
      assert read(",a") == [[sym("unquote"), sym("a")]]
      assert read(",@a") == [[sym("unquote-splicing"), sym("a")]]
    end

    test "prefixes stack and nest" do
      assert read("''a") == [[sym("quote"), [sym("quote"), sym("a")]]]

      assert read("`(a ,b ,@c)") ==
               [
                 [
                   sym("quasiquote"),
                   [sym("a"), [sym("unquote"), sym("b")], [sym("unquote-splicing"), sym("c")]]
                 ]
               ]
    end

    # the old reader had no delimiter for , or ` — ",x" came back as one symbol
    test "a prefix ends the symbol before it" do
      assert read("(a,b)") == [[sym("a"), [sym("unquote"), sym("b")]]]
      assert read("(a`b)") == [[sym("a"), [sym("quasiquote"), sym("b")]]]
    end

    test "a prefix with nothing after it is an error" do
      assert_raise Reader.Error, ~r/end of input/, fn -> read("'") end
      assert_raise Reader.Error, ~r/end of input/, fn -> read(",@") end
    end
  end

  describe "lists and dotted pairs" do
    test "nesting" do
      assert read("(1 (2 (3)) ())") == [[1, [2, [3]], []]]
    end

    test "a dot makes an improper list" do
      assert read("(a . b)") == [[sym("a") | sym("b")]]
      assert read("(a b . c)") == [[sym("a"), sym("b") | sym("c")]]
    end

    test "a list tail after the dot flattens" do
      assert read("(a . (b c))") == [[sym("a"), sym("b"), sym("c")]]
      assert read("(a . ())") == [[sym("a")]]
    end

    test "a lone dot is only special inside a list" do
      assert read("(a . b)") == [[sym("a") | sym("b")]]
      assert_raise Reader.Error, ~r/unexpected \. outside a list/, fn -> read(".") end
      assert read("(... a)") == [[sym("..."), sym("a")]]
    end

    test "a malformed dotted pair names its position" do
      assert_raise Reader.Error,
                   ~r/line 1, column 2: a dotted pair needs a value before the \./,
                   fn ->
                     read("(. b)")
                   end

      assert_raise Reader.Error,
                   ~r/line 1, column 8: a dotted pair takes one value after the \./,
                   fn ->
                     read("(a . b c)")
                   end
    end

    test "unterminated and unopened lists" do
      assert_raise Reader.Error, ~r/line 1, column 1: unterminated list/, fn -> read("(1 2") end
      assert_raise Reader.Error, ~r/unexpected \)/, fn -> read(")") end
      assert_raise Reader.Error, ~r/end of input/, fn -> read("(a .") end
    end
  end

  describe "positions" do
    test "the error names the line and the column of the offending token" do
      e = assert_raise Reader.Error, fn -> read("(a)\n(b)\n  )") end
      assert e.line == 3
      assert e.column == 3
      assert e.message =~ "line 3, column 3"
    end

    test "an unterminated list points at the open paren" do
      e = assert_raise Reader.Error, fn -> read("(a\n b\n c") end
      assert {e.line, e.column} == {1, 1}
    end

    test "a column counts characters, not bytes" do
      e = assert_raise Reader.Error, fn -> read("(λλλ #foo)") end
      assert e.column == 6
    end

    test "a comment does not lose the line count" do
      e = assert_raise Reader.Error, fn -> read("; one\n; two\n)") end
      assert e.line == 3
    end
  end

  describe "read_one" do
    test "returns the form and the unread text" do
      assert {:ok, form, rest} = Reader.read_one("(a b) (c) ")
      assert form == [sym("a"), sym("b")]
      assert String.trim(rest) == "(c)"
      assert Reader.read_all(rest) == [[sym("c")]]
    end

    test "reads through a leading comment" do
      assert {:ok, 1, rest} = Reader.read_one("; hi\n1 2")
      assert String.trim(rest) == "2"
    end

    test "text that stops mid-form asks for more" do
      assert {:incomplete, _} = Reader.read_one("(a b")
      assert {:incomplete, _} = Reader.read_one(~S{"abc})
      assert {:incomplete, _} = Reader.read_one("'")
      assert {:incomplete, _} = Reader.read_one("")
      assert {:incomplete, _} = Reader.read_one("   \n ")
    end

    test "the error carries the incomplete flag" do
      for src <- ["(a b", ~S{"abc}, "|abc", "#| a", "#\\"] do
        e = assert_raise Reader.Error, fn -> Reader.read_all(src) end
        assert e.incomplete, "expected #{inspect(src)} to read as incomplete"
      end

      for src <- [")", "#foo", "(. b)", "#\\nope"] do
        e = assert_raise Reader.Error, fn -> Reader.read_all(src) end
        refute e.incomplete, "expected #{inspect(src)} to be a hard error"
      end
    end

    test "a real syntax error reports now" do
      assert {:error, %Reader.Error{line: 1, column: 1}} = Reader.read_one(")")
      assert {:error, %Reader.Error{}} = Reader.read_one("#foo")
    end
  end

  describe "printing" do
    test "improper lists print with a dot" do
      assert show("'(1 . 2)") == "(1 . 2)"
      assert show("'(1 2 . 3)") == "(1 2 . 3)"
      assert show("(cons 1 2)") == "(1 . 2)"
      assert show("(cons 1 '(2))") == "(1 2)"
    end

    test "characters print by name" do
      assert show("'#\\a") == "#\\a"
      assert show("'#\\space") == "#\\space"
      assert show("'#\\newline") == "#\\newline"
      assert show("(integer->char 955)") == "#\\λ"
    end

    test "display shows the bare character" do
      assert Printer.display({:char, ?a}) == "a"
      assert Printer.display([{:char, ?a} | {:char, ?b}]) == "(a . b)"
    end

    test "read then print round-trips" do
      for src <- ["(1 2 3)", "(1 . 2)", "(1 2 . 3)", "(a (b . c) d)", "#\\space", "#\\a", "()"] do
        assert show("'" <> src) == src
      end
    end
  end

  describe "pairs at the value level" do
    test "car and cdr reach into a dotted pair" do
      assert run("(car '(1 . 2))") == 1
      assert run("(cdr '(1 . 2))") == 2
      assert run("(cdr '(1 2 . 3))") == [2 | 3]
    end

    test "list? tells a proper list from a pair" do
      assert run("(list? '(1 2))") == true
      assert run("(list? '())") == true
      assert run("(list? (cons 1 2))") == false
      assert run("(list? 5)") == false
    end

    test "pair? and null? still hold" do
      assert run("(pair? (cons 1 2))") == true
      assert run("(null? '())") == true
    end

    test "a dotted pair is data, not a call" do
      assert err("(+ . 1)") =~ "cannot call a dotted pair"
    end
  end

  describe "characters at the value level" do
    test "the character predicates and conversions" do
      assert run("(char? #\\a)") == true
      assert run("(char? \"a\")") == false
      assert run("(char->integer #\\A)") == 65
      assert run("(integer->char 65)") == {:char, ?A}
      assert run("(char->string #\\λ)") == "λ"
      assert run("(string->char \"abc\")") == {:char, ?a}
    end

    test "a character evaluates to itself and compares by value" do
      assert run("#\\a") == {:char, ?a}
      assert run("(equal? #\\a #\\a)") == true
      assert run("(equal? #\\a #\\b)") == false
    end
  end

  describe "quasiquote" do
    test "with no unquote it is quote" do
      assert run("`(1 2 3)") == [1, 2, 3]
      assert run("`a") == sym("a")
    end

    test "unquote evaluates one hole" do
      assert run("(define x 5) `(a ,x b)") == [sym("a"), 5, sym("b")]
      assert run("`,(+ 1 2)") == 3
    end

    test "unquote-splicing opens a list into the template" do
      assert run("`(1 ,@(list 2 3) 4)") == [1, 2, 3, 4]
      assert run("`(,@(list 1 2))") == [1, 2]
      assert run("`(1 ,@'())") == [1]
    end

    test "splicing a non-list is an error" do
      assert err("`(1 ,@2)") =~ "unquote-splicing needs a list"
    end

    test "it reaches into nested lists" do
      assert run("(define x 9) `(a (b ,x) c)") == [sym("a"), [sym("b"), 9], sym("c")]
    end

    test "an unquote in the tail is the dotted tail" do
      assert run("`(1 . ,(+ 1 1))") == [1 | 2]
      assert run("`(1 2 . ,(list 9))") == [1, 2, 9]
      assert run("`(a . b)") == [sym("a") | sym("b")]
    end

    test "a nested quasiquote keeps its own template" do
      assert show("`(a `(b ,(c)))") == "(a (quasiquote (b (unquote (c)))))"
      assert show("``(a ,,(+ 1 2))") == "(quasiquote (a (unquote 3)))"
    end

    test "vectors of values survive" do
      assert run("(define f (lambda (n) (* n 2))) `(x ,(f 4))") == [sym("x"), 8]
    end
  end

  describe "the reader still reads what it always read" do
    test "the shipped Scheme library parses" do
      for f <- Path.wildcard(Path.join(__DIR__, "../../../aimax_core/priv/*.scm")) do
        forms = f |> File.read!() |> Reader.read_all()
        assert is_list(forms) and forms != [], "#{Path.basename(f)} read as nothing"
      end
    end

    test "every form in the library is a list or an atom, never a stray dot" do
      for f <- Path.wildcard(Path.join(__DIR__, "../../../aimax_core/priv/*.scm")),
          form <- f |> File.read!() |> Reader.read_all() do
        assert is_list(form),
               "#{Path.basename(f)}: top-level form is not a list: #{inspect(form)}"
      end
    end
  end
end
