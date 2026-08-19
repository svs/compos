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

  test "a workspace daemon hides file buffers from other checkouts" do
    root = Path.join(System.tmp_dir!(), "ibuffer-workspace-#{System.unique_integer([:positive])}")
    other = Path.join(System.tmp_dir!(), "ibuffer-other-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.mkdir_p!(other)
    inside = Path.join(root, "inside.txt")
    outside = Path.join(other, "outside.txt")
    File.write!(inside, "inside\n")
    File.write!(outside, "outside\n")
    old_root = Application.get_env(:aimax_core, :workspace_root)
    Application.put_env(:aimax_core, :workspace_root, root)

    on_exit(fn ->
      if old_root,
        do: Application.put_env(:aimax_core, :workspace_root, old_root),
        else: Application.delete_env(:aimax_core, :workspace_root)

      Aimax.Core.kill_buffer(inside)
      Aimax.Core.kill_buffer(outside)
      File.rm_rf!(root)
      File.rm_rf!(other)
    end)

    {:ok, rows} =
      Aimax.Core.Session.eval(
        ~s{(begin (visit "#{outside}") (visit "#{inside}") (run-command "ibuffer") (list-entries "*ibuffer*"))}
      )

    assert rows =~ inside
    refute rows =~ outside
  end
end
