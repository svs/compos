# The Step 3 measurement of docs/SIMPLIFY-AUDIT.md: what a boot pays for
# the buffer store. Two hundred dormant buffers of twenty kilobytes each;
# the bytes their checkpoints and logs take on disk; the time the boot
# scan spends reading and decoding every checkpoint; the time one wake
# spends bringing a buffer back with its text. Not part of the suite (no
# _test suffix); run it by name:
#
#   cd apps/compos_core && MIX_ENV=test mix test test/bench/store_scan_bench.exs
#
defmodule Compos.StoreScanBench do
  use ExUnit.Case, async: false

  alias Compos.Core.{Buffer, BufferHistoryStore, BufferStore}

  @buffers 200
  @wakes 20

  defp text(i) do
    words = ~w(alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu)
    :rand.seed(:exsss, {i, i + 1, i + 2})

    Stream.repeatedly(fn -> Enum.random(words) end)
    |> Enum.take(3_500)
    |> Enum.chunk_every(9)
    |> Enum.map_join("\n", &Enum.join(&1, " "))
  end

  defp eventually(fun, tries \\ 500) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  defp evict(name) do
    :ok = Buffer.checkpoint_now(name)
    [{pid, _}] = Registry.lookup(Compos.Core.BufferRegistry, name)
    :ok = DynamicSupervisor.terminate_child(Compos.Core.BufferSupervisor, pid)
    assert eventually(fn -> not Buffer.exists?(name) end)
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp scan(paths) do
    Enum.each(paths, fn path ->
      {:ok, bin} = File.read(path)
      %{} = :erlang.binary_to_term(bin)
    end)
  end

  test "boot scan and wake cost of two hundred dormant buffers" do
    names = for i <- 1..@buffers, do: "*scan-bench-#{i}*"

    ids =
      for {name, i} <- Enum.with_index(names, 1) do
        {:ok, ^name} = Compos.Core.create_buffer(name)
        Buffer.append(name, text(i), source: :editor)
        Buffer.set_local(name, "mode-name", "text-mode")
        Buffer.set_local(name, "group-id", "bench")
        id = Buffer.id(name)
        evict(name)
        id
      end

    checkpoints = Enum.map(ids, &BufferStore.checkpoint_path/1)
    logs = Enum.map(ids, &BufferHistoryStore.path/1)
    checkpoint_bytes = checkpoints |> Enum.map(&file_size/1) |> Enum.sum()
    log_bytes = logs |> Enum.map(&file_size/1) |> Enum.sum()

    scan_us =
      for _ <- 1..5 do
        {us, :ok} = :timer.tc(fn -> scan(checkpoints) end)
        us
      end
      |> Enum.min()

    wake_us =
      for name <- Enum.take(names, @wakes) do
        {us, _} =
          :timer.tc(fn ->
            {:ok, ^name} = Compos.Core.ensure_buffer(name)
            Buffer.text(name)
          end)

        us
      end

    IO.puts("""

    store scan bench: #{@buffers} dormant buffers of #{div(byte_size(text(1)), 1024)} KB
      checkpoint bytes on disk   #{checkpoint_bytes}
      log bytes on disk          #{log_bytes}
      boot scan of checkpoints   #{div(scan_us, 1000)} ms (best of 5)
      one wake with its text     #{div(Enum.sum(wake_us), length(wake_us) * 1000)} ms mean, #{div(Enum.max(wake_us), 1000)} ms max
    """)

    Enum.each(names, &Compos.Core.kill_buffer/1)
  end
end
