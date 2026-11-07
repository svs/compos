defmodule Compos.SchemeOptsTest do
  use ExUnit.Case, async: true

  alias Compos.Core.SchemeOpts

  test "an option plist reads as a map with string keys" do
    plist = [{:sym, "mode"}, "diff", {:sym, "limit"}, 10]
    assert SchemeOpts.map(plist) == %{"mode" => "diff", "limit" => 10}
  end

  test "a bare key reads as true" do
    assert SchemeOpts.map([{:sym, "hidden"}]) == %{"hidden" => true}
  end

  test "a value converter turns each option value" do
    plist = [{:sym, "modes"}, [{:sym, "fundamental"}, {:sym, "scheme"}]]

    assert SchemeOpts.map(plist, &SchemeOpts.strings/1) == %{
             "modes" => ["fundamental", "scheme"]
           }
  end

  test "a non-list option argument is no options" do
    assert SchemeOpts.map(false) == %{}
    assert SchemeOpts.map(nil) == %{}
  end

  test "a symbol reads as its name" do
    assert SchemeOpts.plain({:sym, "all"}) == "all"
    assert SchemeOpts.plain("text") == "text"
  end

  test "an absent option is nil, not false" do
    assert SchemeOpts.string(false) == nil
    assert SchemeOpts.string({:sym, "HEAD"}) == "HEAD"
  end

  test "a list of symbols reads as a list of names" do
    assert SchemeOpts.strings([{:sym, "name"}, {:sym, "mode"}]) == ["name", "mode"]
    assert SchemeOpts.strings({:sym, "recent"}) == "recent"
  end

  test "the limit is the integer at the front of the argument list" do
    assert SchemeOpts.integer([5, :extra]) == 5
    assert SchemeOpts.integer([]) == nil
    assert SchemeOpts.integer([{:sym, "five"}]) == nil
  end

  test "a header set written as pairs reads as pairs with text values" do
    pairs = [["authorization", "Bearer t"], ["X-Trace-Id", 7]]

    assert SchemeOpts.pairs(pairs) == [
             {"authorization", "Bearer t"},
             {"X-Trace-Id", "7"}
           ]
  end

  test "a map of headers reads the same way" do
    assert SchemeOpts.pairs(%{"content-type" => true}) == [{"content-type", "true"}]
  end
end
