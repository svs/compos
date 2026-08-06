defmodule Aimax.TsIncrementalTest do
  use ExUnit.Case

  alias Aimax.Core.{Buffer, TS}

  @initial """
  defmodule Foo do
    def bar(x) do
      x + 1
    end
  end
  """

  # ground truth: a fresh stateless parse of the buffer's current text
  defp reference(name), do: TS.ts_highlight("elixir", Buffer.text(name))

  defp new_buffer do
    name = "ts-inc-#{System.unique_integer([:positive])}"
    {:ok, _} = Aimax.Core.create_buffer(name, text: @initial)
    Buffer.set_local(name, "ts-lang", "elixir")
    name
  end

  test "incremental spans match a fresh reparse across edits" do
    name = new_buffer()
    assert Buffer.ts_highlight(name) == reference(name)

    # single-char insert (the per-keystroke path)
    :ok = Buffer.insert_at(name, 20, "z")
    assert Buffer.ts_highlight(name) == reference(name)

    # multi-line insert
    :ok = Buffer.insert_at(name, 0, "# header\ndefp = 1\n")
    assert Buffer.ts_highlight(name) == reference(name)

    # delete spanning a line boundary
    :ok = Buffer.delete_range(name, 5, 12)
    assert Buffer.ts_highlight(name) == reference(name)

    # multibyte content before an edit point
    :ok = Buffer.insert_at(name, 0, "# héllo wörld\n")
    :ok = Buffer.insert_at(name, 30, "q")
    assert Buffer.ts_highlight(name) == reference(name)
  end

  test "undo invalidates the tree and spans stay correct" do
    name = new_buffer()
    _ = Buffer.ts_highlight(name)

    :ok = Buffer.insert_at(name, 20, "zzz")
    _ = Buffer.ts_highlight(name)

    :ok = Buffer.undo(name)
    assert Buffer.ts_highlight(name) == reference(name)
  end

  test "buffers without ts-lang highlight to []" do
    name = "ts-none-#{System.unique_integer([:positive])}"
    {:ok, _} = Aimax.Core.create_buffer(name, text: "plain text")
    assert Buffer.ts_highlight(name) == []
  end

  test "spans are cached per version, recomputed after an edit" do
    name = new_buffer()
    first = Buffer.ts_highlight(name)
    assert Buffer.ts_highlight(name) == first

    :ok = Buffer.insert_at(name, 0, "x = 1\n")
    refute Buffer.ts_highlight(name) == first
  end
end
