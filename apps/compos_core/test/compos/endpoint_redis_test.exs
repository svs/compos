defmodule Compos.EndpointRedisTest do
  @moduledoc """
  The tcp transport carrying a real service.

  The exec transport has psql to prove it. This is the same proof for tcp.
  The Redis client over endpoint-register! and endpoint-ask is the endpoint
  package's, and that package's suite tests it. It uses
  `delimiter "\\r\\n"` framing because RESP terminates every line that way,
  and the same sentinel pattern as the psql connector — Redis pipelines, so
  a trailing ECHO marks the end of a reply.

  Skipped when redis-server is absent.
  """

  use Compos.Case

  alias Compos.Core.{Endpoint}

  @port 6399
  @sentinel "__compos_end__"

  setup_all do
    exe = System.find_executable("redis-server")
    cli = System.find_executable("redis-cli")

    if exe && cli do
      {_, 0} =
        System.cmd(
          exe,
          [
            "--port",
            "#{@port}",
            "--save",
            "",
            "--appendonly",
            "no",
            "--daemonize",
            "yes",
            "--bind",
            "127.0.0.1"
          ], stderr_to_stdout: true)

      Process.sleep(500)

      on_exit(fn ->
        System.cmd(cli, ["-p", "#{@port}", "shutdown", "nosave"], stderr_to_stdout: true)
      end)

      {:ok, redis: true}
    else
      :ok
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
