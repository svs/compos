defmodule Compos.ChatInputGuardTest do
  @moduledoc """
  The live input holds no marker bytes: it is everything past the mark.
  Backspace on an empty input must refuse instead of eating the transcript,
  a chat saved with the old ">>> you: " marker loses it on mode setup, and a
  mark that drifted past the end never breaks reading the input.
  """

  use ExUnit.Case

  alias Compos.Core.{Agent, Buffer, Editor, KeyDispatch, Session}

  @marker "\n>>> you: "

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()

    on_exit(fn ->
      Enum.each(Agent.list(), &Agent.kill/1)

      Enum.each(Compos.Core.list_buffers(), fn name ->
        if String.starts_with?(name, "*chat:") or Buffer.get_local(name, "agent-slug"),
          do: Compos.Core.kill_buffer(name)
      end)

      Editor.delete_other_windows()
    end)

    :ok
  end

  defp stub_chat do
    {:ok, printed_slug} =
      Session.eval("""
      (execute* "go" '(backend "stub" script
        (((type user-msg text "go")
          (type chunk text "Hi.\\n")))))
      """)

    slug = String.trim(printed_slug, "\"")
    # the runtime slug is the chat's durable id; the buffer carries its own name
    {:ok, printed_buf} = Session.eval(~s[(agent-buf "#{slug}")])
    buf = String.trim(printed_buf, "\"")
    assert eventually(fn -> Buffer.text(buf) =~ "Hi." end)
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)
    {:ok, _} = Session.eval(~s[(begin (switch-to-buffer! "#{buf}") (end-of-buffer!))])
    buf
  end

  defp input_text(buf) do
    text = Buffer.text(buf)
    mark = Buffer.get_local(buf, "agent-saved-mark")
    binary_part(text, mark, byte_size(text) - mark)
  end

  test "backspace on an empty input refuses instead of eating the transcript" do
    buf = stub_chat()
    size = Buffer.byte_size(buf)
    mark = Buffer.get_local(buf, "agent-saved-mark")
    assert mark == size

    press(["DEL", "DEL", "DEL"])
    assert Buffer.byte_size(buf) == size
    assert Buffer.get_local(buf, "agent-saved-mark") == mark

    # typing after the refused deletes lands whole, not partially hidden
    press(["a", "b", "c", "d", "e", "f"])
    {:ok, input} = Session.eval(~s[(chat-input-text "#{buf}")])
    assert input == ~s["abcdef"]
    assert input_text(buf) == "abcdef"

    # backspace inside typed input still works, down to the mark and no further
    press(["DEL", "DEL", "DEL", "DEL", "DEL", "DEL", "DEL", "DEL"])
    {:ok, input} = Session.eval(~s[(chat-input-text "#{buf}")])
    assert input == ~s[""]
    assert Buffer.byte_size(buf) == size
    assert Buffer.get_local(buf, "agent-saved-mark") == mark
  end

  test "typing from a stale transcript point returns to the complete input" do
    buf = stub_chat()
    before = Buffer.text(buf)

    {:ok, _} =
      Session.eval(~s[(with-current-buffer "#{buf}" (lambda () (beginning-of-buffer!)))])

    press(["a", "b", "c", "d", "e", "f"])

    {:ok, input} = Session.eval(~s[(chat-input-text "#{buf}")])
    assert input == ~s["abcdef"]
    assert Buffer.text(buf) == before <> "abcdef"
  end

  test "a chat saved with the old input marker loses it on mode setup and keeps its draft" do
    buf = stub_chat()
    mark = Buffer.get_local(buf, "agent-saved-mark")

    # the layout of an older session: marker bytes at the mark, a draft after them
    :ok = Buffer.insert_at(buf, mark, @marker <> "draft")
    Buffer.set_local(buf, "agent-saved-mark", mark)
    Buffer.set_local(buf, "agent-marker-bytes", byte_size(@marker))

    {:ok, _} =
      Session.eval(~s[(with-current-buffer "#{buf}" (lambda () (set-mode! "chat-mode")))])

    assert Buffer.get_local(buf, "agent-saved-mark") == mark
    assert Buffer.get_local(buf, "agent-marker-bytes") == 0
    refute Buffer.text(buf) =~ @marker <> "draft"
    assert input_text(buf) == "draft"
    {:ok, input} = Session.eval(~s[(chat-input-text "#{buf}")])
    assert input == ~s["draft"]
  end

  test "a mark stranded past the end of the buffer cannot break reading the input" do
    buf = stub_chat()
    size = Buffer.byte_size(buf)

    # an edit the local never saw left the mark past the end
    Buffer.set_local(buf, "agent-saved-mark", size + 40)

    {:ok, input} = Session.eval(~s[(chat-input-text "#{buf}")])
    assert input == ~s[""]

    # typing still lands in the input, and RET still reads it
    {:ok, _} = Session.eval(~s[(with-current-buffer "#{buf}" (lambda () (end-of-buffer!)))])
    press(["o", "k"])
    {:ok, input} = Session.eval(~s[(chat-input-text "#{buf}")])
    assert input == ~s["ok"]
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
