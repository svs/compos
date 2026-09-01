defmodule Compos.HooksSchemeTest do
  @moduledoc """
  Runs priv/tests/hook-test.scm alone, and checks the one hook the
  Elixir side must run: post-command-hook after self-insert.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.{Editor, KeyDispatch, Session}

  @file_ Path.join([:code.priv_dir(:compos_core), "tests", "hook-test.scm"])
  @lane {:scheme_suite, __MODULE__}

  defp eval!(code) do
    {:ok, out} = Session.eval(code, nil, 30_000, @lane)
    out
  end

  # the names come from the file, not from (test-names): another test in
  # the same VM may have loaded every file already
  defp names do
    Regex.scan(~r/\(deftest '([^\s()]+)/, File.read!(@file_))
    |> Enum.map(fn [_, name] -> name end)
  end

  test "hook-test.scm passes" do
    eval!(~s{(load "#{@file_}")})
    names = names()
    assert names != [], "the file declares no test"

    for name <- names do
      case Session.eval("(run-test '#{name})", nil, 30_000, @lane) do
        {:ok, "()"} -> :ok
        {:ok, failures} -> flunk("#{name} failed: #{failures}")
        {:error, err} -> flunk("#{name} raised: #{err}")
      end
    end
  end

  test "post-command-hook runs after self-insert" do
    name = "*hook-self-insert-#{System.unique_integer([:positive])}*"
    {:ok, ^name} = Compos.Core.create_buffer(name)
    Editor.minibuffer_close()
    Editor.set_window_buffer(name)

    eval!("(define *hook-test-typed* 0)")
    eval!("(define (hook-test-count!) (set! *hook-test-typed* (+ *hook-test-typed* 1)))")
    eval!("(add-hook! 'post-command-hook 'hook-test-count!)")

    try do
      KeyDispatch.handle_key("a")
      assert eval!("*hook-test-typed*") == "1"
    after
      eval!("(remove-hook! 'post-command-hook 'hook-test-count!)")
      Compos.Core.kill_buffer(name)
    end
  end
end
