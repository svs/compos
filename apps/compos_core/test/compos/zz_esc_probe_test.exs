defmodule Compos.ZzEscProbeTest do
  use Compos.Case
  alias Compos.Core.{Editor, Session}
  test "probe" do
    Editor.minibuffer_close()
    Compos.TestHelpers.one_window!()
    for c <- [~s{(buffer-create "zz-p.txt")}, ~s{(define zl (panes--ensure-layout!))}, ~s{zl}, ~s{(define zm (panes--buffer-mode "zz-p.txt"))}, ~s{(define zp (panes--selected-pane zl))}, ~s{zp}, ~s{(define zs (panes-show-buffer zl "zz-p.txt" zm zp))}, ~s{(define za (panes-focus-window (car zs) (cadr zs)))}, ~s{(define k1 (panes--own-keys za))}, ~s{(define k2 (panes-unique-buffers k1))}, ~s{k2}, ~s{(window-list)}, ~s{(define d1 (panes--frame-kept k2))}, ~s{(define d2 (panes--claim-empty-windows d1))}, ~s{(define d3 (panes--blanks d2))}, ~s{(panes-top-windows d3)}, ~s{(panes--pane-handles d3)}, ~s{(panes--line-shares d3)}, ~s{(buffer-insert! "zz-p.txt" 0 "hi")}, ~s{(goto-char! 0)}] do
      IO.puts("PROBE " <> c <> " => " <> inspect(Session.eval(c)))
    end
  end
end
