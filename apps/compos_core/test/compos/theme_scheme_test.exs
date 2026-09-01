defmodule Compos.ThemeSchemeTest do
  @moduledoc """
  Runs priv/tests/theme-test.scm alone. The theme policy is Scheme; this
  file is the focused bridge for it, so a face change needs no suite run.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.Session

  @file_ Path.join([:code.priv_dir(:compos_core), "tests", "theme-test.scm"])
  @lane {:scheme_suite, __MODULE__}

  defp eval!(code) do
    {:ok, out} = Session.eval(code, nil, 30_000, @lane)
    out
  end

  defp names do
    eval!("(test-names)")
    |> String.trim_leading("(")
    |> String.trim_trailing(")")
    |> String.split(" ", trim: true)
  end

  test "theme-test.scm passes" do
    before = names()
    eval!(~s{(load "#{@file_}")})
    names = names() -- before

    assert names != [], "the file registered no test"

    for name <- names do
      assert eval!("(run-test '#{name})") == "()", "#{name} failed"
    end
  end
end
