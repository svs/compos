defmodule Aimax.AsyncShellTest do
  @moduledoc """
  The async shell lane. A slow command must not hold the Session: the
  callback form of shell-command->string runs in a Task, and the MCP
  proxy's one-shell-form payload rides the deferred-reply lane
  (eval-defer! / eval-resolve!). The inline form stops at a hard limit.
  """

  use ExUnit.Case

  alias Aimax.Core.{KeyDispatch, Session}

  defp eval!(code) do
    {:ok, printed} = Session.eval(code)
    printed
  end

  defp ms(fun) do
    t0 = System.monotonic_time(:millisecond)
    value = fun.()
    {System.monotonic_time(:millisecond) - t0, value}
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      case fun.() do
        false ->
          if System.monotonic_time(:millisecond) > deadline do
            flunk("condition not met within #{timeout_ms}ms")
          end

          Process.sleep(50)
          false

        value ->
          value
      end
    end)
    |> Enum.find(& &1)
  end

  test "the callback form leaves the Session free, driven through a key" do
    eval!(~s{(define *async-shell-out* #f)})

    eval!(~s{(define-command "test-async-shell"
               (lambda ()
                 (shell-command->string "sleep 2; echo done" "/tmp"
                   (lambda (out) (set! *async-shell-out* out)))))})

    eval!(~s{(global-set-key "C-c C-9" "test-async-shell")})

    {pressed, _} =
      ms(fn -> Enum.each(["C-c", "C-9"], &KeyDispatch.handle_key/1) end)

    # the key returns at once; the command runs in a Task
    assert pressed < 1_000
    assert eval!("*async-shell-out*") == "#f"

    # a second eval answers while the command still runs
    {elapsed, "3"} = ms(fn -> eval!("(+ 1 2)") end)
    assert elapsed < 1_000

    # the callback delivers the output through the Session
    wait_until(fn -> eval!("*async-shell-out*") != "#f" end, 10_000)
    assert eval!("*async-shell-out*") =~ "done"
  end

  test "a one-shell-form proxy payload rides the deferred lane" do
    code = ~s{(shell-command->string "sleep 2; echo hi" "/tmp")}
    args = Base.encode64(Jason.encode!(%{"code" => code}))

    task =
      Task.async(fn ->
        ms(fn -> Session.eval(~s{(mcp-proxy-call "eval-scheme" "#{args}")}) end)
      end)

    Process.sleep(300)

    # the Session answers other callers while the command runs
    {elapsed, "3"} = ms(fn -> eval!("(+ 1 2)") end)
    assert elapsed < 1_000

    # the caller still gets the full output, printed and base64-coded
    {total, {:ok, printed}} = Task.await(task, 15_000)
    assert total >= 1_900
    assert printed |> String.trim("\"") |> Base.decode64!() =~ "hi"
  end

  test "a multi-form payload stays on the inline path" do
    code = ~s{(begin (define *proxy-inline-probe* 41) (+ *proxy-inline-probe* 1))}
    args = Base.encode64(Jason.encode!(%{"code" => code}))

    out =
      eval!(~s{(mcp-proxy-call "eval-scheme" "#{args}")})
      |> String.trim("\"")
      |> Base.decode64!()

    assert out =~ "42"
  end

  test "the inline form kills the command at the limit and returns its output" do
    Application.put_env(:aimax_core, :shell_timeout_ms, 500)
    on_exit(fn -> Application.delete_env(:aimax_core, :shell_timeout_ms) end)

    {elapsed, printed} =
      ms(fn -> eval!(~s{(shell-command->string "echo start; sleep 30; echo end")}) end)

    assert elapsed < 5_000
    assert printed =~ "start"
    refute printed =~ "end"
  end
end
