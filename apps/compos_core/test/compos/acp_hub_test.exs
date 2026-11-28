defmodule Compos.ACPHubTest do
  @moduledoc """
  Chats on a sharing connector are sessions of one adapter process
  (Agent.ACPHub): one initialize, ids rewritten per chat, the agent's
  frames routed by sessionId, a leaving chat's session closed, and every
  chat parked for session/load when the shared adapter dies. Driven
  through the FakeTransport: the test is the adapter.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.Agent
  alias Compos.Core.Agent.Backend.ACP

  setup do
    Compos.Test.FakeTransport.own!()
    Application.put_env(:compos_core, :acp_transport, Compos.Test.FakeTransport)
    Application.put_env(:compos_core, :acp_hub_linger_ms, 50)
    Application.put_env(:compos_core, :acp_share_adapters, true)

    on_exit(fn ->
      Application.delete_env(:compos_core, :acp_transport)
      Application.delete_env(:compos_core, :acp_hub_linger_ms)
      Application.put_env(:compos_core, :acp_share_adapters, false)
      Application.delete_env(:compos_core, :agent_idle_ms)
    end)

    {:ok, cmd: "fake-shared-#{System.unique_integer([:positive])}"}
  end

  defp inject(hub, frame), do: send(hub, {:acp_data, Jason.encode!(frame) <> "\n"})

  # a chat stand-in: its backend's events come to the test tagged with TAG
  defp owner(tag) do
    test = self()

    spawn_link(fn ->
      Stream.repeatedly(fn ->
        receive do
          {:backend_event, e} ->
            send(test, {tag, Map.new(Enum.chunk_every(e, 2), fn [{:sym, k}, v] -> {String.to_atom(k), unsym(v)} end)})
        end
      end)
      |> Stream.run()
    end)
  end

  defp unsym({:sym, s}), do: String.to_atom(s)
  defp unsym(v), do: v

  defp backend(cmd, tag) do
    {:ok, pid} = ACP.start(%{"cmd" => cmd, "cwd" => File.cwd!(), "share" => true}, owner(tag))
    on_exit(fn -> if Process.alive?(pid), do: ACP.close(pid) end)
    pid
  end

  defp caps,
    do: %{
      "agentCapabilities" => %{
        "loadSession" => true,
        "sessionCapabilities" => %{"close" => %{}}
      }
    }

  defp chunk(sid, text),
    do: %{
      "method" => "session/update",
      "params" => %{
        "sessionId" => sid,
        "update" => %{"sessionUpdate" => "agent_message_chunk", "content" => %{"type" => "text", "text" => text}}
      }
    }

  defp two_sessions(cmd) do
    a = backend(cmd, :a)
    assert_receive {:transport_open, hub}, 2_000
    assert_receive {:frame, %{"method" => "initialize", "id" => init}}, 2_000
    inject(hub, %{"id" => init, "result" => caps()})
    assert_receive {:frame, %{"method" => "session/new", "id" => new_a}}, 2_000
    inject(hub, %{"id" => new_a, "result" => %{"sessionId" => "sA"}})
    assert_receive {:a, %{type: :ready}}, 2_000

    b = backend(cmd, :b)
    # the second chat joins the running adapter: no process, no initialize
    refute_receive {:transport_open, _}, 100
    assert_receive {:frame, %{"method" => "session/new", "id" => new_b} = f}, 2_000
    refute new_b == new_a
    assert f["params"]["cwd"] == File.cwd!()
    inject(hub, %{"id" => new_b, "result" => %{"sessionId" => "sB"}})
    assert_receive {:b, %{type: :ready}}, 2_000

    {hub, a, b}
  end

  test "two chats share one adapter and each hears only its own session", %{cmd: cmd} do
    {hub, a, b} = two_sessions(cmd)

    inject(hub, chunk("sB", "for b"))
    assert_receive {:b, %{type: :chunk, text: "for b"}}, 1_000
    refute_receive {:a, %{type: :chunk}}, 100

    # both prompt; each answer goes back to the chat that asked
    :ok = ACP.prompt(a, "hi from a", %{})
    assert_receive {:frame, %{"method" => "session/prompt", "id" => pa, "params" => %{"sessionId" => "sA"}}}, 1_000
    :ok = ACP.prompt(b, "hi from b", %{})
    assert_receive {:frame, %{"method" => "session/prompt", "id" => pb, "params" => %{"sessionId" => "sB"}}}, 1_000
    refute pa == pb

    inject(hub, %{"id" => pb, "result" => %{"stopReason" => "end_turn"}})
    assert_receive {:b, %{type: :"turn-end"}}, 1_000
    refute_receive {:a, %{type: :"turn-end"}}, 100

    # the agent's request reaches its session's chat, and the answer keeps
    # the agent's own id
    inject(hub, %{
      "id" => 77,
      "method" => "session/request_permission",
      "params" => %{"sessionId" => "sA", "toolCall" => %{"title" => "t"}, "options" => []}
    })

    assert_receive {:a, %{type: :permission, "rpc-id": 77}}, 1_000
    :ok = GenServer.call(a, {:respond_permission, 77, "allow"})
    assert_receive {:frame, %{"id" => 77, "result" => %{"outcome" => %{"optionId" => "allow"}}}}, 1_000

    # a chat that leaves takes its session out of the adapter
    ACP.close(a)
    assert_receive {:frame, %{"method" => "session/close", "params" => %{"sessionId" => "sA"}}}, 1_000
    assert Process.alive?(hub)
    assert Process.alive?(b)
  end

  test "the adapter closes a linger after its last chat leaves", %{cmd: cmd} do
    {hub, a, b} = two_sessions(cmd)
    ref = Process.monitor(hub)
    ACP.close(a)
    ACP.close(b)
    assert_receive {:DOWN, ^ref, :process, ^hub, :normal}, 1_000
  end

  test "a dead shared adapter parks its chats on their sessions", %{cmd: cmd} do
    {hub, _a, _b} = two_sessions(cmd)
    send(hub, {:acp_exit, 137})
    assert_receive {:a, %{type: :"adapter-lost", session: "sA"}}, 1_000
    assert_receive {:b, %{type: :"adapter-lost", session: "sB"}}, 1_000
  end

  test "a chat parked by a dead adapter comes back with session/load", %{cmd: cmd} do
    slug = "zz-hub-#{System.unique_integer([:positive])}"
    {:ok, _} = Agent.start(slug, %{"cmd" => cmd, "cwd" => File.cwd!(), "share" => true})
    Compos.Core.Buffer.set_local("*agent: #{slug}*", "agent-slug", slug)

    on_exit(fn ->
      Agent.kill(slug)
      Compos.Core.kill_buffer("*agent: #{slug}*")
    end)

    assert_receive {:transport_open, hub}, 2_000
    assert_receive {:frame, %{"method" => "initialize", "id" => init}}, 2_000
    inject(hub, %{"id" => init, "result" => caps()})
    assert_receive {:frame, %{"method" => "session/new", "id" => id}}, 2_000
    inject(hub, %{"id" => id, "result" => %{"sessionId" => "sX"}})
    assert eventually(fn -> Agent.info(slug).status == :idle end)

    send(hub, {:acp_exit, 1})
    assert eventually(fn -> Agent.info(slug).parked end)
    assert Agent.info(slug).status == :idle

    assert :queued = Agent.prompt(slug, "after the crash")
    assert_receive {:transport_open, hub2}, 2_000
    refute hub2 == hub
    assert_receive {:frame, %{"method" => "initialize", "id" => init2}}, 2_000
    inject(hub2, %{"id" => init2, "result" => caps()})
    assert_receive {:frame, %{"method" => "session/load", "id" => load, "params" => %{"sessionId" => "sX"}}}, 2_000
    inject(hub2, chunk("sX", "replayed"))
    inject(hub2, %{"id" => load, "result" => %{}})
    assert_receive {:frame, %{"method" => "session/prompt", "params" => %{"sessionId" => "sX"}}}, 3_000
  end

  test "a chat without the share flag keeps its own adapter", %{cmd: cmd} do
    {:ok, pid} = ACP.start(%{"cmd" => cmd, "cwd" => File.cwd!()}, owner(:solo))
    on_exit(fn -> if Process.alive?(pid), do: ACP.close(pid) end)
    assert_receive {:transport_open, ^pid}, 2_000
  end

  defp eventually(fun, left \\ 3_000) do
    cond do
      fun.() -> true
      left <= 0 -> false
      true ->
        Process.sleep(25)
        eventually(fun, left - 25)
    end
  end
end

defmodule Compos.AgentLaunchTest do
  use ExUnit.Case, async: true

  alias Compos.Core.Agent.Launch

  @tag :tmp_dir
  test "a node script runs under the node beside it", %{tmp_dir: dir} do
    script = Path.join(dir, "adapter")
    File.write!(script, "#!/usr/bin/env node\nconsole.log(1)\n")
    File.chmod!(script, 0o755)
    assert Launch.node_script(script) == {:node, []}

    node = Path.join(dir, "node")
    File.write!(node, "")
    File.chmod!(node, 0o755)
    assert {^node, [^script, "--x"]} = Launch.resolve("#{script} --x", dir)
  end

  @tag :tmp_dir
  test "a binary or a shell script runs as itself", %{tmp_dir: dir} do
    sh = Path.join(dir, "tool")
    File.write!(sh, "#!/bin/sh\necho hi\n")
    File.chmod!(sh, 0o755)
    assert Launch.node_script(sh) == :no
    assert {^sh, ["a"]} = Launch.resolve("#{sh} a", dir)
  end

  test "npx of an installed bin runs the bin" do
    assert Launch.unwrap_npx(["npx", "-y", "@scope/sh@1.2.3", "-c", "true"]) == ["sh", "-c", "true"]
    assert Launch.unwrap_npx(["npx", "zz-not-installed-anywhere"]) == ["npx", "zz-not-installed-anywhere"]
    assert Launch.unwrap_npx(["opencode", "acp"]) == ["opencode", "acp"]
  end

  test "version-manager shims are known by their directory" do
    assert Launch.shim_manager("/Users/x/.asdf/shims/claude-agent-acp") == "asdf"
    assert Launch.shim_manager("/Users/x/.local/share/mise/shims/node") == "mise"
    assert Launch.shim_manager("/usr/local/bin/node") == nil
  end
end
