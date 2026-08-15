defmodule Aimax.ChatCompactTest do
  @moduledoc """
  Compaction is manual.

  It fired by itself at the end of every turn until the prompt cache
  started working. A cached prefix costs a tenth of a fresh one, so
  resending a long chat is cheap while a compaction pays for the summary
  and rewrites the cache. The threshold now only SUGGESTS it; M-x
  chat-compact is the user's to run.
  """

  use ExUnit.Case

  alias Aimax.Core.{Editor, Session}

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp eventually(f, tries \\ 60) do
    cond do
      f.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(f, tries - 1)
    end
  end

  defp turn(role, text), do: ~s{(list 'role "#{role}" 'blocks (list (list "text" "#{text}")))}

  # a chat buffer holding N text turns, newest first
  defp chat_with_turns!(n) do
    eval!(~s{(begin (switch-to-buffer! (group-chat "compactg")) (set-mode! "chat-mode"))})

    turns =
      for i <- n..1//-1,
          do: turn(if(rem(i, 2) == 1, do: "user", else: "assistant"), "turn #{i}")

    eval!(~s{(buffer-set-local! (current-buffer) 'chat-wire-turns (list #{Enum.join(turns, " ")}))})
  end

  setup do
    Application.put_env(:aimax_core, :llm_request_fun, fn _p -> {:ok, "THE SUMMARY"} end)

    on_exit(fn ->
      Application.delete_env(:aimax_core, :llm_request_fun)
      Session.eval(~s{(kill-buffer! (group-chat "compactg"))})
    end)

    :ok
  end

  test "M-x chat-compact summarizes the head and keeps the recent turns" do
    # 20 turns, keep 8 then on to the next user message
    chat_with_turns!(20)
    keep = eval!(~s{(chat-compact-keep-count (chat-record (current-buffer)))})

    eval!(~s{(run-command "chat-compact")})
    assert Editor.snapshot().echo =~ "compacting"

    assert eventually(fn ->
             eval!(~s{(length (chat-record (current-buffer)))}) == "#{String.to_integer(keep) + 1}"
           end)

    record = eval!(~s{(buffer-local (current-buffer) 'chat-wire-turns)})
    assert record =~ "THE SUMMARY"
    assert record =~ "compacted to notes"
    # the newest turns stayed verbatim; the oldest went into the summary
    assert record =~ "turn 20"
    refute record =~ "turn 1\""
  end

  test "a chat with nothing to compact says so and does not call the model" do
    chat_with_turns!(3)

    eval!(~s{(run-command "chat-compact")})
    assert Editor.snapshot().echo =~ "nothing to compact"
    assert eval!(~s{(length (chat-record (current-buffer)))}) == "3"
    assert eval!(~s{(if (buffer-local (current-buffer) 'chat-compacting) #t #f)}) == "#f"
  end

  test "a compaction already in flight is not started twice" do
    chat_with_turns!(20)
    eval!(~s{(buffer-set-local! (current-buffer) 'chat-compacting 4)})

    eval!(~s{(run-command "chat-compact")})
    assert Editor.snapshot().echo =~ "already in flight"
  end

  test "chat-compact refuses a buffer that is not a chat" do
    eval!(~s{(switch-to-buffer! "*not-a-chat*")})
    on_exit(fn -> Session.eval(~s{(kill-buffer! "*not-a-chat*")}) end)

    eval!(~s{(run-command "chat-compact")})
    assert Editor.snapshot().echo =~ "not a chat buffer"
  end

  test "the threshold suggests, it does not act" do
    chat_with_turns!(20)

    old = eval!(~s{chat-compact-threshold})
    # 1 token: every chat is over it
    eval!(~s{(set-symbol-value! 'chat-compact-threshold 1)})
    assert eval!(~s{(if (chat-should-compact? (current-buffer)) #t #f)}) == "#t"

    # the record is untouched: nothing compacts without the command
    assert eval!(~s{(length (chat-record (current-buffer)))}) == "20"
    refute eval!(~s{(buffer-local (current-buffer) 'chat-wire-turns)}) =~ "THE SUMMARY"

    eval!(~s{(set-symbol-value! 'chat-compact-threshold #{old})})
  end

  test "a chat with no runtime compacts without a transcript line" do
    chat_with_turns!(20)
    eval!(~s{(buffer-set-local! (current-buffer) 'agent-slug #f)})

    eval!(~s{(run-command "chat-compact")})

    assert eventually(fn ->
             eval!(~s{(buffer-local (current-buffer) 'chat-wire-turns)}) =~ "THE SUMMARY"
           end)

    refute eval!(~s{(buffer-text (current-buffer))}) =~ "compacted"
  end
end
