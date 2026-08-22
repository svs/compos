defmodule Aimax.IbufferTest do
  @moduledoc "The traditional ibuffer table remains separate from the modal switcher."

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp eval!(code) do
    {:ok, value} = Session.eval(code)
    value
  end

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  setup do
    Editor.minibuffer_close()
    Editor.completion_dismiss()
    Editor.set_pending([])
    Editor.delete_other_windows()

    on_exit(fn ->
      for name <- ["*ibuffer*", "*switch*", "*zz-ibuffer-a*", "*zz-ibuffer-b*"] do
        Aimax.Core.kill_buffer(name)
      end

      Editor.delete_other_windows()
    end)

    :ok
  end

  test "the modal switcher remains available and C-x C-b opens ibuffer" do
    eval!(~s{(begin
      (buffer-create "*zz-ibuffer-a*")
      (switch-to-buffer! "*zz-ibuffer-a*"))})

    eval!(~s{(run-command "switch-to-buffer")})
    assert Editor.current_buffer() == "*switch*"
    assert eval!(~s{(buffer-local "*switch*" 'mode-name)}) == ~s{"switch-mode"}

    press("C-g")
    press(["C-x", "C-b"])
    assert Editor.current_buffer() == "*ibuffer*"
    assert eval!(~s{(buffer-local "*ibuffer*" 'mode-name)}) == ~s{"ibuffer-mode"}
  end

  test "ibuffer renders the traditional management columns" do
    eval!(~s{(begin
      (buffer-create "*zz-ibuffer-a*")
      (switch-to-buffer! "*zz-ibuffer-a*")
      (run-command "ibuffer"))})

    text = Buffer.text("*ibuffer*")
    assert text =~ "Buffers"
    assert text =~ "buffer"
    assert text =~ "SIZE"
    assert text =~ "MODE"
    assert text =~ "GROUP"
    assert text =~ "FILE"
    assert text =~ "d flag"
    assert text =~ "x execute"
    assert text =~ "*zz-ibuffer-a*"
  end

  test "d flags a row and x kills it through key dispatch" do
    eval!(~s{(begin
      (buffer-create "*zz-ibuffer-a*")
      (buffer-create "*zz-ibuffer-b*")
      (switch-to-buffer! "*zz-ibuffer-a*")
      (run-command "ibuffer")
      (list-filter-clear! "*ibuffer*")
      (ibuffer-filter-push! (list "match" "zz-ibuffer-b"))
      (list-goto-first-entry "*ibuffer*"))})

    assert eval!("(ibuffer-current)") == ~s{"*zz-ibuffer-b*"}
    press("d")
    assert eval!(~s{(list-mark-of "*ibuffer*" "*zz-ibuffer-b*")}) == ~s{"D"}

    press("x")
    refute Aimax.Core.BufferStore.known?("*zz-ibuffer-b*")
    refute Buffer.text("*ibuffer*") =~ "*zz-ibuffer-b*"
  end
end
