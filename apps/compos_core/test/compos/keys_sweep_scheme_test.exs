defmodule Compos.KeysSweepSchemeTest do
  @moduledoc """
  Runs priv/tests/keys-sweep-test.scm alone: every key of every core mode resolves through the ladder.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.Session

  @file_ Path.join([:code.priv_dir(:compos_core), "tests", "keys-sweep-test.scm"])
  @lane {:scheme_suite, __MODULE__}

  defp eval!(code) do
    {:ok, out} = Session.eval(code, nil, 30_000, @lane)
    out
  end

  defp names do
    Regex.scan(~r/\(deftest '([^\s()]+)/, File.read!(@file_))
    |> Enum.map(fn [_, name] -> name end)
  end

  @tag timeout: 120_000
  test "keys-sweep-test.scm passes" do
    eval!(~s{(load "#{@file_}")})
    names = names()
    assert names != [], "the file declares no test"

    for name <- names do
      case Session.eval("(run-test '#{name})", nil, 60_000, @lane) do
        {:ok, "()"} -> :ok
        {:ok, failures} -> flunk("#{name} failed: #{failures}")
        {:error, err} -> flunk("#{name} raised: #{err}")
      end
    end
  end
end
