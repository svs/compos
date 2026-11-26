defmodule Compos.MCPTest do
  @moduledoc """
  The MCP bridge: the Elixir client, and one test waiting on a bug.

  The policy — the registry, the ACP translation, the system note, the
  tool list, mcp-call!, mcp-tools, mcp-find and the preset pull — is
  Scheme and lives in priv/tests/mcp-policy-test.scm, which writes its own
  fake server rather than reaching into this tree.

  What stays drives MCP.connect, MCP.call, MCP.tool_specs and the tool
  loop through an Application.put_env stub. Plus the CALLBACK form of
  mcp-call!: it hands its text to a closure created inside the test, and a
  closure created mid-eval points at a frame no other process can resolve,
  so from Scheme the reply is dropped in silence. See
  docs/BUG-escaped-closure-handlers.md; when that is fixed this one moves.
  """

  use Compos.Case

  alias Compos.Core.{MCP, Session}

  @fixture Path.expand("../support/fake_mcp_server.exs", __DIR__)

  defp connect!(name, extra_args \\ []) do
    on_exit(fn -> MCP.disconnect(name) end)
    {:ok, _} = MCP.connect(name, %{"command" => "elixir", "args" => [@fixture | extra_args]})
    wait_until(fn -> MCP.tool_specs([name]) != [] end)
  end

  describe "client" do
    test "handshake publishes qualified specs carrying the raw JSON schema" do
      connect!("fake")

      specs = MCP.tool_specs(["fake"])
      assert [name, desc, schema, effects] = Enum.find(specs, &(hd(&1) == "mcp__fake__echo"))
      assert name == "mcp__fake__echo"
      assert desc =~ "Echo"
      assert Jason.decode!(schema)["required"] == ["v"]
      assert effects == ["read", "external"]

      assert [%{name: "fake", status: :ready, tools: 1}] =
               Enum.filter(MCP.connections(), &(&1.name == "fake"))
    end

    test "missing annotations stay unknown and trusted config can override them" do
      MCP.publish("plain", [%{"name" => "look", "inputSchema" => %{}}])
      on_exit(fn -> :persistent_term.erase({:compos_mcp, "plain"}) end)

      assert [[_, _, _, ["unknown", "external"]]] = MCP.tool_specs(["plain"])

      MCP.publish("plain", [%{"name" => "look", "inputSchema" => %{}}], %{"read-only" => true})

      assert [[_, _, _, ["read", "external"]]] = MCP.tool_specs(["plain"])

      MCP.publish(
        "plain",
        [%{"name" => "look", "inputSchema" => %{}}],
        %{"read-only" => true, "tool-effects" => ["look", ["write"]]}
      )

      assert [[_, _, _, ["write", "external"]]] = MCP.tool_specs(["plain"])
    end

    test "call and call_qualified round trip; unknown server reports" do
      connect!("fake2")

      assert {:ok, "echo:hi"} = MCP.call("fake2", "echo", %{"v" => "hi"})
      assert {:ok, "echo:yo"} = MCP.call_qualified("mcp__fake2__echo", %{"v" => "yo"})
      assert {:error, msg} = MCP.call_qualified("mcp__nope__echo", %{})
      assert msg =~ "not connected"
    end

    test "server names are constrained so qualified names split cleanly" do
      assert {:error, _} = MCP.connect("Bad_Name", %{"command" => "true"})
    end

    test "disconnect unpublishes and frees the name" do
      connect!("fake3")
      assert MCP.connected?("fake3")

      MCP.disconnect("fake3")
      wait_until(fn -> not MCP.connected?("fake3") end)
      assert MCP.tool_specs(["fake3"]) == []
    end

    test "a dead command fails loudly instead of hanging" do
      {:ok, _} = MCP.connect("gone", %{"command" => "no-such-binary-zz"})

      wait_until(fn ->
        {:ok, text} = Session.eval(~s{(messages-text)})
        text =~ "gone failed"
      end)
    end
  end

  describe "tool loop bridge" do
    test "read-only tools on separate MCP servers run concurrently" do
      connect!("parallel-a")
      connect!("parallel-b")
      me = self()

      Application.put_env(:compos_core, :llm_chat_fun, fn %{messages: messages} ->
        seen_result? =
          Enum.any?(messages, fn m ->
            is_list(m.content) and
              Enum.any?(m.content, &(is_map(&1) and &1[:type] == "tool_result"))
          end)

        if seen_result? do
          send(me, :parallel_mcp_done)

          {:ok,
           %{
             "stop_reason" => "end_turn",
             "content" => [%{"type" => "text", "text" => "done"}]
           }}
        else
          {:ok,
           %{
             "stop_reason" => "tool_use",
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "parallel-a",
                 "name" => "mcp__parallel-a__echo",
                 "input" => %{"v" => "a", "wait" => 300}
               },
               %{
                 "type" => "tool_use",
                 "id" => "parallel-b",
                 "name" => "mcp__parallel-b__echo",
                 "input" => %{"v" => "b", "wait" => 300}
               }
             ]
           }}
        end
      end)

      on_exit(fn -> Application.delete_env(:compos_core, :llm_chat_fun) end)

      specs = MCP.tool_specs(["parallel-a", "parallel-b"])
      started = System.monotonic_time(:millisecond)

      assert {:ok, "done", %{}, "end_turn"} =
               Compos.Core.LLM.run_tool_loop(
                 [%{role: "user", content: "go"}],
                 "sys",
                 specs,
                 fn _, _ -> raise "MCP must not use the Scheme dispatcher" end
               )

      elapsed = System.monotonic_time(:millisecond) - started
      assert_receive :parallel_mcp_done
      assert elapsed < 520
    end

    test "mcp__ tools dispatch to the client, not the Scheme dispatcher" do
      connect!("fake4")

      Application.put_env(:compos_core, :llm_chat_fun, fn %{messages: messages, tools: tools} ->
        assert Enum.any?(tools, &(&1.name == "mcp__fake4__echo"))

        seen_result? =
          Enum.any?(messages, fn m ->
            is_list(m.content) and
              Enum.any?(m.content, &(is_map(&1) and &1[:type] == "tool_result"))
          end)

        if seen_result? do
          [%{content: [%{content: result} | _]} | _] = Enum.reverse(messages)

          {:ok,
           %{
             "stop_reason" => "end_turn",
             "content" => [%{"type" => "text", "text" => "got #{result}"}],
             "usage" => %{"input_tokens" => 5, "output_tokens" => 7}
           }}
        else
          {:ok,
           %{
             "stop_reason" => "tool_use",
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "tu_mcp",
                 "name" => "mcp__fake4__echo",
                 "input" => %{"v" => "loop"}
               }
             ],
             "usage" => %{"input_tokens" => 10, "output_tokens" => 2}
           }}
        end
      end)

      on_exit(fn -> Application.delete_env(:compos_core, :llm_chat_fun) end)

      # dispatcher would blow up if consulted for the mcp tool
      eval!("""
      (llm-tools "go" "sys" (mcp-tool-specs (list "fake4"))
        (lambda (n a) (zz-scheme-dispatcher-must-not-see-mcp-tools))
        (lambda (t) (set-symbol-value! 'zz-mcp-reply t))
        (lambda (u) (set-symbol-value! 'zz-mcp-usage u)))
      """)

      wait_until(fn -> match?({:ok, "#t"}, Session.eval("(boundp 'zz-mcp-reply)")) end)
      assert eval!("zz-mcp-reply") == ~s{"got echo:loop"}

      # usage callback saw the summed rounds
      assert eval!("(plist-get zz-mcp-usage 'input)") == "15"
      assert eval!("(plist-get zz-mcp-usage 'output)") == "9"
    end
  end

  describe "form elicitation" do
    test "stateless InputRequiredResult replays tools/call with requestState and inputResponses" do
      connect!("elicit1", ["--elicitation"])

      handler = fn server, tool, params ->
        assert server == "elicit1"
        assert tool == "guarded"
        assert params["message"] =~ "Guarded action"
        %{"action" => "accept", "content" => %{"approval_choice" => "ALLOW_ONCE"}}
      end

      assert {:ok, "approved:ALLOW_ONCE:hello"} =
               MCP.call("elicit1", "guarded", %{"v" => "hello"}, elicitation_handler: handler)

      deny_handler = fn _server, _tool, _params ->
        %{"action" => "accept", "content" => %{"approval_choice" => "DENY_ONCE"}}
      end

      assert {:error, "denied:DENY_ONCE"} =
               MCP.call("elicit1", "guarded", %{"v" => "hello"}, elicitation_handler: deny_handler)
    end

    test "stateful server-initiated elicitation/create replies and completes tools/call" do
      connect!("elicit2", ["--elicitation"])

      Application.put_env(:compos_core, :mcp_elicitation_fun, fn _server, _tool, params ->
        assert params["message"] == "Confirm world"
        %{"action" => "accept", "content" => %{"confirm" => true}}
      end)

      on_exit(fn -> Application.delete_env(:compos_core, :mcp_elicitation_fun) end)

      assert {:ok, "stateful:true:world"} = MCP.call("elicit2", "ask_stateful", %{"v" => "world"})
    end
  end

  describe "scheme policy (packages/mcp.scm)" do
    test "the callback form returns at once and hands the text over later" do
      on_exit(fn -> MCP.disconnect("zzcb") end)
      eval!(~s{(mcp-register! 'zzcb (list 'command "elixir" 'args (list "#{@fixture}")))})

      assert eval!(~s[(mcp-call! 'zzcb "echo" '(v "later")
                        (lambda (ok text) (set-symbol-value! 'zz-cb-reply (list ok text))))]) == ""

      wait_until(fn -> match?({:ok, "#t"}, Session.eval("(boundp 'zz-cb-reply)")) end)
      assert eval!("zz-cb-reply") == ~s[(#t "echo:later")]
    end

  end
end
