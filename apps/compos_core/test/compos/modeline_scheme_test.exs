defmodule Compos.ModelineSchemeTest do
  @moduledoc """
  Runs priv/tests/modeline-test.scm alone: compact buffer names, and the
  summary and jj segments of the dashboard line.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.Session

  @file_ Path.join([:code.priv_dir(:compos_core), "tests", "modeline-test.scm"])
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

  test "modeline-test.scm passes" do
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
end
