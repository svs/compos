defmodule Compos.AppearanceTest do
  @moduledoc """
  packages/appearance.scm — the chrome the user sets. Text scale walks
  a per-buffer ladder through the face remap, on the Cmd chords.
  """

  use ExUnit.Case

  alias Compos.Core.{Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp eval!(code) do
    {:ok, out} = Session.eval(code)
    out
  end

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()

    on_exit(fn ->
      Compos.Core.kill_buffer("*zz-scale*")
      Editor.delete_other_windows()
    end)

    :ok
  end

  test "s-+ grows one buffer's text; s-0 resets; other remaps survive" do
    {:ok, _} =
      Session.eval(~s{(begin
        (buffer-create "*zz-scale*")
        (switch-to-buffer! "*zz-scale*")
        (face-remap-in! "*zz-scale*" 'default (list 'family "TestSerif"))
        #t)})

    press(["s-+"])
    assert eval!(~s{(buffer-local "*zz-scale*" 'text-scale)}) == "1"
    style = eval!(~s{(buffer-local "*zz-scale*" 'style)})
    assert style =~ "--default-size:15px"
    assert style =~ "--default-family:TestSerif", "the scale clobbered the family remap"

    press(["s-+", "s-+"])
    assert eval!(~s{(buffer-local "*zz-scale*" 'text-scale)}) == "3"
    assert eval!(~s{(buffer-local "*zz-scale*" 'style)}) =~ "--default-size:20px"

    press(["s--"])
    assert eval!(~s{(buffer-local "*zz-scale*" 'text-scale)}) == "2"

    press(["s-0"])
    assert eval!(~s{(buffer-local "*zz-scale*" 'text-scale)}) == "0"
    style = eval!(~s{(buffer-local "*zz-scale*" 'style)})
    refute style =~ "--default-size"
    assert style =~ "--default-family:TestSerif"
  end

  test "the scale clamps at the ends of the ladder" do
    {:ok, _} =
      Session.eval(~s{(begin
        (buffer-create "*zz-scale*")
        (switch-to-buffer! "*zz-scale*")
        (text-scale-apply! "*zz-scale*" 99)
        #t)})

    assert eval!(~s{(buffer-local "*zz-scale*" 'text-scale)}) == "6"

    {:ok, _} = Session.eval(~s{(text-scale-apply! "*zz-scale*" -99)})
    assert eval!(~s{(buffer-local "*zz-scale*" 'text-scale)}) == "-4"
  end
end
