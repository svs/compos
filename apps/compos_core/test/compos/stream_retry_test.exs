defmodule Compos.StreamRetryTest do
  @moduledoc """
  A model stream that fails after it opened is asked again once, with the
  same messages. A second failure ends the turn with an error that names
  the round; it never ends as an empty reply.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.LLM

  setup do
    on_exit(fn -> Application.delete_env(:compos_core, :llm_chat_fun) end)
    :ok
  end

  defp reply(text),
    do: %{
      "stop_reason" => "end_turn",
      "content" => [%{"type" => "text", "text" => text}],
      "usage" => %{}
    }

  defp dropped, do: {:error, {:dropped, "status 529: overloaded", nil}}

  defp run(script) do
    me = self()
    {:ok, agent} = Agent.start_link(fn -> script end)

    Application.put_env(:compos_core, :llm_chat_fun, fn req ->
      send(me, {:asked, req.messages})
      Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end)
    end)

    LLM.run_tool_loop([%{role: "user", content: "go"}], "", [], fn _, _ -> "done" end,
      gate: fn _n, _i -> {:ok, "ok"} end,
      on_chunk: fn t -> send(me, {:chunk, t}) end
    )
  end

  defp asked do
    receive do
      {:asked, msgs} -> [msgs | asked()]
    after
      0 -> []
    end
  end

  test "a dropped stream is asked again once with the same messages" do
    assert {:ok, "hi", _, "end_turn"} = run([dropped(), {:ok, reply("hi")}])
    assert [first, second] = asked()
    assert first == second
    assert_received {:chunk, note}
    assert note =~ "529"
  end

  test "a second failure ends the turn with an error that names the round" do
    assert {:error, msg} = run([dropped(), dropped()])
    assert msg =~ "round 1"
    assert msg =~ "529"
    assert length(asked()) == 2
  end

  test "a final error is not asked again" do
    assert {:error, "no key"} = run([{:error, "no key"}])
    assert length(asked()) == 1
  end
end
