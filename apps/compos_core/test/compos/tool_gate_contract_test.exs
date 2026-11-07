defmodule Compos.ToolGateContractTest do
  @moduledoc """
  The direct lane's tool gate is a security boundary: what it refused, it
  must keep refusing. Each test runs one whole turn whose model asks for one
  tool, and reads the tool result the model got back.

  Every refusal the Elixir gate made has a test here: a policy that
  rejects, a policy that crashes, a user who denies an ask, a bad ask
  tool; and one the Scheme gate adds: a gate with no verdict. Not covered:
  the thread going away while an ask waits, which kills the turn that
  would read the answer. The rules: scheme/packages/llm-gate-test.scm.
  """

  use Compos.Case

  alias Compos.Core.{Agent, Buffer, Session}

  @restore_policy """
  (agent-permission-fn!
    (lambda (slug name kind raw)
      (let* ((buf (agent-buf slug)) (v (permit? buf name kind raw)))
        (cond ((equal? v 'reject) 'reject) ((equal? v 'ask) 'ask) (else 'allow)))))
  """

  setup do
    Compos.TestHelpers.one_window!()
    eval!("(define zz-gate-ran 'no)")

    on_exit(fn ->
      Application.delete_env(:compos_core, :llm_chat_fun)
      Session.eval(@restore_policy)
      Enum.each(Agent.list(), &Agent.kill/1)

      Enum.each(Compos.Core.list_buffers(), fn name ->
        if String.starts_with?(name, "*chat:") or Buffer.get_local(name, "agent-slug"),
          do: Compos.Core.kill_buffer(name)
      end)

      Compos.TestHelpers.one_window!()
    end)

    :ok
  end

  # one turn: the model calls NAME with INPUT, then reports what it got
  defp tool_turn(name, input) do
    start_turn(name, input)
    tool_result()
  end

  defp tool_result do
    assert_receive {:result, [%{content: result, is_error: error?} | _]}, 5_000
    {result, error?}
  end

  defp start_turn(name, input) do
    me = self()

    Application.put_env(:compos_core, :llm_chat_fun, fn req ->
      if Enum.any?(req.messages, &is_list(&1.content)) do
        send(me, {:result, req.messages |> List.last() |> Map.get(:content)})

        {:ok,
         %{
           "stop_reason" => "end_turn",
           "content" => [%{"type" => "text", "text" => "done"}],
           "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
         }}
      else
        {:ok,
         %{
           "stop_reason" => "tool_use",
           "content" => [%{"type" => "tool_use", "id" => "t1", "name" => name, "input" => input}],
           "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
         }}
      end
    end)

    {:ok, _} = Session.eval(~s{(execute* "run the tool" '(connector "api"))})
  end

  test "a policy that crashes denies the call, and the tool does not run" do
    eval!("(agent-permission-fn! (lambda (slug name kind raw) (car '())))")

    assert {"permission denied: the permission policy crashed; fix permit? and retry", true} =
             tool_turn("eval-scheme", @mark)

    assert eval!("zz-gate-ran") == "no"
  end

  test "a call the user denies does not run" do
    eval!("(agent-permission-fn! (lambda (slug name kind raw) 'ask))")
    start_turn("eval-scheme", @mark)

    {slug, id} = pending_permission()
    assert :ok = Agent.respond_permission(slug, id, "deny")

    assert {"permission denied: denied", true} = tool_result()
    assert eval!("zz-gate-ran") == "no"
  end

  test "a call the user allows runs" do
    eval!("(agent-permission-fn! (lambda (slug name kind raw) 'ask))")
    start_turn("eval-scheme", @mark)

    {slug, id} = pending_permission()
    assert :ok = Agent.respond_permission(slug, id, "allow")

    # the gate let it through to the tool: no denial reached the model
    assert {result, false} = tool_result()
    refute result =~ "permission denied"
  end

  defp pending_permission(tries \\ 100) do
    found =
      Enum.find_value(Agent.list(), fn slug ->
        case Agent.info(slug) do
          %{permission: %{rpc_id: id}} -> {slug, id}
          _ -> nil
        end
      end)

    cond do
      found -> found
      tries == 0 -> flunk("no permission request was raised")
      true -> Process.sleep(50) && pending_permission(tries - 1)
    end
  end

  @mark %{"code" => "(begin (set! zz-gate-ran 'ran) 'ran)"}

  test "a policy that rejects denies the call, and the tool does not run" do
    eval!("(agent-permission-fn! (lambda (slug name kind raw) 'reject))")

    assert {"permission denied: denied by policy", true} = tool_turn("eval-scheme", @mark)
    assert eval!("zz-gate-ran") == "no"
  end

  test "only the symbols stop a call: a policy answering text allows it" do
    eval!(~s{(agent-permission-fn! (lambda (slug name kind raw) "reject"))})

    assert {_, false} = tool_turn("eval-scheme", @mark)
    assert eval!("zz-gate-ran") == "ran"
  end

  test "the policy sees the tool name, the kind and the raw call text" do
    eval!("""
    (agent-permission-fn!
      (lambda (slug name kind raw) (set! zz-gate-ran (list name kind raw)) 'reject))
    """)

    assert {"permission denied: denied by policy", true} =
             tool_turn("eval-scheme", %{"code" => "(+ 1 1)"})

    assert eval!("zz-gate-ran") ==
             ~S|("eval-scheme" "tool" "eval-scheme %{\"code\" => \"(+ 1 1)\"}")|
  end

  test "the ask tool is not put to the policy, and a bad ask is an error" do
    # a policy that crashes would deny any call it saw
    eval!("(agent-permission-fn! (lambda (slug name kind raw) (car '())))")

    assert {"error: ask requires a question and an answers array", true} =
             tool_turn("ask", %{"answers" => ["a"]})
  end

  test "a gate that gives no verdict denies the call" do
    eval!("(define zz-saved-gate llm-tool-gate)")
    on_exit(fn -> Session.eval("(set! llm-tool-gate zz-saved-gate)") end)
    eval!("(set! llm-tool-gate (lambda (policy slug name raw input) 'maybe))")

    assert {"permission denied: " <> _, true} = tool_turn("eval-scheme", @mark)
    assert eval!("zz-gate-ran") == "no"
  end
end
