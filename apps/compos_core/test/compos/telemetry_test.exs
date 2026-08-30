defmodule Compos.Core.TelemetryTest do
  use ExUnit.Case, async: false

  alias Compos.Core.{Buffer, Editor, KeyDispatch, Session, Telemetry}

  # the handlers run in the emitting process and send to the collector, so a
  # call after the emit reads the row: one process's messages stay in order
  defp rows, do: Telemetry.events(50)

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()
    :ok = Telemetry.clear()

    on_exit(fn ->
      for name <- ["*Telemetry*", "*Telemetry Event*"] do
        if Buffer.exists?(name), do: Compos.Core.kill_buffer(name)
      end
    end)

    :ok
  end

  test "retains normalized lane and task events newest first" do
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
    :telemetry.execute(
      [:compos, :lane, :job],
      %{duration: 12, queue_time: 3, backlog: 2},
      %{lane: :scheme, owner: {:buffer, "*other*"}, label: "command other-window"}
    )

    assert {:ok, _} =
             Session.eval(~S|(begin (run-command "telemetry")
                         (switch-to-buffer! "*Telemetry*")
                         (list-goto-first-entry "*Telemetry*"))|)

    KeyDispatch.handle_key("RET")

    assert Buffer.exists?("*Telemetry Event*")
    assert Buffer.text("*Telemetry Event*") =~ "command other-window"
    assert Buffer.text("*Telemetry Event*") =~ ~s({:buffer, "*other*"})
    assert Buffer.text("*Telemetry Event*") =~ "Layer: scheme"

    assert Buffer.get_local("*Telemetry Event*", "mode-name") ==
             "telemetry-detail-mode"

    assert Buffer.get_local("*Telemetry Event*", "render-mode") == "blocks"
    assert Buffer.get_local("*Telemetry Event*", "render-blocks") != []
  end

  test "clear discards retained events" do
    assert Telemetry.events() == []
  end

  defp socket(frame), do: %{assigns: %{frame: frame}}

  defp native(ms), do: System.convert_time_unit(ms, :millisecond, :native)

  test "a lane job is a scheme row with no trace" do
    :telemetry.execute(
      [:compos, :lane, :job],
      %{duration: 12, queue_time: 3, backlog: 1},
      %{lane: :ui, owner: :ui, label: "command self-insert"}
    )

    assert [row] = rows()
    assert row.layer == "scheme"
    assert row.kind == "lane"
    assert row.duration_ms == 12
    assert row.tid == nil
    assert row.detail == ""
  end

  test "a LiveView event carries the browser's trace id to the refresh and the render" do
    meta = %{
      socket: socket("f-1"),
      event: "intent",
      params: %{"type" => "insertText", "tid" => "ab12:7"}
    }

    :telemetry.execute([:phoenix, :live_view, :handle_event, :start], %{}, meta)

    :telemetry.execute(
      [:compos, :ui, :refresh],
      %{duration: 40, state: 10, decorate: 30},
      %{frame: "f-1"}
    )

    :telemetry.execute([:phoenix, :live_view, :handle_event, :stop], %{duration: native(45)}, meta)

    :telemetry.execute(
      [:phoenix, :live_view, :render, :stop],
      %{duration: native(20)},
      %{socket: socket("f-1"), changed?: true, force?: false}
    )

    assert [render, event, refresh] = rows()

    assert event.layer == "live"
    assert event.kind == "event"
    assert event.label == "event intent insertText"
    assert event.owner == "frame f-1"
    assert event.duration_ms == 45
    assert event.tid == "ab12:7"

    assert refresh.kind == "refresh"
    assert refresh.tid == "ab12:7"
    assert refresh.duration_ms == 40
    assert refresh.detail == "state 10ms decorate 30ms"

    assert render.kind == "render"
    assert render.label == "render"
    assert render.duration_ms == 20
    assert render.tid == "ab12:7"

    # the render consumed the id: a later render from a change notification
    # carries none
    :telemetry.execute(
      [:phoenix, :live_view, :render, :stop],
      %{duration: native(5)},
      %{socket: socket("f-1"), changed?: true, force?: false}
    )

    assert [later | _] = rows()
    assert later.tid == nil
  end

  test "a key event names its key" do
    meta = %{socket: socket("f-1"), event: "key", params: %{"k" => "C-f", "tid" => "ab12:8"}}
    :telemetry.execute([:phoenix, :live_view, :handle_event, :start], %{}, meta)
    :telemetry.execute([:phoenix, :live_view, :handle_event, :stop], %{duration: native(3)}, meta)

    assert [row] = rows()
    assert row.label == "event key C-f"
    assert row.tid == "ab12:8"
  end

  test "the browser's own report leaves no event row and no render row" do
    meta = %{socket: socket("f-1"), event: "telemetry", params: %{"rows" => []}}
    :telemetry.execute([:phoenix, :live_view, :handle_event, :start], %{}, meta)
    :telemetry.execute([:phoenix, :live_view, :handle_event, :stop], %{duration: native(1)}, meta)

    :telemetry.execute(
      [:phoenix, :live_view, :render, :stop],
      %{duration: native(1)},
      %{socket: socket("f-1"), changed?: false, force?: false}
    )

    assert rows() == []
  end

  test "browser rows keep the client's measurements and drop garbage" do
    :ok =
      Telemetry.browser(
        [
          %{
            "k" => "push",
            "l" => "intent insertText",
            "ms" => 180,
            "wait" => 60,
            "t" => 1_700_000_000_000,
            "tid" => "ab12:7",
            "d" => "patch 120ms 40960b"
          },
          %{"k" => "paint", "l" => "paint keydown", "ms" => 210.4, "wait" => 8, "tid" => nil},
          "not a row"
        ],
        "f-1"
      )

    assert [paint, push] = rows()

    assert push.layer == "browser"
    assert push.kind == "push"
    assert push.label == "intent insertText"
    assert push.duration_ms == 180
    assert push.queue_ms == 60
    assert push.time_ms == 1_700_000_000_000
    assert push.tid == "ab12:7"
    assert push.detail == "patch 120ms 40960b"
    assert push.owner == "frame f-1"

    assert paint.duration_ms == 210
    assert paint.tid == nil
    assert paint.detail == ""
    assert is_integer(paint.time_ms)
  end

  test "reattach keeps collecting" do
    assert :ok = Telemetry.reattach()

    :telemetry.execute(
      [:compos, :scheme, :task],
      %{duration: 2},
      %{task: 7, label: "t", status: :ok}
    )

    assert [%{kind: "task", layer: "scheme"}] = rows()
  end
end
