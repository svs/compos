defmodule Aimax.EndpointRedisTest do
  @moduledoc """
  The tcp transport carrying a real service.

  The exec transport has psql to prove it. This is the same proof for tcp:
  a Redis client written in Scheme, in the test, over one endpoint. It uses
  `delimiter "\\r\\n"` framing because RESP terminates every line that way,
  and the same sentinel pattern as the psql connector — Redis pipelines, so
  a trailing ECHO marks the end of a reply.

  Skipped when redis-server is absent.
  """

  use ExUnit.Case

  alias Aimax.Core.{Endpoint, Session}

  @port 6399
  @sentinel "__aimax_end__"

  setup_all do
    exe = System.find_executable("redis-server")
    cli = System.find_executable("redis-cli")

    if exe && cli do
      {_, 0} =
        System.cmd(exe, [
          "--port", "#{@port}", "--save", "", "--appendonly", "no",
          "--daemonize", "yes", "--bind", "127.0.0.1"
        ], stderr_to_stdout: true)

      Process.sleep(500)
      on_exit(fn -> System.cmd(cli, ["-p", "#{@port}", "shutdown", "nosave"], stderr_to_stdout: true) end)
      {:ok, redis: true}
    else
      :ok
    end
  end

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp wait_until(fun, tries \\ 400) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true ->
        Process.sleep(10)
        wait_until(fun, tries - 1)
    end
  end

  test "a Scheme client drives Redis over one tcp endpoint", ctx do
    if ctx[:redis] == nil do
      IO.puts("skipped: no redis-server")
    else
      # the whole client: register, connect once, ask with a sentinel.
      # RESP replies are lines, so Scheme reads them as frames.
      eval!("""
      (endpoint-register! "redis-test"
        (list 'host "127.0.0.1" 'port #{@port} 'framing "delimiter" 'delimiter "\\r\\n"))

      (define (redis name cmd k)
        (endpoint-ask name
          (string-append cmd "\\r\\nECHO #{@sentinel}")
          "#{@sentinel}"
          (lambda (ok frames)
            ;; drop RESP length prefixes ($3, *2) and the trailing marker line
            (k ok (if ok (filter (lambda (l) (not (string-prefix? "$" l))) frames) frames)))))
      """)

      eval!(~s|(endpoint-ensure! "redis-test")|)
      wait_until(fn -> eval!(~s|(endpoint-connected? "redis-test")|) == "#t" end)
      on_exit(fn -> Endpoint.stop("redis-test") end)

      eval!("(define r1 'pending)")
      eval!("(define r2 'pending)")
      eval!("(define r3 'pending)")

      eval!(~s|(redis "redis-test" "SET greeting hello" (lambda (ok v) (set! r1 (list ok v))))|)
      eval!(~s|(redis "redis-test" "GET greeting" (lambda (ok v) (set! r2 (list ok v))))|)
      eval!(~s|(redis "redis-test" "INCR counter\\r\\nINCR counter" (lambda (ok v) (set! r3 (list ok v))))|)

      wait_until(fn -> eval!("r3") != "pending" end)

      assert eval!("r1") == ~s|(#t ("+OK"))|
      assert eval!("r2") == ~s|(#t ("hello"))|
      # two commands pipelined on the one live connection
      assert eval!("r3") == ~s|(#t (":1" ":2"))|

      # one connection served all three: that is the point of an endpoint
      assert eval!(~s|(endpoint-detail "redis-test")|) =~ ~s|status "ready"|
      assert eval!(~s|(endpoint-detail "redis-test")|) =~ ~s|transport "tcp"|
    end
  end

  test "a dropped server fails the asks and the endpoint reports it", ctx do
    if ctx[:redis] == nil do
      IO.puts("skipped: no redis-server")
    else
      eval!("""
      (endpoint-start! "redis-drop"
        (list 'host "127.0.0.1" 'port #{@port} 'framing "delimiter" 'delimiter "\\r\\n"))
      """)

      wait_until(fn -> Endpoint.whereis("redis-drop") != nil end)
      on_exit(fn -> Endpoint.stop("redis-drop") end)

      eval!("(define q 'pending)")

      # QUIT closes the connection server-side; the ask must fail, not hang
      eval!("""
      (endpoint-ask "redis-drop" "QUIT" "#{@sentinel}" 3000
        (lambda (ok v) (set! q (list ok v))))
      """)

      wait_until(fn -> eval!("q") != "pending" end)
      assert eval!("q") =~ "#f"
    end
  end
end
