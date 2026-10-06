defmodule Compos.TsHighlightLinesTest do
  use ExUnit.Case

  alias Compos.Core.TS

  @lines ["defmodule Foo do", "  def bar(x), do: x + 1", "end"]

  test "a hunk side gets one run list per line, with scopes" do
    rows = TS.highlight_lines("elixir", @lines)
    assert length(rows) == 3
    assert Enum.any?(List.first(rows), fn {_, _, scope} -> scope == "keyword" end)
  end

  # The compiled query is cached per language. Before the cache every call
  # compiled the Elixir query again, about 50ms each, so a diff of 40 hunks
  # held the UI lane for seconds. 80 calls stay well under one second.
  test "repeated calls do not recompile the query" do
    TS.highlight_lines("elixir", @lines)
    {us, rows} = :timer.tc(fn -> for _ <- 1..80, do: TS.highlight_lines("elixir", @lines) end)
    assert Enum.all?(rows, &(&1 == List.first(rows)))
    assert div(us, 1000) < 1000
  end

  test "the stateless and the stateful paths colour the same text alike" do
    text = Enum.join(@lines, "\n")
    stateless = TS.ts_highlight("elixir", text)

    name = "ts-hl-#{System.unique_integer([:positive])}"
    {:ok, _} = Compos.Core.create_buffer(name, text: text)
    Compos.Core.Buffer.set_local(name, "ts-lang", "elixir")
    assert Compos.Core.Buffer.ts_highlight(name) == stateless
  end
end
