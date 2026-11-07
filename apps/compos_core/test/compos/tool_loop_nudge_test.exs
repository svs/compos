defmodule Compos.ToolLoopNudgeTest do
  @moduledoc """
  A model can run its tools and end the turn with no text. The loop then
  asks once, in the same turn, with the words the context gives it.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.LLM

  @nudge "You ended your turn without a reply."

  setup do
    on_exit(fn -> Application.delete_env(:compos_core, :llm_chat_fun) end)
    :ok
  end

  defp tool_use,
    do: %{
      "stop_reason" => "tool_use",
      "content" => [%{"type" => "tool_use", "id" => "t1", "name" => "noop", "input" => %{}}],
      "usage" => %{}
    }

  defp reply(text),
    do: %{
      "stop_reason" => "end_turn",
      "content" => if(text == "", do: [], else: [%{"type" => "text", "text" => text}]),
      "usage" => %{}
    }

  defp run(script, opts) do
    me = self()
    {:ok, agent} = Agent.start_link(fn -> script end)

    Application.put_env(:compos_core, :llm_chat_fun, fn req ->
      send(me, {:asked, req.messages})
      Agent.get_and_update(agent, fn [next | rest] -> {{:ok, next}, rest} end)
    end)

    dispatcher = fn _name, _input -> "done" end

    LLM.run_tool_loop([%{role: "user", content: "go"}], "", [], dispatcher,
      [gate: fn _n, _i -> {:ok, "ok"} end] ++ opts)
  end

  defp asked do
    receive do
      {:asked, msgs} -> [msgs | asked()]
    after
      0 -> []
    end
  end

  test "after a tool round, a blank reply is asked for once" do
    assert {:ok, "I ran noop.", _, _} =
             run([tool_use(), reply(""), reply("I ran noop.")], empty_reply_nudge: @nudge)

    calls = asked()
    assert length(calls) == 3
    assert inspect(List.last(calls)) =~ @nudge
  end

  test "a second blank reply ends the turn; the nudge is not repeated" do
    assert {:ok, "", _, _} =
             run([tool_use(), reply(""), reply("")], empty_reply_nudge: @nudge)

    assert length(asked()) == 3
  end

  test "no tool round, no nudge; no nudge text, no nudge" do
    assert {:ok, "", _, _} = run([reply("")], empty_reply_nudge: @nudge)
    assert length(asked()) == 1
    assert {:ok, "", _, _} = run([tool_use(), reply("")], [])
    assert length(asked()) == 2
  end
end
