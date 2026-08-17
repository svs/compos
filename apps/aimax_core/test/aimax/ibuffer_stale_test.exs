defmodule Aimax.IbufferStaleTest do
  @moduledoc """
  A list acts on the rows that exist, and point rests on a row.

  Two ways `k` said "killed 0 buffers" and RET said "no buffer here":
  point sat in the chrome (a click lands on the key bar, and a click runs
  no command), and a row named a buffer that C-x k killed from somewhere
  else.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp eval!(code) do
    {:ok, out} = Session.eval(code)
    out
  end

  defp open_ibuffer do
    {:ok, _} =
      Session.eval(~s{(begin
        (buffer-create "*zz-sa*")
        (buffer-create "*zz-sb*")
        (buffer-create "*zz-sc*")
        (delete-other-windows!)
        (switch-to-buffer! "*zz-sa*")
        (run-command "ibuffer")
        (list-filter-clear! "*ibuffer*")
        (ibuffer-filter-push! (list "match" "zz-s"))
        (list-goto-first-entry "*ibuffer*"))})
  end

  setup do
    Editor.minibuffer_close()
    Editor.completion_dismiss()
    Editor.set_pending([])
    Editor.delete_other_windows()

    on_exit(fn ->
      for b <- ["*zz-sa*", "*zz-sb*", "*zz-sc*", "*ibuffer*"], do: Aimax.Core.kill_buffer(b)
      Editor.delete_other_windows()
    end)

    :ok
  end

  test "a verb acts on the nearest row when point sits in the chrome" do
    open_ibuffer()

    # point on the key bar: below every row
    {:ok, _} =
      Session.eval(~s{(buffer-goto! "*ibuffer*" (- (buffer-size "*ibuffer*") 3))})

    assert eval!(~s{(ibuffer-current)}) =~ "zz-s", "the nearest row is the row at point"

    before = eval!(~s{(length (list-entries "*ibuffer*"))}) |> String.to_integer()
    press(["k"])

    after_kill = eval!(~s{(length (list-entries "*ibuffer*"))}) |> String.to_integer()
    assert after_kill == before - 1, "k killed nothing from the key bar"

    # and point now rests on a row, so the reader sees what the next key acts on
    i = eval!(~s{(list-index "*ibuffer*")})
    assert i != "#f"
    assert String.to_integer(i) < after_kill
  end

  test "a row for a buffer killed elsewhere leaves the list on the next command" do
    open_ibuffer()

    {:ok, _} = Session.eval(~s{(buffer-kill! "*zz-sc*")})
    refute Buffer.exists?("*zz-sc*")

    # any command re-renders the list: the stamp moved
    press(["n"])

    entries = eval!(~s{(list-entries "*ibuffer*")})
    refute entries =~ "zz-sc", "the dead buffer still has a row: #{entries}"
    assert eval!(~s{(ibuffer-current)}) =~ "zz-s"
  end
end
