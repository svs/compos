defmodule Aimax.IbufferPreviewTest do
  @moduledoc "Preview survives after killing the home window's buffer from ibuffer."

  use ExUnit.Case

  alias Aimax.Core.{Editor, KeyDispatch}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp windows do
    {:ok, wins} = Aimax.Core.Session.eval("(window-list)")
    Regex.scan(~r/\((\d+) "([^"]+)"\)/, wins)
    |> Enum.map(fn [_, id, b] -> {String.to_integer(id), b} end)
  end

  setup do
    Editor.minibuffer_close()
    Editor.completion_dismiss()
    Editor.set_pending([])
    Editor.delete_other_windows()

    on_exit(fn ->
      for b <- ["*zz-ka*", "*zz-kb*", "*zz-kc*", "*ibuffer*"], do: Aimax.Core.kill_buffer(b)
      Editor.delete_other_windows()
    end)

    :ok
  end

  test "preview keeps working after killing the buffer the home window showed" do
    {:ok, _} = Aimax.Core.Session.eval(~s{(begin
      (buffer-create "*zz-ka*")
      (buffer-create "*zz-kb*")
      (buffer-create "*zz-kc*")
      (delete-other-windows!)
      (switch-to-buffer! "*zz-ka*")
      (run-command "ibuffer")
      (buffer-set-local! "*ibuffer*" 'ibuffer-filters '())
      (ibuffer-filter-push! (list "match" "zz-k"))
      (list-goto-first-entry "*ibuffer*"))})

    home =
      Enum.find_value(windows(), fn {id, b} -> if b == "*zz-ka*", do: id end)

    assert home, "home window shows *zz-ka*: #{inspect(windows())}"

    # line 1 = *zz-ka* (MRU head among the filtered) — flag and kill it
    assert {:ok, ~s{"*zz-ka*"}} = Aimax.Core.Session.eval("(ibuffer-current)")
    press(["d", "x"])
    refute Aimax.Core.Buffer.exists?("*zz-ka*")

    # home window must not have become a second *ibuffer*
    home_buf = Enum.find_value(windows(), fn {id, b} -> if id == home, do: b end)
    refute home_buf == "*ibuffer*", "kill duplicated the ibuffer window"

    # n from the top entry previews the second remaining buffer at home
    {:ok, _} = Aimax.Core.Session.eval(~s{(list-goto-first-entry "*ibuffer*")})
    press(["n"])
    home_buf2 = Enum.find_value(windows(), fn {id, b} -> if id == home, do: b end)
    assert home_buf2 =~ "zz-k", "preview did not land in home window"
  end

  test "re-running ibuffer from inside the popup still previews into another window" do
    {:ok, _} = Aimax.Core.Session.eval(~s{(begin
      (buffer-create "*zz-ka*")
      (buffer-create "*zz-kb*")
      (delete-other-windows!)
      (switch-to-buffer! "*zz-ka*")
      (run-command "ibuffer")
      (run-command "ibuffer")
      (buffer-set-local! "*ibuffer*" 'ibuffer-filters '())
      (ibuffer-filter-push! (list "match" "zz-k"))
      (list-goto-first-entry "*ibuffer*"))})

    assert Editor.current_buffer() == "*ibuffer*"

    press(["n"])
    other = Enum.find(windows(), fn {_, b} -> b != "*ibuffer*" end)
    assert other, "no non-ibuffer window: #{inspect(windows())}"
    {_, shown} = other
    assert shown =~ "zz-k", "preview did not land anywhere useful"
  end
end
