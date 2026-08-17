defmodule Aimax.IbufferStaleTest do
  @moduledoc """
  A list acts on the rows it shows, and point rests on a row.

  Three ways `k` said "killed 0 buffers" and RET said "no buffer here":
  the row named a DORMANT buffer (a checkpoint and no process, which the
  list shows and `buffer-exists?` denies), point sat in the chrome (a
  click lands on the key bar, and a click runs no command), and a row
  named a buffer that C-x k killed from somewhere else.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, BufferStore, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(str), do: str |> String.graphemes() |> press()

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

  test "ibuffer opens wide: the typed narrowing does not outlive the list" do
    open_ibuffer()
    assert eval!(~s{(list-query "*ibuffer*")}) == ~s{"zz-s"}

    # the narrowing says itself while it holds: the count and the way out
    text = Buffer.text("*ibuffer*")
    assert text =~ "of ", "the header does not count what the narrowing hid"
    assert text =~ "narrowed to /zz-s"
    assert text =~ "\\ widens"

    press(["q"])
    {:ok, _} = Session.eval(~s{(run-command "ibuffer")})

    assert eval!(~s{(list-query "*ibuffer*")}) == ~s{""}
    refute Buffer.text("*ibuffer*") =~ "narrowed to"
  end

  test "a mode's own filter kind survives the open a typed query does not" do
    open_ibuffer()
    {:ok, _} = Session.eval(~s{(ibuffer-filter-push! (list "dot" "on"))})

    {:ok, _} = Session.eval(~s{(run-command "ibuffer")})

    assert eval!(~s{(list-query "*ibuffer*")}) == ~s{""}
    assert eval!(~s{(list-filters "*ibuffer*")}) == ~s{(("dot" "on"))}
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

  # the editor puts an idle buffer to sleep: the checkpoint stays, the
  # process goes. The list still names it, so every verb must act on it.
  defp evict(name) do
    :ok = Buffer.checkpoint_now(name)
    [{pid, _}] = Registry.lookup(Aimax.Core.BufferRegistry, name)
    :ok = DynamicSupervisor.terminate_child(Aimax.Core.BufferSupervisor, pid)
    # the registry clears after the process goes
    assert eventually(fn -> not Buffer.exists?(name) end)
    assert BufferStore.known?(name)
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  test "k kills the dormant buffer the row names" do
    open_ibuffer()
    evict("*zz-sc*")

    {:ok, _} = Session.eval(~s{(list-goto-index! "*ibuffer*" 0)})

    # walk to the dormant row: it is a row like any other
    {:ok, rows} = Session.eval(~s{(list-entries "*ibuffer*")})
    assert rows =~ "zz-sc", "the dormant buffer left the list"

    {:ok, _} =
      Session.eval(~s{(list-goto-index! "*ibuffer*" (list-index-of "*ibuffer*" (list-entries "*ibuffer*") "*zz-sc*"))})

    assert eval!(~s{(ibuffer-current)}) == ~s{"*zz-sc*"}
    press(["k"])

    refute BufferStore.known?("*zz-sc*"), "k left the dormant buffer in the store"
    refute eval!(~s{(list-entries "*ibuffer*")}) =~ "zz-sc"
    assert Buffer.text("*messages*") =~ "killed 1 buffer"
  end

  test "RET wakes the dormant buffer the row names" do
    open_ibuffer()
    evict("*zz-sb*")

    {:ok, _} =
      Session.eval(~s{(list-goto-index! "*ibuffer*" (list-index-of "*ibuffer*" (list-entries "*ibuffer*") "*zz-sb*"))})

    assert eval!(~s{(ibuffer-current)}) == ~s{"*zz-sb*"}
    press(["RET"])

    assert Buffer.exists?("*zz-sb*"), "RET did not wake the dormant buffer"
    assert Editor.current_buffer() == "*zz-sb*"
    refute Buffer.text("*messages*") =~ "no buffer here"
  end

  # C-x b offers buffer-list-mru, and most of that list is dormant. The
  # confirm branch asked buffer-exists?, so RET on a dormant candidate
  # fell through to "nothing matches" and founded a group named after the
  # file you asked for.
  test "C-x b RET wakes the dormant buffer it offers, and founds no group" do
    open_ibuffer()
    press(["q"])
    evict("*zz-sb*")

    press(["C-x", "b"])
    type("zz-sb")
    press(["RET"])

    assert Buffer.exists?("*zz-sb*"), "C-x b did not wake the dormant buffer"
    assert Editor.current_buffer() == "*zz-sb*"
    refute Buffer.text("*messages*") =~ "founded group"
    assert eval!(~s{(buffer-group "*zz-sb*")}) == "#f"
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
