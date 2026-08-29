defmodule Compos.SessionSafeTest do
  @moduledoc """
  A primitive fed garbage must fail the eval, never the Session — its
  crash cascades into an app shutdown and the editor 500s everywhere.
  """

  use ExUnit.Case

  alias Compos.Core.Session

  test "a raising primitive fails the eval, not the editor" do
    # String.starts_with?/2 raises ArgumentError on a non-binary pattern
    assert {:error, msg} = Session.eval(~s{(string-prefix? #f "x")})
    assert msg =~ ~r/argument|pattern/i

    # the session is still alive and evaluating
    assert {:ok, "3"} = Session.eval("(+ 1 2)")
  end

  test "a dead-process exit inside a primitive also fails only the eval" do
    Session.eval(~s{(buffer-create "safe-victim")})
    assert {:ok, _} = Session.eval(~s{(buffer-kill! "safe-victim")})
    # touching the killed buffer exits in the Buffer GenServer call.
    # buffer-text reads a dormant name as "" now, so ask for the overlays:
    # those still need the process.
    assert {:error, _} = Session.eval(~s{(buffer-overlays "safe-victim")})
    assert {:ok, "3"} = Session.eval("(+ 1 2)")
  end
end
