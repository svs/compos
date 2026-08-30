defmodule Compos.PeekTest do
  @moduledoc "The Scheme peek tests, in this daemon: they rearrange windows, so never in the live one."
  use ExUnit.Case

  alias Compos.Core.{Editor, Session}

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    :ok
  end

  test "peek" do
    {:ok, names} = Session.eval("(begin (load-tests!) (filter (lambda (n) (string-contains? (symbol->string n) \"peek\")) (test-names)))")

    for name <- names |> String.trim("(") |> String.trim(")") |> String.split(" ", trim: true) do
      {:ok, out} = Session.eval("(run-test '#{name})", nil, 60_000) |> then(fn {_, v} -> {:ok, inspect(v)} end)
      assert out == ~s{"()"}, "#{name}: #{out}"
    end
  end
end
