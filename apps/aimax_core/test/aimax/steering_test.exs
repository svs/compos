defmodule Aimax.SteeringTest do
  @moduledoc """
  Steering: text typed while a turn runs joins that turn at its next tool
  round on the direct lane, instead of waiting for the turn to end. The
  thread drains its prompt queue (`Agent.take_steering/1`), the tool loop
  appends the text to the tool-result message, and the transcript echoes
  the message at the drain point.
  """

  use ExUnit.Case

  alias Aimax.Core.{Agent, Buffer, KeyDispatch, Session}

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(str), do: str |> String.graphemes() |> press()

  defp focus(buf) do
    {:ok, _} = Session.eval(~s[(begin (switch-to-buffer! "#{buf}") (end-of-buffer!))])
  end

  defp queued_blocks(buf) do
    Enum.filter(Buffer.get_local(buf, "agent-blocks") || [], fn
      [_, _, "queued" | _] -> true
      _ -> false
    end)
  end

  defp paused_stub_chat(prompt) do
    slug =
      String.trim(
        eval!("""
        (execute* "#{prompt}" '(permission-mode ask backend "stub" script
          (((type chunk text "working…")
            (type permission rpc-id 3 title "Write x" kind "edit"
                  options (("opt-allow" "Allow" "allow_once")))))))
        """),
        "\""
      )

    {slug, "*chat:#{slug}*"}
  end

  defp eventually(fun, tries \\ 80) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true ->
        Process.sleep(50)
        eventually(fun, tries - 1)
    end
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:aimax_core, :llm_chat_fun)
      Enum.each(Agent.list(), &Agent.kill/1)

      Enum.each(Aimax.Core.list_buffers(), fn name ->
        if String.starts_with?(name, "*chat:") or Buffer.get_local(name, "agent-slug"),
          do: Aimax.Core.kill_buffer(name)
      end)

      Aimax.Core.Editor.delete_other_windows()
    end)

    :ok
  end

  test "take_steering drains the queue into the running turn and echoes it" do
    {slug, buf} = paused_stub_chat("go")

    # the scripted turn pauses at the permission — the turn is running
    assert eventually(fn -> match?(%{status: :needs_attention}, Agent.info(slug)) end)

    # a prompt mid-turn queues instead of sending
    assert Agent.prompt(slug, "steer me") == :queued
    assert Agent.info(slug).queued == 1

    # the drain empties the queue and echoes the message into the transcript
    assert Agent.take_steering(slug) == [{"steer me", nil}]
    assert Agent.info(slug).queued == 0
    assert Agent.take_steering(slug) == []
    assert eventually(fn -> Buffer.text(buf) =~ ">>> you: steer me" end)

    # the turn ends with an empty queue: nothing runs twice
    assert Agent.respond_permission(slug, 3, "opt-allow") == :ok
    assert eventually(fn -> match?(%{status: :idle, queued: 0}, Agent.info(slug)) end)

    # an idle thread has nothing to steer
    assert Agent.take_steering(slug) == []
  end

  test "RET mid-turn moves the message into the transcript and frees the input" do
    {slug, buf} = paused_stub_chat("go")

    assert eventually(fn -> match?(%{status: :needs_attention}, Agent.info(slug)) end)

    focus(buf)
    type("steer me please")
    press(["RET"])

    # the message left the input and sits in the transcript as a muted line
    assert eventually(fn -> Agent.info(slug).queued == 1 end)
    assert Buffer.text(buf) =~ ">>> you: steer me please"
    assert [[_, _, "queued", "steer me please"]] = queued_blocks(buf)
    assert eval!(~s{(chat-input-text "#{buf}")}) == ~s{""}

    # the input is free: a second message queues behind the first
    type("and another thing")
    press(["RET"])
    assert eventually(fn -> Agent.info(slug).queued == 2 end)
    assert length(queued_blocks(buf)) == 2
    assert eval!(~s{(chat-input-text "#{buf}")}) == ~s{""}

    # the turn ends; the queue pops in order and the muted lines become
    # normal user lines — nothing stays queued
    assert Agent.respond_permission(slug, 3, "opt-allow") == :ok
    assert eventually(fn -> queued_blocks(buf) == [] end)
    assert eventually(fn -> match?(%{status: :idle, queued: 0}, Agent.info(slug)) end)
    assert Buffer.text(buf) =~ ">>> you: steer me please"
    assert Buffer.text(buf) =~ ">>> you: and another thing"
  end

  test "abort discards the queued message and its muted line" do
    {slug, buf} = paused_stub_chat("go")

    assert eventually(fn -> match?(%{status: :needs_attention}, Agent.info(slug)) end)

    focus(buf)
    type("never mind this")
    press(["RET"])
    assert eventually(fn -> Agent.info(slug).queued == 1 end)
    assert Buffer.text(buf) =~ ">>> you: never mind this"

    press(["C-g"])

    assert eventually(fn -> queued_blocks(buf) == [] end)
    refute Buffer.text(buf) =~ "never mind this"
  end

  test "the tool loop appends steered text to the tool-result message" do
    Process.put(:zz_round, 0)
    Process.put(:zz_records, [])

    Application.put_env(:aimax_core, :llm_chat_fun, fn req ->
      round = Process.get(:zz_round)
      Process.put(:zz_round, round + 1)
      Process.put({:zz_req, round}, req.messages)

      case round do
        0 ->
          {:ok,
           %{
             "stop_reason" => "tool_use",
             "content" => [
               %{"type" => "tool_use", "id" => "t1", "name" => "zz-x", "input" => %{}}
             ]
           }}

        _ ->
          {:ok, %{"stop_reason" => "end_turn", "content" => [%{"type" => "text", "text" => "ok"}]}}
      end
    end)

    assert {:ok, "ok", _usage, "end_turn"} =
             Aimax.Core.LLM.run_tool_loop(
               [%{role: "user", content: "go"}],
               "sys",
               [],
               nil,
               tool_handler: fn _name, _input -> {:ok, "tool ran"} end,
               steer: fn -> ["change course"] end,
               on_record: fn role, blocks ->
                 Process.put(:zz_records, Process.get(:zz_records) ++ [{role, blocks}])
               end
             )

    # the second request's last user message carries the result AND the text
    %{role: "user", content: content} = List.last(Process.get({:zz_req, 1}))

    assert [
             %{type: "tool_result", tool_use_id: "t1", content: "tool ran"},
             %{"type" => "text", "text" => "change course"}
           ] = content

    # the record keeps the merged turn, so a replay matches this wire
    assert {"user", ^content} =
             Enum.find(Process.get(:zz_records), &match?({"user", _}, &1))
  end

  test "the direct lane steers a queued prompt into the running turn" do
    test_pid = self()

    Application.put_env(:aimax_core, :llm_chat_fun, fn req ->
      send(test_pid, {:llm_req, req.messages, self()})

      receive do
        {:reply, resp} -> resp
      after
        15_000 -> {:error, "the test never replied"}
      end
    end)

    # a pure tool passes the effects verdict without a banner
    eval!("""
    (define-tool! 'zz-steer-probe "Test probe." '() (lambda (args) "probed") '(pure))
    """)

    slug =
      String.trim(eval!(~s{(execute* "" '(connector "api" permission-mode auto))}), "\"")

    buf = "*chat:#{slug}*"

    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)
    assert Agent.prompt(slug, "start the work") == :sent

    # round 1 is on the wire; the user types — it queues, not sends
    assert_receive {:llm_req, _messages, worker}, 10_000
    assert Agent.prompt(slug, "actually, do less") == :queued

    send(
      worker,
      {:reply,
       {:ok,
        %{
          "stop_reason" => "tool_use",
          "content" => [
            %{"type" => "tool_use", "id" => "t1", "name" => "zz-steer-probe", "input" => %{}}
          ]
        }}}
    )

    # round 2 carries the tool result AND the steered text in one message
    assert_receive {:llm_req, messages, worker2}, 10_000
    %{role: "user", content: content} = List.last(messages)
    assert Enum.any?(content, &match?(%{type: "tool_result", tool_use_id: "t1"}, &1))
    assert Enum.any?(content, &match?(%{"type" => "text", "text" => "actually, do less"}, &1))

    send(
      worker2,
      {:reply,
       {:ok, %{"stop_reason" => "end_turn", "content" => [%{"type" => "text", "text" => "done"}]}}}
    )

    # the transcript echoes the steered message; the queue never re-runs it
    assert eventually(fn -> Buffer.text(buf) =~ ">>> you: actually, do less" end)
    assert eventually(fn -> match?(%{status: :idle, queued: 0}, Agent.info(slug)) end)
    assert eventually(fn -> Buffer.text(buf) =~ "done" end)
  end
end
