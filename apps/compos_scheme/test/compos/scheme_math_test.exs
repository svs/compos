defmodule Compos.Scheme.MathTest do
  use ExUnit.Case, async: true

  alias Compos.Scheme

  defp run(src) do
    {:ok, val, _} = Scheme.eval_string(Scheme.new(), src)
    val
  end

  test "floor, ceiling, round and truncate answer integers" do
    assert run("(list (floor 2.7) (floor -2.2) (floor 7 2) (floor -7 2) (floor 7.5 2))") ==
             [2, -3, 3, -4, 3]

    assert run("(list (ceiling 2.1) (round 2.5) (round -2.5) (truncate -2.7) (round 3))") ==
             [3, 3, -3, -2, 3]
  end

  test "expt keeps integers exact and falls back to floats" do
    assert run("(expt 10 20)") == 100_000_000_000_000_000_000
    assert run("(expt 2 -1)") == 0.5
    assert run("(expt 4 0.5)") == 2.0
  end

  test "log takes an optional base" do
    assert run("(log 1)") == 0.0
    assert run("(log 1000 10)") == 3.0
    assert run("(log 8 2)") == 3.0
    assert_in_delta run("(log 81 3)"), 4.0, 1.0e-12
  end

  test "trigonometry is in radians" do
    assert run("(sin 0)") == 0.0
    assert run("(cos 0)") == 1.0
    assert_in_delta run("(atan 1 1)"), :math.pi() / 4, 1.0e-12
    assert_in_delta run("(* 4 (atan 1))"), run("(float-pi)"), 1.0e-12
  end

  test "sqrt, exp, float and the number predicates" do
    assert run("(list (sqrt 9) (exp 0) (float 3))") == [3.0, 1.0, 3.0]
    assert run("(list (integer? 3) (integer? 3.0) (float? 3.0) (zero? 0) (zero? 0.0) (zero? 1))") ==
             [true, false, true, true, true, false]
  end
end
