defmodule Compos.AgentIdleParkTest do
  @moduledoc """
  An idle thread closes its adapter and keeps its session; the next prompt
  opens a new adapter on the same session (ACP session/load). Driven at
  the Agent level through the FakeTransport: no adapter binary.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.Agent

  setup do
    Compos.Test.FakeTransport.own!()
    Application.put_env(:compos_core, :acp_transport, Compos.Test.FakeTransport)
    # the idle clock, in ms; Scheme passes "idle-seconds" in a real chat
    Application.put_env(:compos_core, :agent_idle_ms, 150)

    on_exit(fn ->
      Application.delete_env(:compos_core, :acp_transport)
      Application.delete_env(:compos_core, :agent_idle_ms)
    end)

    :ok
  end

  defp start(slug, extra \\ %{}) do
    {:ok, _pid} = Agent.start(slug, Map.merge(%{"cmd" => "fake", "cwd" => File.cwd!()}, extra))
    # the chat's context handler finds the thread's buffer by this local
    Compos.Core.Buffer.set_local("*agent: #{slug}*", "agent-slug", slug)

    on_exit(fn ->
      Agent.kill(slug)
      Compos.Core.kill_buffer("*agent: #{slug}*")
    end)

    slug
  end

  defp inject(backend, frame), do: send(backend, {:acp_data, Jason.encode!(frame) <> "\n"})

  # the handshake up to the session: initialize answered with the given
  # capabilities, then whatever the adapter sends next is returned
  defp handshake(caps) do
    assert_receive {:transport_open, backend}, 2_000
    assert_receive {:frame, %{"method" => "initialize", "id" => init_id}}, 2_000
    inject(backend, %{"id" => init_id, "result" => %{"agentCapabilities" => caps}})
    assert_receive {:frame, %{"method" => method, "id" => id, "params" => params}}, 2_000
    {backend, method, id, params}
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

  test "an idle thread parks its adapter and reopens the same session on the next prompt" do
    slug = start("zz-park-#{System.unique_integer([:positive])}")

    {backend1, "session/new", id, _} = handshake(%{"loadSession" => true})
    inject(backend1, %{"id" => id, "result" => %{"sessionId" => "sess-1"}})

    assert eventually(fn -> Agent.info(slug).status == :idle end)
    assert Agent.info(slug).session == "sess-1"

    # the idle clock runs out: adapter closed, thread still idle
    assert eventually(fn -> Agent.info(slug).parked end)
    refute Process.alive?(backend1)
    assert Agent.info(slug).status == :idle

    # the next prompt opens a new adapter on the old session
    assert :queued = Agent.prompt(slug, "hello again")
    {backend2, "session/load", load_id, params} = handshake(%{"loadSession" => true})
    assert params["sessionId"] == "sess-1"
    assert backend2 != backend1

    # history replayed by the load reaches nobody: the transcript has it
    inject(backend2, %{
      "method" => "session/update",
      "params" => %{
        "sessionId" => "sess-1",
        "update" => %{"sessionUpdate" => "agent_message_chunk", "content" => %{"text" => "old"}}
      }
    })

    inject(backend2, %{"id" => load_id, "result" => %{}})

    assert_receive {:frame, %{"method" => "session/prompt", "params" => %{"sessionId" => "sess-1"}}},
                   3_000

    refute Agent.info(slug).parked
    assert Agent.info(slug).status == :running
  end

  test "an agent that cannot load a session starts a fresh one" do
    slug = start("zz-park-fresh-#{System.unique_integer([:positive])}", %{"resume-session" => "gone"})

    {backend, "session/new", id, params} = handshake(%{"loadSession" => false})
    refute Map.has_key?(params, "sessionId")
    inject(backend, %{"id" => id, "result" => %{"sessionId" => "sess-2"}})

    assert eventually(fn -> Agent.info(slug).session == "sess-2" end)
  end

  test "a failed load falls back to a new session" do
    slug = start("zz-park-fail-#{System.unique_integer([:positive])}", %{"resume-session" => "stale"})

    {backend, "session/load", id, %{"sessionId" => "stale"}} = handshake(%{"loadSession" => true})
    inject(backend, %{"id" => id, "error" => %{"code" => -32000, "message" => "unknown session"}})

    assert_receive {:frame, %{"method" => "session/new", "id" => new_id}}, 2_000
    inject(backend, %{"id" => new_id, "result" => %{"sessionId" => "sess-3"}})
    assert eventually(fn -> Agent.info(slug).session == "sess-3" end)
  end

  test "a running turn is never parked" do
    slug = start("zz-park-busy-#{System.unique_integer([:positive])}")

    {backend, "session/new", id, _} = handshake(%{"loadSession" => true})
    inject(backend, %{"id" => id, "result" => %{"sessionId" => "sess-4"}})
    assert eventually(fn -> Agent.info(slug).status == :idle end)

    assert :sent = Agent.prompt(slug, "work")
    assert_receive {:frame, %{"method" => "session/prompt"}}, 3_000

    Process.sleep(400)
    refute Agent.info(slug).parked
    assert Process.alive?(backend)
    assert Agent.info(slug).status == :running
  end
end
