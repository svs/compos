defmodule Aimax.SchemeSuiteTest do
  @moduledoc """
  Runs the Scheme test suite in priv/tests.

  Policy this editor decides in Scheme is tested in Scheme: the test calls
  the function and reads the value, with no keystroke in between. This
  module is the bridge that puts those tests in CI.

  One eval per test, so a test that raises fails alone and the rest still
  run. A new file in priv/tests needs no change here.
  """

  use ExUnit.Case

  alias Aimax.Core.Session

  defp eval!(code) do
    {:ok, out} = Session.eval(code)
    out
  end

  # symbols print as a bare list: (a b c)
  defp names do
    eval!("(begin (load-tests!) (test-names))")
    |> String.trim_leading("(")
    |> String.trim_trailing(")")
    |> String.split(" ", trim: true)
  end

  test "the Scheme suite passes" do
    found = names()

    assert found != [], "priv/tests registered no tests — did load-tests! find the directory?"

    failures =
      for name <- found,
          result = Session.eval("(run-test '#{name})"),
          reduced = reduce(name, result),
          reduced != nil,
          do: reduced

    assert failures == [], "\n" <> Enum.join(failures, "\n")
  end

  # "()" is a pass. Anything else is the test's own report, or the eval
  # died — which is a failure of that test and not of this one.
  defp reduce(_name, {:ok, "()"}), do: nil
  defp reduce(name, {:ok, out}), do: "  #{name}\n      #{out}"
  defp reduce(name, {:error, msg}), do: "  #{name}\n      raised: #{msg}"
end
