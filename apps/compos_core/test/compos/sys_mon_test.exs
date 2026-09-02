defmodule Compos.Core.SysMonTest do
  use ExUnit.Case, async: false

  alias Compos.Core.SysMon

  defp get(plist, key) do
    case Enum.drop_while(plist, &(&1 != {:sym, key})) do
      [_, value | _] -> value
      _ -> nil
    end
  end

  test "a sample names every scheduler and carries the VM counters" do
    sample = SysMon.sample()
    normal = :erlang.system_info(:schedulers)

    assert length(get(sample, "schedulers")) == normal
    assert length(get(sample, "dirty-cpu")) == :erlang.system_info(:dirty_cpu_schedulers)
    assert Enum.all?(get(sample, "schedulers"), &(&1 in 0..100))
    assert get(sample, "process-count") > 0
    assert get(get(sample, "memory"), "total") > 0
    assert is_binary(get(get(sample, "os"), "load1"))
    assert is_list(get(get(sample, "os"), "disks"))
  end

  test "the second sample reports rates since the first" do
    SysMon.sample()
    Enum.reduce(1..200_000, 0, &(&1 + &2))
    sample = SysMon.sample()
    assert get(sample, "reductions-rate") >= 0
    assert is_integer(get(sample, "io-in-rate"))
  end

  test "the process table filters by name, sorts by a key, and bounds the rows" do
    result = SysMon.processes(5, "memory", "Compos.Core.Session")
    rows = get(result, "rows")

    assert get(result, "count") > 0
    assert get(result, "matched") >= 1
    assert length(rows) <= 5
    assert Enum.all?(rows, &String.contains?(get(&1, "name"), "Compos.Core.Session"))

    by_memory = SysMon.processes(20, "memory", "")
    memories = Enum.map(get(by_memory, "rows"), &get(&1, "memory"))
    assert memories == Enum.sort(memories, :desc)

    by_name = SysMon.processes(20, "name", "")
    names = Enum.map(get(by_name, "rows"), &String.downcase(get(&1, "name")))
    assert names == Enum.sort(names)
  end

  defmodule Server do
    use GenServer
    def init(state), do: {:ok, state}
  end

  test "a GenServer row wears its module, not proc_lib" do
    {:ok, pid} = GenServer.start_link(Server, nil)
    text = pid |> :erlang.pid_to_list() |> to_string()
    rows = SysMon.processes(10_000, "name", text) |> get("rows")
    assert [row] = rows
    assert get(row, "pid") == text
    assert get(row, "name") == "Compos.Core.SysMonTest.Server.init/1"
    GenServer.stop(pid)
  end

  test "process info reads one process and kill ends it" do
    pid = spawn(fn -> receive do: (:never -> :ok) end)
    text = pid |> :erlang.pid_to_list() |> to_string()

    info = SysMon.process_info(text)
    assert get(info, "pid") == text
    assert get(info, "status") in ["waiting", "runnable", "running"]
    assert is_integer(get(info, "memory"))

    assert SysMon.kill(text) == true
    refute Process.alive?(pid)
    assert SysMon.process_info(text) == false
    assert SysMon.kill(text) == false
    assert SysMon.kill("not a pid") == false
  end
end
