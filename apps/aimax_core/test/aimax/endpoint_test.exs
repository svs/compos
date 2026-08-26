defmodule Aimax.EndpointTest do
  @moduledoc """
  The endpoint mechanism: a named long-lived connection that carries frames
  and holds no protocol.

  These tests drive it the way a Scheme package does — through the
  `endpoint-*` primitives — because that is the only surface a package has.
  The framing functions are tested directly, since a package never sees them.
  """

  use ExUnit.Case

  alias Aimax.Core.{Endpoint, Session}
  alias Aimax.Core.Endpoint.Conn

  @fixture Path.expand("../support/fake_endpoint.exs", __DIR__)

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp wait_until(fun, tries \\ 300) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true ->
        Process.sleep(10)
        wait_until(fun, tries - 1)
    end
  end

  defp start_fake(name) do
    elixir = System.find_executable("elixir")

    eval!("""
    (endpoint-start! "#{name}"
      '(command "#{elixir}" args ("#{@fixture}") framing "line"))
    """)

    wait_until(fn -> Endpoint.whereis(name) != nil end)
    on_exit(fn -> Endpoint.stop(name) end)
  end

  # collect an ask's result into a Scheme global the test can read back
  defp ask!(name, text, until, var) do
    eval!("(define #{var} 'pending)")

    eval!("""
    (endpoint-ask "#{name}" "#{text}" #{until}
      (lambda (ok val) (set! #{var} (list ok val))))
    """)

    wait_until(fn -> eval!("#{var}") != "pending" end)
    eval!("#{var}")
  end

  describe "exec transport" do
    test "an ask collects frames up to the sentinel" do
      start_fake("t-echo")
      assert ask!("t-echo", "echo hello", ~s|"END"|, "r") == ~s|(#t ("hello"))|
    end

    test "a multi-frame answer arrives whole and in order" do
      start_fake("t-rows")
      assert ask!("t-rows", "rows 3", ~s|"END"|, "r") == ~s|(#t ("row-1" "row-2" "row-3"))|
    end

    test "a nil sentinel takes exactly the next frame" do
      start_fake("t-one")
      assert ask!("t-one", "echo solo", "#f", "r") == ~s|(#t ("solo"))|
    end

    test "asks stay serial: two answers never interleave" do
      start_fake("t-serial")
      eval!("(define a 'pending)")
      eval!("(define b 'pending)")

      eval!("""
      (begin
        (endpoint-ask "t-serial" "rows 2" "END" (lambda (ok v) (set! a (list ok v))))
        (endpoint-ask "t-serial" "echo second" "END" (lambda (ok v) (set! b (list ok v)))))
      """)

      wait_until(fn -> eval!("b") != "pending" end)
      assert eval!("a") == ~s|(#t ("row-1" "row-2"))|
      assert eval!("b") == ~s|(#t ("second"))|
    end
  end

  describe "failure" do
    test "an ask that never sees its sentinel times out and frees the queue" do
      start_fake("t-slow")
      eval!("(define a 'pending)")
      eval!("(define b 'pending)")

      eval!("""
      (begin
        (endpoint-ask "t-slow" "quiet" "END" 300 (lambda (ok v) (set! a (list ok v))))
        (endpoint-ask "t-slow" "echo after" "END" (lambda (ok v) (set! b (list ok v)))))
      """)

      wait_until(fn -> eval!("b") != "pending" end)
      assert eval!("a") =~ "timed out"
      # the queue moved on rather than wedging behind the dead ask
      assert eval!("b") == ~s|(#t ("after"))|
    end

    test "a died process fails every ask in flight" do
      start_fake("t-die")
      eval!("(define a 'pending)")

      eval!("""
      (begin
        (endpoint-send! "t-die" "bye")
        (endpoint-ask "t-die" "echo never" "END" (lambda (ok v) (set! a (list ok v)))))
      """)

      wait_until(fn -> eval!("a") != "pending" end)
      assert eval!("a") =~ "#f"
    end

    test "a command that does not exist reports rather than starts" do
      eval!(~s|(endpoint-start! "t-missing" '(command "no-such-binary-xyz"))|)
      wait_until(fn -> Endpoint.whereis("t-missing") == nil end)
      assert Endpoint.last("t-missing").status == :error
    end

    test "a tcp port that is not a port number reports rather than crashes" do
      eval!(~s|(endpoint-start! "t-badport" '(host "127.0.0.1" port "not-a-port"))|)
      wait_until(fn -> Endpoint.whereis("t-badport") == nil end)
      assert Endpoint.last("t-badport").status == :error
      assert Enum.any?(Endpoint.last("t-badport").log, &(&1.text =~ "tcp port must be"))
    end

    test "a refused tcp connection reports the reason" do
      # port 1 on loopback has no listener
      eval!(~s|(endpoint-start! "t-refused" '(host "127.0.0.1" port 1))|)
      wait_until(fn -> Endpoint.whereis("t-refused") == nil end)
      assert Endpoint.last("t-refused").status == :error
      assert Enum.any?(Endpoint.last("t-refused").log, &(&1.text =~ "tcp connect"))
    end

    test "a bad name is refused" do
      assert {:error, msg} = Endpoint.start("Bad Name!", %{"command" => "cat"})
      assert msg =~ "endpoint names are"
    end
  end

  describe "unsolicited frames" do
    test "a frame nobody asked for reaches the Scheme handler" do
      start_fake("t-notice")
      eval!("(define seen '())")

      eval!("""
      (endpoint-on-event!
        (lambda (name kind text) (set! seen (cons (list name kind text) seen))))
      """)

      eval!(~s|(endpoint-send! "t-notice" "notice ping")|)
      wait_until(fn -> eval!("seen") =~ "ping" end)
      assert eval!("seen") =~ ~s|("t-notice" "frame" "ping")|
    end
  end

  describe "introspection" do
    test "list, detail, and log describe a live endpoint" do
      start_fake("t-info")
      ask!("t-info", "echo x", ~s|"END"|, "r")

      assert eval!(~s|(endpoint-detail "t-info")|) =~ ~s|status "ready"|
      assert eval!(~s|(endpoint-detail "t-info")|) =~ ~s|transport "exec"|
      assert eval!(~s|(endpoint-detail "t-info")|) =~ ~s|framing "line"|

      list = eval!("(endpoint-list)")
      assert list =~ "t-info"

      # the log holds both directions of the exchange that just happened
      log = eval!(~s|(endpoint-log "t-info")|)
      assert log =~ "echo x"
      assert log =~ "out"
      assert log =~ "in"
    end
  end

  describe "diagnostics" do
    test "the log names the command that ran, so a wrong binary is visible" do
      start_fake("t-cmd")
      assert eval!(~s|(endpoint-log "t-cmd")|) =~ "fake_endpoint.exs"
    end

    test "stderr merges onto the frame stream when the spec asks for it" do
      sh = System.find_executable("sh")

      eval!("""
      (endpoint-start! "t-err"
        (list 'command "#{sh}" 'args (list "-c" "echo oops >&2; sleep 5")
              'framing "line" 'stderr "merge"))
      """)

      wait_until(fn -> Endpoint.whereis("t-err") != nil end)
      on_exit(fn -> Endpoint.stop("t-err") end)
      wait_until(fn -> eval!(~s|(endpoint-log "t-err")|) =~ "oops" end)
    end

    test "without the merge, stderr stays off the frame stream" do
      sh = System.find_executable("sh")

      eval!("""
      (endpoint-start! "t-quiet-err"
        (list 'command "#{sh}" 'args (list "-c" "echo oops >&2; sleep 5") 'framing "line"))
      """)

      wait_until(fn -> Endpoint.whereis("t-quiet-err") != nil end)
      on_exit(fn -> Endpoint.stop("t-quiet-err") end)
      Process.sleep(300)

      # the command-line note quotes the script, so ask the log for
      # inbound rows only: with no merge, nothing arrives as a frame
      inbound =
        Aimax.Core.Endpoint.log("t-quiet-err") |> Enum.filter(&(&1.dir == :in))

      assert inbound == []
    end
  end

  describe "tcp transport" do
    test "an endpoint connects to a listener and exchanges frames" do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])
      {:ok, port_no} = :inet.port(listener)

      # a one-shot echo server: read a line, answer it, then the sentinel
      spawn_link(fn ->
        {:ok, sock} = :gen_tcp.accept(listener)
        {:ok, line} = :gen_tcp.recv(sock, 0, 5_000)
        :gen_tcp.send(sock, "got:#{String.trim(line)}\nEND\n")
        Process.sleep(1_000)
      end)

      eval!(~s|(endpoint-start! "t-tcp" '(host "127.0.0.1" port #{port_no} framing "line"))|)
      wait_until(fn -> Endpoint.whereis("t-tcp") != nil end)
      on_exit(fn -> Endpoint.stop("t-tcp") end)

      assert ask!("t-tcp", "hello", ~s|"END"|, "r") == ~s|(#t ("got:hello"))|
      assert eval!(~s|(endpoint-detail "t-tcp")|) =~ ~s|transport "tcp"|
    end
  end

  describe "framing" do
    test "line framing keeps a partial frame for the next chunk" do
      assert Conn.unframe({:delimiter, "\n"}, "a\nb\nc") == {["a", "b"], "c"}
    end

    test "a custom delimiter frames on that string" do
      assert Conn.unframe({:delimiter, ";;"}, "one;;two;;thr") == {["one", "two"], "thr"}
    end

    test "content-length reads the LSP base protocol, including two in one chunk" do
      buf = "Content-Length: 2\r\n\r\nhiContent-Length: 3\r\n\r\nbye"
      assert Conn.unframe(:content_length, buf) == {["hi", "bye"], ""}
    end

    test "content-length holds a body that has not fully arrived" do
      buf = "Content-Length: 5\r\n\r\nabc"
      assert Conn.unframe(:content_length, buf) == {[], buf}
    end

    test "raw framing passes a chunk through untouched" do
      assert Conn.unframe(:raw, "anything at all") == {["anything at all"], ""}
    end
  end
end
