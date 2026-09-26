defmodule Compos.SteerSettleTest do
  @moduledoc """
  A steer moves an ACP turn's close off the model result and onto an idle
  signal inside the adapter. The adapter can lose that signal, and then it
  never answers session/prompt: the turn produces its result, goes quiet,
  and the chat says "streaming" at an agent that stopped.

  The Agent recovers. It watches the cycle result the adapter settles on,
  waits the grace the chat gives it, and ends the turn itself.
  """

  use Compos.Case

  alias Compos.Core.{Agent, Buffer}
  alias Compos.Core.Agent.Backend

  defp eventually(fun, tries \\ 80) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(50)
        eventually(fun, tries - 1)
    end
  end

  # a turn that streams, reports its cycle result, and then never ends
  defp wedged_chat(script) do
    slug =
      String.trim(
        eval!(~s[(execute* "go" '(permission-mode auto backend "stub" script (#{script})))]),
        "\""
      )

    # the chat names its own buffer; the runtime reports which one
    {slug, Agent.info(slug).buffer}
  end

  setup do
    eval!("(set-symbol-value! 'chat-steer-settle-seconds 1)")

    on_exit(fn ->
      eval!("(set-symbol-value! 'chat-steer-settle-seconds 180)")
      Enum.each(Agent.list(), &Agent.kill/1)

      Enum.each(Compos.Core.list_buffers(), fn name ->
        if String.starts_with?(name, "*chat:") or Buffer.get_local(name, "agent-slug"),
          do: Compos.Core.kill_buffer(name)
      end)
    end)

    :ok
  end

  test "a steered turn the agent never ends is ended by the grace" do
    {slug, buf} =
      wedged_chat("""
      ((type chunk text "the answer")
       (type steering-accepted)
       (type cycle-result)
       (type hang))
      """)

    # the turn is running and the grace is counting: the result landed and
    # the close did not
    assert eventually(fn -> match?(%{status: :running, settling: true}, Agent.info(slug)) end)

    # the grace expires and the turn ends, with the transcript saying why
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)
    assert Agent.info(slug).settling == false

    # the reply and the one line that says why the turn closed
    assert eventually(fn -> Buffer.text(buf) =~ "did not end this steered turn" end)
    assert Buffer.text(buf) =~ "the answer"

    # the chat takes the next message: nothing is queued behind the turn
    assert Agent.info(slug).queued == 0
  end

  test "a turn nobody steered keeps its own deadline" do
    {slug, _buf} =
      wedged_chat("""
      ((type chunk text "still working")
       (type cycle-result)
       (type hang))
      """)

    # no steer, so the adapter answers session/prompt at its result the
    # ordinary way. The Agent arms nothing and waits, however long the turn
    # takes.
    assert eventually(fn -> match?(%{status: :running}, Agent.info(slug)) end)
    Process.sleep(1_500)
    assert match?(%{status: :running, settling: false}, Agent.info(slug))
  end

  test "output after the result disarms the grace" do
    {slug, _buf} =
      wedged_chat("""
      ((type steering-accepted)
       (type cycle-result)
       (type chunk text "more to say")
       (type hang))
      """)

    # the cycle result armed the grace and the chunk behind it disarmed:
    # the turn still produces, so it has not ended
    assert eventually(fn -> match?(%{status: :running}, Agent.info(slug)) end)
    Process.sleep(1_500)
    assert match?(%{status: :running, settling: false}, Agent.info(slug))
  end

  test "the chat turns the recovery off" do
    eval!("(set-symbol-value! 'chat-steer-settle-seconds 0)")

    {slug, _buf} =
      wedged_chat("""
      ((type steering-accepted)
       (type cycle-result)
       (type hang))
      """)

    assert eventually(fn -> match?(%{status: :running}, Agent.info(slug)) end)
    Process.sleep(1_500)
    assert match?(%{status: :running, settling: false}, Agent.info(slug))
  end

  test "the turn-end the agent sends late is swallowed" do
    {slug, buf} =
      wedged_chat("""
      ((type steering-accepted)
       (type cycle-result)
       (type hang))
      """)

    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)
    before = Buffer.text(buf)

    # the adapter wakes up and answers the prompt it held. The turn is over
    # already, so the late close changes nothing.
    [{pid, _}] = Registry.lookup(Compos.Core.AgentRegistry, slug)
    send(pid, {:backend_event, Backend.plist(type: :"turn-end", "stop-reason": "end_turn")})
    Process.sleep(200)

    assert match?(%{status: :idle}, Agent.info(slug))
    assert Buffer.text(buf) == before
  end

end
