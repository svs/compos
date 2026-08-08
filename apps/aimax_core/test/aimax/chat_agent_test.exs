defmodule Aimax.ChatAgentTest.FakeTransport do
  @moduledoc "Same seam as Aimax.AgentTest.FakeTransport (that one lives in its test file)."

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

defmodule Aimax.ChatAgentTest do
  @moduledoc """
  Chat/agent unification: a chat buffer hosts an ACP thread
  (chat-set-backend), the caller's presets become the session's MCP servers,
  and the editor's own tool proxy always rides along.
  """

  use ExUnit.Case

  alias Aimax.Core.{Agent, Session}

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true ->
        Process.sleep(20)
        wait_until(fun, tries - 1)
    end
  end

  setup do
    :persistent_term.put(:agent_test_pid, self())
    Application.put_env(:aimax_core, :acp_transport, Aimax.ChatAgentTest.FakeTransport)
    System.put_env("ZZ_TEST_KEY", "sekrit")

    on_exit(fn ->
      Application.delete_env(:aimax_core, :acp_transport)
      System.delete_env("ZZ_TEST_KEY")
      Enum.each(Agent.list(), &Agent.kill/1)
      Aimax.Core.kill_buffer("*zz-uchat*")
    end)

    :ok
  end

  defp inject(agent, frame), do: send(agent, {:acp_data, Jason.encode!(frame) <> "\n"})

  defp handshake(agent) do
    assert_receive {:frame, %{"method" => "initialize", "id" => iid}}, 2_000
    inject(agent, %{jsonrpc: "2.0", id: iid, result: %{protocolVersion: 1}})
    assert_receive {:frame, %{"method" => "session/new", "id" => sid} = frame}, 2_000
    inject(agent, %{jsonrpc: "2.0", id: sid, result: %{sessionId: "s1"}})
    frame
  end

  test "a chat becomes an agent thread; session/new carries the caller's MCP set" do
    eval!(~s{(buffer-create "*zz-uchat*")})
    eval!(~s{(buffer-append! "*zz-uchat*" "### You\\nhello\\n")})

    eval!(~s{(mcp-register! 'zzsrv
               (list 'command "echo" 'args (list "hi")
                     'env (list 'K "@ZZ_TEST_KEY")))})
    eval!(~s{(define-preset! 'zzpre "test" '(zzsrv))})
    eval!(~s{(buffer-set-local! "*zz-uchat*" 'chat-presets '(zzpre))})

    slug = String.trim(eval!(~s{(chat-attach-agent! "*zz-uchat*" "claude-code")}), "\"")

    assert_receive {:transport_open, agent}, 2_000
    %{"params" => %{"mcpServers" => servers}} = handshake(agent)

    names = Enum.map(servers, & &1["name"])
    assert "aimax" in names
    assert "zzsrv" in names

    aimax = Enum.find(servers, &(&1["name"] == "aimax"))
    assert aimax["command"] == "elixir"
    assert [path] = aimax["args"]
    assert String.ends_with?(path, "aimax-mcp-proxy.exs")

    # "@" env refs resolved at the boundary, not stored anywhere
    zz = Enum.find(servers, &(&1["name"] == "zzsrv"))
    assert zz["env"] == [%{"name" => "K", "value" => "sekrit"}]

    # the thread is bound to the chat buffer, not a *agent:* buffer
    assert eval!("(agent-buf \"#{slug}\")") == ~s{"*zz-uchat*"}
    info = Agent.info(slug)
    assert info.buffer == "*zz-uchat*"
  end

  test "prompts flow through the thread and chunks render into the chat buffer" do
    eval!(~s{(buffer-create "*zz-uchat*")})
    slug = String.trim(eval!(~s{(chat-attach-agent! "*zz-uchat*" "claude-code")}), "\"")

    assert_receive {:transport_open, agent}, 2_000
    handshake(agent)

    wait_until(fn -> Agent.info(slug).status == :idle end)
    assert Agent.prompt(slug, "hi there") == :sent

    assert_receive {:frame, %{"method" => "session/prompt", "id" => pid_} = f}, 2_000
    assert get_in(f, ["params", "prompt"]) == [%{"text" => "hi there", "type" => "text"}]

    inject(agent, %{
      jsonrpc: "2.0",
      method: "session/update",
      params: %{
        sessionId: "s1",
        update: %{sessionUpdate: "agent_message_chunk", content: %{type: "text", text: "sub-powered reply"}}
      }
    })

    inject(agent, %{jsonrpc: "2.0", id: pid_, result: %{stopReason: "end_turn"}})

    wait_until(fn ->
      {:ok, text} = Session.eval(~s{(buffer-text "*zz-uchat*")})
      text =~ "sub-powered reply"
    end)
  end

  test "api threads pin a per-chat model and take a switch in place" do
    slug = String.trim(eval!(~s{(execute* "" '(connector "api"))}), "\"")
    buf = "*chat:#{slug}*"

    on_exit(fn ->
      Aimax.Core.kill_buffer(buf)
      Aimax.Core.Editor.delete_other_windows()
    end)

    # unpinned, the modeline follows the editor default
    assert eval!("(buffer-local (agent-buf \"#{slug}\") 'agent-model)") == "#f"
    assert eval!(~s{(buffer-local "#{buf}" 'modeline-info)}) =~ "api"

    # the direct lane is stateless: a model switch always lands in place,
    # so the conversation never restarts for a model change
    assert eval!(~s{(agent-set-model! "#{slug}" "claude-opus-5")}) == "#t"
    eval!(~s{(begin (buffer-set-local! "#{buf}" 'agent-model "claude-opus-5")
                    (agent-update-modeline! "#{buf}"))})

    assert eval!(~s{(buffer-local "#{buf}" 'modeline-info)}) =~ "claude-opus-5"
  end

  test "the proxy surface serves the registry and calls tools, base64 both ways" do
    tools =
      eval!("(mcp-proxy-tools-json)")
      |> String.trim("\"")
      |> Base.decode64!()
      |> Jason.decode!()

    names = Enum.map(tools, & &1["name"])
    assert "eval-scheme" in names
    assert Enum.all?(tools, & &1["inputSchema"])

    eval!(~s{(buffer-create "*zz-uchat*")})
    eval!(~s{(buffer-append! "*zz-uchat*" "proxy sees mé")})

    args = Base.encode64(Jason.encode!(%{"code" => ~s{(buffer-text "*zz-uchat*")}}))

    result =
      eval!(~s{(mcp-proxy-call "eval-scheme" "#{args}")})
      |> String.trim("\"")
      |> Base.decode64!()

    # eval-scheme returns the printed value, quotes included
    assert result == ~s{"proxy sees mé"}
  end
end
