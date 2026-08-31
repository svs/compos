defmodule Compos.FrameWindowsTest do
  @moduledoc "The tool buffer context and with-frame-windows: the Scheme tests, in this daemon."
  use ExUnit.Case

  alias Compos.Core.{Editor, Session}

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    :ok
  end

  test "buffer context and the frame-windows escape" do
    for name <- [
          "window-reads-ignore-the-buffer-context",
          "switch-under-context-changes-no-window",
          "with-frame-windows-reaches-the-real-windows"
        ] do
      {:ok, out} = Session.eval("(begin (load-tests!) (run-test '#{name}))")
      assert out == "()", "#{name}: #{out}"
    end
  end
end
