defmodule Aimax.AgentTest.FakeTransport do
  @moduledoc """
  The ACP test seam: frames the Agent sends arrive in the test process as
  `{:frame, decoded_map}`; the test injects adapter output with
  `send(agent, {:acp_data, json <> "\n"})`.
  """

  @behaviour Aimax.Core.Agent.Transport

  @impl true
  def open(cmd, _opts, owner) do
    test = :persistent_term.get(:agent_test_pid)
    send(test, {:transport_open, owner})
    send(test, {:transport_cmd, cmd})
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
        if String.starts_with?(name, "*agent") or Buffer.get_local(name, "agent-slug"),
          do: Aimax.Core.kill_buffer(name)
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

  # boot a thread through (execute ...) and complete the ACP handshake.
  # Threads boot in ask mode here: these tests are about the banner flow,
  # and the default (approve) answers most requests without one.
  defp boot(task) do
    {:ok, _} = Session.eval(~s[(execute* "#{task}" '(permission-mode ask))])
    assert_receive {:transport_open, agent}, 1_000

    assert_receive {:frame, %{"method" => "initialize", "id" => iid}}, 1_000
    inject(agent, %{"jsonrpc" => "2.0", "id" => iid, "result" => %{"protocolVersion" => 1}})

    assert_receive {:frame, %{"method" => "session/new", "id" => nid, "params" => np}}, 1_000
    assert is_binary(np["cwd"])
    inject(agent, %{"jsonrpc" => "2.0", "id" => nid, "result" => %{"sessionId" => "sess-1"}})

    {"a1", "*chat:a1*", agent}
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

    assert Buffer.text(buf) =~ "chat · a1"
    assert Buffer.text(buf) =~ ">>> you:"
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
    assert Buffer.text(buf) =~ ">>> you:"
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)

    # the block model mapped every span: user turn, merged prose, closed tool
    blocks = Buffer.get_local(buf, "agent-blocks") |> Enum.reverse()
    kinds = Enum.map(blocks, fn [_, _, k | _] -> k end)
    assert "user" in kinds and "prose" in kinds and "tool" in kinds
    refute "waiting" in kinds

    [_, _, "tool", "tc1", "Read foo.ex", "read", "done", body_start] =
      Enum.find(blocks, fn [_, _, k | _] -> k == "tool" end)

    assert binary_part(text, body_start, 13) == "defmodule Foo"
    assert Buffer.get_local(buf, "render-mode") == "agent"
  end

  test "typing at the marker + RET steers; queued while running; queue pops on turn end" do
    {slug, buf, agent} = boot("")
    focus(buf)

    type("first message")
    press(["RET"])

    assert_receive {:frame, %{"method" => "session/prompt", "id" => pid, "params" => p}}, 1_000
    assert [%{"text" => "first message"}] = p["prompt"]
    # input region cleared back to the marker; message echoed into the transcript
    assert eventually(fn -> String.ends_with?(Buffer.text(buf), ">>> you: ") end)
    assert eventually(fn -> Buffer.text(buf) =~ ">>> you: first message\n" end)

    # second message while running -> queued: stays visible (muted), no frame yet
    focus(buf)
    type("second message")
    press(["RET"])
    refute_receive {:frame, %{"method" => "session/prompt"}}, 200
    assert %{queued: 1} = Agent.info(slug)
    assert Buffer.text(buf) =~ ": second message"

    inject(agent, %{"jsonrpc" => "2.0", "id" => pid, "result" => %{"stopReason" => "end_turn"}})

    assert_receive {:frame, %{"method" => "session/prompt", "params" => p2}}, 1_000
    assert [%{"text" => "second message"}] = p2["prompt"]
    # its turn started: the muted copy left the input region, the rendered
    # user line replaced it — exactly one occurrence remains
    assert eventually(fn -> Buffer.text(buf) =~ ">>> you: second message\n" end)

    assert eventually(fn ->
             parts = String.split(Buffer.text(buf), "second message")
             length(parts) == 2
           end)
  end

  test "codex-style connectors wire the model through the command line" do
    {:ok, cmd} =
      Session.eval(
        ~s[(plist-get (agent-resolve-config '(connector "codex" model "gpt-5.5")) 'cmd)]
      )

    assert cmd == ~s["codex-acp -c model=\\"gpt-5.5\\""]

    # and the FLAGGED cmd is what actually reaches the transport — duplicate
    # plist keys must resolve first-wins on the elixir side too
    {:ok, _} =
      Session.eval(~s{(execute* "" '(connector "codex" model "gpt-5.5" cmd "fake"))})

    assert_receive {:transport_open, _}, 1_000
    assert_receive {:transport_cmd, spawned}, 1_000
    assert spawned == ~s[fake -c model="gpt-5.5"]
  end

  test "the adapter's reported model is the modeline truth; C-c m switches in place" do
    {:ok, _} = Session.eval(~s[(execute "")])
    assert_receive {:transport_open, agent}, 1_000
    assert_receive {:frame, %{"method" => "initialize", "id" => iid}}, 1_000
    inject(agent, %{"jsonrpc" => "2.0", "id" => iid, "result" => %{"protocolVersion" => 1}})
    assert_receive {:frame, %{"method" => "session/new", "id" => nid}}, 1_000

    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => nid,
      "result" => %{
        "sessionId" => "sess-m",
        "models" => %{
          "currentModelId" => "claude-opus-4-6",
          "availableModels" => [
            %{"modelId" => "claude-opus-4-6", "name" => "Opus"},
            %{"modelId" => "claude-sonnet-5", "name" => "Sonnet"}
          ]
        }
      }
    })

    buf = "*chat:a1*"
    assert eventually(fn -> Buffer.get_local(buf, "agent-model") == "claude-opus-4-6" end)
    assert {:ok, ml} = Session.eval(~s[(buffer-local "#{buf}" 'modeline-info)])
    assert ml =~ "claude-opus-4-6"

    # C-c m: live switch over session/set_model — no reconnect, context kept
    focus(buf)
    press(["C-c", "m"])
    type("claude-sonnet-5")
    press(["RET"])

    assert_receive {:frame, %{"method" => "session/set_model", "params" => sp}}, 1_000
    assert sp["modelId"] == "claude-sonnet-5"
    assert sp["sessionId"] == "sess-m"
    assert eventually(fn -> Buffer.get_local(buf, "agent-model") == "claude-sonnet-5" end)
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

    # banner is in the block model while pending
    assert eventually(fn ->
             (Buffer.get_local(buf, "agent-blocks") || [])
             |> Enum.any?(&match?([_, _, "permission" | _], &1))
           end)

    focus(buf)
    press(["C-c", "C-y"])

    assert_receive {:frame, %{"id" => 77, "result" => %{"outcome" => outcome}}}, 1_000
    assert outcome == %{"outcome" => "selected", "optionId" => "opt-allow"}
    assert eventually(fn -> match?(%{status: :running}, Agent.info(slug)) end)

    # answered -> the stale banner leaves the rich view
    assert eventually(fn ->
             not ((Buffer.get_local(buf, "agent-blocks") || [])
                  |> Enum.any?(&match?([_, _, "permission" | _], &1)))
           end)
  end

  test "allow-always picks the allow_always option" do
    {slug, _buf, agent} = boot("")

    {:ok, _} = Session.eval(~s[(agent-prompt! "#{slug}" "go")])
    assert_receive {:frame, %{"method" => "session/prompt"}}, 1_000

    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => 88,
      "method" => "session/request_permission",
      "params" => %{
        "sessionId" => "sess-1",
        "toolCall" => %{"title" => "Bash", "kind" => "execute"},
        "options" => [
          %{"optionId" => "o-once", "name" => "Allow", "kind" => "allow_once"},
          %{"optionId" => "o-always", "name" => "Always", "kind" => "allow_always"},
          %{"optionId" => "o-no", "name" => "Reject", "kind" => "reject_once"}
        ]
      }
    })

    assert eventually(fn -> match?(%{status: :needs_attention}, Agent.info(slug)) end)
    focus("*chat:a1*")
    press(["C-c", "C-a"])

    assert_receive {:frame, %{"id" => 88, "result" => %{"outcome" => outcome}}}, 1_000
    assert outcome == %{"outcome" => "selected", "optionId" => "o-always"}
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
             Session.eval(~s[(buffer-local (agent-buf "a1") 'agent-connector)])

    # model choice is scoped to what the connector declares
    assert {:ok, models} = Session.eval(~s[(connector-models "claude-code")])
    assert models =~ "claude-sonnet-5"
    assert {:ok, "()"} = Session.eval(~s[(connector-models "test-conn")])
    assert {:ok, api_models} = Session.eval(~s[(connector-models "api")])
    assert api_models =~ "openrouter" or api_models =~ "claude"
  end

  test "desktop: agent transcript, folds, and overlays survive restore; thread revives on RET" do
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
    assert Buffer.get_local(buf, "mode-name") == "chat-mode"
    # mode setup rebuilt presentation from the persisted locals (live overlays
    # drift as appends land at their edges — the locals hold authored ranges)
    assert Buffer.hidden(buf) == hidden
    assert Buffer.overlays(buf) |> Enum.map(&Tuple.to_list/1) ==
             Buffer.get_local(buf, "agent-overlays")

    # local keys are back; interacting with the dead thread revives it
    focus(buf)
    press(["RET"])
    assert Editor.snapshot().echo =~ "revived"
    assert_receive {:transport_open, _fresh}, 1_000
  end

  test "RET on a dead thread revives it on its connector and sends" do
    {slug, buf, agent} = boot("")
    Agent.kill(slug)
    assert eventually(fn -> Agent.list() == [] end)

    focus(buf)
    type("are you alive")
    press(["RET"])

    # a fresh runtime attaches to the same buffer
    assert_receive {:transport_open, agent2}, 1_000
    assert agent2 != agent
    assert_receive {:frame, %{"method" => "initialize", "id" => iid}}, 1_000
    inject(agent2, %{"jsonrpc" => "2.0", "id" => iid, "result" => %{}})
    assert_receive {:frame, %{"method" => "session/new", "id" => nid}}, 1_000
    inject(agent2, %{"jsonrpc" => "2.0", "id" => nid, "result" => %{"sessionId" => "sess-2"}})

    assert_receive {:frame, %{"method" => "session/prompt", "params" => p}}, 1_000
    # an EMPTY conversation (meta card only) seeds nothing — the message
    # goes out bare; seeding with history is covered by the restart test
    [%{"text" => sent}] = p["prompt"]
    assert sent == "are you alive"
    refute sent =~ "Context: this continues an earlier conversation"
    assert eventually(fn -> Buffer.text(buf) =~ ">>> you: are you alive\n" end)
  end

  test "waiting line shows after send, clears on first output" do
    {slug, buf, agent} = boot("")

    {:ok, _} = Session.eval(~s[(agent-prompt! "#{slug}" "go")])
    assert_receive {:frame, %{"method" => "session/prompt", "id" => pid}}, 1_000
    assert eventually(fn -> Buffer.text(buf) =~ "⋯ thinking" end)

    update(agent, "sess-1", %{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{"type" => "text", "text" => "On it."}
    })

    assert eventually(fn -> Buffer.text(buf) =~ "On it." end)
    refute Buffer.text(buf) =~ "⋯ thinking"

    inject(agent, %{"jsonrpc" => "2.0", "id" => pid, "result" => %{"stopReason" => "end_turn"}})
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)
    refute Buffer.text(buf) =~ "⋯ thinking"
  end

  test "api connector: in-process thread, turns accumulate, no subprocess" do
    rounds = :ets.new(:api_rounds, [:public])

    Application.put_env(:aimax_core, :llm_chat_fun, fn %{messages: messages} ->
      n = :ets.info(rounds, :size) + 1
      :ets.insert(rounds, {n, messages})

      {:ok,
       %{
         "stop_reason" => "end_turn",
         "content" => [%{"type" => "text", "text" => "reply-#{n}"}],
         "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
       }}
    end)

    on_exit(fn -> Application.delete_env(:aimax_core, :llm_chat_fun) end)

    {:ok, _} = Session.eval(~s{(execute* "what is 6*7" '(connector "api"))})
    buf = "*chat:a1*"

    # no ACP handshake — no transport was opened
    refute_receive {:transport_open, _}, 200
    assert eventually(fn -> Buffer.text(buf) =~ "reply-1" end)
    assert eventually(fn -> match?(%{status: :idle}, Agent.info("a1")) end)

    focus(buf)
    type("and 8*8")
    press(["RET"])

    assert eventually(fn -> Buffer.text(buf) =~ "reply-2" end)

    # the second request replays the whole conversation from the record —
    # no private history in the runtime
    [{_, msgs} | _] = rounds |> :ets.tab2list() |> Enum.sort(:desc)
    flat = Enum.map_join(msgs, "\n", fn m -> inspect(m.content) end)
    assert flat =~ "what is 6*7"
    assert flat =~ "reply-1"
    assert flat =~ "and 8*8"

    # the modeline names the running backend and its model
    assert {:ok, ml} = Session.eval(~s[(buffer-local "*chat:a1*" 'modeline-info)])
    assert ml =~ "api"
  end

  test "a failed prompt returns the thread to idle instead of wedging in :running" do
    {slug, buf, agent} = boot("")

    {:ok, _} = Session.eval(~s[(agent-prompt! "#{slug}" "go")])
    assert_receive {:frame, %{"method" => "session/prompt", "id" => pid}}, 1_000

    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => pid,
      "error" => %{"code" => -32603, "message" => "Internal error"}
    })

    assert eventually(fn -> Buffer.text(buf) =~ "Internal error" end)
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)
    refute Buffer.text(buf) =~ "⋯ thinking"
  end

  test "*agents* fleet: sorted by attention, y answers the current line's thread" do
    # thread 1: running; thread 2: needs permission
    {_, _, agent1} = boot("")
    {:ok, _} = Session.eval(~s[(agent-prompt! "a1" "task one")])
    assert_receive {:frame, %{"method" => "session/prompt"}}, 1_000

    {:ok, _} = Session.eval(~s{(execute* "" '(permission-mode ask))})
    assert_receive {:transport_open, agent2}, 1_000
    assert_receive {:frame, %{"method" => "initialize", "id" => iid}}, 1_000
    inject(agent2, %{"jsonrpc" => "2.0", "id" => iid, "result" => %{}})
    assert_receive {:frame, %{"method" => "session/new", "id" => nid}}, 1_000
    inject(agent2, %{"jsonrpc" => "2.0", "id" => nid, "result" => %{"sessionId" => "sess-2"}})
    {:ok, _} = Session.eval(~s[(agent-prompt! "a2" "task two")])
    assert_receive {:frame, %{"method" => "session/prompt"}}, 1_000

    inject(agent2, %{
      "jsonrpc" => "2.0",
      "id" => 91,
      "method" => "session/request_permission",
      "params" => %{
        "sessionId" => "sess-2",
        "toolCall" => %{"title" => "Write x", "kind" => "edit"},
        "options" => [%{"optionId" => "ok", "name" => "Allow", "kind" => "allow_once"}]
      }
    })

    assert eventually(fn -> match?(%{status: :needs_attention}, Agent.info("a2")) end)

    # attention segment lists a2
    assert eventually(fn -> Editor.render_state().modeline_extra =~ "a2" end)

    {:ok, _} = Session.eval(~s[(run-command "chat-list")])
    text = Buffer.text("*chats*")
    [_header, first_line | _] = String.split(text, "\n")
    assert first_line =~ "a2"
    assert first_line =~ "needs_attention"

    # point lands after the header refresh; move to the first entry and answer
    focus("*chats*")
    {:ok, _} = Session.eval("(begin (beginning-of-buffer!) (next-line!))")
    press(["y"])

    assert_receive {:frame, %{"id" => 91, "result" => %{"outcome" => outcome}}}, 1_000
    assert outcome == %{"outcome" => "selected", "optionId" => "ok"}

    # attention clears once answered
    assert eventually(fn -> Editor.render_state().modeline_extra == "" end)
    _ = agent1
  end

  test "k in *agents* notes the stop in the transcript; x releases windows before killing" do
    {slug, buf, _agent} = boot("")

    # show the thread in the main window, then open the fleet popup
    focus(buf)
    {:ok, _} = Session.eval(~s[(run-command "chat-list")])
    focus("*chats*")

    # the list holds every chat — put point on THIS thread's row
    rows = Buffer.get_local("*chats*", "list-entries")
    row = Enum.find_index(rows, &(&1 == buf))
    assert row, "thread #{buf} not listed in #{inspect(rows)}"
    {:ok, _} = Session.eval("(beginning-of-buffer!)")
    for _ <- 0..row, do: {:ok, _} = Session.eval("(next-line!)")

    press(["k"])
    assert eventually(fn -> Buffer.text(buf) =~ "[agent stopped]" end)
    assert eventually(fn -> Agent.list() == [] end)
    assert Buffer.text("*chats*") =~ "x #{slug}"

    # the refresh re-sorted (dead ranks last) — find the row again
    rows = Buffer.get_local("*chats*", "list-entries")
    row = Enum.find_index(rows, &(&1 == buf))
    assert row, "thread #{buf} not listed in #{inspect(rows)}"
    {:ok, _} = Session.eval("(beginning-of-buffer!)")
    for _ <- 0..row, do: {:ok, _} = Session.eval("(next-line!)")

    press(["x"])
    assert eventually(fn -> not Buffer.exists?(buf) end)
    # no window points at the killed buffer (no empty-ghost resurrection)
    windows = Editor.list_windows()
    refute Enum.any?(windows, fn {_id, b} -> b == buf end)
  end

  # The renderer slices the input region from 'agent-saved-mark. An append
  # grows the transcript ABOVE that mark, so both have to land in one
  # buffer message. While Scheme set the local in a second call, every
  # streamed chunk painted a frame in which the mark was stale, and the
  # input row rendered the new text and the ">>> you: " marker with it.
  test "an append moves the saved mark in the same buffer message" do
    {slug, buf, agent} = boot("")

    before_mark = Buffer.get_local(buf, "agent-saved-mark")
    text = "streamed reply\n"

    update(agent, "sess-1", %{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{"type" => "text", "text" => text}
    })

    assert eventually(fn -> Buffer.text(buf) =~ "streamed reply" end)

    # the mark advanced past the appended text, and the marker still sits
    # after it — the input region holds no transcript and no marker
    mark = Buffer.get_local(buf, "agent-saved-mark")
    assert mark > before_mark
    assert Agent.mark(slug) == mark

    input = binary_part(Buffer.text(buf), mark, byte_size(Buffer.text(buf)) - mark)
    assert String.starts_with?(input, "\n>>> you: ")
    refute String.contains?(binary_part(input, 10, byte_size(input) - 10), ">>> you:")
  end

  # Up and down walk what you sent, like a shell. The draft you were
  # typing comes back when you walk down past the newest message.
  test "up and down recall sent messages, and give the draft back" do
    {slug, buf, agent} = boot("")

    # a queued second message would still sit in the input region, so let
    # each turn finish before typing the next one
    send_turn = fn text ->
      focus(buf)
      type(text)
      press(["RET"])
      assert_receive {:frame, %{"method" => "session/prompt", "id" => id}}, 1_000
      inject(agent, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"stopReason" => "end_turn"}})
      assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)
      assert eventually(fn -> String.ends_with?(Buffer.text(buf), ">>> you: ") end)
    end

    send_turn.("first message")
    send_turn.("second message")

    # a half-typed draft, then walk back through the history
    focus(buf)
    type("draft")
    press(["<up>"])
    assert eventually(fn -> String.ends_with?(Buffer.text(buf), ">>> you: second message") end)

    press(["<up>"])
    assert eventually(fn -> String.ends_with?(Buffer.text(buf), ">>> you: first message") end)

    # nothing older: the input holds still rather than emptying
    press(["<up>"])
    assert eventually(fn -> String.ends_with?(Buffer.text(buf), ">>> you: first message") end)

    press(["<down>"])
    assert eventually(fn -> String.ends_with?(Buffer.text(buf), ">>> you: second message") end)

    # ...and back to what was typed before the walk started
    press(["<down>"])
    assert eventually(fn -> String.ends_with?(Buffer.text(buf), ">>> you: draft") end)

    # the walk reads the conversation of record — there is no second copy
    # of the messages
    assert {:ok, ~s{(("user" "second message") ("user" "first message"))}} =
             Session.eval(
               ~s{(filter (lambda (t) (equal? (car t) "user")) (chat-turns "#{buf}"))}
             )
  end

  # A chat restored from a .chat file gets its turns back. Walking must
  # come back with them: a separate history local would start empty and
  # leave every existing chat with no history at all.
  test "up walks the turns a restored chat already has" do
    {_slug, buf, _agent} = boot("")

    {:ok, _} =
      Session.eval("""
      (buffer-set-local! "#{buf}" 'chat-wire-turns
        '((role "assistant" blocks (("text" "sure")))
          (role "user" blocks (("text" "newer question")))
          (role "assistant" blocks (("text" "ok")))
          (role "user" blocks (("text" "older question")))))
      """)

    focus(buf)
    press(["<up>"])
    assert eventually(fn -> String.ends_with?(Buffer.text(buf), ">>> you: newer question") end)

    press(["<up>"])
    assert eventually(fn -> String.ends_with?(Buffer.text(buf), ">>> you: older question") end)
  end

  # The case that matters most: reopen the editor and press up. A restored
  # chat has no 'agent-slug until its first send, so the walk must read the
  # buffer-locals, never the runtime.
  test "up works on a restored chat that has no runtime yet" do
    buf = "*chat:restored*"
    {:ok, _} = Aimax.Core.create_buffer(buf)

    {:ok, _} =
      Session.eval("""
      (begin
        (buffer-append! "#{buf}" "chat\\n")
        (buffer-set-local! "#{buf}" 'agent-saved-mark (buffer-size "#{buf}"))
        (buffer-append! "#{buf}" "\\n>>> you: ")
        (buffer-set-local! "#{buf}" 'agent-marker-bytes 10)
        (buffer-set-local! "#{buf}" 'chat-turns '(("user" "what I asked before")))
        (switch-to-buffer! "#{buf}")
        ;; the mode setup is what a desktop restore runs — it binds the keys
        (set-mode! "chat-mode")
        (end-of-buffer!))
      """)

    refute Buffer.get_local(buf, "agent-slug")

    press(["<up>"])
    assert eventually(fn -> String.ends_with?(Buffer.text(buf), ">>> you: what I asked before") end)

    press(["<down>"])
    assert eventually(fn -> String.ends_with?(Buffer.text(buf), ">>> you: ") end)

    Aimax.Core.kill_buffer(buf)
  end

  test "up inside a multi-line input still moves the cursor" do
    {slug, buf, agent} = boot("")

    focus(buf)
    type("line one")
    press(["RET"])
    assert_receive {:frame, %{"method" => "session/prompt", "id" => id}}, 1_000
    inject(agent, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"stopReason" => "end_turn"}})
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)
    assert eventually(fn -> String.ends_with?(Buffer.text(buf), ">>> you: ") end)

    # RET sends, so build a two-line input without sending
    focus(buf)
    {:ok, _} = Session.eval(~s[(begin (end-of-buffer!) (insert! "aaa\\nbbb"))])

    # point sits on the last line, with a line above it: up is motion
    press(["<up>"])
    assert String.ends_with?(Buffer.text(buf), "aaa\nbbb")

    # now on the first line, so up recalls the newest sent message
    press(["<up>"])
    assert eventually(fn -> String.ends_with?(Buffer.text(buf), ">>> you: line one") end)
  end

  test "adapter exit renders a death notice and marks the thread dead" do
    {slug, buf, agent} = boot("")

    send(agent, {:acp_exit, 1})

    assert eventually(fn -> Buffer.text(buf) =~ "[agent exited]" end)
    assert eventually(fn -> match?(%{status: :dead}, Agent.info(slug)) end)
  end

  test "session/new carries our mcpServers and _meta; the adapter loads no user config" do
    {:ok, _} = Session.eval(~s[(execute "")])
    assert_receive {:transport_open, agent}, 1_000
    assert_receive {:frame, %{"method" => "initialize", "id" => iid, "params" => ip}}, 1_000

    # fs/* stays refused: agents read live editor state through mcp__aimax__,
    # not through a filesystem shim over buffers
    assert %{"fs" => %{"readTextFile" => false, "writeTextFile" => false}} =
             ip["clientCapabilities"]

    inject(agent, %{"jsonrpc" => "2.0", "id" => iid, "result" => %{"protocolVersion" => 1}})

    assert_receive {:frame, %{"method" => "session/new", "id" => nid, "params" => np}}, 1_000

    # aimax's own tool proxy is handed over as an MCP server...
    assert Enum.any?(np["mcpServers"] || [], &(&1["name"] == "aimax"))

    # ...and the two keys that make aimax the only source. settingSources
    # [] drops the user's settings files; strictMcpConfig true drops the
    # user's own MCP registry in ~/.claude.json, which no setting source
    # covers and which otherwise merges into every session.
    assert %{
             "claudeCode" => %{
               "options" => %{"settingSources" => [], "strictMcpConfig" => true}
             }
           } = np["_meta"]

    # session modes come back in the same payload we used to drop
    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => nid,
      "result" => %{
        "sessionId" => "sess-md",
        "modes" => %{
          "currentModeId" => "default",
          "availableModes" => [
            %{"id" => "default", "name" => "Default", "description" => "asks"},
            %{"id" => "plan", "name" => "Plan Mode", "description" => "no execution"},
            %{"id" => "dontAsk", "name" => "Don't Ask", "description" => "no prompts"}
          ]
        }
      }
    })

    buf = "*chat:a1*"
    assert eventually(fn -> Buffer.get_local(buf, "agent-mode") == "default" end)

    assert [["default", "Default", "asks"] | _] = Buffer.get_local(buf, "agent-modes")

    # agent-set-mode! reaches the wire, and the agent's own switch is heard
    assert {:ok, "#t"} = Session.eval(~s[(agent-set-mode! "a1" "plan")])
    assert_receive {:frame, %{"method" => "session/set_mode", "params" => sp}}, 1_000
    assert sp == %{"sessionId" => "sess-md", "modeId" => "plan"}

    update(agent, "sess-md", %{"sessionUpdate" => "current_mode_update", "currentModeId" => "plan"})
    assert eventually(fn -> Buffer.get_local(buf, "agent-mode") == "plan" end)
    assert eventually(fn -> Buffer.get_local(buf, "modeline-info") =~ "plan" end)
  end

  test "auto mode tells a session-mode backend to stop asking us at all" do
    {:ok, _} = Session.eval(~s[(execute* "" '(permission-mode auto))])
    assert_receive {:transport_open, agent}, 1_000
    assert_receive {:frame, %{"method" => "initialize", "id" => iid}}, 1_000
    inject(agent, %{"jsonrpc" => "2.0", "id" => iid, "result" => %{}})
    assert_receive {:frame, %{"method" => "session/new", "id" => nid}}, 1_000

    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => nid,
      "result" => %{
        "sessionId" => "sess-auto",
        "modes" => %{
          "currentModeId" => "default",
          "availableModes" => [
            %{"id" => "default", "name" => "Default"},
            %{"id" => "dontAsk", "name" => "Don't Ask"}
          ]
        }
      }
    })

    # learning the session takes modes is enough — no user gesture needed
    assert_receive {:frame, %{"method" => "session/set_mode", "params" => sp}}, 1_000
    assert sp["modeId"] == "dontAsk"
    assert eventually(fn -> Buffer.get_local("*chat:a1*", "agent-mode") == "dontAsk" end)
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
