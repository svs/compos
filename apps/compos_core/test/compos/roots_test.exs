defmodule Compos.Core.RootsTest do
  use ExUnit.Case, async: false

  alias Compos.Core.Roots

  test "a root holds its value until it is dropped" do
    key = {:roots_test, make_ref()}
    assert Roots.put(key, :value)
    assert Roots.get(key) == :value
    assert {key, :value} in Roots.all()
    assert Roots.drop(key) == :ok
    assert Roots.get(key) == nil
    assert Roots.drop(key) == :ok
  end

  test "a take hands the value to one caller only" do
    key = {:roots_test, make_ref()}
    Roots.put(key, :once)

    takes =
      1..20
      |> Enum.map(fn _ -> Task.async(fn -> Roots.take(key) end) end)
      |> Enum.map(&Task.await/1)

    assert Enum.count(takes, &(&1 == :once)) == 1
    assert Roots.get(key) == nil
  end

  # A hold keeps the frames alive and nothing else: the table held a
  # second copy of each callback body and task result before.
  test "a hold stores the frames a value captures, and no copy of the value" do
    alias Compos.Scheme

    interp = Scheme.new()

    {:ok, counter, interp} =
      Scheme.eval_string(interp, "(let ((n 0)) (lambda () (set! n (+ n 1)) n))")

    key = {:roots_test, make_ref()}
    value = [counter, String.duplicate("x", 100_000)]
    assert Roots.hold(key, value)
    on_exit(fn -> Roots.drop(key) end)

    held = Roots.get(key)
    assert [{:closure, [], [], _frame}] = held
    assert :erts_debug.flat_size(held) < 100

    # the held frames are what the sweep needs: the counter keeps its state
    swept = Scheme.gc(interp, [held])
    assert {:ok, 1, _} = Scheme.call(swept, counter, [])
  end

  test "a hold of a value with no closure stores nothing to walk" do
    key = {:roots_test, make_ref()}
    assert Roots.hold(key, {:ok, [1, 2, "text"]})
    assert Roots.get(key) == []
    Roots.drop(key)
  end
end
