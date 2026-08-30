defmodule Compos.WindowConfigHookTest do
  @moduledoc """
  Emacs window-configuration-change-hook: the editor tells Scheme once
  for each change of a frame's windows or their buffers, whoever changed
  them. The frame's group derives from its windows, so a kill that drops
  a window onto a group's buffer puts the frame back in the group with no
  command involved.
  """

  use ExUnit.Case

  alias Compos.Core.{Editor, Session}

  defp eval!(code) do
    {:ok, out} = Session.eval(code)
    out
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true ->
        Process.sleep(40)
        eventually(fun, tries - 1)
    end
  end

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    :ok
  end

  test "a kill from Elixir puts the frame back in the group its window fell to" do
    id = eval!(~s{(group-record-create! "zz-hook-group")}) |> String.trim("\"")

    on_exit(fn ->
      Session.eval(~s{(begin (switch-to-buffer! "*scratch*") (group-record-delete! "#{id}") #t)})
      for b <- ["*zz-hook-member*", "*zz-hook-visitor*"], do: Compos.Core.kill_buffer(b)
    end)

    eval!(~s{(begin
      (buffer-create "*zz-hook-member*")
      (buffer-create "*zz-hook-visitor*")
      (buffer-add-group! "*zz-hook-member*" "#{id}")
      (switch-to-buffer! "*zz-hook-member*")
      #t)})

    assert eval!("(frame-group)") == ~s{"#{id}"}

    eval!(~s{(switch-to-buffer! "*zz-hook-visitor*")})
    assert eval!("(frame-group)") == "#f", "a visit to an ungrouped buffer leaves the group"

    # the Elixir path: no Scheme command, no window-state-changed! call
    Compos.Core.kill_buffer("*zz-hook-visitor*")

    assert eventually(fn -> eval!("(frame-group)") == ~s{"#{id}"} end),
           "the frame did not return to the group after the window fell back"
  end

  test "the Scheme half: popups and ibuffer order" do
    for name <- ["a-popup-does-not-change-the-frame-group", "ibuffer-puts-the-frames-group-first"] do
      assert eval!("(begin (load-tests!) (run-test '#{name}))") == "()", name
    end
  end
end
