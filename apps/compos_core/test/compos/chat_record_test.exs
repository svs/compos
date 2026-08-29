defmodule Compos.ChatRecordTest do
  @moduledoc """
  R1's done-when: one conversation of record.

  The record is what the model saw, not what the buffer shows. It holds the
  tool calls and the tool results, so the api lane replays each turn's
  history byte for byte. That is the whole point: a prefix that changes
  every turn can never hit a prompt cache, and rendered prose cannot
  reconstruct a prefix it never held.
  """

  use ExUnit.Case

  alias Compos.Core.{Agent, Buffer, Editor, KeyDispatch, Session}
  alias Compos.Core.Agent.Backend

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(str), do: str |> String.graphemes() |> press()

  # The save prompt arrives prefilled with a suggested file name. To choose a
  # different absolute path, a user types it over the prefill: the leading
  # slash makes the "//" that normalize-file-input reads as "start again
  # here", which is Emacs' rule.
  defp type_over_prefill(path), do: type("/" <> path)

  defp focus(buf),
    do: {:ok, _} = Session.eval(~s[(begin (switch-to-buffer! "#{buf}") (end-of-buffer!))])

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()

    on_exit(fn ->
      Application.delete_env(:compos_core, :llm_chat_fun)
      Enum.each(Agent.list(), &Agent.kill/1)

      Enum.each(Compos.Core.list_buffers(), fn name ->
        if String.starts_with?(name, "*chat:") or String.ends_with?(name, ".chat") or
             Buffer.get_local(name, "agent-slug"),
           do: Compos.Core.kill_buffer(name)
      end)

      Editor.delete_other_windows()
    end)

    :ok
  end

  # every request the wire sees, in order
  defp record_requests(pid) do
    Application.put_env(:compos_core, :llm_chat_fun, fn req ->
      send(pid, {:request, req.messages})

      case length(req.messages) do
        # turn 1, round 1: call a tool and say nothing at all — the turn
        # that used to record NOTHING (A2)
        1 ->
          {:ok,
           %{
             "stop_reason" => "tool_use",
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "tu_1",
                 "name" => "eval-scheme",
                 "input" => %{"code" => "(+ 20 22)"}
               }
             ],
             "usage" => %{"input_tokens" => 10, "output_tokens" => 2}
           }}

        _ ->
          {:ok,
           %{
             "stop_reason" => "end_turn",
             "content" => [%{"type" => "text", "text" => "42."}],
             "usage" => %{"input_tokens" => 20, "output_tokens" => 3}
           }}
      end
    end)
  end

  test "the second turn resends the first turn's history byte for byte" do
    record_requests(self())

    {:ok, _} = Session.eval(~s{(execute* "" '(connector "api"))})
    buf = "*chat:a1*"
    focus(buf)

    type("what is 20+22")
    press(["RET"])

    assert_receive {:request, _round1}, 2_000
    assert_receive {:request, round2}, 2_000
    assert eventually(fn -> match?(%{status: :idle}, Agent.info("a1")) end)

    # turn 1 ended having sent: the user message, the assistant's tool call,
    # the tool result
    assert [_user, %{role: "assistant"}, %{role: "user"}] = round2

    focus(buf)
    type("and 8*8")
    press(["RET"])

    assert_receive {:request, round3}, 2_000
    assert eventually(fn -> match?(%{status: :idle}, Agent.info("a1")) end)

    # THE invariant: everything turn 1 sent is the head of turn 2's
    # request, unchanged. Not "equivalent" — identical terms, which is what
    # a byte-identical wire prefix reduces to before encoding.
    assert Enum.take(round3, 3) == round2

    # ...and what follows is the reply and the new question, nothing else
    assert [_, _, _, %{role: "assistant"}, %{role: "user", content: last}] = round3
    assert last =~ "and 8*8"
  end

  test "a tool call the model made with no prose still lands in the record" do
    record_requests(self())

    {:ok, _} = Session.eval(~s{(execute* "" '(connector "api"))})
    buf = "*chat:a1*"
    focus(buf)

    type("what is 20+22")
    press(["RET"])

    assert eventually(fn -> Buffer.text(buf) =~ "42." end)
    assert eventually(fn -> match?(%{status: :idle}, Agent.info("a1")) end)

    turns = Buffer.get_local(buf, "chat-wire-turns") |> Enum.reverse()

    assert [user, call, result, reply] = turns
    assert Backend.plist_get(user, "role") == "user"
    assert [["text", "what is 20+22"]] = Backend.plist_get(user, "blocks")

    # the silent round: an assistant turn made of one tool call
    assert Backend.plist_get(call, "role") == "assistant"
    assert [["tool-use", "tu_1", "eval-scheme", input]] = Backend.plist_get(call, "blocks")
    assert Jason.decode!(input) == %{"code" => "(+ 20 22)"}

    # its result, as the wire carried it: a user turn of tool results
    assert Backend.plist_get(result, "role") == "user"
    assert [["tool-result", "tu_1", "42", false]] = Backend.plist_get(result, "blocks")

    assert [["text", "42."]] = Backend.plist_get(reply, "blocks")

    # a tool round is wire, not conversation: the display turns skip it
    assert {:ok, ~s{(("user" "what is 20+22") ("assistant" "42."))}} =
             Session.eval(~s{(reverse (chat-turns "#{buf}"))})
  end

  test "a .chat saved with tool blocks replays them after a kill and reopen" do
    dir = Path.join(System.tmp_dir!(), "chatrec-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "tools.chat")

    record_requests(self())

    {:ok, _} = Session.eval(~s{(execute* "" '(connector "api"))})
    buf = "*chat:a1*"
    focus(buf)

    type("what is 20+22")
    press(["RET"])

    assert eventually(fn -> Buffer.text(buf) =~ "42." end)
    assert eventually(fn -> match?(%{status: :idle}, Agent.info("a1")) end)

    before = shape(Buffer.get_local(buf, "chat-wire-turns"))

    focus(buf)
    {:ok, _} = Session.eval(~s{(run-command "save-buffer")})
    type_over_prefill(path)
    press(["RET"])

    saved = File.read!(path)
    # v1 still reads it: identity line, then the plain transcript
    assert saved =~ ~s{#+chat: (connector "api"}
    assert saved =~ "### You\nwhat is 20+22"
    assert saved =~ "### Assistant\n42."
    # ...and v2 carries what the transcript cannot say
    assert saved =~ "#+chat-record: "
    assert saved =~ "tool-use"

    Enum.each(Agent.list(), &Agent.kill/1)
    {:ok, _} = Session.eval(~s[(begin (buffer-kill! "#{path}") #t)])
    {:ok, _} = Session.eval(~s[(visit "#{path}")])

    # the blocks came back whole — the reopened chat can resend the same
    # prefix the killed one did
    assert shape(Buffer.get_local(path, "chat-wire-turns")) == before

    # and the surface is a chat again, not a file full of markers
    text = Buffer.text(path)
    assert text =~ ">>> you: what is 20+22"
    refute text =~ "#+chat-record:"
    refute text =~ "### You"
  end

  test "a v1 .chat with no record section still opens, with text turns" do
    dir = Path.join(System.tmp_dir!(), "chatrec-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, "old.chat")

    File.write!(path, """
    #+chat: (connector "api" permission-mode approve)

    ### You
    what shipped?

    ### Assistant
    the mail client

    ### You
    """)

    {:ok, _} = Session.eval(~s[(visit "#{path}")])

    assert {:ok, ~s{(("user" "what shipped?") ("assistant" "the mail client"))}} =
             Session.eval(~s{(reverse (chat-turns "#{path}"))})

    # a v1 file has no blocks to replay, so every turn is one text block
    for turn <- Buffer.get_local(path, "chat-wire-turns") do
      assert [["text", _]] = Backend.plist_get(turn, "blocks")
    end
  end

  # what a turn IS, oldest first. A file round trip goes through JSON, so
  # the plist keys come back in a different order — the reader takes them
  # by name and does not care, and neither does this.
  defp shape(turns) do
    for t <- Enum.reverse(turns || []) do
      {Backend.plist_get(t, "role"), Backend.plist_get(t, "blocks"),
       Backend.plist_get(t, "wire")}
    end
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
