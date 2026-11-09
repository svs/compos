defmodule Compos.BuiltinFaultTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Compos.Scheme

  # A primitive that raises an exception the evaluator does not expect is a
  # fault in the daemon. The caller gets a Scheme error that names the
  # primitive and says so, and the fault goes to the log.
  test "an unexpected exception in a primitive is a daemon fault that names the primitive" do
    interp =
      Scheme.new(primitives: %{"broken" => fn [] -> apply(Compos.NoSuchModule, :f, []) end})

    log =
      capture_log(fn ->
        assert {:error, msg} = Scheme.eval_string(interp, "(broken)")
        assert msg =~ "broken: daemon fault (UndefinedFunctionError)"
      end)

    assert log =~ "broken: daemon fault"
  end

  test "a bad argument to a primitive stays the caller's error" do
    interp = Scheme.new(primitives: %{"one" => fn [x] when is_integer(x) -> x end})
    assert {:error, msg} = Scheme.eval_string(interp, "(one \"a\")")
    assert msg =~ "one:"
    refute msg =~ "daemon fault"
  end
end
