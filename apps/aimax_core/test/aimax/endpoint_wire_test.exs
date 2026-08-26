defmodule Aimax.EndpointWireTest do
  @moduledoc """
  Length-prefixed binary framing, against the real PostgreSQL wire protocol.

  This is the case that text framing cannot reach: a backend message is a
  one-byte tag, a big-endian Int32 length that counts itself, and a binary
  payload. Elixir does the byte math, so Scheme receives whole protocol
  messages instead of arbitrary TCP chunks.

  The server here listens on a unix socket, so the test bridges with `nc -U`
  over the exec transport. The framing is the same on tcp.
  """

  use ExUnit.Case

  alias Aimax.Core.{Endpoint, Session}
  alias Aimax.Core.Endpoint.Conn

  @sock "/tmp/.s.PGSQL.5432"

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

  # PostgreSQL: prefix is the 1-byte tag, the Int32 length counts itself.
  @pg %{width: 4, prefix: 1, endian: :big, counts: :self}

  describe "length framing" do
    test "splits two PostgreSQL messages out of one chunk" do
      # exactly what the real server sent: R(len 8) then E(len 89)
      r = <<?R, 0, 0, 0, 8, 0, 0, 0, 0>>
      e = <<?E, 0, 0, 0, 6, 1, 2>>
      {frames, rest} = Conn.unframe({:length, @pg}, r <> e)
      assert frames == [r, e]
      assert rest == ""
    end

    test "holds a message whose payload has not fully arrived" do
      partial = <<?R, 0, 0, 0, 8, 0, 0>>
      assert Conn.unframe({:length, @pg}, partial) == {[], partial}
    end

    test "holds a header that has not fully arrived" do
      assert Conn.unframe({:length, @pg}, <<?R, 0, 0>>) == {[], <<?R, 0, 0>>}
    end

    test "payload counting is the plain case: length excludes the header" do
      o = %{width: 4, prefix: 0, endian: :big, counts: :payload}
      assert Conn.unframe({:length, o}, <<0, 0, 0, 3, "abc", 0, 0>>) ==
               {[<<0, 0, 0, 3, "abc">>], <<0, 0>>}
    end

    test "little-endian widths decode too" do
      o = %{width: 2, prefix: 0, endian: :little, counts: :payload}
      assert Conn.unframe({:length, o}, <<3, 0, "xyz">>) == {[<<3, 0, "xyz">>], ""}
    end

    test "a desynchronized length drops the buffer instead of looping" do
      # a length smaller than its own header cannot be honoured
      o = %{width: 4, prefix: 1, endian: :big, counts: :self}
      assert Conn.unframe({:length, o}, <<?X, 0, 0, 0, 1, "junk">>) == {[], ""}
    end
  end

  describe "the real server" do
    test "a Scheme caller speaks the PostgreSQL wire protocol and gets whole messages" do
      nc = System.find_executable("nc")

      if nc == nil or not File.exists?(@sock) do
        IO.puts("skipped: no nc or no PostgreSQL unix socket")
      else
        eval!("""
        (endpoint-start! "pg-wire"
          (list 'command "#{nc}" 'args (list "-U" "#{@sock}")
                'framing "length"
                'length-prefix 1 'length-width 4 'length-counts "self"))
        """)

        wait_until(fn -> Endpoint.whereis("pg-wire") != nil end)
        on_exit(fn -> Endpoint.stop("pg-wire") end)

        # the startup packet, built byte by byte in Scheme:
        # Int32 total length, Int32 protocol 3.0, then "user\\0svs\\0\\0"
        eval!(~S"""
        (define pg-startup
          "\x00;\x00;\x00;\x12;\x00;\x03;\x00;\x00;user\x00;svs\x00;\x00;")
        """)

        assert eval!("(string-byte-length pg-startup)") == "18"

        eval!("(define got '())")

        eval!("""
        (on-endpoint-event! "wire-test"
          (lambda (name kind text)
            (when (equal? kind "frame") (set! got (cons text got)))))
        """)

        eval!(~s|(endpoint-send! "pg-wire" pg-startup)|)
        wait_until(fn -> eval!("(length got)") != "0" end)
        Process.sleep(300)

        frames = eval!("(reverse got)")

        # the tag byte is ASCII, so Scheme can read it without byte accessors
        assert eval!("(string-prefix? \"R\" (car (reverse got)))") == "#t"

        # the authentication message is exactly 9 bytes: tag + Int32 + Int32
        assert eval!("(string-byte-length (car (reverse got)))") == "9"

        # every frame is a whole message, never a partial chunk
        assert eval!("(> (length got) 1)") == "#t"
        refute frames == ""
      end
    end
  end
end
