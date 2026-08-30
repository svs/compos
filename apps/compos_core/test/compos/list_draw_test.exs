defmodule Compos.ListDrawTest do
  @moduledoc """
  One list draw is few buffer changes. Every change is a frame refresh
  and a render, and a draw of twelve changes made the view jump: a render
  between the delete and the write saw an empty buffer and reset the
  window's top.
  """

  use ExUnit.Case

  alias Compos.Core.{Buffer, Events, Session}

  defp eval!(code) do
    {:ok, out} = Session.eval(code)
    out
  end

  defp count_changes(ref, n \\ 0) do
    receive do
      {:buffer_change, ^ref, _} -> count_changes(ref, n + 1)
    after
      300 -> n
    end
  end

  test "set_locals writes several locals with one change" do
    name = "*zz-locals-#{System.unique_integer([:positive])}*"
    {:ok, ^name} = Compos.Core.create_buffer(name)
    ref = Buffer.ref(name)
    Events.subscribe(ref)

    eval!(~s{(buffer-set-locals! "#{name}" (list 'a 1 'b "two" 'c '(3)))})

    assert Buffer.get_local(name, "a") == 1
    assert Buffer.get_local(name, "b") == "two"
    assert Buffer.get_local(name, "c") == [3]
    assert count_changes(ref) == 1
    Compos.Core.kill_buffer(name)
  end

  test "a list redraw is at most eight buffer changes" do
    eval!(~s{(begin (load-tests!) (list-mode-show! "zz-page-mode") #t)})
    ref = Buffer.ref("*zz-page*")
    Events.subscribe(ref)

    eval!(~s{(list-redraw! "*zz-page*")})

    changes = count_changes(ref)
    assert changes <= 8, "a redraw made #{changes} buffer changes"
    assert Buffer.text("*zz-page*") =~ "row 49"
    eval!(~s{(buffer-kill! "*zz-page*")})
  end
end
