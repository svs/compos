defmodule Compos.ZzT455ProbeTest do
  use Compos.Case, async: false
  alias Compos.Core.Editor

  defp p(label, code), do: IO.puts(label <> " " <> inspect(Compos.Core.Session.eval(code)))

  test "probe" do
    Editor.split(:h, 0.5)
    Editor.split(:h, 0.5)
    p("RECTS", "(list (window-rects) (display--work-windows) (float-window) (map (lambda (w) (window-dock? w (window-buffer w))) (map car (window-list))) (panes-layout) (frame-group))")
    p("ADOPT", "(panes-adopt)")
  end
end
