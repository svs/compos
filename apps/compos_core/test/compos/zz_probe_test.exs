defmodule Compos.ZzProbeTest do
  use Compos.Case
  alias Compos.Core.Editor

  test "tab effect" do
    n = "zz-probe-#{System.unique_integer([:positive])}"
    Compos.Core.create_buffer(n)
    Compos.Core.Session.eval(~s{(switch-to-buffer! "#{n}")})
    IO.inspect(Compos.Core.Session.eval("*switch-last-tab*"), label: "LAST")
    IO.inspect(Compos.Core.Session.eval("(frame-local 'current-group)"), label: "CURGROUP")

    Compos.Core.Session.eval("(set! *switch-last-tab* 'all)")
    Compos.Core.Session.run_command("ibuffer-prompt")
    mb = Editor.render_state().minibuffer
    IO.inspect({mb.total, length(mb.candidates), mb.tabs}, label: "ALLTAB")
    Compos.Core.Session.eval("(minibuffer-abort!)")

    Compos.Core.Session.eval("(set! *switch-last-tab* 'group)")
    Compos.Core.Session.run_command("ibuffer-prompt")
    mb2 = Editor.render_state().minibuffer
    IO.inspect({mb2.total, length(mb2.candidates)}, label: "GROUPTAB")
    Compos.Core.Session.eval("(minibuffer-abort!)")
  end
end
