defmodule Compos.AppearanceTest do
  @moduledoc """
  packages/appearance.scm — the chrome the user sets. Two text scales walk
  the 1.2 ladder: the buffer scale is a factor in one buffer's face remap,
  the application scale is the 'ui face's zoom. Tests name the commands;
  a chord is a preference.
  """

  use ExUnit.Case

  alias Compos.Core.{Buffer, Editor, Session}

  defp eval!(code) do
    {:ok, out} = Session.eval(code)
    out
  end

  defp run!(command), do: {:ok, _} = Session.eval(~s{(run-command "#{command}")})

  defp ui_zoom, do: get_in(Editor.desktop_view(), [:faces, "ui", "zoom"])

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()

    on_exit(fn ->
      Compos.Core.kill_buffer("*zz-scale*")
      Session.eval("(ui-scale-apply! 0)")
      Editor.delete_other_windows()
    end)

    :ok
  end

  test "the buffer scale is a factor in one buffer's remap; other remaps survive" do
    {:ok, _} =
      Session.eval(~s{(begin
        (buffer-create "*zz-scale*")
        (switch-to-buffer! "*zz-scale*")
        (face-remap-in! "*zz-scale*" 'default (list 'family "TestSerif" 'size "17px"))
        #t)})

    run!("text-scale-increase")
    assert eval!(~s{(buffer-local "*zz-scale*" 'text-scale)}) == "1"
    style = eval!(~s{(buffer-local "*zz-scale*" 'style)})
    assert style =~ "--text-scale-factor:1.2;"
    assert style =~ "--default-family:TestSerif", "the scale clobbered the family remap"
    assert style =~ "--default-size:17px", "the scale clobbered the size remap"

    run!("text-scale-increase")
    run!("text-scale-increase")
    assert eval!(~s{(buffer-local "*zz-scale*" 'text-scale)}) == "3"
    assert eval!(~s{(buffer-local "*zz-scale*" 'style)}) =~ "--text-scale-factor:1.728;"

    run!("text-scale-decrease")
    assert eval!(~s{(buffer-local "*zz-scale*" 'text-scale)}) == "2"

    run!("text-scale-reset")
    assert eval!(~s{(buffer-local "*zz-scale*" 'text-scale)}) == "0"
    style = eval!(~s{(buffer-local "*zz-scale*" 'style)})
    refute style =~ "--text-scale-factor"
    assert style =~ "--default-family:TestSerif"
    assert style =~ "--default-size:17px"
  end

  test "the buffer scale clamps at the ends of the ladder" do
    {:ok, _} =
      Session.eval(~s{(begin
        (buffer-create "*zz-scale*")
        (switch-to-buffer! "*zz-scale*")
        (text-scale-apply! "*zz-scale*" 99)
        #t)})

    assert eval!(~s{(buffer-local "*zz-scale*" 'text-scale)}) == "6"
    assert eval!(~s{(buffer-local "*zz-scale*" 'style)}) =~ "--text-scale-factor:2.986;"

    {:ok, _} = Session.eval(~s{(text-scale-apply! "*zz-scale*" -99)})
    assert eval!(~s{(buffer-local "*zz-scale*" 'text-scale)}) == "-4"
  end

  # A restart or an idle eviction keeps the buffer's checkpoint; the wake
  # reads it back and the runtime restore re-runs the mode setup.
  defp evict(name) do
    :ok = Buffer.checkpoint_now(name)
    [{pid, _}] = Registry.lookup(Compos.Core.BufferRegistry, name)
    :ok = DynamicSupervisor.terminate_child(Compos.Core.BufferSupervisor, pid)
    assert eventually(fn -> not Buffer.exists?(name) end)
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true ->
        Process.sleep(20)
        eventually(fun, tries - 1)
    end
  end

  test "the buffer scale is a buffer-local that survives eviction and wake" do
    {:ok, _} =
      Session.eval(~s{(begin
        (buffer-create "*zz-scale*")
        (switch-to-buffer! "*zz-scale*")
        (text-scale-apply! "*zz-scale*" 2)
        (switch-to-buffer! "*scratch*")
        #t)})

    evict("*zz-scale*")

    Editor.set_window_buffer("*zz-scale*")
    assert Buffer.exists?("*zz-scale*")
    Compos.Core.restore_runtime("*zz-scale*")

    assert eval!(~s{(buffer-local "*zz-scale*" 'text-scale)}) == "2"
    assert eval!(~s{(buffer-local "*zz-scale*" 'style)}) =~ "--text-scale-factor:1.44;"
    Editor.set_window_buffer("*scratch*")
  end

  test "a mode that restores a saved remap keeps the buffer's scale" do
    {:ok, _} =
      Session.eval(~s{(begin
        (buffer-create "*zz-scale*")
        (switch-to-buffer! "*zz-scale*")
        (text-scale-apply! "*zz-scale*" 1)
        ;; a mode teardown puts back the remap it saved before the scale
        (buffer-set-local! "*zz-scale*" 'face-remap '())
        (buffer-set-local! "*zz-scale*" 'style "")
        (text-scale-sync! "*zz-scale*")
        #t)})

    assert eval!(~s{(buffer-local "*zz-scale*" 'style)}) =~ "--text-scale-factor:1.2;"
  end

  test "the application scale is the 'ui face's zoom and a saved setting" do
    assert ui_zoom() == "1"

    run!("ui-scale-increase")
    assert eval!("ui-scale") == "1"
    assert ui_zoom() == "1.2"

    run!("ui-scale-increase")
    assert ui_zoom() == "1.44"
    assert eval!(~s{(cadr (assoc 'ui-scale *custom-set-vars*))}) == "2"

    run!("ui-scale-decrease")
    assert ui_zoom() == "1.2"

    run!("ui-scale-reset")
    assert eval!("ui-scale") == "0"
    assert ui_zoom() == "1"
  end

  test "the application scale is a step on the ladder, so it clamps too" do
    {:ok, _} = Session.eval("(ui-scale-apply! 99)")
    assert eval!("ui-scale") == "6"
    assert ui_zoom() == "2.986"
  end
end
