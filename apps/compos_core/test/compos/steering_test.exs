defmodule Compos.SteeringTest do
  @moduledoc """
  Steering is an explicit two-step interaction: non-empty RET queues text,
  then RET on the blank input promotes the oldest queued message. Boundary
  backends drain that promoted message at the next model-request boundary;
  push backends inject it into the live turn.
  """

  use ExUnit.Case

  alias Compos.Core.{Agent, Buffer, KeyDispatch, Session}

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(str), do: str |> String.graphemes() |> press()

  defp focus(buf) do
    {:ok, _} = Session.eval(~s[(begin (switch-to-buffer! "#{buf}") (end-of-buffer!))])
  end

  # queued messages live in the 'chat-queued local, not in the transcript
  defp queued_texts(buf), do: Buffer.get_local(buf, "chat-queued") || []

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
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(50)
        eventually(fun, tries - 1)
    end
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:compos_core, :llm_chat_fun)
      Enum.each(Agent.list(), &Agent.kill/1)

      Enum.each(Compos.Core.list_buffers(), fn name ->
        if String.starts_with?(name, "*chat:") or Buffer.get_local(name, "agent-slug"),
          do: Compos.Core.kill_buffer(name)
      end)

      Compos.Core.Editor.delete_other_windows()
    end)

    :ok
  end

  test "RET mid-turn moves the message into the transcript and frees the input" do
    {slug, buf} = paused_stub_chat("go")

    assert eventually(fn -> match?(%{status: :needs_attention}, Agent.info(slug)) end)

    focus(buf)
    type("steer me please")
    press(["RET"])

    # the message left the input and sits in 'chat-queued, not in the
    # transcript text — a streamed event must never repaint it
    assert eventually(fn -> Agent.info(slug).queued == 1 end)
    assert queued_texts(buf) == ["steer me please"]
    refute Buffer.text(buf) =~ "steer me please"
    assert eval!(~s{(chat-input-text "#{buf}")}) == ~s{""}

    # the input is free: a second message queues behind the first
    type("and another thing")
    press(["RET"])
    assert eventually(fn -> Agent.info(slug).queued == 2 end)
    assert queued_texts(buf) == ["steer me please", "and another thing"]
    assert eval!(~s{(chat-input-text "#{buf}")}) == ~s{""}

    # the turn ends; the queue pops in order and the texts become normal
    # user lines — nothing stays queued
    assert Agent.respond_permission(slug, 3, "opt-allow") == :ok
    assert eventually(fn -> queued_texts(buf) == [] end)
    assert eventually(fn -> match?(%{status: :idle, queued: 0}, Agent.info(slug)) end)
    assert Buffer.text(buf) =~ ">>> you: steer me please"
    assert Buffer.text(buf) =~ ">>> you: and another thing"
  end

  test "abort discards the queued message" do
    {slug, buf} = paused_stub_chat("go")

    assert eventually(fn -> match?(%{status: :needs_attention}, Agent.info(slug)) end)

    focus(buf)
    type("never mind this")
    press(["RET"])
    assert eventually(fn -> Agent.info(slug).queued == 1 end)
    assert queued_texts(buf) == ["never mind this"]

    press(["C-g"])

    assert eventually(fn -> queued_texts(buf) == [] end)
    refute Buffer.text(buf) =~ "never mind this"
  end

  test "chat-unqueue takes the newest queued message back into the input" do
    {slug, buf} = paused_stub_chat("go")

    assert eventually(fn -> match?(%{status: :needs_attention}, Agent.info(slug)) end)

    focus(buf)
    type("first steer")
    press(["RET"])
    type("second steer")
    press(["RET"])
    assert eventually(fn -> Agent.info(slug).queued == 2 end)

    # C-c C-d: the newest message leaves the queue and returns to the input
    press(["C-c", "C-d"])
    assert eventually(fn -> Agent.info(slug).queued == 1 end)
    assert queued_texts(buf) == ["first steer"]
    assert eval!(~s{(chat-input-text "#{buf}")}) == ~s{"second steer"}

    # again: the older message joins ahead of the draft
    press(["C-c", "C-d"])
    assert eventually(fn -> Agent.info(slug).queued == 0 end)
    assert queued_texts(buf) == []
    assert eval!(~s{(chat-input-text "#{buf}")}) == ~s{"first steer\\nsecond steer"}

    # nothing queued: the command only says so
    press(["C-c", "C-d"])
    assert eval!(~s{(chat-input-text "#{buf}")}) == ~s{"first steer\\nsecond steer"}
  end

  test "the tool loop appends steered text to the tool-result message" do
    Process.put(:zz_round, 0)
    Process.put(:zz_records, [])
    Process.put(:zz_steered, false)

    Application.put_env(:compos_core, :llm_chat_fun, fn req ->
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
          {:ok,
           %{"stop_reason" => "end_turn", "content" => [%{"type" => "text", "text" => "ok"}]}}
      end
    end)

    assert {:ok, "ok", _usage, "end_turn"} =
             Compos.Core.LLM.run_tool_loop(
               [%{role: "user", content: "go"}],
               "sys",
               [],
               nil,
               tool_handler: fn _name, _input -> {:ok, "tool ran"} end,
               steer: fn ->
                 if Process.get(:zz_steered) do
                   []
                 else
                   Process.put(:zz_steered, true)
                   ["change course"]
                 end
               end,
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

  test "the tool loop continues immediately when steering follows a normal response" do
    Process.put(:zz_round, 0)
    Process.put(:zz_steered, false)

    Application.put_env(:compos_core, :llm_chat_fun, fn req ->
      round = Process.get(:zz_round)
      Process.put(:zz_round, round + 1)
      Process.put({:zz_normal_req, round}, req.messages)

      text = if round == 0, do: "first answer", else: "revised answer"
      {:ok, %{"stop_reason" => "end_turn", "content" => [%{"type" => "text", "text" => text}]}}
    end)

    assert {:ok, "revised answer", _usage, "end_turn"} =
             Compos.Core.LLM.run_tool_loop(
               [%{role: "user", content: "go"}],
               "sys",
               [],
               nil,
               steer: fn ->
                 if Process.get(:zz_steered) do
                   []
                 else
                   Process.put(:zz_steered, true)
                   ["change course"]
                 end
               end
             )

    %{role: "user", content: [%{"type" => "text", "text" => "change course"}]} =
      Process.get({:zz_normal_req, 1}) |> List.last()
  end

  test "the direct lane steers a queued prompt into the running turn" do
    test_pid = self()

    Application.put_env(:compos_core, :llm_chat_fun, fn req ->
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

    # Round 1 is on the wire. A non-empty RET only queues the message.
    assert_receive {:llm_req, _messages, worker}, 10_000
    focus(buf)
    type("actually, do less")
    press(["RET"])
    type("keep this for later")
    press(["RET"])
    assert eventually(fn -> Agent.info(slug).queued == 2 end)
    assert queued_texts(buf) == ["actually, do less", "keep this for later"]

    # RET on the now-blank input promotes only the oldest queued message.
    press(["RET"])
    assert Agent.info(slug).queued == 2

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
    refute Enum.any?(content, &match?(%{"type" => "text", "text" => "keep this for later"}, &1))
    assert eventually(fn -> queued_texts(buf) == ["keep this for later"] end)

    send(
      worker2,
      {:reply,
       {:ok, %{"stop_reason" => "end_turn", "content" => [%{"type" => "text", "text" => "done"}]}}}
    )

    # The steered message is not re-run. The second FIFO row starts normally
    # only after the original turn finishes.
    assert eventually(fn -> Buffer.text(buf) =~ ">>> you: actually, do less" end)
    assert_receive {:llm_req, followup, worker3}, 10_000
    assert %{role: "user", content: "keep this for later"} = List.last(followup)

    send(
      worker3,
      {:reply,
       {:ok,
        %{"stop_reason" => "end_turn", "content" => [%{"type" => "text", "text" => "all done"}]}}}
    )

    assert eventually(fn -> match?(%{status: :idle, queued: 0}, Agent.info(slug)) end)
    assert eventually(fn -> Buffer.text(buf) =~ "all done" end)
  end
end
