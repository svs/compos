defmodule Compos.GraveyardSweepTest do
  @moduledoc """
  The two sweeps of the buffer store (`scheme/packages/housekeeping.scm`
  decides when they run and how long the graveyard keeps an entry).

  A kill buries a checkpoint and a log; the sweep deletes buried pairs
  older than the keep window and leaves the burial log alone. The second
  sweep deletes a log that only repeats a checkpoint: text in the
  checkpoint, recording stopped by a mode. A user's own stop keeps its log.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.{BufferHistoryStore, BufferStore}

  defp uniq(label), do: "zz-sweep-#{label}-#{System.unique_integer([:positive])}"

  defp dead_logs, do: Path.join(BufferHistoryStore.dir(), "dead")

  defp bury(id, days_ago) do
    File.mkdir_p!(BufferStore.graveyard_dir())
    File.mkdir_p!(dead_logs())
    etf = Path.join(BufferStore.graveyard_dir(), id <> ".etf")
    loro = Path.join(dead_logs(), id <> ".loro")
    File.write!(etf, "x")
    File.write!(loro, "x")
    t = System.os_time(:second) - days_ago * 86_400
    File.touch!(etf, t)
    File.touch!(loro, t)
    on_exit(fn -> Enum.each([etf, loro], &File.rm/1) end)
    {etf, loro}
  end

  defp checkpoint(id, cp) do
    File.mkdir_p!(BufferStore.dir())
    File.mkdir_p!(BufferHistoryStore.dir())
    etf = BufferStore.checkpoint_path(id)
    loro = BufferHistoryStore.path(id)
    File.write!(etf, :erlang.term_to_binary(Map.merge(%{version: 2, id: id, name: id}, cp)))
    File.write!(loro, "x")
    on_exit(fn -> Enum.each([etf, loro], &File.rm/1) end)
    {etf, loro}
  end

  test "the graveyard sweep deletes old pairs and keeps young ones" do
    {old_etf, old_loro} = bury(uniq("old"), 40)
    {young_etf, young_loro} = bury(uniq("young"), 1)

    assert BufferStore.sweep_graveyard(30) >= 1

    refute File.exists?(old_etf)
    refute File.exists?(old_loro)
    assert File.exists?(young_etf)
    assert File.exists?(young_loro)
  end

  test "a pair whose log is young stays whole" do
    id = uniq("half")
    {etf, loro} = bury(id, 40)
    File.touch!(loro, System.os_time(:second))

    BufferStore.sweep_graveyard(30)

    assert File.exists?(etf)
    assert File.exists?(loro)
  end

  test "the redundant-history sweep deletes a mode-stopped log and keeps the others" do
    {_, mode_loro} =
      checkpoint(uniq("mode"), %{
        text: "rendered",
        provenance: %{enabled: false, policy_source: "mode"}
      })

    {_, user_loro} =
      checkpoint(uniq("user"), %{
        text: "typed",
        provenance: %{enabled: false, policy_source: "user"}
      })

    # no text in the checkpoint: the log IS the text
    {_, live_loro} =
      checkpoint(uniq("log"), %{provenance: %{enabled: false, policy_source: "mode"}})

    assert BufferStore.sweep_redundant_history() >= 1

    refute File.exists?(mode_loro)
    assert File.exists?(user_loro)
    assert File.exists?(live_loro)
  end
end
