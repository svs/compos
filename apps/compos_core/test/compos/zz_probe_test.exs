defmodule Compos.ZzProbeTest do
  use Compos.Case
  alias Compos.Core.Editor

  defp rows do
    :compos_recent
    |> :ets.tab2list()
    |> Enum.filter(fn {k, _} -> is_binary(k) or is_tuple(k) or k == :"$seq" or k == :"$low" end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(14)
  end

  defp say(label, x), do: IO.puts(label <> ": " <> inspect(x))

  test "probe" do
    say("START", rows())
    Compos.Core.Session.eval(~s{(panes-choose-layout! #f)})
    Compos.TestHelpers.one_window!()
    Compos.Core.create_buffer("zz-p-home")
    Editor.set_window_buffer("zz-p-home")
    say("AFTER set_window_buffer", rows())

    Compos.Core.Session.eval(~s{(panes-adopt!)})
    say("adopted layout", Compos.Core.Session.eval(~s{(panes-layout)}))
    say("door", Compos.Core.Session.eval(~s{(panes--door?)}))
    say("layout", Compos.Core.Session.eval(~s{(panes-layout)}))
    for n <- ["zz-p-a", "zz-p-b", "zz-p-c"] do
      Compos.Core.create_buffer(n)
      {:ok, r} = Compos.Core.Session.eval(~s{(begin (set-frame-local! 'current-group #f) (switch-to-buffer! "#{n}"))})
      say("SWITCH #{n} -> #{r} echo=#{inspect(Editor.snapshot().echo)}", rows())
      say("  windows", Editor.list_windows())
    end

    say("refusal", Compos.Core.Session.eval(~s{(display-buffer-agent-refuses? "zz-p-q" (list))}))
  end
end
defmodule Compos.ZzProbeTest do
  use Compos.Case
  alias Compos.Core.Editor

  defp mru, do: elem(Compos.Core.Session.eval(~s{(buffer-list-mru)}), 1)

  defp say(label, code) do
    r = Compos.Core.Session.eval(code)
    IO.puts("PROBE|" <> label <> "|" <> inspect(r) <> "|mru=" <> mru() <> "|wins=" <> inspect(Editor.list_windows()))
  end

  defp home do
    Compos.Core.create_buffer("zz-p-home")
    Editor.set_window_buffer("zz-p-home")
  end

  test "probe" do
    for n <- ["zz-p-a", "zz-p-b", "zz-p-c"], do: Compos.Core.create_buffer(n)
    Compos.TestHelpers.one_window!()
    Compos.Core.Session.eval(~s{(panes-choose-layout! #f)})
    home()
    say("start", ~s{(buffer-list-mru)})
    home()
    say("scheme switch", ~S|(switch-to-buffer! "zz-p-a")|)
    home()
    say("raw window switch", ~S|(raw-window-switch-buffer! "zz-p-b")|)
    home()
    say("window switch", ~S|(window-switch-buffer! "zz-p-c")|)
    home()
    say("window set", ~S|(window-set-buffer! (active-window) "zz-p-a")|)
    home()
    say("ctx", ~s{(buffer-context?)})
    home()
    say("other window", ~s{(other-window!)})
  end
end
