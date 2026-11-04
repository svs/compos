defmodule Compos.ZzT455ProbeTest do
  use Compos.Case, async: false

  defp ev(code), do: Compos.Core.Session.eval(code)

  @steps [
    {"mb", ~s{(when (minibuffer-state) (minibuffer-cancel!))}},
    {"float", ~s{(when (float-open?) (float-close!))}},
    {"bufs", ~s{(for-each (lambda (b) (test-buffer! b "")) (list t--sw-first t--sw-second t--sw-third))}},
    {"recs", ~s{(begin (set! *group-records* '()) (set! *group-mru* '()) (set! *group-next-id* 0))}},
    {"choose", ~s{(panes-choose-layout! #f)}},
    {"locals", ~s{(begin (set-frame-local! 'current-group #f) (set-frame-local! 'previous-group #f) (set-frame-local! 'pinned-group #f))}},
    {"dow", ~s{(delete-other-windows!)}},
    {"sw1", ~s{(switch-to-buffer! t--sw-first)}},
    {"sw2", ~s{(switch-to-buffer! t--sw-second)}},
    {"sw3", ~s{(switch-to-buffer! t--sw-first)}},
    {"done-mb", ~s{(when (minibuffer-state) (minibuffer-cancel!))}},
    {"done-choose", ~s{(panes-choose-layout! #f)}},
    {"done-kill", ~s{(for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b))) (list t--sw-first t--sw-second t--sw-third))}},
    {"done-dow", ~s{(delete-other-windows!)}}
  ]

  test "probe" do
    ev(~s{(load-package-tests-once!)})
    Enum.reduce_while(1..10, nil, fn i, _ ->
      bad =
        Enum.find(@steps, fn {name, code} ->
          case ev(code) do
            {:error, e} ->
              IO.puts("HIT #{i} #{name} #{e}")
              IO.puts("STATE " <> inspect(ev(~s{(list (window-list) (frame-group) (panes-layout))})))
              true
            _ -> false
          end
        end)
      if bad, do: {:halt, bad}, else: {:cont, nil}
    end)
    IO.puts("END-PROBE")
  end
end
