defmodule Aimax.ApiLaneTest do
  @moduledoc """
  W3's done-when: the direct API lane is a thread like any other. One chat,
  driven through KeyDispatch, gets streaming prose, a tool card, mid-turn
  queueing, C-RET cancel, and cost — the capabilities the old api lane
  didn't have, on the same code path ACP uses.
  """

  use ExUnit.Case

  alias Aimax.Core.{Agent, Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(str), do: str |> String.graphemes() |> press()

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp focus(buf),
    do: {:ok, _} = Session.eval(~s[(begin (switch-to-buffer! "#{buf}") (end-of-buffer!))])

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()

    on_exit(fn ->
      Application.delete_env(:aimax_core, :llm_chat_fun)
      Enum.each(Agent.list(), &Agent.kill/1)

      Enum.each(Aimax.Core.list_buffers(), fn name ->
        if String.starts_with?(name, "*chat:") or Buffer.get_local(name, "agent-slug"),
          do: Aimax.Core.kill_buffer(name)
      end)

      Editor.delete_other_windows()
    end)

    :ok
  end

  defp stub_chat(fun) do
    Application.put_env(:aimax_core, :llm_chat_fun, fun)
  end

  test "an api chat streams, runs a tool with a card, prices the turn" do
    me = self()

    stub_chat(fn req ->
      if Enum.any?(req.messages, &(is_list(&1.content) and &1.content != [])) do
        # round 2: the tool result came back
        send(me, {:round2, req.messages})

        # a streaming wire pushes deltas; "streamed" tells the loop not to
        # re-emit the text
        req.on_chunk.("All ")
        req.on_chunk.("set.")

        {:ok,
         %{
           "stop_reason" => "end_turn",
           "streamed" => true,
           "content" => [%{"type" => "text", "text" => "All set."}],
           "usage" => %{"input_tokens" => 100, "output_tokens" => 20}
         }}
      else
        {:ok,
         %{
           "stop_reason" => "tool_use",
           "content" => [
             %{
               "type" => "tool_use",
               "id" => "tu_1",
               "name" => "eval-scheme",
               "input" => %{"code" => ~s{(+ 20 22)}}
             }
           ],
           "usage" => %{"input_tokens" => 50, "output_tokens" => 10}
         }}
      end
    end)

    {:ok, _} = Session.eval(~s{(execute* "what is 20+22" '(connector "api"))})
    buf = "*chat:a1*"

    assert eventually(fn -> Buffer.text(buf) =~ "All set." end)
    assert eventually(fn -> match?(%{status: :idle}, Agent.info("a1")) end)

    text = Buffer.text(buf)
    # the user turn, the tool card, its body, then the streamed prose
    you = :binary.match(text, "what is 20+22") |> elem(0)
    card = :binary.match(text, "▸ tool · eval-scheme") |> elem(0)
    body = :binary.match(text, "42") |> elem(0)
    done = :binary.match(text, "All set.") |> elem(0)
    assert you < card and card < body and body < done

    # the tool ran for real, through the Scheme registry
    assert_received {:round2, msgs}
    flat = inspect(msgs)
    assert flat =~ "42"

    # blocks map every span; the tool body folded closed on completion
    blocks = Buffer.get_local(buf, "agent-blocks") |> Enum.reverse()
    kinds = Enum.map(blocks, fn [_, _, k | _] -> k end)
    assert "user" in kinds and "tool" in kinds and "prose" in kinds
    assert [{s, e} | _] = Buffer.hidden(buf)
    assert s <= body and body < e

    # the record is the conversation truth — not buffer text. It holds the
    # tool round too: the call the model made and the result it got back.
    assert {:ok, ~s{(("user" "what is 20+22") ("assistant" "All set."))}} =
             Session.eval(~s{(reverse (chat-turns "#{buf}"))})

    kinds =
      for turn <- Enum.reverse(Buffer.get_local(buf, "chat-wire-turns")),
          block <- Aimax.Core.Agent.Backend.plist_get(turn, "blocks"),
          do: hd(block)

    assert kinds == ["text", "tool-use", "tool-result", "text"]

    # both rounds' usage summed onto the chat (pricing itself depends on
    # the models.dev catalog, so 'chat-cost only lands for a priced model)
    usage = Buffer.get_local(buf, "chat-last-usage")
    assert Enum.at(usage, Enum.find_index(usage, &(&1 == {:sym, "input"})) + 1) == 150
    assert Enum.at(usage, Enum.find_index(usage, &(&1 == {:sym, "output"})) + 1) == 30

    assert eventually(fn -> Buffer.get_local(buf, "modeline-info") =~ "api" end)
  end

  test "RET mid-turn queues and pops on turn end; C-RET cancels" do
    me = self()

    stub_chat(fn req ->
      # the stub runs INSIDE the turn task — hand the test its pid so the
      # turn can be held open and released deterministically
      send(me, {:sent, req.messages |> List.last() |> Map.get(:content), self()})

      receive do
        :release -> :ok
      after
        5_000 -> :ok
      end

      {:ok,
       %{
         "stop_reason" => "end_turn",
         "content" => [%{"type" => "text", "text" => "ok"}],
         "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
       }}
    end)

    {:ok, _} = Session.eval(~s{(execute* "" '(connector "api"))})
    buf = "*chat:a1*"
    focus(buf)

    type("first message")
    press(["RET"])
    assert_receive {:sent, first, task1}, 2_000
    assert first =~ "first message"

    # a second send while running: queued, kept visible (muted), no request
    focus(buf)
    type("second message")
    press(["RET"])
    refute_receive {:sent, _, _}, 200
    assert %{queued: 1} = Agent.info("a1")
    assert Buffer.text(buf) =~ ": second message"

    # release round 1 -> the queue pops by itself
    send(task1, :release)
    assert_receive {:sent, second, _task2}, 2_000
    assert second =~ "second message"

    # its turn started: the muted copy left the input region
    assert eventually(fn -> Buffer.text(buf) =~ ">>> you: second message\n" end)

    # C-RET cancels the running turn: the thread returns to idle without
    # waiting for the (still-blocked) wire
    focus(buf)
    press(["C-RET"])
    assert eventually(fn -> match?(%{status: :idle}, Agent.info("a1")) end)
  end

  test "C-g aborts the turn in flight, and quits the usual way when idle" do
    me = self()

    stub_chat(fn req ->
      send(me, {:sent, req.messages |> List.last() |> Map.get(:content), self()})

      receive do
        :release -> :ok
      after
        5_000 -> :ok
      end

      {:ok,
       %{
         "stop_reason" => "end_turn",
         "content" => [%{"type" => "text", "text" => "ok"}],
         "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
       }}
    end)

    {:ok, _} = Session.eval(~s{(execute* "" '(connector "api"))})
    buf = "*chat:a1*"
    focus(buf)

    type("a long question")
    press(["RET"])
    assert_receive {:sent, _, _task}, 2_000
    assert eventually(fn -> match?(%{status: :running}, Agent.info("a1")) end)

    press(["C-g"])
    assert eventually(fn -> match?(%{status: :idle}, Agent.info("a1")) end)

    # the thinking marker went with it
    refute Buffer.text(buf) =~ "thinking"

    # nothing running: C-g is keyboard-quit again, and the thread lives on
    focus(buf)
    press(["C-g"])
    assert %{status: :idle} = Agent.info("a1")
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
