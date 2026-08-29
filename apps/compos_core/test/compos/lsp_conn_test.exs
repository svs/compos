defmodule Compos.LSPConnTest do
  @moduledoc """
  LSP client transport: Content-Length framing, the initialize
  handshake, server->client requests, document sync, and shutdown —
  against a real subprocess (the fake server in test/support).
  """

  use ExUnit.Case

  alias Compos.Core.{Buffer, LSP}
  alias Compos.Core.LSP.Conn

  @fixture Path.expand("../support/fake_lsp_server.exs", __DIR__)
  @root "/tmp"

  defp wait_until(fun, tries \\ 300) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true ->
        Process.sleep(20)
        wait_until(fun, tries - 1)
    end
  end

  defp spec(env, extra) do
    Map.merge(
      %{"command" => "elixir", "args" => [@fixture], "env" => env, "language" => "elixir"},
      extra
    )
  end

  defp start!(name, env \\ %{}, extra \\ %{}) do
    on_exit(fn ->
      LSP.stop(name, @root)
      wait_until(fn -> LSP.whereis(name, @root) == nil end)
    end)

    {:ok, _} = LSP.start(name, @root, spec(env, extra))
    wait_until(fn -> connected_status(name) == :ready end)
    LSP.whereis(name, @root)
  end

  defp connected_status(name) do
    case LSP.whereis(name, @root) do
      nil -> :gone
      pid -> Conn.status(pid)
    end
  end

  defp doc!(pid, text) do
    name = "/lsp-doc-#{System.unique_integer([:positive])}.ex"
    {:ok, _} = Compos.Core.create_buffer(name, text: text)
    on_exit(fn -> if Buffer.exists?(name), do: Compos.Core.kill_buffer(name) end)
    Conn.open_doc(pid, name)
    wait_until(fn -> name in (Conn.detail(pid) || %{docs: []}).docs end)
    name
  end

  defp log_texts(pid), do: for(%{text: t} <- Conn.log(pid), do: t)

  test "handshake reaches ready and answers workspace/configuration" do
    pid = start!("fake-hs")

    assert [%{name: "fake-hs", status: :ready, root: @root}] =
             Enum.filter(LSP.connections(), &(&1.name == "fake-hs"))

    texts = log_texts(pid)
    assert Enum.any?(texts, &(&1 =~ "initialize"))
    assert Enum.any?(texts, &(&1 =~ "workspace/configuration"))
    # the fake acknowledges our configuration answer
    wait_until(fn -> Enum.any?(log_texts(pid), &(&1 =~ "fake/configAnswered")) end)
  end

  test "the spec's settings are what the configuration answer carries" do
    pid = start!("fake-cfg", %{}, %{"settings" => %{"dialyzerEnabled" => false}})

    wait_until(fn -> Enum.any?(log_texts(pid), &(&1 =~ "fake/configAnswered")) end)

    answer = Enum.find(log_texts(pid), &(&1 =~ "fake/configAnswered"))
    assert answer =~ ~s("dialyzerEnabled":false)
  end

  test "a buffer-local write syncs nothing; a text edit still syncs" do
    pid = start!("fake-phantom")
    buf = doc!(pid, "alpha\n")

    # the phantom change: set_local repaints views, it moves no text.
    # Diagnostics write locals, so syncing this one loops the server.
    Buffer.set_local(buf, :lsp_diagnostics, [])
    Process.sleep(300)
    refute Enum.any?(log_texts(pid), &(&1 =~ "fake/sync"))

    Buffer.insert_at(buf, 0, "beta ")
    wait_until(fn -> Enum.any?(log_texts(pid), &(&1 =~ "fake/sync")) end)
  end

  test "buffer_request round-trips and enriches locations with byte offsets" do
    pid = start!("fake-req")
    buf = doc!(pid, "x TARGET y\n")
    me = self()

    Conn.buffer_request(pid, "textDocument/definition", buf, 0, %{}, fn result ->
      send(me, {:definition, result})
    end)

    assert_receive {:definition, {:ok, loc}}, 5_000
    assert loc["buffer"] == buf
    assert loc["startByte"] == 2
    assert loc["endByte"] == 8
  end

  test "utf-16 positions convert around multibyte text" do
    pid = start!("fake-mb")
    buf = doc!(pid, "é𝄞 TARGET\n")
    me = self()

    Conn.buffer_request(pid, "textDocument/definition", buf, 0, %{}, fn result ->
      send(me, {:definition, result})
    end)

    # é = 2 bytes, 𝄞 = 4 bytes: TARGET starts at byte 7
    assert_receive {:definition, {:ok, loc}}, 5_000
    assert loc["startByte"] == 7
    assert loc["endByte"] == 13
  end

  test "utf-8 encoding negotiates and converts the same text" do
    pid = start!("fake-u8", %{"FAKE_LSP_ENCODING" => "utf-8"})
    assert (Conn.detail(pid) || %{}).encoding == :utf8

    buf = doc!(pid, "é𝄞 TARGET\n")
    me = self()

    Conn.buffer_request(pid, "textDocument/definition", buf, 0, %{}, fn result ->
      send(me, {:definition, result})
    end)

    assert_receive {:definition, {:ok, loc}}, 5_000
    assert loc["startByte"] == 7
  end

  test "frames split across chunks reassemble" do
    pid = start!("fake-split", %{"FAKE_LSP_SPLIT" => "1"})
    buf = doc!(pid, "a TARGET b\n")
    me = self()

    Conn.buffer_request(pid, "textDocument/hover", buf, 0, %{}, fn result ->
      send(me, {:hover, result})
    end)

    assert_receive {:hover, {:ok, hover}}, 5_000
    assert hover["contents"]["value"] == "hover:a"
  end

  test "an edited buffer syncs: the fake echoes the new version" do
    pid = start!("fake-sync")
    buf = doc!(pid, "one\n")

    :ok = Buffer.insert_at(buf, 0, "zero ", source: :editor)

    wait_until(fn -> Enum.any?(log_texts(pid), &(&1 =~ "fake/sync")) end)
    sync = Enum.find(log_texts(pid), &(&1 =~ "fake/sync"))
    assert sync =~ "\"length\":9"
  end

  test "a killed buffer closes its document at flush" do
    pid = start!("fake-close")
    buf = doc!(pid, "gone\n")

    :ok = Buffer.insert_at(buf, 0, "x", source: :editor)
    Compos.Core.kill_buffer(buf)

    wait_until(fn -> Enum.any?(log_texts(pid), &(&1 =~ "didClose")) end)
    assert (Conn.detail(pid) || %{docs: [:still_open]}).docs == []
  end

  test "a dead command fails loudly and leaves a post-mortem" do
    name = "fake-dead"
    {:ok, _} = LSP.start(name, @root, %{"command" => "definitely-not-a-command-9x9"})
    wait_until(fn -> LSP.whereis(name, @root) == nil end)

    assert %{status: :error, log: log} = LSP.detail(name, @root)
    assert Enum.any?(log, &(&1.text =~ "command not found"))
  end

  test "stop runs the shutdown handshake: shutdown, then exit, then gone" do
    start!("fake-bye")
    LSP.stop("fake-bye", @root)
    wait_until(fn -> LSP.whereis("fake-bye", @root) == nil end)

    %{log: log} = LSP.detail("fake-bye", @root)
    texts = for %{text: t} <- log, do: t
    shutdown_at = Enum.find_index(texts, &(&1 =~ "\"shutdown\""))
    exit_at = Enum.find_index(texts, &(&1 =~ "\"exit\""))
    assert shutdown_at != nil and exit_at != nil and shutdown_at < exit_at
  end

  test "split_frames tolerates bare newline separators and partial bodies" do
    body = Jason.encode!(%{"jsonrpc" => "2.0", "method" => "m", "params" => %{}})

    assert {[%{"method" => "m"}], ""} =
             Conn.split_frames("Content-Length: #{byte_size(body)}\n\n" <> body)

    frame = "Content-Length: #{byte_size(body)}\r\n\r\n" <> body
    {half, rest} = String.split_at(frame, 20)
    assert {[], ^half} = Conn.split_frames(half)
    assert {[%{"method" => "m"}], ""} = Conn.split_frames(half <> rest)
  end
end
