defmodule Compos.ZzProbeTest do
  use Compos.Case
  alias Compos.Core.Editor

  defp say(label) do
    {:ok, mru} = Compos.Core.Session.eval(~s{(buffer-list-mru)})
    {:ok, cur} = Compos.Core.Session.eval(~s{(current-buffer)})
    {:ok, act} = Compos.Core.Session.eval(~s{(active-window)})
    IO.puts("PROBE|" <> label <> "|mru=" <> (mru |> String.split(" ") |> Enum.take(4) |> Enum.join(" ")) <> "|cur=" <> cur <> "|active=" <> inspect(act) <> "|wins=" <> inspect(Editor.list_windows()))
  end

  test "cxo" do
    for n <- ["zz-o-a", "zz-o-b"], do: Compos.Core.create_buffer(n)
    Compos.TestHelpers.one_window!()
    say("start")
    {:ok, _} = Compos.Core.Session.eval(~S|(begin (set-frame-local! 'current-group #f) (delete-other-windows!) (switch-to-buffer! "zz-o-a"))|)
    say("after left")
    {:ok, _} = Compos.Core.Session.eval(~S|(split-window! 'h 0.5)|)
    say("after split")
    {:ok, _} = Compos.Core.Session.eval(~s{(other-window!)})
    say("after other1")
    {:ok, _} = Compos.Core.Session.eval(~S|(switch-to-buffer! "zz-o-b")|)
    say("after right")
    {:ok, _} = Compos.Core.Session.eval(~s{(other-window!)})
    say("after other2")
  end
end
