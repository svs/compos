defmodule Compos.ChatInputMarkerTest do
  @moduledoc """
  The chat layout invariant: [transcript ... mark][">>> you: "][input].
  The buffer-local 'agent-saved-mark is the one truth for the mark, and
  every transcript insert goes through Buffer.insert_at_mark, which moves
  text and local in one message. These tests transmit through the real
  key path and read the invariant back.
  """

  use ExUnit.Case

  alias Compos.Core.{Agent, Buffer, Editor, KeyDispatch, Session}

  @marker "\n>>> you: "

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp eval!(src), do: (fn {:ok, p} -> p end).(Session.eval(src))

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()

    on_exit(fn ->
      Enum.each(Agent.list(), &Agent.kill/1)

      Enum.each(Compos.Core.list_buffers(), fn name ->
        if String.starts_with?(name, "*chat:"), do: Compos.Core.kill_buffer(name)
      end)

      Editor.delete_other_windows()
    end)

    :ok
  end

  defp marker_at_mark?(buf) do
    text = Buffer.text(buf)
    mark = Buffer.get_local(buf, "agent-saved-mark")
    mb = Buffer.get_local(buf, "agent-marker-bytes")

    mark + mb <= byte_size(text) and
      binary_part(text, mark, mb) == @marker
  end

  test "insert_at_mark moves the text and the local in one message" do
    name = "*mark-op-test*"
    Compos.Core.create_buffer(name)
    on_exit(fn -> Compos.Core.kill_buffer(name) end)

    Buffer.append(name, "head#{@marker}draft")
    Buffer.set_local(name, "agent-saved-mark", 4)

    assert Buffer.insert_at_mark(name, "grow") == 8
    assert Buffer.text(name) == "headgrow#{@marker}draft"
    assert Buffer.get_local(name, "agent-saved-mark") == 8
  end

  test "the marker stays at the mark across transmits, and typed input survives" do
    eval!("""
    (execute* "first" '(backend "stub" script
      (((type user-msg text "first") (type chunk text "First reply.\\n"))
       ((type user-msg text "hello") (type chunk text "Second reply.\\n"))
       ((type user-msg text "again") (type chunk text "Third reply.\\n")))))
    """)

    buf = "*chat:a1*"
    assert eventually(fn -> Buffer.text(buf) =~ "First reply." end)
    assert eventually(fn -> match?(%{status: :idle}, Agent.info("a1")) end)
    assert marker_at_mark?(buf)

    eval!(~s{(begin (switch-to-buffer! "#{buf}") (end-of-buffer!) #t)})
    press(~w(h e l l o))
    assert String.ends_with?(Buffer.text(buf), ">>> you: hello")
    press("RET")

    assert eventually(fn -> Buffer.text(buf) =~ "Second reply." end)
    assert eventually(fn -> match?(%{status: :idle}, Agent.info("a1")) end)
    assert marker_at_mark?(buf)

    eval!(~s{(begin (switch-to-buffer! "#{buf}") (end-of-buffer!) #t)})
    press(~w(a g a i n))
    assert String.ends_with?(Buffer.text(buf), ">>> you: again")
    press("RET")

    assert eventually(fn -> Buffer.text(buf) =~ "Third reply." end)
    assert eventually(fn -> match?(%{status: :idle}, Agent.info("a1")) end)
    assert marker_at_mark?(buf)

    # the transcript holds every user line; the input region is empty
    text = Buffer.text(buf)
    assert text =~ ">>> you: hello"
    assert text =~ ">>> you: again"
    assert String.ends_with?(text, @marker)
  end

  defp eventually(fun, tries \\ 60) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true ->
        Process.sleep(50)
        eventually(fun, tries - 1)
    end
  end
end
