defmodule Compos.Core.TelemetryTest do
  use ExUnit.Case

  alias Compos.Core.{Buffer, Editor, KeyDispatch, Session, Telemetry}

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()

    on_exit(fn ->
      for name <- ["*Scheme Telemetry*", "*Scheme Telemetry Event*"] do
        if Buffer.exists?(name), do: Compos.Core.kill_buffer(name)
      end
    end)

    :ok
  end

  test "retains normalized lane and task events newest first" do
    :ok = Telemetry.clear()
    label = "telemetry-test-#{System.unique_integer([:positive])}"

    :telemetry.execute(
      [:compos, :lane, :job],
      %{duration: 12, queue_time: 3, backlog: 2},
      %{lane: :scheme, owner: {:agent, "test"}, label: label}
    )

    :telemetry.execute(
      [:compos, :scheme, :task],
      %{duration: 7},
      %{task: 42, status: :ok}
    )

    assert [task, lane] = Telemetry.events(2)
    assert task.kind == "task"
    assert task.duration_ms == 7
    assert task.status == "ok"

    assert lane.kind == "lane"
    assert lane.duration_ms == 12
    assert lane.queue_ms == 3
    assert lane.backlog == 2
    assert lane.owner == ~s({:agent, "test"})
    assert lane.label == label
  end

  test "RET opens a readable detail view with the complete job and owner" do
    :ok = Telemetry.clear()

    :telemetry.execute(
      [:compos, :lane, :job],
      %{duration: 12, queue_time: 3, backlog: 2},
      %{lane: :scheme, owner: {:buffer, "*other*"}, label: "command other-window"}
    )

    assert {:ok, _} =
             Session.eval(~S|(begin (run-command "telemetry")
                         (switch-to-buffer! "*Scheme Telemetry*")
                         (list-goto-first-entry "*Scheme Telemetry*"))|)

    KeyDispatch.handle_key("RET")

    assert Buffer.exists?("*Scheme Telemetry Event*")
    assert Buffer.text("*Scheme Telemetry Event*") =~ "command other-window"
    assert Buffer.text("*Scheme Telemetry Event*") =~ ~s({:buffer, "*other*"})

    assert Buffer.get_local("*Scheme Telemetry Event*", "mode-name") ==
             "telemetry-detail-mode"

    assert Buffer.get_local("*Scheme Telemetry Event*", "render-mode") == "blocks"
    assert Buffer.get_local("*Scheme Telemetry Event*", "render-blocks") != []
  end

  test "clear discards retained events" do
    :ok = Telemetry.clear()
    assert Telemetry.events() == []
  end
end
