defmodule Compos.ModelineTest do
  @moduledoc """
  A dashboard catches up on another frame through the configuration hook.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.Session

  @lane {:scheme_suite, __MODULE__}

  defp eval!(code) do
    {:ok, out} = Session.eval(code, nil, 30_000, @lane)
    out
  end

  test "a dashboard catches up on another frame through the configuration hook" do
    alias Compos.Core.{Buffer, Editor}
    previous = Editor.last_active_frame()
    {:ok, frame} = Editor.attach_frame(nil)
    name = "*zz-dashboard-cross-frame*"

    try do
      eval!(~s|(test-buffer! "#{name}" "")|)
      eval!(~s|(dashboard--sync! "#{name}")|)
      assert eval!(~s|(buffer-dirty? "\#{name}" 'dashboard)|) == "#t"
      assert Buffer.get_local(name, "dashboard-line-blocks") == nil

      {window, _, ^frame} =
        Enum.find(Editor.list_windows_all(), fn {_, _, fid} -> fid == frame end)

      :ok = Editor.window_set_buffer(window, name)
      await_dashboard(name, 100)
      assert is_list(Buffer.get_local(name, "dashboard-line-blocks"))

      # The event runs from the original frame while the reader is elsewhere.
      Editor.select_frame(previous)
      eval!(~s|(buffer-set-local! "#{name}" 'minor-modes '("zz-cross-frame-mode"))|)
      eval!(~s|(dashboard--sync! "#{name}")|)
      assert Buffer.get_local(name, "dashboard-line") =~ "zz-cross-frame"
      assert eval!(~s|(buffer-dirty? "\#{name}" 'dashboard)|) == "#f"
    after
      Editor.delete_frame(frame)
      Editor.select_frame(previous)
      eval!(~s|(buffer-kill! "#{name}")|)
    end
  end

  defp await_dashboard(name, attempts) do
    if eval!(~s|(buffer-dirty? "\#{name}" 'dashboard)|) == "#f" do
      :ok
    else
      assert attempts > 0, "configuration hook did not materialize the dashboard"
      Process.sleep(10)
      await_dashboard(name, attempts - 1)
    end
  end
end
