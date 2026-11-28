defmodule Compos.ProfilerTest do
  @moduledoc """
  The mechanism under `M-x profile`: arm the call_time tracer, run work,
  read where the time went, and leave nothing traced behind.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.Profiler
  alias Compos.Core.SysMon

  # the profile covers one small module, so the assertions name a
  # function the test itself calls
  @covered ["Elixir.Compos.Core.SysMon"]
  @mfa {SysMon, :to_plist, 1}

  setup do
    on_exit(fn -> Profiler.cancel() end)
    Profiler.cancel()
    :ok
  end

  defp fetch(plist, key) when is_list(plist) do
    plist
    |> Enum.chunk_every(2)
    |> Enum.reduce(nil, fn
      [{:sym, ^key}, value], _acc -> value
      _, acc -> acc
    end)
  end

  test "nothing armed, nothing to report" do
    refute Profiler.armed?()
    assert Profiler.stop() == false
    assert Profiler.cancel() == false
  end

  test "a profile names the functions that ran and what the command cost" do
    :ok = Profiler.start(@covered)
    assert Profiler.armed?()

    Enum.each(1..200, fn n -> SysMon.to_plist(%{n: n}) end)

    report = Profiler.stop()
    refute Profiler.armed?()

    functions = fetch(report, "functions")
    assert is_list(functions)

    row = Enum.find(functions, fn f -> fetch(f, "function") == "to_plist/1" end)
    assert row, "to_plist/1 is missing from #{inspect(Enum.map(functions, &fetch(&1, "function")))}"
    assert fetch(row, "module") == "Compos.Core.SysMon"
    assert fetch(row, "calls") >= 200

    assert fetch(report, "wall-us") > 0
    assert fetch(report, "at-ms") > 0
    assert fetch(report, "calls") >= 200
    assert fetch(report, "functions-seen") >= 1
    # the prefix covers SysMon and its submodules, and the editor's own
    # monitors may call those while the profile runs
    assert fetch(report, "modules") >= 1
    assert fetch(report, "modules-called") >= 1
    assert fetch(report, "reductions") > 0
    assert is_integer(fetch(report, "gcs"))
    assert is_integer(fetch(report, "memory"))

    processes = fetch(report, "processes")
    assert is_list(processes)
    assert processes != []
    assert Enum.all?(processes, fn p -> fetch(p, "reductions") > 0 end)
    assert Enum.all?(processes, fn p -> String.starts_with?(fetch(p, "pid"), "<") end)
  end

  test "a stopped profile leaves no counter behind" do
    :ok = Profiler.start(@covered)
    assert {:call_count, n} = :erlang.trace_info(@mfa, :call_count)
    assert is_integer(n)

    _ = Profiler.stop()
    assert {:call_count, off} = :erlang.trace_info(@mfa, :call_count)
    refute is_integer(off)
  end

  test "cancel disarms without a report, and arming twice keeps one trace" do
    :ok = Profiler.start(@covered)
    :ok = Profiler.start(@covered)
    assert Profiler.armed?()

    assert Profiler.cancel() == true
    refute Profiler.armed?()
    assert {:call_count, off} = :erlang.trace_info(@mfa, :call_count)
    refute is_integer(off)
  end

  test "an empty prefix list falls back to the editor's own modules" do
    :ok = Profiler.start([])
    report = Profiler.stop()
    assert fetch(report, "modules") > 1
  end
end
