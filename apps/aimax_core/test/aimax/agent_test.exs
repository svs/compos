defmodule Aimax.AgentTest.FakeTransport do
  @moduledoc """
  The ACP test seam: frames the Agent sends arrive in the test process as
  `{:frame, decoded_map}`; the test injects adapter output with
  `send(agent, {:acp_data, json <> "\n"})`.
  """

  @behaviour Aimax.Core.Agent.Transport

  @impl true
  def open(_cmd, _opts, owner) do
    test = :persistent_term.get(:agent_test_pid)
    send(test, {:transport_open, owner})
    {:ok, test}
  end

  @impl true
  def send_frame(test, data) do
    send(test, {:frame, Jason.decode!(IO.iodata_to_binary(data))})
    :ok
  end

  @impl true
  def close(_test), do: :ok
end

defmodule Aimax.AgentTest do
  @moduledoc "Drives agent threads through keys + the FakeTransport — no adapter binary."

  use ExUnit.Case

  alias Aimax.Core.{Agent, Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(str), do: str |> String.graphemes() |> press()

  setup do
    :persistent_term.put(:agent_test_pid, self())
    Application.put_env(:aimax_core, :acp_transport, Aimax.AgentTest.FakeTransport)

    Editor.minibuffer_close()
    Editor.delete_other_windows()

    on_exit(fn ->
      Application.delete_env(:aimax_core, :acp_transport)
      Enum.each(Agent.list(), &Agent.kill/1)

      Enum.each(Aimax.Core.list_buffers(), fn name ->
        if String.starts_with?(name, "*agent"), do: Aimax.Core.kill_buffer(name)
      end)

      # (execute) pops a window — don't leak it into later suites
      Editor.delete_other_windows()
    end)

    :ok
  end

  defp inject(agent, frame),
    do: send(agent, {:acp_data, Jason.encode!(frame) <> "\n"})

  defp update(agent, sid, update) do
    inject(agent, %{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => sid, "update" => update}
    })
  end

  # boot a thread through (execute ...) and complete the ACP handshake
  defp boot(task) do
    {:ok, _} = Session.eval(~s[(execute "#{task}")])
    assert_receive {:transport_open, agent}, 1_000

    assert_receive {:frame, %{"method" => "initialize", "id" => iid}}, 1_000
    inject(agent, %{"jsonrpc" => "2.0", "id" => iid, "result" => %{"protocolVersion" => 1}})

    assert_receive {:frame, %{"method" => "session/new", "id" => nid, "params" => np}}, 1_000
    assert is_binary(np["cwd"])
    inject(agent, %{"jsonrpc" => "2.0", "id" => nid, "result" => %{"sessionId" => "sess-1"}})

    {"a1", "*agent: a1*", agent}
  end

  defp focus(buf) do
    {:ok, _} = Session.eval(~s[(begin (switch-to-buffer! "#{buf}") (end-of-buffer!))])
  end

  test "execute: handshake, banner, marker, initial prompt sent after session/new" do
    {_slug, buf, agent} = boot("fix the bug")

    # initial task was queued during :starting and fires once idle
    assert_receive {:frame, %{"method" => "session/prompt", "params" => p}}, 1_000
    assert [%{"type" => "text", "text" => "fix the bug"}] = p["prompt"]
    assert p["sessionId"] == "sess-1"

    assert Buffer.text(buf) =~ ";; agent thread · a1"
    assert Buffer.text(buf) =~ "╰─ you ▸"
    assert %{status: :running} = Agent.info("a1")
    _ = agent
  end

  test "chunks stream in order across a tool-call interleave; body folds on completion" do
    {slug, buf, agent} = boot("")

    {:ok, _} = Session.eval(~s[(agent-prompt! "#{slug}" "go")])
    assert_receive {:frame, %{"method" => "session/prompt", "id" => pid}}, 1_000

    update(agent, "sess-1", %{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{"type" => "text", "text" => "Hello "}
    })

    update(agent, "sess-1", %{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{"type" => "text", "text" => "world.\n"}
    })

    update(agent, "sess-1", %{
      "sessionUpdate" => "tool_call",
      "toolCallId" => "tc1",
      "title" => "Read foo.ex",
      "kind" => "read",
      "status" => "pending"
    })

    update(agent, "sess-1", %{
      "sessionUpdate" => "tool_call_update",
      "toolCallId" => "tc1",
      "status" => "completed",
      "content" => [
        %{"type" => "content", "content" => %{"type" => "text", "text" => "defmodule Foo\n"}}
      ]
    })

    update(agent, "sess-1", %{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{"type" => "text", "text" => "Done."}
    })

    inject(agent, %{"jsonrpc" => "2.0", "id" => pid, "result" => %{"stopReason" => "end_turn"}})

    assert eventually(fn -> Buffer.text(buf) =~ "Done." end)

    text = Buffer.text(buf)
    hello = :binary.match(text, "Hello world.") |> elem(0)
    tool = :binary.match(text, "▸ read · Read foo.ex") |> elem(0)
    body = :binary.match(text, "defmodule Foo") |> elem(0)
    done = :binary.match(text, "Done.") |> elem(0)
    assert hello < tool and tool < body and body < done

    # tool body hidden; marker still at the very end
    assert [{s, e} | _] = Buffer.hidden(buf)
    assert s <= body and body < e
    assert Buffer.text(buf) =~ "╰─ you ▸"
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)
  end

  test "typing at the marker + RET steers; queued while running; queue pops on turn end" do
    {slug, buf, agent} = boot("")
    focus(buf)

    type("first message")
    press(["RET"])

    assert_receive {:frame, %{"method" => "session/prompt", "id" => pid, "params" => p}}, 1_000
    assert [%{"text" => "first message"}] = p["prompt"]
    # input region cleared back to the marker; message echoed into the transcript
    assert eventually(fn -> String.ends_with?(Buffer.text(buf), "╰─ you ▸ ") end)
    assert eventually(fn -> Buffer.text(buf) =~ "╰─ you ▸ first message\n" end)

    # second message while running -> queued, no frame yet
    focus(buf)
    type("second message")
    press(["RET"])
    refute_receive {:frame, %{"method" => "session/prompt"}}, 200
    assert %{queued: 1} = Agent.info(slug)

    inject(agent, %{"jsonrpc" => "2.0", "id" => pid, "result" => %{"stopReason" => "end_turn"}})

    assert_receive {:frame, %{"method" => "session/prompt", "params" => p2}}, 1_000
    assert [%{"text" => "second message"}] = p2["prompt"]
  end

  test "permission request: needs_attention, inline banner, C-c C-y answers allow option" do
    {slug, buf, agent} = boot("")

    {:ok, _} = Session.eval(~s[(agent-prompt! "#{slug}" "edit stuff")])
    assert_receive {:frame, %{"method" => "session/prompt"}}, 1_000

    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => 77,
      "method" => "session/request_permission",
      "params" => %{
        "sessionId" => "sess-1",
        "toolCall" => %{"title" => "Write foo.ex", "kind" => "edit"},
        "options" => [
          %{"optionId" => "opt-allow", "name" => "Allow", "kind" => "allow_once"},
          %{"optionId" => "opt-reject", "name" => "Reject", "kind" => "reject_once"}
        ]
      }
    })

    assert eventually(fn -> Buffer.text(buf) =~ "needs permission: Write foo.ex" end)
    assert %{status: :needs_attention} = Agent.info(slug)

    focus(buf)
    press(["C-c", "C-y"])

    assert_receive {:frame, %{"id" => 77, "result" => %{"outcome" => outcome}}}, 1_000
    assert outcome == %{"outcome" => "selected", "optionId" => "opt-allow"}
    assert eventually(fn -> match?(%{status: :running}, Agent.info(slug)) end)
  end

  test "C-RET cancels the running turn" do
    {slug, buf, agent} = boot("")

    {:ok, _} = Session.eval(~s[(agent-prompt! "#{slug}" "long task")])
    assert_receive {:frame, %{"method" => "session/prompt"}}, 1_000

    focus(buf)
    press(["C-RET"])

    assert_receive {:frame, %{"method" => "session/cancel", "params" => %{"sessionId" => "sess-1"}}},
                   1_000

    _ = agent
  end

  test "connectors: named config resolves into the session; per-call opts win" do
    {:ok, _} =
      Session.eval(~s{(define-connector! "test-conn" '(cwd "/tmp/conn-home" cmd "fake-acp"))})

    {:ok, _} = Session.eval(~s{(execute* "" '(connector "test-conn"))})
    assert_receive {:transport_open, agent}, 1_000
    assert_receive {:frame, %{"method" => "initialize", "id" => iid}}, 1_000
    inject(agent, %{"jsonrpc" => "2.0", "id" => iid, "result" => %{}})

    assert_receive {:frame, %{"method" => "session/new", "params" => %{"cwd" => "/tmp/conn-home"}}},
                   1_000

    assert {:ok, ~s["test-conn"]} =
             Session.eval(~s[(buffer-local (agent-buffer "a1") 'agent-connector)])
  end

  test "desktop: agent transcript, folds, and overlays survive restore; dead thread says so" do
    {slug, buf, agent} = boot("")

    {:ok, _} = Session.eval(~s[(agent-prompt! "#{slug}" "go")])
    assert_receive {:frame, %{"method" => "session/prompt", "id" => pid}}, 1_000

    update(agent, "sess-1", %{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{"type" => "text", "text" => "Hello world.\n"}
    })

    update(agent, "sess-1", %{
      "sessionUpdate" => "tool_call",
      "toolCallId" => "tc1",
      "title" => "Read foo.ex",
      "kind" => "read",
      "status" => "pending"
    })

    update(agent, "sess-1", %{
      "sessionUpdate" => "tool_call_update",
      "toolCallId" => "tc1",
      "status" => "completed",
      "content" => [
        %{"type" => "content", "content" => %{"type" => "text", "text" => "defmodule Foo\n"}}
      ]
    })

    inject(agent, %{"jsonrpc" => "2.0", "id" => pid, "result" => %{"stopReason" => "end_turn"}})
    assert eventually(fn -> Buffer.text(buf) =~ "defmodule Foo" end)
    assert eventually(fn -> Buffer.hidden(buf) != [] end)
    hidden = Buffer.hidden(buf)

    assert :ok = Aimax.Core.Desktop.save_now()

    # a daemon restart: the agent process and the buffer are both gone
    Agent.kill(slug)
    Aimax.Core.kill_buffer(buf)
    assert eventually(fn -> not Buffer.exists?(buf) end)

    assert :ok = Aimax.Core.Desktop.restore_now()

    assert Buffer.text(buf) =~ "Hello world."
    assert Buffer.text(buf) =~ "defmodule Foo"
    assert Buffer.get_local(buf, "mode-name") == "agent-mode"
    # mode setup rebuilt presentation from the persisted locals (live overlays
    # drift as appends land at their edges — the locals hold authored ranges)
    assert Buffer.hidden(buf) == hidden
    assert Buffer.overlays(buf) |> Enum.map(&Tuple.to_list/1) ==
             Buffer.get_local(buf, "agent-overlays")

    # local keys are back but the thread is dead: RET explains, no crash
    focus(buf)
    press(["RET"])
    assert Editor.snapshot().echo =~ "agent exited"
  end

  test "adapter exit renders a death notice and marks the thread dead" do
    {slug, buf, agent} = boot("")

    send(agent, {:acp_exit, 1})

    assert eventually(fn -> Buffer.text(buf) =~ "[agent exited]" end)
    assert eventually(fn -> match?(%{status: :dead}, Agent.info(slug)) end)
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
