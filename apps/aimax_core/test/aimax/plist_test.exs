defmodule Aimax.PlistTest do
  use ExUnit.Case, async: true

  alias Aimax.Core.Plist

  test "a shadowed key crosses as the value Scheme reads, not the one it replaced" do
    # Scheme shadows by consing a new pair on the front, and plist-get
    # answers with the first pair. agent-config-append-system builds its
    # system prompt this way, one fragment at a time.
    plist = [{:sym, "systemPrompt"}, "second", {:sym, "systemPrompt"}, "first"]

    assert Plist.to_json(plist) == %{"systemPrompt" => "second"}
  end

  test "a plist without duplicates is unchanged" do
    plist = [{:sym, "a"}, 1, {:sym, "b"}, 2]
    assert Plist.to_json(plist) == %{"a" => 1, "b" => 2}
  end

  test "the rule holds inside a nested plist" do
    plist = [{:sym, "meta"}, [{:sym, "k"}, "new", {:sym, "k"}, "old"]]
    assert Plist.to_json(plist) == %{"meta" => %{"k" => "new"}}
  end
end
