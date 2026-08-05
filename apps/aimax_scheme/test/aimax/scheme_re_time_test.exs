defmodule Aimax.SchemeReTimeTest do
  use ExUnit.Case, async: true

  alias Aimax.Scheme

  defp run(src) do
    {:ok, val, _} = Scheme.eval_string(Scheme.new(), src)
    val
  end

  test "re-match? and re-match" do
    assert run(~S{(re-match? "^\*+ " "** hi")}) == true
    assert run(~S{(re-match? "^\*+ " "no")}) == false
    assert run(~S{(re-match "^(\*+)[ ]" "** hi")}) == ["** ", "**"]
    assert run(~S{(re-match "x" "abc")}) == false
  end

  test "re-find returns byte offsets" do
    assert run(~S{(re-find "l+" "hello" 0)}) == [2, 4]
    assert run(~S{(re-find "l+" "hello" 4)}) == false
    # multibyte before the match: offsets are bytes, not graphemes
    assert run(~S{(re-find "x" "éx" 0)}) == [2, 3]
  end

  test "re-find* finds all matches" do
    assert run(~S{(re-find* "o+" "foo boo")}) == [[1, 3], [5, 7]]
    assert run(~S{(re-find* "z" "foo")}) == []
  end

  test "re-groups gives per-group byte ranges" do
    assert run(~S{(re-groups "(a+)(b+)" "xaabbb" 0)}) == [[1, 6], [1, 3], [3, 6]]
    assert run(~S{(re-groups "(a)|(b)" "b" 0)}) == [[0, 1], false, [0, 1]]
    assert run(~S{(re-groups "z" "ab" 0)}) == false
  end

  test "re-replace and re-replace-all" do
    assert run(~S{(re-replace "o" "foo" "0")}) == "f0o"
    assert run(~S{(re-replace-all "o" "foo" "0")}) == "f00"
    assert run(~S{(re-replace-all "(a)b" "ab ab" "\1!")}) == "a! a!"
  end

  test "bad regex raises a scheme error" do
    assert {:error, msg} = Scheme.eval_string(Scheme.new(), ~S{(re-match? "(" "x")})
    assert msg =~ "bad regex"
  end

  test "time round-trip and formatting" do
    assert is_integer(run("(current-time)"))

    src = """
    (let* ((t (parts->time 2026 8 6 12 0))
           (p (time->parts t)))
      (list (list-ref p 0) (list-ref p 1) (list-ref p 2)
            (list-ref p 3) (list-ref p 4) (list-ref p 5)))
    """

    assert run(src) == [2026, 8, 6, 12, 0, 4]

    assert run("(format-time (parts->time 2026 8 6 12 0) \"%Y-%m-%d %a\")") ==
             "2026-08-06 Thu"

    assert run("(format-time (time+ (parts->time 2026 8 6 12 0) 1) \"%Y-%m-%d\")") ==
             "2026-08-07"
  end
end
