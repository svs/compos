defmodule Aimax.ChatInputGuardTest do
  @moduledoc """
  The ">>> you: " marker between transcript and input is not editable.
  Backspace on an empty input must refuse instead of eating marker bytes,
  and a marker already mangled by older sessions heals on mode setup.
  """

  use ExUnit.Case

  alias Aimax.Core.{Agent, Buffer, Editor, KeyDispatch, Session}

  @marker "\n>>> you: "

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()

    on_exit(fn ->
      Enum.each(Agent.list(), &Agent.kill/1)

      Enum.each(Aimax.Core.list_buffers(), fn name ->
        if String.starts_with?(name, "*chat:") or Buffer.get_local(name, "agent-slug"),
          do: Aimax.Core.kill_buffer(name)
      end)

      Editor.delete_other_windows()
    end)

    :ok
  end

  defp stub_chat do
    {:ok, _} =
      Session.eval("""
      (execute* "go" '(backend "stub" script
        (((type user-msg text "go")
          (type chunk text "Hi.\\n")))))
      """)

    buf = "*chat:a1*"
    assert eventually(fn -> Buffer.text(buf) =~ "Hi." end)
    assert eventually(fn -> match?(%{status: :idle}, Agent.info("a1")) end)
    {:ok, _} = Session.eval(~s[(begin (switch-to-buffer! "#{buf}") (end-of-buffer!))])
    buf
  end

  defp marker_at_mark(buf) do
    mark = Buffer.get_local(buf, "agent-saved-mark")
    binary_part(Buffer.text(buf), mark, min(byte_size(@marker), Buffer.byte_size(buf) - mark))
  end

  test "backspace on an empty input refuses instead of eating the marker" do
    buf = stub_chat()
    size = Buffer.byte_size(buf)

    press(["DEL", "DEL", "DEL"])
    assert Buffer.byte_size(buf) == size
    assert marker_at_mark(buf) == @marker

    # typing after the refused deletes lands whole, not partially hidden
    press(["a", "b", "c", "d", "e", "f"])
    {:ok, input} = Session.eval(~s[(chat-input-text "#{buf}")])
    assert input == ~s["abcdef"]

    # backspace inside typed input still works, down to the marker and no further
    press(["DEL", "DEL", "DEL", "DEL", "DEL", "DEL", "DEL", "DEL"])
    {:ok, input} = Session.eval(~s[(chat-input-text "#{buf}")])
    assert input == ~s[""]
    assert marker_at_mark(buf) == @marker
  end

  test "a marker mangled by an older session heals on mode setup" do
    buf = stub_chat()

    # simulate the historic damage: three marker bytes eaten, garbage typed
    size = Buffer.byte_size(buf)
    :ok = Buffer.delete_range(buf, size - 3, 3)
    :ok = Buffer.insert_at(buf, Buffer.byte_size(buf), "ehhll")
    refute marker_at_mark(buf) == @marker

    {:ok, _} =
      Session.eval(~s[(with-current-buffer "#{buf}" (lambda () (set-mode! "chat-mode")))])

    assert marker_at_mark(buf) == @marker
    assert Buffer.byte_size(buf) == Buffer.get_local(buf, "agent-saved-mark") + byte_size(@marker)
    {:ok, input} = Session.eval(~s[(chat-input-text "#{buf}")])
    assert input == ~s[""]
  end

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true ->
        Process.sleep(50)
        eventually(fun, tries - 1)
    end
  end
end
