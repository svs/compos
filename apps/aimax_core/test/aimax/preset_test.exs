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
  W6: presets are the single source of truth for a chat's tools. An ACP
  session fixes mcpServers at session/new, so a preset change under a live
  agent must reattach — never silently do nothing.
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

  test "loading a preset on a live ACP chat reattaches; the conversation survives" do
    {slug, buf, agent, first_new} = boot()

    # the fresh session has only the editor's own tool proxy
    assert servers(first_new) == ["aimax"]

    # give the chat a real conversation to carry across the reconnect
    {:ok, _} = Session.eval(~s[(agent-prompt! "#{slug}" "what is the weather")])
    assert_receive {:frame, %{"method" => "session/prompt", "id" => pid}}, 1_000

    send(agent, {:acp_data, Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => "sess-1",
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "I have no weather tool."}
        }
      }
    }) <> "\n"})

    inject(agent, %{"jsonrpc" => "2.0", "id" => pid, "result" => %{"stopReason" => "end_turn"}})
    assert eventually(fn -> Buffer.text(buf) =~ "no weather tool" end)

    # load the preset from the real command, and decline the offer to
    # reconnect right now — the change must still not be lost
    {:ok, _} = Session.eval(~s[(switch-to-buffer! "#{buf}")])
    {:ok, _} = Session.eval(~s[(run-command "chat-load-preset")])
    type("zz-pack")
    press(["RET"])
    assert eventually(fn -> Editor.snapshot().minibuffer != nil end)
    type("no")
    press(["RET"])

    assert Buffer.get_local(buf, "chat-presets") == [sym: "zz-pack"]
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
    assert "zz-weather" in servers(np2)
    assert "aimax" in servers(np2)

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
    {:ok, _} = Session.eval(~s[(run-command "chat-load-preset")])
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
    {:ok, _} = Session.eval(~s[(run-command "chat-unload-preset")])
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
    assert Buffer.get_local(buf, "chat-presets") == []
  end

  test "the api lane needs no reconnect: its tool specs are read at send time" do
    {:ok, _} = Session.eval(~s{(execute* "" '(connector "api"))})
    buf = "*chat:a1*"

    {:ok, _} = Session.eval(~s[(switch-to-buffer! "#{buf}")])
    {:ok, _} = Session.eval(~s[(run-command "chat-load-preset")])
    type("zz-pack")
    press(["RET"])

    # no reconnect prompt at all — nothing to reconnect
    refute Editor.snapshot().minibuffer
    assert Buffer.get_local(buf, "chat-presets") == [sym: "zz-pack"]
    assert Buffer.get_local(buf, "chat-mcp-dirty") in [false, nil]
    refute_received {:transport_open, _}
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
