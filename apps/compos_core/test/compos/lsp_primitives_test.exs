defmodule Compos.LSPPrimitivesTest do
  @moduledoc """
  The Scheme surface of the LSP client: lsp-start!, lsp-open!, the
  lsp-on-event! pipe, and lsp-buffer-request — against the fake server.
  """

  use ExUnit.Case

  alias Compos.Core.{Buffer, LSP, Session}

  @fixture Path.expand("../support/fake_lsp_server.exs", __DIR__)
  @root "/tmp"

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp wait_until(fun, tries \\ 300) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true ->
        Process.sleep(20)
        wait_until(fun, tries - 1)
    end
  end

  defp start!(name) do
    on_exit(fn ->
      eval!(~s{(lsp-stop! "#{name}@#{@root}")})
      wait_until(fn -> LSP.whereis(name, @root) == nil end)
    end)

    eval!("""
    (begin
      (define *lsp-test-events* '())
      (on-lsp-event! "test" (lambda (id method params)
        (set! *lsp-test-events* (cons (list id method params) *lsp-test-events*))))
      (lsp-start! "#{name}" "#{@root}"
        (list 'command "elixir" 'args (list "#{@fixture}") 'language "elixir")))
    """)

    wait_until(fn -> LSP.whereis(name, @root) != nil and connected?(name) end)
    "#{name}@#{@root}"
  end

  defp connected?(name) do
    case LSP.whereis(name, @root) do
      nil -> false
      pid -> Compos.Core.LSP.Conn.status(pid) == :ready
    end
  end

  defp doc!(id, text) do
    buf = "/lsp-prim-#{System.unique_integer([:positive])}.ex"
    {:ok, _} = Compos.Core.create_buffer(buf, text: text)
    on_exit(fn -> if Buffer.exists?(buf), do: Compos.Core.kill_buffer(buf) end)
    eval!(~s{(lsp-open! "#{id}" "#{buf}")})
    buf
  end

  defp event_methods do
    eval!("(map (lambda (e) (cadr e)) *lsp-test-events*)")
  end

  test "the event pipe carries status, diagnostics with byte offsets, and sync echoes" do
    id = start!("prim-a")
    _buf = doc!(id, "é WARNME x\n")

    wait_until(fn -> event_methods() =~ "publishDiagnostics" end)

    assert eval!("""
           (let loop ((es *lsp-test-events*))
             (cond ((null? es) #f)
                   ((equal? (cadr (car es)) "textDocument/publishDiagnostics")
                    (let ((d (car (plist-get (caddr (car es)) 'diagnostics))))
                      (list (plist-get d 'startByte)
                            (plist-get d 'endByte)
                            (plist-get d 'message))))
                   (else (loop (cdr es)))))
           """) == ~S{(3 9 "warn me not")}

    # status events ride the same pipe
    assert event_methods() =~ "compos/status"
  end

  test "an edit reaches the server: the fake's sync echo comes back as an event" do
    id = start!("prim-b")
    buf = doc!(id, "one\n")

    :ok = Buffer.insert_at(buf, 0, "zero ", source: :editor)
    wait_until(fn -> event_methods() =~ "fake/sync" end)

    assert eval!("""
           (let loop ((es *lsp-test-events*))
             (cond ((null? es) #f)
                   ((equal? (cadr (car es)) "fake/sync")
                    (plist-get (caddr (car es)) 'length))
                   (else (loop (cdr es)))))
           """) == "9"
  end

  test "lsp-buffer-request answers through a Scheme callback" do
    id = start!("prim-c")
    buf = doc!(id, "hola TARGET\n")

    eval!("""
    (begin
      (define *lsp-test-hover* #f)
      (lsp-buffer-request "#{id}" "textDocument/hover" "#{buf}" 0
        (lambda (ok result)
          (set! *lsp-test-hover* (list ok (plist-get (plist-get result 'contents) 'value))))))
    """)

    wait_until(fn -> eval!("*lsp-test-hover*") != "#f" end)
    assert eval!("*lsp-test-hover*") == ~S{(#t "hover:hola")}
  end

  test "lsp-connections and lsp-server-detail answer from Scheme" do
    id = start!("prim-d")

    assert eval!("(lsp-connections)") =~ ~s{("#{id}" "ready" "prim-d" "/tmp")}
    assert eval!(~s{(plist-get (lsp-server-detail "#{id}") 'server-name)}) == ~S{"fake-lsp"}
    assert eval!(~s{(lsp-server-detail "nope@/tmp")}) == "#f"
  end

  test "a request against a missing connection raises, and lsp-log answers" do
    id = start!("prim-e")

    assert {:error, msg} =
             Session.eval(~s{(lsp-request "gone@/x" "m" '() (lambda (ok r) #f))})

    assert msg =~ "no connection"
    assert eval!(~s{(length (lsp-log "#{id}"))}) =~ ~r/\d+/
  end
end
