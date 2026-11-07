defmodule Compos.ZzPaletteKeyTimeTest do
  use Compos.Case
  alias Compos.Core.Editor

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    Compos.TestHelpers.one_window!()
    on_exit(fn -> Editor.minibuffer_close() end)
    :ok
  end

  test "diag: write-file C-n then RET" do
    root = Path.join(System.tmp_dir!(), "compos-zzwf-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "foo-bar.txt"), "X")
    name = "*zz-wf-diag*"
    {:ok, _} = Compos.Core.Session.eval(~s{(begin (buffer-create "#{name}") (switch-to-buffer! "#{name}") (buffer-insert! "#{name}" 0 "chosen"))})
    {:ok, _} = Compos.Core.Session.eval(~s[(run-command "write-file")])
    Editor.minibuffer_set_input(root <> "/")
    type("foo.txt")
    IO.puts("DIAG before #{inspect(Compos.Core.Session.eval("(minibuffer--facts)"))}")
    IO.puts("DIAG keyC-n #{inspect(Compos.Core.Session.eval(~s{(key-binding '(\"C-n\"))}))}")
    press(["C-n"])
    IO.puts("DIAG after C-n #{inspect(Compos.Core.Session.eval("(minibuffer--facts)"))}")
    press(["RET"])
    IO.puts("DIAG after RET cur=#{inspect(Editor.current_buffer())} facts=#{inspect(Compos.Core.Session.eval("(minibuffer--facts)"))} echo=#{inspect(Compos.Core.Session.eval("(frame--get 'echo)"))}")
    Editor.minibuffer_close()
  end

  test "time a palette keystroke" do
    {open_us, _} = :timer.tc(fn -> press("s-p") end)
    keys = for ch <- ~w(o p e n f i l e), do: elem(:timer.tc(fn -> type(ch) end), 0)
    Editor.minibuffer_close()
    {open2_us, _} = :timer.tc(fn -> press("s-p") end)
    keys2 = for ch <- ~w(o p e n f i l e), do: elem(:timer.tc(fn -> type(ch) end), 0)
    IO.puts("PALETTE open_us=#{open_us} keys_us=#{inspect(keys)} open2_us=#{open2_us} keys2_us=#{inspect(keys2)}")
  end
end
