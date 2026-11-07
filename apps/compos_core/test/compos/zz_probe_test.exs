defmodule Compos.ZzProbeTest do
  use Compos.Case
  alias Compos.Core.Editor

  defp say(label) do
    {:ok, mru} = Compos.Core.Session.eval(~s{(buffer-list-mru)})
    IO.puts("PROBE|" <> label <> "|mru=" <> (mru |> String.split(" ") |> Enum.take(3) |> Enum.join(" ")) <> "|recent=" <> inspect(Enum.take(Compos.Core.Recent.buffers(), 3)) <> "|active=" <> inspect(elem(Compos.Core.Session.eval(~s{(active-window)}), 1)) <> "|wins=" <> inspect(Editor.list_windows()))
  end

  @tag timeout: 600_000
  test "base" do
    old = ~S'''
(define (switch-to-buffer--show! buf)
  (when (and (not (buffer-context?)) (boundp 'buffer-promote!)
             (not (agent-edit-author? (current-edit-author))))
    (buffer-promote! buf))
  (when (and (not (buffer-context?)) (boundp 'buffer-join-here!))
    (buffer-join-here! buf))
  (cond ((buffer-context?) (switch-to-buffer-here! buf))
        ((boundp 'panes-visit!) (panes-visit! buf) buf)
        (else (window-display! (lambda () (switch-to-buffer-here! buf) (active-window))) buf)))
'''
    for flavor <- [String.to_atom(System.get_env("FLAVOR", "new"))] do
      if flavor == :old, do: {:ok, _} = Compos.Core.Session.eval(old)
      System.put_env("SCHEME_TESTS", "group-switch")
      real = Compos.SchemeSuite.names(:packages) |> Compos.SchemeSuite.own(:packages) |> Compos.SchemeSuite.selected(:packages)
      failures = Compos.SchemeSuite.run(real)
      IO.puts("PROBE|#{flavor}|#{length(real)} tests|" <> Enum.join(Enum.map(failures, fn f -> f |> String.trim() |> String.split("\n") |> hd() end), ","))
    end
  end

  test "grp" do
    for n <- ["zz-g-a", "zz-g-b", "zz-g-home"], do: Compos.Core.create_buffer(n)
    Compos.TestHelpers.one_window!()
    {:ok, _} = Compos.Core.Session.eval(~S|(begin (set-frame-local! 'current-group #f) (delete-other-windows!) (switch-to-buffer! "zz-g-a") (switch-to-buffer! "zz-g-b") (buffer-set-local! "zz-g-a" 'group "zzgrp") (buffer-set-local! "zz-g-b" 'group "zzgrp") (switch-to-buffer! "zz-g-home") #t)|)
    say("before")
    r = Compos.Core.Session.eval(~S|(begin (switch-to-group! "zzgrp") (list (frame-local 'current-group) (group-resolve-id "zzgrp") (panes-layout)))|)
    IO.puts("PROBE|switch|" <> inspect(r))
    say("after")
  end

  test "cxo" do
    for n <- ["zz-o-a", "zz-o-b"], do: Compos.Core.create_buffer(n)
    Compos.TestHelpers.one_window!()
    {:ok, _} = Compos.Core.Session.eval(~S|(begin (set-frame-local! 'current-group #f) (delete-other-windows!) (switch-to-buffer! "zz-o-a"))|)
    say("left")
    {:ok, _} = Compos.Core.Session.eval(~S|(split-window! 'h 0.5)|)
    say("split")
    {:ok, _} = Compos.Core.Session.eval(~s{(other-window!)})
    say("other1")
    {:ok, _} = Compos.Core.Session.eval(~S|(switch-to-buffer! "zz-o-b")|)
    say("right")
    {:ok, _} = Compos.Core.Session.eval(~s{(other-window!)})
    say("other2")
  end
end
