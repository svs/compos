defmodule Compos.DiffBlockRestartTest do
  @moduledoc """
  A waiting diff block survives a restart. The record rides the buffer's
  checkpoint next to the text it points into, so after the buffer comes
  back the verbs still work. Eviction is the same lifecycle: checkpoint,
  terminate, wake.
  """

  use ExUnit.Case

  alias Compos.Core.{Buffer, Session}

  defp eval!(code) do
    case Session.eval(code, nil, 30_000, {:test, :diff_block_restart}) do
      {:ok, out} -> out
      other -> flunk("eval failed: #{inspect(other)}")
    end
  end

  defp evict(name) do
    :ok = Buffer.checkpoint_now(name)
    [{pid, _}] = Registry.lookup(Compos.Core.BufferRegistry, name)
    :ok = DynamicSupervisor.terminate_child(Compos.Core.BufferSupervisor, pid)
  end

  test "a waiting diff block still accepts after eviction" do
    name = "diff-restart-#{System.unique_integer([:positive])}"

    assert eval!("""
           (let ((b "#{name}"))
             (test-buffer! b "old words here\\n")
             (diff-block-propose! b 0 14 "old words here" "new words here" ""))
           """) == "ok"

    evict(name)

    assert Buffer.text(name) =~ "```diff theirs"

    assert eval!("(if (diff-block-pending \"#{name}\") 'held 'lost)") == "held"

    eval!("(diff-block-accept! \"#{name}\")")
    assert Buffer.text(name) == "new words here\n"

    Compos.Core.kill_buffer(name)
  end

  test "a waiting diff block still rejects after eviction" do
    name = "diff-restart-#{System.unique_integer([:positive])}"

    assert eval!("""
           (let ((b "#{name}"))
             (test-buffer! b "old words here\\n")
             (diff-block-propose! b 0 14 "old words here" "better words" ""))
           """) == "ok"

    evict(name)

    eval!("(diff-block-reject! \"#{name}\")")
    assert Buffer.text(name) == "old words here\n"

    Compos.Core.kill_buffer(name)
  end
end
