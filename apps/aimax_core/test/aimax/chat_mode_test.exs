defmodule Aimax.ChatModeTest do
  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp eval!(source) do
    {:ok, value} = Session.eval(source)
    value
  end

  defp type(text), do: text |> String.graphemes() |> Enum.each(&KeyDispatch.handle_key/1)
  defp press(keys), do: keys |> List.wrap() |> Enum.each(&KeyDispatch.handle_key/1)

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, attempts - 1)
    end
  end

  test "a group chat sends before a show command reruns its mode" do
    group = "zz-chat-mode-#{System.unique_integer([:positive])}"
    chat = "*chat:#{group}*"

    Application.put_env(:aimax_core, :llm_chat_fun, fn _request ->
      {:ok,
       %{
         "stop_reason" => "end_turn",
         "content" => [%{"type" => "text", "text" => "mode is live"}]
       }}
    end)

    on_exit(fn ->
      Application.delete_env(:aimax_core, :llm_chat_fun)
      if Buffer.exists?(chat), do: Aimax.Core.kill_buffer(chat)
      eval!(~s{(group-record-delete! (group-resolve-id "#{group}"))})
    end)

    assert eval!(~s{(group-chat "#{group}")}) == ~s{"#{chat}"}
    assert Buffer.get_local(chat, "mode-name") == "chat-mode"
    assert is_integer(Buffer.get_local(chat, "agent-saved-mark"))

    Editor.set_window_buffer(chat)
    Buffer.goto(chat, Buffer.byte_size(chat))
    type("hello")
    press("RET")

    assert eventually(fn -> Buffer.text(chat) =~ "mode is live" end)
  end
end
