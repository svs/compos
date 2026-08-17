defmodule Aimax.PresetTest.FakeTransport do
  @moduledoc "Same ACP seam as agent_test: frames land in the test process."
  @behaviour Aimax.Core.Agent.Transport

  @impl true
  def open(cmd, _opts, owner) do
    test = :persistent_term.get(:preset_test_pid)
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

defmodule Aimax.PresetTest do
  @moduledoc """
  W6: optional presets are the single source of truth for a chat's extra
  tools; the core aimax editor bridge is intrinsic. An ACP session fixes
  mcpServers at session/new, so a preset change under a live agent must
  reattach — never silently do nothing.
  """

  use ExUnit.Case

  alias Aimax.Core.{Agent, Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(str), do: str |> String.graphemes() |> press()

  defp inject(agent, frame), do: send(agent, {:acp_data, Jason.encode!(frame) <> "\n"})

  setup do
    :persistent_term.put(:preset_test_pid, self())
    Application.put_env(:aimax_core, :acp_transport, Aimax.PresetTest.FakeTransport)

    Editor.minibuffer_close()
    Editor.delete_other_windows()

    # a server + preset to load (never actually connected — the ACP lane
    # only needs its spawn spec, which is what session/new carries)
    {:ok, _} =
      Session.eval("""
      (begin
        (mcp-register! 'zz-weather '(command "zz-weather-server" args ("--stdio")))
        (define-preset! 'zz-pack "test pack" '(zz-weather)))
      """)

    on_exit(fn ->
      Application.delete_env(:aimax_core, :acp_transport)
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

  # boot an ACP chat and finish the handshake
  defp boot do
    {:ok, _} = Session.eval(~s[(execute "")])
    assert_receive {:transport_open, agent}, 1_000
    assert_receive {:frame, %{"method" => "initialize", "id" => iid}}, 1_000
    inject(agent, %{"jsonrpc" => "2.0", "id" => iid, "result" => %{}})
    assert_receive {:frame, %{"method" => "session/new", "id" => nid, "params" => np}}, 1_000
    inject(agent, %{"jsonrpc" => "2.0", "id" => nid, "result" => %{"sessionId" => "sess-1"}})
    {"a1", "*chat:a1*", agent, np}
  end

  defp servers(params), do: Enum.map(params["mcpServers"] || [], & &1["name"])

  test "loading a preset refreshes an API chat's frozen tool surface" do
    {:ok, _} = Session.eval(~s[(execute* "" '(connector "api"))])
    buf = "*chat:a1*"

    # The first tool-free turn froze an empty surface. A later preset change
    # must take effect immediately; requiring a second, undiscoverable refresh
    # made llm-mode look as though its tools did not work.
    {:ok, _} = Session.eval(~s[(buffer-set-local! "#{buf}" 'chat-tool-specs '())])
    {:ok, _} = Session.eval(~s[(switch-to-buffer! "#{buf}")])
    {:ok, _} = Session.eval(~s[(run-command "llm-set-preset")])
    type("aimax")
    press(["RET"])

    # aimax is intrinsic, so selecting it need not materialize a redundant
    # buffer-local preset entry.
    assert Buffer.get_local(buf, "chat-presets") in [nil, false, []]
    assert "eval-scheme" in (Buffer.get_local(buf, "chat-tool-specs") |> Enum.map(&List.first/1))
    refute Buffer.get_local(buf, "modeline-info") =~ "tools stale"
  end

  test "ACP-backed llm-mode mounts the buffer presets as MCP servers" do
    buf = "llm-acp-presets-#{System.unique_integer([:positive])}"
    on_exit(fn -> if Buffer.exists?(buf), do: Aimax.Core.kill_buffer(buf) end)

    {:ok, _} =
      Session.eval(~s[(begin
        (buffer-create "#{buf}")
        (switch-to-buffer! "#{buf}")
        (buffer-set-local! "#{buf}" 'llm-connector "codex-app-server")
        (buffer-set-local! "#{buf}" 'llm-model "gpt-5.6-terra")
        (buffer-set-local! "#{buf}" 'chat-presets '(aimax))
        (insert! "read the companion")
        (run-command "llm-send-buffer"))])

    assert_receive {:transport_open, agent}, 1_000
    assert_receive {:frame, %{"method" => "initialize", "id" => iid}}, 1_000
    inject(agent, %{"jsonrpc" => "2.0", "id" => iid, "result" => %{}})

    assert_receive {:frame,
                    %{
                      "method" => "thread/start",
                      "id" => thread_request,
                      "params" => %{"config" => %{"mcp_servers" => mcp_servers}}
                    } = thread_frame},
                   1_000

    assert Map.has_key?(mcp_servers, "aimax")
    assert thread_frame["params"]["ephemeral"] == false

    inject(agent, %{
      "id" => thread_request,
      "result" => %{"thread" => %{"id" => "writing-thread"}, "model" => "gpt-5.6-terra"}
    })

    assert_receive {:frame, %{"method" => "turn/start", "id" => turn_request, "params" => turn}},
                   1_000

    assert turn["threadId"] == "writing-thread"
    assert turn["input"] == [%{"type" => "text", "text" => "read the companion"}]
    inject(agent, %{"id" => turn_request, "result" => %{"turn" => %{"id" => "turn-1"}}})

    inject(agent, %{
      "method" => "item/agentMessage/delta",
      "params" => %{"itemId" => "msg-1", "delta" => "First answer"}
    })

    inject(agent, %{
      "method" => "turn/completed",
      "params" => %{
        "threadId" => "writing-thread",
        "turn" => %{"id" => "turn-1", "status" => "completed"}
      }
    })

    assert eventually(fn -> Buffer.text(buf) =~ "First answer" end)
    assert Buffer.get_local(buf, "llm-thread-id") == "writing-thread"
    session_id = Buffer.get_local(buf, "llm-session-id")
    assert eventually(fn -> Agent.info(session_id).status == :idle end)
    refute Buffer.get_local(buf, "llm-session-dirty")

    :ok = Buffer.append(buf, "\nwhat about the ending?", source: :editor)
    Buffer.goto(buf, Buffer.byte_size(buf))
    refute Buffer.get_local(buf, "llm-session-dirty")
    assert session_id in Agent.list()
    {:ok, _} = Session.eval(~s[(run-command "llm-send-buffer")])

    # No second transport or thread/start: this is another turn on the same
    # Codex thread, carrying only text written below the previous response.
    refute_receive {:transport_open, _}, 100
    assert_receive {:frame, %{"method" => "turn/start", "params" => second_turn}}, 1_000
    assert second_turn["threadId"] == "writing-thread"
    assert second_turn["input"] == [%{"type" => "text", "text" => "\n\nwhat about the ending?"}]

    assert :ok = Aimax.Core.kill_buffer(buf)
    assert eventually(fn -> session_id not in Agent.list() end)
  end

  test "a legacy llm transcript seeds its first native thread in full" do
    buf = "llm-legacy-seed-#{System.unique_integer([:positive])}"
    on_exit(fn -> if Buffer.exists?(buf), do: Aimax.Core.kill_buffer(buf) end)

    {:ok, _} =
      Session.eval(~s[(begin
        (buffer-create "#{buf}")
        (buffer-append! "#{buf}" "q\n\nanswer\nnext")
        (buffer-set-local! "#{buf}" 'llm-connector "codex-app-server")
        (buffer-set-local! "#{buf}" 'llm-responses '((3 9)))
        (buffer-set-local! "#{buf}" 'test-wire
          (llm-mode--wire-text "#{buf}" (buffer-text "#{buf}"))))])

    assert Buffer.get_local(buf, "test-wire") == "q\n\nanswer\nnext"

    {:ok, _} =
      Session.eval(~s[(begin
        (buffer-set-local! "#{buf}" 'llm-thread-id "saved-thread")
        (buffer-set-local! "#{buf}" 'test-wire
          (llm-mode--wire-text "#{buf}" (buffer-text "#{buf}"))))])

    assert Buffer.get_local(buf, "test-wire") == "\nnext"
  end

  test "loading a preset on a live ACP chat reattaches; the conversation survives" do
    {slug, buf, agent, first_new} = boot()

    # No optional preset still carries the intrinsic live-editor bridge.
    assert servers(first_new) == ["aimax"]

    # give the chat a real conversation to carry across the reconnect
    {:ok, _} = Session.eval(~s[(agent-prompt! "#{slug}" "what is the weather")])
    assert_receive {:frame, %{"method" => "session/prompt", "id" => pid}}, 1_000

    send(
      agent,
      {:acp_data,
       Jason.encode!(%{
         "jsonrpc" => "2.0",
         "method" => "session/update",
         "params" => %{
           "sessionId" => "sess-1",
           "update" => %{
             "sessionUpdate" => "agent_message_chunk",
             "content" => %{"type" => "text", "text" => "I have no weather tool."}
           }
         }
       }) <> "\n"}
    )

    inject(agent, %{"jsonrpc" => "2.0", "id" => pid, "result" => %{"stopReason" => "end_turn"}})
    assert eventually(fn -> Buffer.text(buf) =~ "no weather tool" end)

    # load the preset from the real command, and decline the offer to
    # reconnect right now — the change must still not be lost
    {:ok, _} = Session.eval(~s[(switch-to-buffer! "#{buf}")])
    {:ok, _} = Session.eval(~s[(run-command "llm-set-preset")])
    type("zz-pack")
    press(["RET"])
    assert eventually(fn -> Editor.snapshot().minibuffer != nil end)
    type("no")
    press(["RET"])

    assert Buffer.get_local(buf, "chat-presets") == [sym: "zz-pack", sym: "aimax"]
    assert Buffer.get_local(buf, "chat-mcp-dirty") == true

    # ...the next send reattaches with the new server list
    {:ok, _} = Session.eval(~s[(begin (switch-to-buffer! "#{buf}") (end-of-buffer!))])
    type("try again")
    press(["RET"])

    assert_receive {:transport_open, agent2}, 1_000
    assert agent2 != agent
    assert_receive {:frame, %{"method" => "initialize", "id" => iid2}}, 1_000
    inject(agent2, %{"jsonrpc" => "2.0", "id" => iid2, "result" => %{}})

    assert_receive {:frame, %{"method" => "session/new", "id" => nid2, "params" => np2}}, 1_000
    assert Enum.sort(servers(np2)) == ["aimax", "zz-weather"]

    inject(agent2, %{"jsonrpc" => "2.0", "id" => nid2, "result" => %{"sessionId" => "sess-2"}})

    # the conversation carried over: the first prompt on the new session
    # seeds the earlier turns
    assert_receive {:frame, %{"method" => "session/prompt", "params" => p}}, 1_000
    [%{"text" => sent}] = p["prompt"]
    assert sent =~ "what is the weather"
    assert sent =~ "no weather tool"
    assert sent =~ "try again"

    # the flag cleared — one reconnect, not one per send
    assert Buffer.get_local(buf, "chat-mcp-dirty") in [false, nil]
  end

  test "answering yes reconnects immediately, and unloading removes the server" do
    {_slug, buf, _agent, _} = boot()

    {:ok, _} = Session.eval(~s[(switch-to-buffer! "#{buf}")])
    {:ok, _} = Session.eval(~s[(run-command "llm-set-preset")])
    type("zz-pack")
    press(["RET"])
    assert eventually(fn -> Editor.snapshot().minibuffer != nil end)
    type("yes")
    press(["RET"])

    # reconnected on the spot, no send needed
    assert_receive {:transport_open, agent2}, 1_000
    assert_receive {:frame, %{"method" => "initialize", "id" => iid}}, 1_000
    inject(agent2, %{"jsonrpc" => "2.0", "id" => iid, "result" => %{}})
    assert_receive {:frame, %{"method" => "session/new", "id" => nid, "params" => np}}, 1_000
    assert "zz-weather" in servers(np)
    inject(agent2, %{"jsonrpc" => "2.0", "id" => nid, "result" => %{"sessionId" => "sess-2"}})

    assert Buffer.get_local(buf, "chat-mcp-dirty") in [false, nil]

    # unloading takes it away again
    {:ok, _} = Session.eval(~s[(switch-to-buffer! "#{buf}")])
    {:ok, _} = Session.eval(~s[(run-command "llm-unset-preset")])
    type("zz-pack")
    press(["RET"])
    assert eventually(fn -> Editor.snapshot().minibuffer != nil end)
    type("yes")
    press(["RET"])

    assert_receive {:transport_open, agent3}, 1_000
    assert_receive {:frame, %{"method" => "initialize", "id" => iid3}}, 1_000
    inject(agent3, %{"jsonrpc" => "2.0", "id" => iid3, "result" => %{}})
    assert_receive {:frame, %{"method" => "session/new", "params" => np3}}, 1_000

    assert servers(np3) == ["aimax"]
    assert Buffer.get_local(buf, "chat-presets") == [sym: "aimax"]
  end

  test "an http server reaches the agent too, with its headers resolved" do
    System.put_env("ZZ_MCP_TOKEN", "sekrit")
    on_exit(fn -> System.delete_env("ZZ_MCP_TOKEN") end)

    {:ok, _} =
      Session.eval("""
      (begin
        (mcp-register! 'zz-http '(type "http" url "https://zz.test/mcp"
                                  headers (Authorization "@ZZ_MCP_TOKEN")))
        (define-preset! 'zz-httppack "http pack" '(zz-http)))
      """)

    {:ok, _} = Session.eval(~s{(execute* "" '(presets (zz-httppack)))})
    assert_receive {:transport_open, agent}, 1_000
    assert_receive {:frame, %{"method" => "initialize", "id" => iid}}, 1_000
    inject(agent, %{"jsonrpc" => "2.0", "id" => iid, "result" => %{}})
    assert_receive {:frame, %{"method" => "session/new", "params" => np}}, 1_000

    entry = Enum.find(np["mcpServers"], &(&1["name"] == "zz-http"))
    assert entry["type"] == "http"
    assert entry["url"] == "https://zz.test/mcp"
    assert entry["headers"] == [%{"name" => "Authorization", "value" => "sekrit"}]

    # an http entry carries no command: the adapter starts no subprocess
    refute Map.has_key?(entry, "command")

    # and the prompt names every registered server, so a thread that holds
    # no tool for one still knows it is a server and not a host
    assert %{"systemPrompt" => %{"append" => note}} = np["_meta"]
    assert note =~ "zz-http"
    assert note =~ "mcp-call!"

    # the connector's own _meta survives beside it — BOTH keys. Losing
    # strictMcpConfig is the silent failure: the CLI reads the user's own
    # MCP registry from ~/.claude.json, which no setting source covers,
    # and merges it in. The preset then stops being the whole surface.
    assert %{
             "claudeCode" => %{
               "options" => %{"settingSources" => [], "strictMcpConfig" => true}
             }
           } = np["_meta"]
  end

  test "presets declared at spawn survive a revive: they land in the buffer-local" do
    {:ok, _} =
      Session.eval("""
      (begin
        (mcp-register! 'zz-spawn '(command "zz" args ("--stdio")))
        (define-preset! 'zz-spawnpack "spawn pack" '(zz-spawn)))
      """)

    {:ok, _} = Session.eval(~s{(execute* "" '(presets (zz-spawnpack)))})
    assert_receive {:transport_open, agent}, 1_000
    assert_receive {:frame, %{"method" => "initialize", "id" => iid}}, 1_000
    inject(agent, %{"jsonrpc" => "2.0", "id" => iid, "result" => %{}})
    assert_receive {:frame, %{"method" => "session/new", "id" => nid, "params" => np}}, 1_000
    assert "zz-spawn" in servers(np)
    inject(agent, %{"jsonrpc" => "2.0", "id" => nid, "result" => %{"sessionId" => "s1"}})

    # the spawn config alone is not enough: agent-revive! reads the
    # buffer-local, so a thread that only carried it in opts came back bare
    buf = Enum.find(Aimax.Core.list_buffers(), &(Buffer.get_local(&1, "agent-slug") == "a1"))
    assert Buffer.get_local(buf, "chat-presets") == [{:sym, "zz-spawnpack"}]

    {:ok, _} = Session.eval(~s[(begin (agent-kill! "a1") (agent-revive! "a1"))])
    assert_receive {:transport_open, agent2}, 1_000
    assert_receive {:frame, %{"method" => "initialize", "id" => iid2}}, 1_000
    inject(agent2, %{"jsonrpc" => "2.0", "id" => iid2, "result" => %{}})
    assert_receive {:frame, %{"method" => "session/new", "params" => np2}}, 1_000
    assert "zz-spawn" in servers(np2)
  end

  test "chat-tool-surface names every server the chat's agent holds, and no other" do
    {:ok, _} =
      Session.eval("""
      (begin
        (mcp-register! 'zz-surface '(command "zz" args ("--stdio")))
        (define-preset! 'zz-surfacepack "surface pack" '(zz-surface)))
      """)

    {:ok, _} = Session.eval(~s{(execute* "" '(presets (zz-surfacepack)))})
    assert_receive {:transport_open, agent}, 1_000
    assert_receive {:frame, %{"method" => "initialize", "id" => iid}}, 1_000
    inject(agent, %{"jsonrpc" => "2.0", "id" => iid, "result" => %{}})
    assert_receive {:frame, %{"method" => "session/new", "params" => np}}, 1_000

    buf = Enum.find(Aimax.Core.list_buffers(), &(Buffer.get_local(&1, "agent-slug") == "a1"))

    {:ok, _} =
      Session.eval(~s[(begin (switch-to-buffer! "#{buf}") (run-command "chat-tool-surface"))])

    text = Buffer.text("*chat tools*")
    on_exit(fn -> Aimax.Core.kill_buffer("*chat tools*") end)

    # the report names exactly the servers that went over the wire
    for s <- np["mcpServers"], do: assert(text =~ s["name"])
    assert text =~ "zz-surfacepack"
    assert text =~ "zz --stdio"
    refute text =~ "google-search"
  end

  test "the api lane needs no reconnect: its tool specs are read at send time" do
    {:ok, _} = Session.eval(~s{(execute* "" '(connector "api"))})
    buf = "*chat:a1*"

    {:ok, _} = Session.eval(~s[(switch-to-buffer! "#{buf}")])
    {:ok, _} = Session.eval(~s[(run-command "llm-set-preset")])
    type("zz-pack")
    press(["RET"])

    # no reconnect prompt at all — nothing to reconnect
    refute Editor.snapshot().minibuffer
    assert Buffer.get_local(buf, "chat-presets") == [sym: "zz-pack", sym: "aimax"]
    assert Buffer.get_local(buf, "chat-mcp-dirty") in [false, nil]
    refute_received {:transport_open, _}
  end

  test "llm-set-preset targets an ordinary llm-mode buffer" do
    buf = "zz-llm-preset-#{System.unique_integer([:positive])}"
    on_exit(fn -> if Buffer.exists?(buf), do: Aimax.Core.kill_buffer(buf) end)

    parent = self()

    Application.put_env(:aimax_core, :llm_chat_fun, fn req ->
      send(parent, {:llm_mode_request, req})

      {:ok,
       %{
         "stop_reason" => "end_turn",
         "content" => [%{"type" => "text", "text" => "preset-aware reply"}]
       }}
    end)

    on_exit(fn -> Application.delete_env(:aimax_core, :llm_chat_fun) end)

    {:ok, _} =
      Session.eval(
        ~s[(begin (buffer-create "#{buf}") (switch-to-buffer! "#{buf}") (buffer-set-local! "#{buf}" 'llm-connector "api") (run-command "llm-mode"))]
      )

    {:ok, _} = Session.eval(~s[(run-command "llm-set-preset")])
    type("zz-pack")
    press(["RET"])

    assert Buffer.get_local(buf, "chat-presets") == [sym: "zz-pack", sym: "aimax"]

    # The editor toolbox is mounted explicitly, through its own preset.
    {:ok, _} = Session.eval(~s[(run-command "llm-set-preset")])
    type("aimax")
    press(["RET"])

    assert Buffer.get_local(buf, "chat-presets") == [sym: "zz-pack", sym: "aimax"]

    {:ok, _} =
      Session.eval(
        ~s[(begin (buffer-set-local! "#{buf}" 'llm-model "openai:zz-writer") (insert! "draft") (run-command "llm-send-buffer"))]
      )

    assert_receive {:llm_mode_request, req}, 1_000
    assert req.model == "openai:zz-writer"
    assert Enum.any?(req.tools, &(&1.name == "eval-scheme"))
    assert req.system =~ "zz-weather"
    assert eventually(fn -> Buffer.text(buf) =~ "preset-aware reply" end)
  end

  test "the aimax editor bridge is intrinsic even for an empty restored chat" do
    buf = "zz-intrinsic-aimax-#{System.unique_integer([:positive])}"
    on_exit(fn -> if Buffer.exists?(buf), do: Aimax.Core.kill_buffer(buf) end)

    {:ok, presets} =
      Session.eval(
        ~s[(begin (buffer-create "#{buf}") (buffer-set-local! "#{buf}" 'chat-presets '()) (chat-presets-of "#{buf}"))]
      )

    assert presets == "(aimax)"

    {:ok, servers} =
      Session.eval(
        ~s[(presets-acp-servers (chat-presets-of "#{buf}"))]
      )

    assert servers =~ ~s{"aimax"}
    assert servers =~ "aimax-mcp-proxy.exs"
  end

  test "the intrinsic editor surface freezes without any optional preset" do
    {:ok, _} = Session.eval(~s{(execute* "" '(connector "api"))})
    buf = "*chat:a1*"

    # Even an old chat whose local preset list is empty starts with the live
    # Scheme editor toolbox; it can never freeze a tool-less first turn.
    {:ok, _} = Session.eval(~s[(chat-tools "#{buf}")])
    names = Buffer.get_local(buf, "chat-tool-specs") |> Enum.map(&List.first/1)
    assert "eval-scheme" in names
    assert "apropos" in names
    refute Buffer.get_local(buf, "modeline-info") =~ "tools stale"
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
