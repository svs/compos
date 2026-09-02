defmodule Compos.ChatInputMarkerTest do
  @moduledoc """
  The chat layout invariant: [transcript ... mark][input]. The live input
  holds no marker bytes; ">>> you: " is the prefix of a sent user line.
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

  # the input is empty: the buffer ends at the mark
  defp input_empty?(buf) do
    Buffer.get_local(buf, "agent-marker-bytes") == 0 and
      Buffer.get_local(buf, "agent-saved-mark") == Buffer.byte_size(buf)
  end

  test "insert_at_local moves the text and the named local in one message" do
    name = "*mark-op-test*"
    Compos.Core.create_buffer(name)
    on_exit(fn -> Compos.Core.kill_buffer(name) end)

    Buffer.append(name, "head#{@marker}draft")
    Buffer.set_local(name, "agent-saved-mark", 4)

    assert Buffer.insert_at_local(name, "agent-saved-mark", "grow") == 8
    assert Buffer.text(name) == "headgrow#{@marker}draft"
    assert Buffer.get_local(name, "agent-saved-mark") == 8
  end

  test "a marker local rides every edit; several stay solid at once" do
    name = "*marker-test*"
    Compos.Core.create_buffer(name)
    on_exit(fn -> Compos.Core.kill_buffer(name) end)

    Buffer.append(name, "aaaa|bbbb|cccc")
    Buffer.set_local(name, "m1", 4)
    Buffer.set_local(name, "m2", 9)
    Buffer.declare_marker_local(name, "m1", :advance)
    Buffer.declare_marker_local(name, "m2", :stay)

    # an insert before both shifts both
    Buffer.insert_at(name, 0, "..")
    assert Buffer.get_local(name, "m1") == 6
    assert Buffer.get_local(name, "m2") == 11

    # text landing exactly on a marker: advance moves, stay does not
    Buffer.insert_at(name, 6, "X")
    assert Buffer.get_local(name, "m1") == 7
    Buffer.insert_at(name, 11 + 1, "Y")
    assert Buffer.get_local(name, "m2") == 12

    # a delete before pulls back; one spanning clamps to its start
    Buffer.delete_range(name, 0, 2)
    assert Buffer.get_local(name, "m1") == 5
    assert Buffer.get_local(name, "m2") == 10
    Buffer.delete_range(name, 4, 3)
    assert Buffer.get_local(name, "m1") == 4
    assert Buffer.get_local(name, "m2") == 7

    # insert_at_local on one marker shifts the other with it
    pos = Buffer.insert_at_local(name, "m1", "zz")
    assert pos == 6
    assert Buffer.get_local(name, "m1") == 6
    assert Buffer.get_local(name, "m2") == 9
  end

  test "the input starts at the mark across transmits, and typed input survives" do
    slug =
      eval!("""
      (execute* "first" '(backend "stub" script
        (((type user-msg text "first") (type chunk text "First reply.\\n"))
         ((type user-msg text "hello") (type chunk text "Second reply.\\n"))
         ((type user-msg text "again") (type chunk text "Third reply.\\n")))))
      """)
      |> String.trim("\"")

    buf = eval!(~s[(agent-buf "#{slug}")]) |> String.trim("\"")
    assert eventually(fn -> Buffer.text(buf) =~ "First reply." end)
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)
    assert input_empty?(buf)

    eval!(~s{(begin (switch-to-buffer! "#{buf}") (end-of-buffer!) #t)})
    press(~w(h e l l o))
    assert String.ends_with?(Buffer.text(buf), "hello")
    refute input_empty?(buf)
    press("RET")

    assert eventually(fn -> Buffer.text(buf) =~ "Second reply." end)
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)
    assert input_empty?(buf)

    eval!(~s{(begin (switch-to-buffer! "#{buf}") (end-of-buffer!) #t)})
    press(~w(a g a i n))
    assert String.ends_with?(Buffer.text(buf), "again")
    press("RET")

    assert eventually(fn -> Buffer.text(buf) =~ "Third reply." end)
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)
    assert input_empty?(buf)

    # the transcript holds every user line; the input region is empty
    text = Buffer.text(buf)
    assert text =~ ">>> you: hello"
    assert text =~ ">>> you: again"
    refute String.ends_with?(text, @marker)
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
