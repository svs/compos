defmodule Aimax.UniversalArgumentTest do
  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp eval!(source) do
    {:ok, value} = Session.eval(source)
    value
  end

  setup do
    name = "*zz-prefix-#{System.unique_integer([:positive])}*"
    Aimax.Core.create_buffer(name)
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.set_prefix_arg(nil)

    eval!(~s{
      (begin
        (switch-to-buffer! "#{name}")
        (define *zz-prefix-seen* #f)
        (define-command "zz-prefix-capture"
          (lambda () (set! *zz-prefix-seen* (current-prefix-arg))))
        (global-set-key "<f9> u" "universal-argument")
        (global-set-key "<f9> c" "zz-prefix-capture"))})

    on_exit(fn ->
      Editor.set_prefix_arg(nil)
      Aimax.Core.kill_buffer(name)
    end)

    {:ok, name: name}
  end

  test "universal-argument supplies one raw argument to the next command" do
    press(["<f9>", "u", "<f9>", "c"])

    assert eval!("*zz-prefix-seen*") == "(4)"
    assert eval!("(current-prefix-arg)") == "#f"
  end

  test "repeated universal-argument multiplies by four" do
    press(["<f9>", "u", "<f9>", "u", "<f9>", "c"])

    assert eval!("*zz-prefix-seen*") == "(16)"
  end

  test "digits and minus build a numeric argument" do
    press(["<f9>", "u", "3", "<f9>", "c"])
    assert eval!("*zz-prefix-seen*") == "3"

    press(["<f9>", "u", "-", "2", "<f9>", "c"])
    assert eval!("*zz-prefix-seen*") == "-2"
  end

  test "self insertion uses the numeric prefix and clears it", %{name: name} do
    press(["<f9>", "u", "x"])

    assert Buffer.text(name) == "xxxx"
    assert eval!("(current-prefix-arg)") == "#f"
  end
end
