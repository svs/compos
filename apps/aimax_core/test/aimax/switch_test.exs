defmodule Aimax.SwitchTest.FakeTransport do
  @moduledoc "ACP seam: frames land in the test process."
  @behaviour Aimax.Core.Agent.Transport

  @impl true
  def open(cmd, _opts, owner) do
    test = :persistent_term.get(:switch_test_pid)
    send(test, {:transport_open, owner, cmd})
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

defmodule Aimax.SwitchTest do
  @moduledoc """
  W7's done-when: ONE chat walks api -> codex -> claude-code -> api.
  Turns, presets, permission mode, cost, group and slug all survive every
  hop; each hop's first outbound prompt carries the earlier conversation;
  and the modeline names the backend actually running at every step.
  """

  use ExUnit.Case

  alias Aimax.Core.{Agent, Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(str), do: str |> String.graphemes() |> press()
  defp inject(agent, frame), do: send(agent, {:acp_data, Jason.encode!(frame) <> "\n"})

  defp focus(buf),
    do: {:ok, _} = Session.eval(~s[(begin (switch-to-buffer! "#{buf}") (end-of-buffer!))])

  setup do
    :persistent_term.put(:switch_test_pid, self())
    Application.put_env(:aimax_core, :acp_transport, Aimax.SwitchTest.FakeTransport)

    Editor.minibuffer_close()
    Editor.delete_other_windows()

    {:ok, _} =
      Session.eval("""
      (begin
        (mcp-register! 'zz-sw '(command "zz-sw-server"))
        (define-preset! 'zz-swpack "switch pack" '(zz-sw)))
      """)

    # this test follows one buffer by name across three backends, and the
    # stub answers every request with the same text — including the one that
    # names the chat, which would rename the buffer out from under it
    {:ok, _} = Session.eval("(customize-set! 'chat-auto-rename #f)")

    on_exit(fn ->
      Session.eval("(customize-set! 'chat-auto-rename #t)")
      Application.delete_env(:aimax_core, :acp_transport)
      Application.delete_env(:aimax_core, :llm_chat_fun)
      Enum.each(Agent.list(), &Agent.kill/1)

      Enum.each(Aimax.Core.list_buffers(), fn name ->
        if String.starts_with?(name, "*chat:") or Buffer.get_local(name, "agent-slug"),
          do: Aimax.Core.kill_buffer(name)
      end)

      Editor.minibuffer_close()
      Editor.delete_other_windows()
    end)

    :ok
  end

  # complete an ACP handshake and return the first session/new params
  defp handshake(agent, sid, models \\ nil) do
    assert_receive {:frame, %{"method" => "initialize", "id" => iid}}, 1_000
    inject(agent, %{"jsonrpc" => "2.0", "id" => iid, "result" => %{}})
    assert_receive {:frame, %{"method" => "session/new", "id" => nid, "params" => np}}, 1_000

    result =
      %{"sessionId" => sid}
      |> then(fn r -> if models, do: Map.put(r, "models", models), else: r end)

    inject(agent, %{"jsonrpc" => "2.0", "id" => nid, "result" => result})
    np
  end

  defp reply_turn(agent, sid, text) do
    assert_receive {:frame, %{"method" => "session/prompt", "id" => pid, "params" => p}}, 1_000

    send(
      agent,
      {:acp_data,
       Jason.encode!(%{
         "jsonrpc" => "2.0",
         "method" => "session/update",
         "params" => %{
           "sessionId" => sid,
           "update" => %{
             "sessionUpdate" => "agent_message_chunk",
             "content" => %{"type" => "text", "text" => text}
           }
         }
       }) <> "\n"}
    )

    inject(agent, %{"jsonrpc" => "2.0", "id" => pid, "result" => %{"stopReason" => "end_turn"}})
    p["prompt"] |> hd() |> Map.get("text")
  end

  test "api -> codex -> claude-code -> api on ONE chat: everything survives" do
    Application.put_env(:aimax_core, :llm_chat_fun, fn _req ->
      {:ok,
       %{
         "stop_reason" => "end_turn",
         "content" => [%{"type" => "text", "text" => "api says hi"}],
         "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
       }}
    end)

    # --- hop 1: born on the api lane -----------------------------------
    {:ok, _} = Session.eval(~s{(execute* "hello there" '(connector "api"))})
    buf = "*chat:a1*"
    assert eventually(fn -> Buffer.text(buf) =~ "api says hi" end)

    # give the chat an identity worth preserving
    {:ok, _} =
      Session.eval("""
      (begin
        (buffer-set-local! "#{buf}" 'group "zz-group")
        (buffer-set-local! "#{buf}" 'chat-presets '(zz-swpack))
        (buffer-set-local! "#{buf}" 'chat-permission-mode 'ask)
        #t)
      """)

    cost_after_api = Buffer.get_local(buf, "chat-cost")
    assert Buffer.get_local(buf, "modeline-info") =~ "api"

    # --- hop 2: to codex ------------------------------------------------
    focus(buf)
    {:ok, _} = Session.eval(~s[(run-command "chat-set-backend")])
    press(["b"])
    type("codex")
    press(["RET"])
    press(["C-g"])

    assert_receive {:transport_open, codex, cmd}, 1_000
    # the codex connector is the native App Server now, not the ACP bridge
    assert cmd =~ "codex app-server"

    assert_receive {:frame, %{"method" => "initialize", "id" => iid}}, 1_000
    inject(codex, %{"jsonrpc" => "2.0", "id" => iid, "result" => %{}})

    # the conversation carried over: the first prompt seeds it
    focus(buf)
    type("still there?")
    press(["RET"])

    assert_receive {:frame,
                    %{
                      "method" => "thread/start",
                      "id" => thread_id,
                      "params" => %{"config" => %{"mcp_servers" => mcp_servers}}
                    }},
                   10_000

    # presets came along: the new thread gets their servers, beside the
    # intrinsic aimax bridge every chat carries
    assert Enum.sort(Map.keys(mcp_servers)) == ["aimax", "zz-sw"]

    inject(codex, %{
      "id" => thread_id,
      "result" => %{"thread" => %{"id" => "sess-codex"}, "model" => "gpt-5.6-sol"}
    })

    assert_receive {:frame, %{"method" => "turn/start", "id" => turn_id, "params" => turn}},
                   10_000
    sent = Jason.encode!(turn["input"])
    assert sent =~ "hello there"
    assert sent =~ "api says hi"
    assert sent =~ "still there?"

    inject(codex, %{"id" => turn_id, "result" => %{"turn" => %{"id" => "turn-1"}}})

    inject(codex, %{
      "method" => "item/agentMessage/delta",
      "params" => %{"itemId" => "msg-1", "delta" => "codex says hi"}
    })

    inject(codex, %{
      "method" => "turn/completed",
      "params" => %{"turnId" => "turn-1"}
    })

    assert eventually(fn -> Buffer.text(buf) =~ "codex says hi" end)
    assert Buffer.get_local(buf, "modeline-info") =~ "codex"

    # --- hop 3: to claude-code -----------------------------------------
    focus(buf)
    {:ok, _} = Session.eval(~s[(run-command "chat-set-backend")])
    press(["b"])
    type("claude-code")
    press(["RET"])
    press(["C-g"])

    assert_receive {:transport_open, cc, cmd2}, 1_000
    assert cmd2 =~ "claude-code-acp"

    handshake(cc, "sess-cc", %{
      "currentModelId" => "claude-sonnet-5",
      "availableModels" => [
        %{"modelId" => "claude-sonnet-5", "name" => "Sonnet"},
        %{"modelId" => "claude-opus-5", "name" => "Opus"}
      ]
    })

    focus(buf)
    type("and now?")
    press(["RET"])
    sent2 = reply_turn(cc, "sess-cc", "claude says hi")
    # the WHOLE conversation, including the codex turn
    assert sent2 =~ "hello there"
    assert sent2 =~ "codex says hi"
    assert sent2 =~ "and now?"

    assert eventually(fn -> Buffer.text(buf) =~ "claude says hi" end)
    assert eventually(fn -> Buffer.get_local(buf, "modeline-info") =~ "claude-sonnet-5" end)

    # a model the LIVE session offers switches in place — no new session
    focus(buf)
    {:ok, _} = Session.eval(~s[(run-command "chat-set-model")])
    type("claude-opus-5")
    press(["RET"])

    assert_receive {:frame, %{"method" => "session/set_model", "params" => sp}}, 1_000
    assert sp == %{"sessionId" => "sess-cc", "modelId" => "claude-opus-5"}
    refute_receive {:transport_open, _, _}, 200
    assert eventually(fn -> Buffer.get_local(buf, "modeline-info") =~ "claude-opus-5" end)

    # --- hop 4: back to the api lane ------------------------------------
    focus(buf)
    {:ok, _} = Session.eval(~s[(run-command "chat-set-backend")])
    press(["b"])
    type("api")
    press(["RET"])
    press(["C-g"])

    me = self()

    Application.put_env(:aimax_core, :llm_chat_fun, fn req ->
      send(me, {:api_messages, req.messages})

      {:ok,
       %{
         "stop_reason" => "end_turn",
         "content" => [%{"type" => "text", "text" => "api again"}],
         "usage" => %{"input_tokens" => 20, "output_tokens" => 5}
       }}
    end)

    focus(buf)
    type("last one")
    press(["RET"])
    assert eventually(fn -> Buffer.text(buf) =~ "api again" end)

    # the api lane replays the WHOLE conversation, every hop included
    assert_received {:api_messages, msgs}
    flat = Enum.map_join(msgs, "\n", &inspect(&1.content))
    assert flat =~ "hello there"
    assert flat =~ "codex says hi"
    assert flat =~ "claude says hi"
    assert flat =~ "last one"

    # --- and everything that defines the chat is still there ------------
    assert Buffer.get_local(buf, "agent-slug") == "a1"
    assert Buffer.get_local(buf, "group") == "zz-group"
    assert Buffer.get_local(buf, "chat-presets") == [sym: "zz-swpack"]
    assert Buffer.get_local(buf, "chat-permission-mode") == {:sym, "ask"}
    assert Buffer.get_local(buf, "chat-cost") >= cost_after_api
    assert Buffer.get_local(buf, "modeline-info") =~ "api"
    assert Buffer.get_local(buf, "modeline-info") =~ "ask"

    # RET never got rebound — the ec8cba3 bug class is structurally gone
    focus(buf)
    assert Editor.lookup_key(["RET"]) == {:command, "agent-send"}

    # the transcript is one continuous conversation
    {:ok, roles} = Session.eval(~s{(map car (reverse (chat-turns "#{buf}")))})

    assert roles ==
             ~s{("user" "assistant" "user" "assistant" "user" "assistant" "user" "assistant")}
  end

  defp eventually(fun, tries \\ 40) do
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
end
