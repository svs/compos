defmodule Compos.AgentTest.FakeTransport do
  @moduledoc """
  The ACP test seam: frames the Agent sends arrive in the test process as
  `{:frame, decoded_map}`; the test injects adapter output with
  `send(agent, {:acp_data, json <> "\n"})`.
  """

  @behaviour Compos.Core.Agent.Transport

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

defmodule Compos.AgentTest do
  @moduledoc "Drives agent threads through keys + the FakeTransport — no adapter binary."

  use ExUnit.Case

  alias Compos.Core.{Agent, Buffer, Editor, KeyDispatch, Session}
  alias Compos.Core.Agent.Backend

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  # the live input: everything past the mark. The input carries no marker
  # bytes, so an empty input means the buffer ends at the mark.
  defp input_text(buf) do
    text = Buffer.text(buf)
    mark = min(Buffer.get_local(buf, "agent-saved-mark") || byte_size(text), byte_size(text))
    binary_part(text, mark, byte_size(text) - mark)
  end
  defp type(str), do: str |> String.graphemes() |> press()

  defp evict(name) do
    :ok = Buffer.checkpoint_now(name)
    [{pid, _}] = Registry.lookup(Compos.Core.BufferRegistry, name)
    :ok = DynamicSupervisor.terminate_child(Compos.Core.BufferSupervisor, pid)
    assert eventually(fn -> not Buffer.exists?(name) end)
  end

  setup do
    # the frame's group and the last one visited are global editor state:
    # a module that entered a group leaves the next one starting inside it
    Compos.Core.Session.eval(
      "(begin (set-frame-local! 'current-group #f) (set-frame-local! 'previous-group #f))"
    )
    :persistent_term.put(:agent_test_pid, self())
    Application.put_env(:compos_core, :acp_transport, Compos.AgentTest.FakeTransport)

    Editor.minibuffer_close()
    Editor.delete_other_windows()

    on_exit(fn ->
      Application.delete_env(:compos_core, :acp_transport)
      Enum.each(Agent.list(), &Agent.kill/1)

      Enum.each(Compos.Core.list_buffers(), fn name ->
        if String.starts_with?(name, "*agent") or Buffer.get_local(name, "agent-slug"),
          do: Compos.Core.kill_buffer(name)
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

  test "native Codex App Server handshake, stream, approval, and completion normalize to backend events" do
    {:ok, backend} =
      Compos.Core.Agent.Backend.CodexAppServer.start(
        %{
          "cmd" => "fake",
          "cwd" => File.cwd!(),
          "model" => "gpt-5.5",
          "effort" => "high",
          "meta" => [{:sym, "systemPrompt"}, [{:sym, "append"}, "Use Compos."]],
          "mcp-servers" => [
            [
              "name",
              "compos",
              "command",
              "compos-mcp-proxy",
              "args",
              ["--stdio"],
              "env",
              [["COMPOS_AGENT", "a1"]]
            ]
          ]
        },
        self()
      )

    on_exit(fn -> Compos.Core.Agent.Backend.CodexAppServer.close(backend) end)

    assert_receive {:transport_open, ^backend}, 1_000
    assert_receive {:transport_cmd, "fake"}, 1_000

    assert_receive {:frame, %{"method" => "initialize", "id" => init_id} = init}, 1_000
    refute Map.has_key?(init, "jsonrpc")
    assert get_in(init, ["params", "clientInfo", "name"]) == "compos"

    inject(backend, %{"id" => init_id, "result" => %{}})
    assert_receive {:frame, %{"method" => "initialized"}}, 1_000
    assert_receive {:frame, %{"method" => "model/list", "id" => models_id}}, 1_000
    assert_receive {:backend_event, ready}, 1_000
    assert Backend.event_type(ready) == "ready"

    inject(backend, %{
      "id" => models_id,
      "result" => %{
        "data" => [
          %{
            "model" => "gpt-5.5",
            "displayName" => "GPT-5.5",
            "hidden" => false,
            "supportedReasoningEfforts" => [
              %{"reasoningEffort" => "low"},
              %{"reasoningEffort" => "medium"},
              %{"reasoningEffort" => "high"},
              %{"reasoningEffort" => "xhigh"}
            ],
            "defaultReasoningEffort" => "medium"
          }
        ]
      }
    })

    assert_receive {:backend_event, model_event}, 1_000
    assert Backend.event_type(model_event) == "model-state"
    assert Backend.plist_get(model_event, "current") == "gpt-5.5"

    assert Backend.plist_get(model_event, "available") == [
             ["gpt-5.5", "GPT-5.5", ["low", "medium", "high", "xhigh"], "medium"]
           ]

    assert :ok =
             Compos.Core.Agent.Backend.CodexAppServer.prompt(backend, "hello", %{
               system: "Chat system context."
             })

    assert_receive {:frame,
                    %{"method" => "thread/start", "id" => thread_id, "params" => thread_params}},
                   1_000

    assert thread_params["ephemeral"]
    assert thread_params["model"] == "gpt-5.5"
    assert thread_params["developerInstructions"] =~ "Use Compos."
    assert thread_params["developerInstructions"] =~ "Chat system context."
    assert thread_params["developerInstructions"] =~ ~s{exact runtime model ID is "gpt-5.5"}

    assert get_in(thread_params, ["config", "mcp_servers", "compos"]) == %{
             "command" => "compos-mcp-proxy",
             "args" => ["--stdio"],
             "env" => %{"COMPOS_AGENT" => "a1"}
           }

    inject(backend, %{
      "id" => thread_id,
      "result" => %{"thread" => %{"id" => "thread-1"}, "model" => "gpt-5.5"}
    })

    assert_receive {:backend_event, thread_event}, 1_000
    assert Backend.event_type(thread_event) == "thread-id"
    assert Backend.plist_get(thread_event, "id") == "thread-1"
    assert_receive {:backend_event, _second_model_event}, 1_000

    assert_receive {:frame, %{"method" => "turn/start", "id" => turn_request, "params" => turn}},
                   1_000

    assert turn["threadId"] == "thread-1"
    assert turn["input"] == [%{"type" => "text", "text" => "hello"}]
    assert turn["effort"] == "high"
    inject(backend, %{"id" => turn_request, "result" => %{"turn" => %{"id" => "turn-1"}}})

    assert :ok =
             Compos.Core.Agent.Backend.CodexAppServer.steer(
               backend,
               7,
               "change direction",
               nil,
               3
             )

    assert_receive {:frame,
                    %{
                      "method" => "turn/steer",
                      "id" => steer_request,
                      "params" => steer
                    }},
                   1_000

    assert steer == %{
             "threadId" => "thread-1",
             "expectedTurnId" => "turn-1",
             "input" => [%{"type" => "text", "text" => "change direction"}]
           }

    inject(backend, %{"id" => steer_request, "result" => %{"turnId" => "turn-1"}})
    assert_receive {:backend_event, steer_event}, 1_000
    assert Backend.event_type(steer_event) == "steering-accepted"
    assert Backend.plist_get(steer_event, "token") == 7
    assert Backend.plist_get(steer_event, "epoch") == 3

    inject(backend, %{
      "method" => "item/agentMessage/delta",
      "params" => %{"itemId" => "msg-1", "delta" => "Hi"}
    })

    assert_receive {:backend_event, chunk}, 1_000
    assert Backend.event_type(chunk) == "chunk"
    assert Backend.plist_get(chunk, "text") == "Hi"

    inject(backend, %{
      "method" => "item/reasoning/textDelta",
      "params" => %{"itemId" => "reason-1", "delta" => "Checking the live editor."}
    })

    assert_receive {:backend_event, thought}, 1_000
    assert Backend.event_type(thought) == "thought"
    assert Backend.plist_get(thought, "text") == "Checking the live editor."

    inject(backend, %{
      "id" => 91,
      "method" => "item/commandExecution/requestApproval",
      "params" => %{"itemId" => "cmd-1", "command" => "git status"}
    })

    assert_receive {:backend_event, permission}, 1_000
    assert Backend.event_type(permission) == "permission"
    assert Backend.plist_get(permission, "rpc-id") == 91

    assert :ok =
             Compos.Core.Agent.Backend.CodexAppServer.respond_permission(
               backend,
               91,
               "allow_always"
             )

    assert_receive {:frame, %{"id" => 91, "result" => %{"decision" => "acceptForSession"}}},
                   1_000

    inject(backend, %{
      "id" => 92,
      "method" => "mcpServer/elicitation/request",
      "params" => %{
        "serverName" => "compos",
        "threadId" => "thread-1",
        "turnId" => "turn-1",
        "mode" => "form",
        "message" => "How should I inspect this change?",
        "requestedSchema" => %{
          "type" => "object",
          "properties" => %{
            "answer" => %{
              "type" => "string",
              "enum" => ["Diff first", "Run tests", "Open files", "Continue"]
            }
          }
        }
      }
    })

    assert_receive {:backend_event, question}, 1_000
    assert Backend.event_type(question) == "question"
    assert Backend.plist_get(question, "id") == 92
    assert Backend.plist_get(question, "question") == "How should I inspect this change?"

    assert Backend.plist_get(question, "answers") == [
             "Diff first",
             "Run tests",
             "Open files",
             "Continue"
           ]

    assert :ok =
             Compos.Core.Agent.Backend.CodexAppServer.respond_question(
               backend,
               92,
               "Diff first"
             )

    assert_receive {:frame,
                    %{
                      "id" => 92,
                      "result" => %{
                        "action" => "accept",
                        "content" => %{"answer" => "Diff first"}
                      }
                    }},
                   1_000

    inject(backend, %{
      "method" => "turn/completed",
      "params" => %{
        "threadId" => "thread-1",
        "turn" => %{"id" => "turn-1", "status" => "completed"}
      }
    })

    assert_receive {:backend_event, turn_end}, 1_000
    assert Backend.event_type(turn_end) == "turn-end"

    assert :ok = Compos.Core.Agent.Backend.CodexAppServer.prompt(backend, "second", %{})

    assert_receive {:frame, %{"method" => "turn/start", "params" => second_turn}}, 1_000
    assert second_turn["input"] == [%{"type" => "text", "text" => "second"}]
    assert second_turn["effort"] == "high"
  end

  test "cancelling Codex before turn start discards backend-held steering" do
    {:ok, backend} =
      Compos.Core.Agent.Backend.CodexAppServer.start(
        %{"cmd" => "fake", "cwd" => File.cwd!(), "model" => "gpt-5.5"},
        self()
      )

    on_exit(fn -> Compos.Core.Agent.Backend.CodexAppServer.close(backend) end)

    assert_receive {:transport_open, ^backend}, 1_000
    assert_receive {:transport_cmd, "fake"}, 1_000
    assert_receive {:frame, %{"method" => "initialize", "id" => init_id}}, 1_000
    inject(backend, %{"id" => init_id, "result" => %{}})
    assert_receive {:frame, %{"method" => "initialized"}}, 1_000
    assert_receive {:frame, %{"method" => "model/list"}}, 1_000

    assert :ok =
             Compos.Core.Agent.Backend.CodexAppServer.prompt(backend, "start", %{
               system: "system",
               tools: []
             })

    assert_receive {:frame, %{"method" => "thread/start", "id" => thread_request}}, 1_000
    assert :ok = Compos.Core.Agent.Backend.CodexAppServer.steer(backend, 1, "stale", nil, 1)
    assert :ok = Compos.Core.Agent.Backend.CodexAppServer.cancel(backend)

    inject(backend, %{
      "id" => thread_request,
      "result" => %{"thread" => %{"id" => "thread-cancelled"}}
    })

    assert_receive {:frame, %{"method" => "turn/start", "id" => turn_request}}, 1_000
    inject(backend, %{"id" => turn_request, "result" => %{"turn" => %{"id" => "turn-late"}}})
    refute_receive {:frame, %{"method" => "turn/steer"}}, 100
  end

  # the codex lane names MCP tools server/tool and carries their arguments
  # on the item — both must reach the tool-call event, or the card titles
  # with the bare tool name
  test "native Codex MCP tool items carry name and arguments into backend events" do
    {:ok, backend} =
      Compos.Core.Agent.Backend.CodexAppServer.start(
        %{"cmd" => "fake", "cwd" => File.cwd!()},
        self()
      )

    on_exit(fn -> Compos.Core.Agent.Backend.CodexAppServer.close(backend) end)
    assert_receive {:transport_open, ^backend}, 1_000

    inject(backend, %{
      "method" => "item/started",
      "params" => %{
        "item" => %{
          "type" => "mcpToolCall",
          "id" => "mcp-1",
          "server" => "compos",
          "tool" => "eval-scheme",
          "arguments" => %{"code" => "(buffer-list)"},
          "status" => "inProgress"
        }
      }
    })

    assert_receive {:backend_event, call}, 1_000
    assert Backend.event_type(call) == "tool-call"
    assert Backend.plist_get(call, "name") == "compos/eval-scheme"
    assert Backend.plist_get(call, "input") == ~s|{"code":"(buffer-list)"}|
    assert Backend.plist_get(call, "kind") == "mcp"

    inject(backend, %{
      "method" => "item/completed",
      "params" => %{
        "item" => %{
          "type" => "mcpToolCall",
          "id" => "mcp-1",
          "server" => "compos",
          "tool" => "eval-scheme",
          "arguments" => %{"code" => "(buffer-list)"},
          "status" => "completed",
          "result" => %{"content" => [%{"type" => "text", "text" => "()"}]}
        }
      }
    })

    assert_receive {:backend_event, update}, 1_000
    assert Backend.event_type(update) == "tool-update"
    assert Backend.plist_get(update, "name") == "compos/eval-scheme"
    assert Backend.plist_get(update, "input") == ~s|{"code":"(buffer-list)"}|
    assert Backend.plist_get(update, "status") == "completed"
    assert is_integer(Backend.plist_get(update, "duration-ms"))
  end

  # duration-ms is stamped where the events serialize, so each backend
  # only has to thread its emit — the ACP lane proves the wire shape
  test "an ACP tool completion carries duration-ms; the call itself does not" do
    {:ok, backend} =
      Compos.Core.Agent.Backend.ACP.start(%{"cmd" => "fake", "cwd" => File.cwd!()}, self())

    on_exit(fn -> Compos.Core.Agent.Backend.ACP.close(backend) end)
    assert_receive {:transport_open, ^backend}, 1_000

    update(backend, "sess-1", %{
      "sessionUpdate" => "tool_call",
      "toolCallId" => "tc1",
      "title" => "Read foo.ex",
      "kind" => "read",
      "status" => "pending"
    })

    assert_receive {:backend_event, call}, 1_000
    assert Backend.event_type(call) == "tool-call"
    assert Backend.plist_get(call, "duration-ms") == nil

    update(backend, "sess-1", %{
      "sessionUpdate" => "tool_call_update",
      "toolCallId" => "tc1",
      "status" => "in_progress"
    })

    assert_receive {:backend_event, progress}, 1_000
    assert Backend.event_type(progress) == "tool-update"
    assert Backend.plist_get(progress, "duration-ms") == nil

    update(backend, "sess-1", %{
      "sessionUpdate" => "tool_call_update",
      "toolCallId" => "tc1",
      "status" => "completed"
    })

    assert_receive {:backend_event, done}, 1_000
    assert Backend.event_type(done) == "tool-update"
    assert is_integer(Backend.plist_get(done, "duration-ms"))
    assert Backend.plist_get(done, "duration-ms") >= 0
  end

  # the direct lane funnels turn-task events through its GenServer as
  # {:turn_event, kvs} casts — the same funnel must stamp the duration
  test "the ReqLLM event funnel stamps duration-ms on tool completion" do
    {:ok, backend} =
      Compos.Core.Agent.Backend.ReqLLM.start(%{"slug" => "req-timing"}, self())

    on_exit(fn -> Compos.Core.Agent.Backend.ReqLLM.close(backend) end)
    assert_receive {:backend_event, ready}, 1_000
    assert Backend.event_type(ready) == "ready"

    GenServer.cast(
      backend,
      {:turn_event,
       [type: :"tool-call", id: "t1", name: "eval-scheme", input: "{}", kind: "tool", status: "pending"]}
    )

    assert_receive {:backend_event, call}, 1_000
    assert Backend.plist_get(call, "duration-ms") == nil

    GenServer.cast(
      backend,
      {:turn_event, [type: :"tool-update", id: "t1", status: "completed", output: "2"]}
    )

    assert_receive {:backend_event, done}, 1_000
    assert Backend.event_type(done) == "tool-update"
    assert is_integer(Backend.plist_get(done, "duration-ms"))
  end

  test "native Codex MCP tool approval elicitation rides the permission channel" do
    {:ok, backend} =
      Compos.Core.Agent.Backend.CodexAppServer.start(
        %{"cmd" => "fake", "cwd" => File.cwd!(), "model" => "gpt-5.5"},
        self()
      )

    on_exit(fn -> Compos.Core.Agent.Backend.CodexAppServer.close(backend) end)
    assert_receive {:transport_open, ^backend}, 1_000

    approval = fn id ->
      inject(backend, %{
        "id" => id,
        "method" => "mcpServer/elicitation/request",
        "params" => %{
          "serverName" => "compos",
          "threadId" => "thread-1",
          "turnId" => "turn-1",
          "mode" => "form",
          "message" => "Allow the compos MCP server to run tool \"eval-scheme\"?",
          "requestedSchema" => %{"type" => "object", "properties" => %{}},
          "_meta" => %{
            "codex_approval_kind" => "mcp_tool_call",
            "persist" => ["session", "always"],
            "tool_params" => %{"code" => "(buffer-list)"}
          }
        }
      })
    end

    # a permission event, not a question: the policy decides like on
    # every other lane, and the raw carries the payload for the deny scan
    approval.(93)
    assert_receive {:backend_event, permission}, 1_000
    assert Backend.event_type(permission) == "permission"
    assert Backend.plist_get(permission, "rpc-id") == 93
    assert Backend.plist_get(permission, "title") == "eval-scheme"
    assert Backend.plist_get(permission, "kind") == "tool"
    assert Backend.plist_get(permission, "raw") =~ "(buffer-list)"

    # allow-always becomes a durable session grant: codex stops asking
    assert :ok =
             Compos.Core.Agent.Backend.CodexAppServer.respond_permission(
               backend,
               93,
               "allow_always"
             )

    assert_receive {:frame,
                    %{
                      "id" => 93,
                      "result" => %{
                        "action" => "accept",
                        "_meta" => %{"persist" => "session"}
                      }
                    }},
                   1_000

    approval.(94)
    assert_receive {:backend_event, _permission2}, 1_000

    assert :ok =
             Compos.Core.Agent.Backend.CodexAppServer.respond_permission(
               backend,
               94,
               "reject_once"
             )

    assert_receive {:frame, %{"id" => 94, "result" => %{"action" => "decline"}}}, 1_000
  end

  test "native Codex resumes a persisted llm-mode thread" do
    {:ok, backend} =
      Compos.Core.Agent.Backend.CodexAppServer.start(
        %{
          "cmd" => "fake",
          "cwd" => File.cwd!(),
          "model" => "gpt-5.6-terra",
          "thread-id" => "thread-saved",
          "persist-thread" => true
        },
        self()
      )

    on_exit(fn -> Compos.Core.Agent.Backend.CodexAppServer.close(backend) end)

    assert_receive {:transport_open, ^backend}, 1_000
    assert_receive {:transport_cmd, "fake"}, 1_000
    assert_receive {:frame, %{"method" => "initialize", "id" => init_id}}, 1_000
    inject(backend, %{"id" => init_id, "result" => %{}})
    assert_receive {:frame, %{"method" => "initialized"}}, 1_000
    assert_receive {:frame, %{"method" => "model/list"}}, 1_000
    assert_receive {:backend_event, ready}, 1_000
    assert Backend.event_type(ready) == "ready"

    assert :ok =
             Compos.Core.Agent.Backend.CodexAppServer.prompt(backend, "next turn", %{
               system: "Live editor context"
             })

    assert_receive {:frame,
                    %{"method" => "thread/resume", "id" => resume_id, "params" => params}},
                   1_000

    assert params["threadId"] == "thread-saved"
    assert params["model"] == "gpt-5.6-terra"
    assert params["developerInstructions"] =~ "Live editor context"
    refute Map.has_key?(params, "ephemeral")

    inject(backend, %{
      "id" => resume_id,
      "result" => %{"thread" => %{"id" => "thread-saved"}, "model" => "gpt-5.6-terra"}
    })

    assert_receive {:backend_event, thread_event}, 1_000
    assert Backend.event_type(thread_event) == "thread-id"
    assert_receive {:backend_event, _model_event}, 1_000
    assert_receive {:frame, %{"method" => "turn/start", "params" => turn}}, 1_000
    assert turn["threadId"] == "thread-saved"
    assert turn["input"] == [%{"type" => "text", "text" => "next turn"}]
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

  defp boot_steering_acp(session_id) do
    {:ok, _} = Session.eval(~s[(execute* "" '(permission-mode ask))])
    assert_receive {:transport_open, agent}, 1_000
    assert_receive {:frame, %{"method" => "initialize", "id" => iid}}, 1_000

    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => iid,
      "result" => %{
        "protocolVersion" => 1,
        "_meta" => %{"steering" => %{"supported" => true}}
      }
    })

    assert_receive {:frame, %{"method" => "session/new", "id" => nid}}, 1_000
    inject(agent, %{"jsonrpc" => "2.0", "id" => nid, "result" => %{"sessionId" => session_id}})
    assert eventually(fn -> Agent.info("a1").steering end)
    {"a1", agent}
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
    assert eventually(fn -> Buffer.text(buf) =~ ">>> you: fix the bug" end)
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
      "status" => "pending",
      "rawInput" => %{"path" => "foo.ex"}
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
    tool = :binary.match(text, "▸ read · Read foo.ex: foo.ex") |> elem(0)
    body = :binary.match(text, "defmodule Foo") |> elem(0)
    done = :binary.match(text, "Done.") |> elem(0)
    assert hello < tool and tool < body and body < done
    assert text =~ "foo.ex\n\ndefmodule Foo"

    # tool body hidden; the input past the mark is empty
    assert [{s, e} | _] = Buffer.hidden(buf)
    assert s <= body and body < e
    assert input_text(buf) == ""
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)

    # the block model mapped every span: user turn, merged prose, closed tool
    blocks = Buffer.get_local(buf, "agent-blocks") |> Enum.reverse()
    kinds = Enum.map(blocks, fn [_, _, k | _] -> k end)
    assert "user" in kinds and "prose" in kinds and "tool" in kinds
    refute "waiting" in kinds

    [_, _, "tool", "tc1", "Read foo.ex: foo.ex", "read", "done", body_start] =
      Enum.find(blocks, fn [_, _, k | _] -> k == "tool" end)

    input_and_result = "foo.ex\n\ndefmodule Foo"
    assert binary_part(text, body_start, byte_size(input_and_result)) == input_and_result
    assert Buffer.get_local(buf, "render-mode") == "agent"
  end

  # a tool call is transient status: it goes to the echo area and the
  # activity row, not into the modeline
  test "a tool call echoes in the echo area and stays out of the modeline" do
    {slug, buf, agent} = boot("")

    {:ok, _} = Session.eval(~s[(agent-prompt! "#{slug}" "go")])
    assert_receive {:frame, %{"method" => "session/prompt"}}, 1_000

    update(agent, "sess-1", %{
      "sessionUpdate" => "tool_call",
      "toolCallId" => "tc-echo",
      "title" => "Read foo.ex",
      "kind" => "read",
      "status" => "pending",
      "rawInput" => %{"path" => "foo.ex"}
    })

    assert eventually(fn -> Editor.snapshot().echo == "tool · Read foo.ex: foo.ex" end)
    assert Buffer.get_local(buf, "chat-activity") == "tool · Read foo.ex: foo.ex"
    ml = Buffer.get_local(buf, "modeline-info")
    refute ml && ml =~ "tool ·"
  end

  # an MCP tool names its arguments freely — the title takes the first
  # string argument when no known name matches, and shortens the mcp name
  test "an unknown MCP argument still becomes the card title" do
    assert {:ok, ~s("linear:list_issues: svs")} =
             Session.eval(
               ~s[(agent-tool-title (list (quote name) "mcp__linear__list_issues" (quote input) "{\\"limit\\": 5, \\"assignee\\": \\"svs\\"}"))]
             )
  end

  # claude-code streams tool input: the tool_call arrives with an empty
  # rawInput, and a later tool_call_update carries the real one. The card
  # retitles from it, shows the arguments once, and a repeat refinement
  # changes nothing.
  test "a late rawInput retitles the tool card and shows the arguments once" do
    {slug, buf, agent} = boot("")

    {:ok, _} = Session.eval(~s[(agent-prompt! "#{slug}" "go")])
    assert_receive {:frame, %{"method" => "session/prompt", "id" => pid}}, 1_000

    update(agent, "sess-1", %{
      "sessionUpdate" => "tool_call",
      "toolCallId" => "tc9",
      "title" => "mcp__compos__apropos",
      "kind" => "other",
      "status" => "pending",
      "rawInput" => %{}
    })

    refinement = %{
      "sessionUpdate" => "tool_call_update",
      "toolCallId" => "tc9",
      "title" => "mcp__compos__apropos",
      "rawInput" => %{"query" => "split window"}
    }

    update(agent, "sess-1", refinement)
    update(agent, "sess-1", refinement)

    update(agent, "sess-1", %{
      "sessionUpdate" => "tool_call_update",
      "toolCallId" => "tc9",
      "status" => "completed",
      "content" => [
        %{"type" => "content", "content" => %{"type" => "text", "text" => "()\n"}}
      ]
    })

    inject(agent, %{"jsonrpc" => "2.0", "id" => pid, "result" => %{"stopReason" => "end_turn"}})
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)

    text = Buffer.text(buf)
    # the call line kept its short display name; the arguments landed once
    assert text =~ "▸ other · compos:apropos"
    assert text =~ "split window\n\n()"
    assert length(String.split(text, "split window")) == 2

    [_, _, "tool", "tc9", title, "other", "done", body_start] =
      Buffer.get_local(buf, "agent-blocks")
      |> Enum.find(fn [_, _, k | _] -> k == "tool" end)

    assert title == "compos:apropos: split window"
    assert binary_part(text, body_start, byte_size("split window")) == "split window"
  end

  test "typing at the marker queues while running and pops on turn end" do
    {slug, buf, agent} = boot("")
    focus(buf)

    type("first message")
    press(["RET"])

    assert_receive {:frame, %{"method" => "session/prompt", "id" => pid, "params" => p}}, 1_000
    assert [%{"text" => "first message"}] = p["prompt"]
    # input region cleared back to the mark; message echoed into the transcript
    assert eventually(fn -> input_text(buf) == "" end)
    assert eventually(fn -> Buffer.text(buf) =~ ">>> you: first message\n" end)

    # second message while running -> queued: it sits in 'chat-queued
    # (the client renders it as a muted row), not in the transcript text
    focus(buf)
    type("second message")
    press(["RET"])
    refute_receive {:frame, %{"method" => "session/prompt"}}, 200
    assert %{queued: 1} = Agent.info(slug)
    assert Buffer.get_local(buf, "chat-queued") == ["second message"]
    refute Buffer.text(buf) =~ "second message"

    inject(agent, %{"jsonrpc" => "2.0", "id" => pid, "result" => %{"stopReason" => "end_turn"}})

    assert_receive {:frame, %{"method" => "session/prompt", "params" => p2}}, 1_000
    assert [%{"text" => "second message"}] = p2["prompt"]
    # its turn started: the queued row left, the rendered user line took
    # its place — exactly one occurrence in the transcript
    assert eventually(fn -> Buffer.text(buf) =~ ">>> you: second message\n" end)
    assert eventually(fn -> Buffer.get_local(buf, "chat-queued") in [nil, false, []] end)

    assert eventually(fn ->
             parts = String.split(Buffer.text(buf), "second message")
             length(parts) == 2
           end)
  end

  test "Claude ACP queues on non-empty RET and steers the oldest row on blank RET" do
    {:ok, _} = Session.eval(~s[(execute* "" '(permission-mode ask))])
    assert_receive {:transport_open, agent}, 1_000
    assert_receive {:frame, %{"method" => "initialize", "id" => iid}}, 1_000

    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => iid,
      "result" => %{
        "protocolVersion" => 1,
        "_meta" => %{"steering" => %{"supported" => true}}
      }
    })

    assert_receive {:frame, %{"method" => "session/new", "id" => nid}}, 1_000
    inject(agent, %{"jsonrpc" => "2.0", "id" => nid, "result" => %{"sessionId" => "sess-s"}})

    slug = "a1"
    buf = "*chat:a1*"
    assert eventually(fn -> Agent.info(slug).steering end)
    focus(buf)

    type("start")
    press(["RET"])
    assert_receive {:frame, %{"method" => "session/prompt", "id" => prompt_id}}, 1_000

    type("change direction")
    press(["RET"])
    assert eventually(fn -> Agent.info(slug).queued == 1 end)
    assert Buffer.get_local(buf, "chat-queued") == ["change direction"]
    refute_receive {:frame, %{"method" => "_session/steering"}}, 100

    press(["RET"])

    assert_receive {:frame,
                    %{
                      "method" => "_session/steering",
                      "id" => steer_id,
                      "params" => steer
                    }},
                   1_000

    assert steer["sessionId"] == "sess-s"
    assert steer["prompt"] == [%{"type" => "text", "text" => "change direction"}]
    assert get_in(steer, ["_meta", "steering", "idleBehavior"]) == "promptRequired"

    # Once blank RET commits the row, unqueue cannot put a duplicate draft
    # back under the user's cursor while the transport owns delivery.
    press(["C-c", "C-d"])
    assert Buffer.get_local(buf, "chat-queued") == ["change direction"]
    assert {:ok, ~s{""}} = Session.eval(~s{(chat-input-text "#{buf}")})

    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => steer_id,
      "result" => %{"outcome" => "injected"}
    })

    assert eventually(fn -> Agent.info(slug).queued == 0 end)
    assert eventually(fn -> Buffer.get_local(buf, "chat-queued") in [nil, false, []] end)
    assert eventually(fn -> Buffer.text(buf) =~ ">>> you: change direction" end)

    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => prompt_id,
      "result" => %{"stopReason" => "end_turn"}
    })

    assert eventually(fn -> Agent.info(slug).status == :idle end)
    refute_receive {:frame, %{"method" => "session/prompt"}}, 100
  end

  test "Claude ACP preserves the queued row when steering requires a new prompt" do
    {:ok, _} = Session.eval(~s[(execute* "" '(permission-mode ask))])
    assert_receive {:transport_open, agent}, 1_000
    assert_receive {:frame, %{"method" => "initialize", "id" => iid}}, 1_000

    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => iid,
      "result" => %{
        "protocolVersion" => 1,
        "_meta" => %{"steering" => %{"supported" => true}}
      }
    })

    assert_receive {:frame, %{"method" => "session/new", "id" => nid}}, 1_000
    inject(agent, %{"jsonrpc" => "2.0", "id" => nid, "result" => %{"sessionId" => "sess-f"}})

    slug = "a1"
    buf = "*chat:a1*"
    assert eventually(fn -> Agent.info(slug).steering end)
    focus(buf)

    type("start")
    press(["RET"])
    assert_receive {:frame, %{"method" => "session/prompt", "id" => prompt_id}}, 1_000

    type("try to steer")
    press(["RET"])
    press(["RET"])

    assert_receive {:frame, %{"method" => "_session/steering", "id" => steer_id}}, 1_000

    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => steer_id,
      "result" => %{"outcome" => "promptRequired"}
    })

    # ACP declined live injection, so the message remains visibly queued and
    # must run exactly once as the next ordinary prompt.
    assert eventually(fn -> Agent.info(slug).queued == 1 end)
    assert Buffer.get_local(buf, "chat-queued") == ["try to steer"]
    refute Buffer.text(buf) =~ ">>> you: try to steer"

    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => prompt_id,
      "result" => %{"stopReason" => "end_turn"}
    })

    assert_receive {:frame,
                    %{
                      "method" => "session/prompt",
                      "id" => fallback_id,
                      "params" => %{"prompt" => [%{"text" => "try to steer"}]}
                    }},
                   1_000

    assert eventually(fn -> Buffer.text(buf) =~ ">>> you: try to steer" end)
    assert eventually(fn -> Agent.info(slug).queued == 0 end)

    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => fallback_id,
      "result" => %{"stopReason" => "end_turn"}
    })

    assert eventually(fn -> Agent.info(slug).status == :idle end)
    refute_receive {:frame, %{"method" => "session/prompt"}}, 100
  end

  test "Claude ACP completion waits for out-of-order steering fallbacks and preserves FIFO" do
    {:ok, _} = Session.eval(~s[(execute* "" '(permission-mode ask))])
    assert_receive {:transport_open, agent}, 1_000
    assert_receive {:frame, %{"method" => "initialize", "id" => iid}}, 1_000

    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => iid,
      "result" => %{
        "protocolVersion" => 1,
        "_meta" => %{"steering" => %{"supported" => true}}
      }
    })

    assert_receive {:frame, %{"method" => "session/new", "id" => nid}}, 1_000
    inject(agent, %{"jsonrpc" => "2.0", "id" => nid, "result" => %{"sessionId" => "sess-r"}})

    slug = "a1"
    assert eventually(fn -> Agent.info(slug).steering end)
    assert Agent.prompt(slug, "start") == :sent
    assert_receive {:frame, %{"method" => "session/prompt", "id" => prompt_id}}, 1_000

    assert Agent.prompt(slug, "first") == :queued
    assert Agent.steer_next(slug) == :sent
    assert_receive {:frame, %{"method" => "_session/steering", "id" => first_id}}, 1_000

    assert Agent.prompt(slug, "second") == :queued
    assert Agent.steer_next(slug) == :sent
    assert_receive {:frame, %{"method" => "_session/steering", "id" => second_id}}, 1_000

    # Completion wins the wire race, then the second fallback arrives first.
    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => prompt_id,
      "result" => %{"stopReason" => "end_turn"}
    })

    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => second_id,
      "result" => %{"outcome" => "promptRequired"}
    })

    refute_receive {:frame, %{"method" => "session/prompt"}}, 100

    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => first_id,
      "result" => %{"outcome" => "promptRequired"}
    })

    assert_receive {:frame,
                    %{
                      "method" => "session/prompt",
                      "id" => first_prompt,
                      "params" => %{"prompt" => [%{"text" => "first"}]}
                    }},
                   1_000

    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => first_prompt,
      "result" => %{"stopReason" => "end_turn"}
    })

    assert_receive {:frame,
                    %{
                      "method" => "session/prompt",
                      "id" => second_prompt,
                      "params" => %{"prompt" => [%{"text" => "second"}]}
                    }},
                   1_000

    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => second_prompt,
      "result" => %{"stopReason" => "end_turn"}
    })

    assert eventually(fn -> match?(%{status: :idle, queued: 0}, Agent.info(slug)) end)
  end

  test "cancel finishes a turn whose completion is waiting on steering acknowledgement" do
    {slug, agent} = boot_steering_acp("sess-cancel")
    assert Agent.prompt(slug, "start") == :sent
    assert_receive {:frame, %{"method" => "session/prompt", "id" => prompt_id}}, 1_000

    assert Agent.prompt(slug, "committed") == :queued
    assert Agent.steer_next(slug) == :sent
    assert_receive {:frame, %{"method" => "_session/steering", "id" => steer_id}}, 1_000

    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => prompt_id,
      "result" => %{"stopReason" => "end_turn"}
    })

    assert eventually(fn -> Agent.info(slug).status == :running end)
    assert Agent.cancel(slug) == :ok
    assert eventually(fn -> match?(%{status: :idle, queued: 0}, Agent.info(slug)) end)
    refute_receive {:frame, %{"method" => "session/prompt"}}, 100

    # A late transport answer has no ownership left and cannot resurrect it.
    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => steer_id,
      "result" => %{"outcome" => "promptRequired"}
    })

    assert eventually(fn -> match?(%{status: :idle, queued: 0}, Agent.info(slug)) end)
  end

  test "a missing steering acknowledgement falls back after completed turn" do
    {slug, agent} = boot_steering_acp("sess-timeout")
    assert Agent.prompt(slug, "start") == :sent
    assert_receive {:frame, %{"method" => "session/prompt", "id" => prompt_id}}, 1_000

    assert Agent.prompt(slug, "must survive") == :queued
    assert Agent.steer_next(slug) == :sent
    assert_receive {:frame, %{"method" => "_session/steering"}}, 1_000

    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => prompt_id,
      "result" => %{"stopReason" => "end_turn"}
    })

    assert_receive {:frame,
                    %{
                      "method" => "session/prompt",
                      "id" => fallback_id,
                      "params" => %{"prompt" => [%{"text" => "must survive"}]}
                    }},
                   3_000

    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => fallback_id,
      "result" => %{"stopReason" => "end_turn"}
    })

    assert eventually(fn -> match?(%{status: :idle, queued: 0}, Agent.info(slug)) end)
  end

  test "Codex App Server is visible; deprecated Codex names remain hidden compatibility connectors" do
    assert {:ok, visible} = Session.eval(~s[(connector-names)])
    assert visible =~ "codex-app-server"
    refute visible =~ "codex-acp"
    refute visible =~ ~s["codex"]

    assert {:ok, ~s["Codex App Server — ChatGPT subscription"]} =
             Session.eval(~s[(connector-description "codex-app-server")])

    {:ok, native_backend} =
      Session.eval(
        ~s[(plist-get (agent-resolve-config '(connector "codex" model "gpt-5.5")) 'backend)]
      )

    {:ok, native_cmd} =
      Session.eval(
        ~s[(plist-get (agent-resolve-config '(connector "codex" model "gpt-5.5")) 'cmd)]
      )

    assert native_backend == ~s["codex-app-server"]
    assert native_cmd == ~s["codex app-server"]

    {:ok, cmd} =
      Session.eval(
        ~s[(plist-get (agent-resolve-config '(connector "codex-acp" model "gpt-5.5")) 'cmd)]
      )

    assert cmd == ~s["codex-acp -c model=\\"gpt-5.5\\""]

    # and the FLAGGED cmd is what actually reaches the transport — duplicate
    # plist keys must resolve first-wins on the elixir side too
    {:ok, _} =
      Session.eval(~s{(execute* "" '(connector "codex-acp" model "gpt-5.5" cmd "fake"))})

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

  test "opencode connector: session config options drive model and mode state" do
    assert {:ok, names} = Session.eval(~s[(connector-names)])
    assert names =~ "opencode"

    assert {:ok, ~s["OpenCode — multi-provider ACP agent"]} =
             Session.eval(~s[(connector-description "opencode")])

    # 'model-config: the model rides protocol config — no env pair, no cmd flag
    {:ok, conf_cmd} =
      Session.eval(
        ~s[(plist-get (agent-resolve-config '(connector "opencode" model "opencode/claude-sonnet-5")) 'cmd)]
      )

    assert conf_cmd == ~s["opencode acp"]

    {:ok, conf_env} =
      Session.eval(
        ~s[(plist-get (agent-resolve-config '(connector "opencode" model "opencode/claude-sonnet-5")) 'env)]
      )

    assert conf_env == "#f"

    {:ok, _} =
      Session.eval(
        ~s{(execute* "" '(connector "opencode" model "opencode/claude-sonnet-5" cmd "fake"))}
      )

    assert_receive {:transport_open, agent}, 1_000
    assert_receive {:transport_cmd, "fake"}, 1_000
    assert_receive {:frame, %{"method" => "initialize", "id" => iid}}, 1_000
    inject(agent, %{"jsonrpc" => "2.0", "id" => iid, "result" => %{"protocolVersion" => 1}})
    assert_receive {:frame, %{"method" => "session/new", "id" => nid}}, 1_000

    model_option = fn current ->
      %{
        "id" => "model",
        "name" => "Model",
        "type" => "select",
        "currentValue" => current,
        "options" => [
          %{"value" => "opencode/big-pickle", "name" => "Big Pickle"},
          %{"value" => "opencode/claude-sonnet-5", "name" => "Claude Sonnet 5"},
          %{"value" => "opencode/claude-opus-5", "name" => "Claude Opus 5"}
        ]
      }
    end

    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => nid,
      "result" => %{
        "sessionId" => "ses-oc",
        "configOptions" => [
          model_option.("opencode/big-pickle"),
          %{
            "id" => "mode",
            "name" => "Session Mode",
            "type" => "select",
            "currentValue" => "build",
            "options" => [
              %{"value" => "build", "name" => "build", "description" => "Default agent."},
              %{"value" => "plan", "name" => "plan", "description" => "Disallows edits."}
            ]
          }
        ]
      }
    })

    # the pinned model has no spawn-time route on this lane — the backend
    # sets the option itself once the session reports it
    assert_receive {:frame,
                    %{"method" => "session/set_config_option", "id" => pin_id, "params" => pin}},
                   1_000

    assert pin == %{
             "sessionId" => "ses-oc",
             "configId" => "model",
             "value" => "opencode/claude-sonnet-5"
           }

    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => pin_id,
      "result" => %{"configOptions" => [model_option.("opencode/claude-sonnet-5")]}
    })

    buf = "*chat:a1*"

    assert eventually(fn ->
             Buffer.get_local(buf, "agent-model") == "opencode/claude-sonnet-5"
           end)

    assert eventually(fn -> Buffer.get_local(buf, "agent-mode") == "build" end)
    assert [["build", "build", _], ["plan", "plan", _]] = Buffer.get_local(buf, "agent-modes")

    # C-c m rides set_config_option on this lane, not session/set_model
    focus(buf)
    press(["C-c", "m"])
    type("opencode/claude-opus-5")
    press(["RET"])

    assert_receive {:frame, %{"method" => "session/set_config_option", "params" => sp}}, 1_000
    assert sp["configId"] == "model"
    assert sp["value"] == "opencode/claude-opus-5"

    # the agent's own report stays the truth
    update(agent, "ses-oc", %{
      "sessionUpdate" => "config_option_update",
      "configOptions" => [model_option.("opencode/big-pickle")]
    })

    assert eventually(fn -> Buffer.get_local(buf, "agent-model") == "opencode/big-pickle" end)
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
        "toolCall" => %{"title" => "Edit files", "kind" => "edit"},
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

  test "ask is separate from permission and accepts any choice or typed answer" do
    {slug, buf, agent} = boot("")

    {:ok, _} = Session.eval(~s[(agent-prompt! "#{slug}" "plan the change")])
    assert_receive {:frame, %{"method" => "session/prompt"}}, 1_000

    task =
      Task.async(fn ->
        Agent.ask_user(slug, "Open a new workspace?", ["Yes", "No", "Show diff first"])
      end)

    assert eventually(fn ->
             match?(
               %{
                 status: :needs_attention,
                 question: %{
                   question: "Open a new workspace?",
                   answers: ["Yes", "No", "Show diff first"]
                 }
               },
               Agent.info(slug)
             )
           end)

    assert eventually(fn ->
             Enum.any?(Buffer.get_local(buf, "agent-blocks") || [], fn
               [_, _, "question", _, ^slug, "Open a new workspace?", answers] ->
                 answers == ["Yes", "No", "Show diff first"]

               _ ->
                 false
             end)
           end)

    # RET while a question is pending answers the tool. It does not queue a
    # second user turn, and it does not use permission options.
    focus(buf)
    type("Use the existing checkout")
    press(["RET"])

    assert Task.await(task, 1_000) == {:ok, "Use the existing checkout"}
    assert %{status: :running, queued: 0, permission: nil, question: nil} = Agent.info(slug)

    assert eventually(fn ->
             not Enum.any?(Buffer.get_local(buf, "agent-blocks") || [], fn
               [_, _, "question" | _] -> true
               _ -> false
             end)
           end)

    _ = agent
  end

  test "command execution is rejected — compos is the only sandbox" do
    {slug, _buf, agent} = boot("")

    {:ok, _} = Session.eval(~s[(agent-prompt! "#{slug}" "go")])
    assert_receive {:frame, %{"method" => "session/prompt"}}, 1_000

    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => 89,
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

    # auto-rejected even in ask mode — no banner, no needs_attention
    assert_receive {:frame, %{"id" => 89, "result" => %{"outcome" => outcome}}}, 1_000
    assert outcome == %{"outcome" => "selected", "optionId" => "o-no"}
  end

  test "C-RET cancels the running turn" do
    {slug, buf, agent} = boot("")

    {:ok, _} = Session.eval(~s[(agent-prompt! "#{slug}" "long task")])
    assert_receive {:frame, %{"method" => "session/prompt"}}, 1_000

    focus(buf)
    press(["C-RET"])

    assert_receive {:frame,
                    %{"method" => "session/cancel", "params" => %{"sessionId" => "sess-1"}}},
                   1_000

    _ = agent
  end

  test "C-g cancels every queued turn and finalizes running tool cards" do
    {slug, buf, agent} = boot("")

    {:ok, _} = Session.eval(~s[(agent-prompt! "#{slug}" "long task")])
    assert_receive {:frame, %{"method" => "session/prompt", "id" => prompt_id}}, 1_000

    update(agent, "sess-1", %{
      "sessionUpdate" => "tool_call",
      "toolCallId" => "tc-abort",
      "title" => "compos/eval-scheme",
      "kind" => "execute",
      "status" => "in_progress",
      "rawInput" => %{"code" => "(long-running-call)"}
    })

    assert eventually(fn ->
             Enum.any?(Buffer.get_local(buf, "agent-blocks"), fn
               [_, _, "tool", "tc-abort", _, _, "running", _] -> true
               _ -> false
             end)
           end)

    focus(buf)
    type("do not run this next")
    press(["RET"])
    assert eventually(fn -> Agent.info(slug).queued == 1 end)

    press(["C-g"])

    assert_receive {:frame,
                    %{"method" => "session/cancel", "params" => %{"sessionId" => "sess-1"}}},
                   1_000

    assert eventually(fn ->
             Enum.any?(Buffer.get_local(buf, "agent-blocks"), fn
               [_, _, "tool", "tc-abort", _, _, "cancelled", _] -> true
               _ -> false
             end)
           end)

    refute "tc-abort" in (Buffer.get_local(buf, "agent-open-cards") || [])

    assert Buffer.get_local(buf, "chat-queued") in [nil, false, []]
    refute Buffer.text(buf) =~ "do not run this next"

    inject(agent, %{
      "jsonrpc" => "2.0",
      "id" => prompt_id,
      "result" => %{"stopReason" => "cancelled"}
    })

    assert eventually(fn -> match?(%{status: :idle, queued: 0}, Agent.info(slug)) end)
    refute_receive {:frame, %{"method" => "session/prompt"}}, 200
  end

  test "connectors: named config resolves into the session; per-call opts win" do
    {:ok, _} =
      Session.eval(~s{(define-connector! "test-conn" '(cwd "/tmp/conn-home" cmd "fake-acp"))})

    {:ok, _} = Session.eval(~s{(execute* "" '(connector "test-conn"))})
    assert_receive {:transport_open, agent}, 1_000
    assert_receive {:frame, %{"method" => "initialize", "id" => iid}}, 1_000
    inject(agent, %{"jsonrpc" => "2.0", "id" => iid, "result" => %{}})

    assert_receive {:frame,
                    %{"method" => "session/new", "params" => %{"cwd" => "/tmp/conn-home"}}},
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

  test "gemini nano connector is available for new browser-backed instances" do
    assert {:ok, names} = Session.eval("(connector-names)")
    assert names =~ "gemini-nano"

    assert {:ok, models} = Session.eval(~s[(connector-models "gemini-nano")])
    assert models =~ "gemini-nano"

    assert {:ok, capabilities} = Session.eval(~s[(connector-capabilities "gemini-nano")])
    assert capabilities =~ "stateless"

    assert {:ok, description} = Session.eval(~s[(connector-description "gemini-nano")])
    assert description =~ "Chrome Gemini Nano"

    assert {:ok, backend} =
             Session.eval(
               ~s[(plist-get (agent-resolve-config '(connector "gemini-nano")) 'backend)]
             )

    assert backend =~ "chrome-gemini-nano"
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

    assert :ok = Compos.Core.Desktop.save_now()

    # a daemon restart: the agent process and the buffer are both gone
    Agent.kill(slug)
    evict(buf)

    assert :ok = Compos.Core.Desktop.restore_now()

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

  test "desktop restore reconnects and continues a turn interrupted by restart" do
    {slug, buf, agent} = boot("")

    {:ok, _} = Session.eval(~s[(agent-prompt! "#{slug}" "finish the repair")])
    assert_receive {:frame, %{"method" => "session/prompt"}}, 1_000
    assert eventually(fn -> Buffer.text(buf) =~ ">>> you: finish the repair" end)
    assert Buffer.get_local(buf, "chat-turn-active")

    update(agent, "sess-1", %{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{"type" => "text", "text" => "I started the repair.\n"}
    })

    assert eventually(fn -> Buffer.text(buf) =~ "I started the repair." end)
    assert :ok = Compos.Core.Desktop.save_now()

    Agent.kill(slug)
    evict(buf)
    assert :ok = Compos.Core.Desktop.restore_now()

    # the dead runtime's spinner is swept from text and blocks, and its
    # unrevealed prose joins the prose block
    assert eventually(fn -> not (Buffer.text(buf) =~ "⋯ thinking") end)
    refute "waiting" in block_kinds(buf)
    assert "prose" in block_kinds(buf)
    [ps, pe] = prose_range(buf)
    assert binary_part(Buffer.text(buf), ps, pe - ps) == "I started the repair.\n"

    # No key press: chat-mode sees the durable in-flight flag and reconnects.
    assert_receive {:transport_open, fresh}, 1_000
    assert_receive {:frame, %{"method" => "initialize", "id" => iid}}, 1_000
    inject(fresh, %{"jsonrpc" => "2.0", "id" => iid, "result" => %{"protocolVersion" => 1}})

    assert_receive {:frame, %{"method" => "session/new", "id" => nid}}, 1_000
    inject(fresh, %{"jsonrpc" => "2.0", "id" => nid, "result" => %{"sessionId" => "sess-2"}})

    assert_receive {:frame,
                    %{"method" => "session/prompt", "id" => prompt_id, "params" => prompt}},
                   1_000

    [%{"text" => wire}] = prompt["prompt"]
    assert wire =~ "finish the repair"
    assert wire =~ "Continue the work interrupted by the editor restart"
    assert Buffer.text(buf) =~ "fresh session"

    inject(fresh, %{
      "jsonrpc" => "2.0",
      "id" => prompt_id,
      "result" => %{"stopReason" => "end_turn"}
    })

    assert eventually(fn -> Buffer.get_local(buf, "chat-turn-active") == false end)
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

  test "waiting spinner is a block; prose reveals by paragraph; turn end flushes the tail" do
    {slug, buf, agent} = boot("")

    {:ok, _} = Session.eval(~s[(agent-prompt! "#{slug}" "go")])
    assert_receive {:frame, %{"method" => "session/prompt", "id" => pid}}, 1_000
    assert eventually(fn -> Buffer.text(buf) =~ "⋯ thinking" end)
    # the rich view renders blocks only — the spinner must be one
    assert "waiting" in block_kinds(buf)

    update(agent, "sess-1", %{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{"type" => "text", "text" => "On it."}
    })

    # a partial paragraph stays pending: the text lands, the spinner stays
    assert eventually(fn -> Buffer.text(buf) =~ "On it." end)
    assert Buffer.text(buf) =~ "⋯ thinking"
    refute "prose" in block_kinds(buf)

    update(agent, "sess-1", %{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{"type" => "text", "text" => " First.\n\nSecond "}
    })

    # the paragraph break reveals the first paragraph and clears the spinner
    assert eventually(fn -> "prose" in block_kinds(buf) end)
    refute Buffer.text(buf) =~ "⋯ thinking"
    refute "waiting" in block_kinds(buf)
    [s, e] = prose_range(buf)
    assert binary_part(Buffer.text(buf), s, e - s) == "On it. First.\n\n"

    inject(agent, %{"jsonrpc" => "2.0", "id" => pid, "result" => %{"stopReason" => "end_turn"}})
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)
    refute Buffer.text(buf) =~ "⋯ thinking"

    # turn end reveals the pending tail
    [s2, e2] = prose_range(buf)
    assert binary_part(Buffer.text(buf), s2, e2 - s2) == "On it. First.\n\nSecond "
    assert Buffer.get_local(buf, "agent-prose-from") in [nil, false]
  end

  test "api connector: in-process thread, turns accumulate, no subprocess" do
    rounds = :ets.new(:api_rounds, [:public])

    Application.put_env(:compos_core, :llm_chat_fun, fn %{messages: messages} = req ->
      naming? =
        Enum.any?(messages, fn
          %{content: content} when is_binary(content) ->
            content =~ "Name this editor conversation"

          _ ->
            false
        end)

      if naming? do
        {:ok,
         %{
           "stop_reason" => "end_turn",
           "content" => [%{"type" => "text", "text" => "math chat"}]
         }}
      else
        n = :ets.info(rounds, :size) + 1
        :ets.insert(rounds, {n, messages, req[:reasoning_effort]})

        {:ok,
         %{
           "stop_reason" => "end_turn",
           "content" => [%{"type" => "text", "text" => "reply-#{n}"}],
           "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
         }}
      end
    end)

    on_exit(fn -> Application.delete_env(:compos_core, :llm_chat_fun) end)

    {:ok, _} =
      Session.eval(~s{(execute* "what is 6*7" '(connector "api" effort "high"))})

    initial_buf = "*chat:a1*"

    # no ACP handshake — no transport was opened
    refute_receive {:transport_open, _}, 200
    assert eventually(fn -> Buffer.text(Agent.info("a1").buffer) =~ "reply-1" end)
    assert eventually(fn -> match?(%{status: :idle}, Agent.info("a1")) end)

    # A chat is named for where it lives, never for what was said in it, so
    # the name it was born with is the name it keeps.
    buf = Agent.info("a1").buffer
    assert buf == initial_buf
    assert Buffer.exists?(buf)
    focus(buf)
    type("and 8*8")
    press(["RET"])

    assert eventually(fn -> Buffer.text(Agent.info("a1").buffer) =~ "reply-2" end)

    # the second request replays the whole conversation from the record —
    # no private history in the runtime
    [{_, msgs, effort} | _] = rounds |> :ets.tab2list() |> Enum.sort(:desc)
    assert effort == :high
    flat = Enum.map_join(msgs, "\n", fn m -> inspect(m.content) end)
    assert flat =~ "what is 6*7"
    assert flat =~ "reply-1"
    assert flat =~ "and 8*8"

    # the modeline names the running backend and its model
    final_buf = Agent.info("a1").buffer
    assert {:ok, ml} = Session.eval(~s[(buffer-local "#{final_buf}" 'modeline-info)])
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

  test "a bare turn-failed event clears the active chat state" do
    {slug, buf, agent} = boot("")

    {:ok, _} = Session.eval(~s[(agent-prompt! "#{slug}" "go")])
    assert_receive {:frame, %{"method" => "session/prompt"}}, 1_000
    assert eventually(fn -> Buffer.get_local(buf, "chat-turn-active") == true end)

    update(agent, "sess-1", %{
      "sessionUpdate" => "tool_call",
      "toolCallId" => "tc-stuck",
      "title" => "eval-scheme",
      "kind" => "other",
      "status" => "pending",
      "rawInput" => %{"code" => "(+ 1 2)"}
    })

    assert eventually(fn ->
             (Buffer.get_local(buf, "agent-blocks") || [])
             |> Enum.any?(&match?([_, _, "tool", "tc-stuck", _, _, "running" | _], &1))
           end)

    assert "tc-stuck" in (Buffer.get_local(buf, "agent-open-cards") || [])

    [{owner, _}] = Registry.lookup(Compos.Core.AgentRegistry, slug)
    send(owner, {:backend_event, Backend.plist(type: :"turn-failed")})

    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)
    assert eventually(fn -> Buffer.get_local(buf, "chat-turn-active") == false end)

    assert eventually(fn ->
             (Buffer.get_local(buf, "agent-blocks") || [])
             |> Enum.any?(&match?([_, _, "tool", "tc-stuck", _, _, "failed" | _], &1))
           end)

    assert Buffer.get_local(buf, "agent-open-cards") == []
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
    assert text =~ "a2"
    assert text =~ "needs_attention"

    # point lands on the first table entry; answer through the real key path
    focus("*chats*")
    {:ok, _} = Session.eval(~s[(list-goto-first-entry "*chats*")])
    press(["y"])

    assert_receive {:frame, %{"id" => 91, "result" => %{"outcome" => outcome}}}, 1_000
    assert outcome == %{"outcome" => "selected", "optionId" => "ok"}

    # attention clears once answered
    assert eventually(fn -> Editor.render_state().modeline_extra == "" end)
    _ = agent1
  end

  test "k flags and x kills the runtime; d flags and x releases windows before archiving" do
    {_slug, buf, _agent} = boot("")

    # show the thread in the main window, then open the fleet popup
    focus(buf)
    {:ok, _} = Session.eval(~s[(run-command "chat-list")])
    focus("*chats*")
    goto_chat_row(buf)

    # k only flags — the runtime stays up until x runs the flags
    press(["k"])
    assert Buffer.text("*chats*") =~ "K"
    assert Agent.list() != []

    press(["x"])
    assert eventually(fn -> Buffer.text(buf) =~ "[agent stopped]" end)
    assert eventually(fn -> Agent.list() == [] end)
    assert Buffer.text("*chats*") =~ "x  #{buf}"
    # the flag is gone with the runtime it killed
    refute Buffer.get_local("*chats*", "list-marks") |> Enum.any?()

    # the refresh re-sorted (dead ranks last) — find the row again
    goto_chat_row(buf)

    press(["d"])
    press(["x"])
    assert eventually(fn -> not Buffer.exists?(buf) end)
    # no window points at the killed buffer (no empty-ghost resurrection)
    windows = Editor.list_windows()
    refute Enum.any?(windows, fn {_id, b} -> b == buf end)
  end

  test "m marks; a verb acts on every marked chat, not the line at point" do
    {_slug1, buf1, _a1} = boot("")

    # a second thread, the way every two-agent test here boots one
    {:ok, _} = Session.eval(~s{(execute* "" '(permission-mode ask))})
    assert_receive {:transport_open, agent2}, 1_000
    assert_receive {:frame, %{"method" => "initialize", "id" => iid}}, 1_000
    inject(agent2, %{"jsonrpc" => "2.0", "id" => iid, "result" => %{}})
    assert_receive {:frame, %{"method" => "session/new", "id" => nid}}, 1_000
    inject(agent2, %{"jsonrpc" => "2.0", "id" => nid, "result" => %{"sessionId" => "sess-2"}})
    buf2 = "*chat:a2*"
    assert eventually(fn -> Buffer.exists?(buf2) end)

    {:ok, _} = Session.eval(~s[(run-command "chat-list")])
    focus("*chats*")

    # mark both, then stand on neither: the flags still find them
    goto_chat_row(buf1)
    press(["m"])
    goto_chat_row(buf2)
    press(["m"])
    assert length(Buffer.get_local("*chats*", "list-marks")) == 2

    # U drops every mark
    press(["U"])
    assert Buffer.get_local("*chats*", "list-marks") == []

    # flag both for the kill, then run the flags in one go
    goto_chat_row(buf1)
    press(["k"])
    goto_chat_row(buf2)
    press(["k"])
    press(["x"])

    assert eventually(fn -> Agent.list() == [] end)
    assert Buffer.text(buf1) =~ "[agent stopped]"
    assert Buffer.text(buf2) =~ "[agent stopped]"
  end

  # put point on BUF's row in the *chats* list
  defp goto_chat_row(buf) do
    rows = Buffer.get_local("*chats*", "list-entries")
    row = Enum.find_index(rows, &(&1 == buf))
    assert row, "chat #{buf} not listed in #{inspect(rows)}"
    {:ok, _} = Session.eval(~s[(list-goto-first-entry "*chats*")])
    press(List.duplicate("C-n", row))
    :ok
  end

  # The renderer slices the input region from 'agent-saved-mark. An append
  # grows the transcript ABOVE that mark, so both have to land in one
  # buffer message. While Scheme set the local in a second call, every
  # streamed chunk painted a frame in which the mark was stale, and the
  # input row rendered the new text as if it were typed.
  test "an append moves the saved mark in the same buffer message" do
    {slug, buf, agent} = boot("")

    before_mark = Buffer.get_local(buf, "agent-saved-mark")
    text = "streamed reply\n"

    update(agent, "sess-1", %{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{"type" => "text", "text" => text}
    })

    assert eventually(fn -> Buffer.text(buf) =~ "streamed reply" end)

    # the mark advanced past the appended text — the input region past
    # it holds no transcript
    mark = Buffer.get_local(buf, "agent-saved-mark")
    assert mark > before_mark
    assert Agent.mark(slug) == mark

    assert input_text(buf) == ""
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
      assert eventually(fn -> input_text(buf) == "" end)
    end

    send_turn.("first message")
    send_turn.("second message")

    # a half-typed draft, then walk back through the history
    focus(buf)
    type("draft")
    press(["<up>"])
    assert eventually(fn -> input_text(buf) == "second message" end)

    press(["<up>"])
    assert eventually(fn -> input_text(buf) == "first message" end)

    # nothing older: the input holds still rather than emptying
    press(["<up>"])
    assert eventually(fn -> input_text(buf) == "first message" end)

    press(["<down>"])
    assert eventually(fn -> input_text(buf) == "second message" end)

    # ...and back to what was typed before the walk started
    press(["<down>"])
    assert eventually(fn -> input_text(buf) == "draft" end)

    # the walk reads the conversation of record — there is no second copy
    # of the messages
    assert {:ok, ~s{(("user" "second message") ("user" "first message"))}} =
             Session.eval(~s{(filter (lambda (t) (equal? (car t) "user")) (chat-turns "#{buf}"))})
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
    assert eventually(fn -> input_text(buf) == "newer question" end)

    press(["<up>"])
    assert eventually(fn -> input_text(buf) == "older question" end)
  end

  # The case that matters most: reopen the editor and press up. A restored
  # chat has no 'agent-slug until its first send, so the walk must read the
  # buffer-locals, never the runtime.
  test "up works on a restored chat that has no runtime yet" do
    buf = "*chat:restored*"
    {:ok, _} = Compos.Core.create_buffer(buf)

    {:ok, _} =
      Session.eval("""
      (begin
        (buffer-append! "#{buf}" "chat\\n")
        (buffer-set-local! "#{buf}" 'agent-saved-mark (buffer-size "#{buf}"))
        (buffer-set-local! "#{buf}" 'agent-marker-bytes 0)
        (buffer-set-local! "#{buf}" 'chat-turns '(("user" "what I asked before")))
        (switch-to-buffer! "#{buf}")
        ;; the mode setup is what a desktop restore runs — it binds the keys
        (set-mode! "chat-mode")
        (end-of-buffer!))
      """)

    refute Buffer.get_local(buf, "agent-slug")

    press(["<up>"])

    assert eventually(fn ->
             input_text(buf) == "what I asked before"
           end)

    press(["<down>"])
    assert eventually(fn -> input_text(buf) == "" end)

    Compos.Core.kill_buffer(buf)
  end

  test "up inside a multi-line input still moves the cursor" do
    {slug, buf, agent} = boot("")

    focus(buf)
    type("line one")
    press(["RET"])
    assert_receive {:frame, %{"method" => "session/prompt", "id" => id}}, 1_000
    inject(agent, %{"jsonrpc" => "2.0", "id" => id, "result" => %{"stopReason" => "end_turn"}})
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)
    assert eventually(fn -> input_text(buf) == "" end)

    # RET sends, so build a two-line input without sending
    focus(buf)
    {:ok, _} = Session.eval(~s[(begin (end-of-buffer!) (insert! "aaa\\nbbb"))])

    # point sits on the last line, with a line above it: up is motion
    press(["<up>"])
    assert String.ends_with?(Buffer.text(buf), "aaa\nbbb")

    # now on the first line, so up recalls the newest sent message
    press(["<up>"])
    assert eventually(fn -> input_text(buf) == "line one" end)
  end

  test "adapter exit renders a death notice and marks the thread dead" do
    {slug, buf, agent} = boot("")

    send(agent, {:acp_exit, 1})

    assert eventually(fn -> Buffer.text(buf) =~ "[agent exited]" end)
    assert eventually(fn -> match?(%{status: :dead}, Agent.info(slug)) end)
  end

  test "a backend process crash leaves the session alive for queued rendering and revival" do
    {slug, buf, backend} = boot("")

    Process.exit(backend, :boom)

    assert eventually(fn -> match?(%{status: :dead}, Agent.info(slug)) end)
    assert is_integer(Agent.append_at_mark(slug, "late event\n"))
    assert Buffer.text(buf) =~ "late event"
  end

  test "a late render after its target was killed does not kill the session" do
    {slug, buf, _backend} = boot("")

    assert :ok = Compos.Core.kill_buffer(buf)
    assert Agent.append_at_mark(slug, "too late\n") == {:error, :no_buffer}
    assert Agent.running?(slug)
  end

  test "session/new carries our mcpServers and _meta; the adapter loads no user config" do
    {:ok, _} = Session.eval(~s[(execute* "" '(presets (compos)))])
    assert_receive {:transport_open, agent}, 1_000
    assert_receive {:frame, %{"method" => "initialize", "id" => iid, "params" => ip}}, 1_000

    # fs/* stays refused: agents read live editor state through mcp__compos__,
    # not through a filesystem shim over buffers
    assert %{"fs" => %{"readTextFile" => false, "writeTextFile" => false}} =
             ip["clientCapabilities"]

    inject(agent, %{"jsonrpc" => "2.0", "id" => iid, "result" => %{"protocolVersion" => 1}})

    assert_receive {:frame, %{"method" => "session/new", "id" => nid, "params" => np}}, 1_000

    # The explicit compos preset mounts the editor proxy.
    assert Enum.any?(np["mcpServers"] || [], &(&1["name"] == "compos"))

    # The two keys still make this explicit list the only source. settingSources
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

    update(agent, "sess-md", %{
      "sessionUpdate" => "current_mode_update",
      "currentModeId" => "plan"
    })

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

  defp block_kinds(buf),
    do: (Buffer.get_local(buf, "agent-blocks") || []) |> Enum.map(fn [_, _, k | _] -> k end)

  defp prose_range(buf) do
    [s, e | _] =
      Buffer.get_local(buf, "agent-blocks")
      |> Enum.find(fn [_, _, k | _] -> k == "prose" end)

    [s, e]
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
