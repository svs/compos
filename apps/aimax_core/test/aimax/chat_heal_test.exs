defmodule Aimax.ChatHealTest do
  @moduledoc """
  A tool call and its result are one unit on the wire.

  The provider rejects a result whose call it cannot see ("No tool call
  found for function call output"), and it rejects a call whose result
  never came. One such request wedges the whole chat, because every later
  turn replays the same broken prefix. The record heals itself before each
  send, and compaction no longer cuts a tool round in half.
  """

  use ExUnit.Case

  alias Aimax.Core.{Editor, Session}

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  # a record, newest first, in one buffer local
  defp put_record!(buf, turns) do
    eval!(~s{(buffer-set-local! "#{buf}" 'chat-wire-turns (list #{turns}))})
  end

  defp turn(role, blocks), do: ~s{(list 'role "#{role}" 'blocks (list #{blocks}))}
  defp text(t), do: ~s{(list "text" "#{t}")}
  defp call(id), do: ~s[(list "tool-use" "#{id}" "eval-scheme" "{}")]
  defp result(id), do: ~s{(list "tool-result" "#{id}" "42" #f)}

  setup do
    eval!(~s{(switch-to-buffer! "*heal-test*")})
    on_exit(fn -> Session.eval(~s{(kill-buffer! "*heal-test*")}) end)
    :ok
  end

  test "a result whose call is gone loses the result, not the conversation" do
    # newest first: the compacted summary swallowed the assistant turn that
    # made the call, and only the results turn survived
    put_record!("*heal-test*", [
      turn("assistant", text("done")),
      turn("user", result("tu_1")),
      turn("user", text("[compacted]"))
    ] |> Enum.join(" "))

    assert eval!(~s{(chat-heal! "*heal-test*")}) == "1"

    # the orphaned result is gone; both prose turns stay
    refute eval!(~s{(buffer-local "*heal-test*" 'chat-wire-turns)}) =~ "tool-result"
    assert eval!(~s{(length (chat-turns "*heal-test*"))}) == "2"
  end

  test "a call whose result never came loses the call" do
    # an aborted turn: the assistant asked for a tool, nothing answered
    put_record!("*heal-test*", [
      turn("assistant", call("tu_9")),
      turn("user", text("hello"))
    ] |> Enum.join(" "))

    assert eval!(~s{(chat-heal! "*heal-test*")}) == "1"
    # the assistant turn held nothing else, so the turn goes with it
    assert eval!(~s{(length (buffer-local "*heal-test*" 'chat-wire-turns))}) == "1"
  end

  test "a whole tool round survives, and healing writes nothing" do
    record =
      [
        turn("assistant", text("done")),
        turn("user", result("tu_1")),
        turn("assistant", ~s{#{text("calling")} #{call("tu_1")}}),
        turn("user", text("hello"))
      ]
      |> Enum.join(" ")

    put_record!("*heal-test*", record)
    before = eval!(~s{(buffer-local "*heal-test*" 'chat-wire-turns)})

    assert eval!(~s{(chat-heal! "*heal-test*")}) == "0"
    assert eval!(~s{(buffer-local "*heal-test*" 'chat-wire-turns)}) == before
  end

  test "healing keeps the text of a turn whose call it drops" do
    put_record!("*heal-test*", [
      turn("assistant", ~s{#{text("I will look")} #{call("tu_7")}}),
      turn("user", text("hello"))
    ] |> Enum.join(" "))

    assert eval!(~s{(chat-heal! "*heal-test*")}) == "1"
    assert eval!(~s{(buffer-local "*heal-test*" 'chat-wire-turns)}) =~ "I will look"
    assert eval!(~s{(length (buffer-local "*heal-test*" 'chat-wire-turns))}) == "2"
  end

  test "healing keeps a turn's wire text" do
    eval!(~s{(buffer-set-local! "*heal-test*" 'chat-wire-turns
               (list (list 'role "user" 'blocks (list #{result("tu_x")}))
                     (list 'role "user" 'blocks (list #{text("hi")}) 'wire "hi + context")))})

    assert eval!(~s{(chat-heal! "*heal-test*")}) == "1"
    assert eval!(~s{(buffer-local "*heal-test*" 'chat-wire-turns)}) =~ "hi + context"
  end

  test "the compaction window opens on a user message, never on tool results" do
    # newest first. With chat-compact-keep at 1 the window used to stop at
    # the results turn — a "user" role that is not a user message.
    record =
      [
        turn("assistant", text("done")),
        turn("user", result("tu_1")),
        turn("assistant", call("tu_1")),
        turn("user", text("do it")),
        turn("assistant", text("older")),
        turn("user", text("older question"))
      ]
      |> Enum.join(" ")

    old = eval!(~s{chat-compact-keep})
    eval!(~s{(set-symbol-value! 'chat-compact-keep 1)})
    keep = eval!(~s{(chat-compact-keep-count (list #{record}))})
    eval!(~s{(set-symbol-value! 'chat-compact-keep #{old})})

    # 4: everything back to the "do it" that started the round
    assert keep == "4"
  end

  test "M-x chat-heal reports what it dropped" do
    eval!(~s{(begin (switch-to-buffer! (group-chat "healg")) (set-mode! "chat-mode"))})

    on_exit(fn -> Session.eval(~s{(kill-buffer! (group-chat "healg"))}) end)

    eval!(~s{(buffer-set-local! (current-buffer) 'chat-wire-turns
               (list (list 'role "user" 'blocks (list #{result("tu_z")}))))})

    eval!(~s{(run-command "chat-heal")})
    assert Editor.snapshot().echo =~ "dropped 1 orphaned tool block"

    eval!(~s{(run-command "chat-heal")})
    assert Editor.snapshot().echo =~ "record is whole"
  end
end
