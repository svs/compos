defmodule Aimax.TerminalTest do
  use ExUnit.Case

  alias Aimax.Core.{Buffer, Session, Terminal}
  alias Aimax.Core.Terminal.Transcript

  defp wait_until(fun, tries \\ 300) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(20)
        wait_until(fun, tries - 1)
    end
  end

  defp start_terminal!(command) do
    name = "*terminal-test-#{System.unique_integer([:positive])}*"
    {:ok, _} = Terminal.start(name, command)

    on_exit(fn ->
      if Terminal.running?(name), do: Terminal.kill(name)
      Aimax.Core.kill_buffer(name)
    end)

    name
  end

  test "raw PTY output bypasses the transcript and remains readable in its buffer" do
    name = start_terminal!("printf '\\033[31mrails-ready\\033[0m\\n'; cat")
    assert {:ok, history} = Terminal.subscribe(name)
    assert is_binary(history)

    raw =
      receive do
        {:terminal_data, ^name, data} -> data
      after
        2_000 -> flunk("terminal sent no raw output")
      end

    assert raw =~ "\e[31mrails-ready\e[0m"
    wait_until(fn -> Buffer.text(name) =~ "rails-ready" end)
    refute Buffer.text(name) =~ "\e[31m"

    assert :ok = Terminal.send_text(name, "from-client\n")
    wait_until(fn -> Buffer.text(name) =~ "from-client" end)

    {:ok, tool_result} =
      Session.eval(~s{(llm-tool-call "eval-scheme" (list 'code "(buffer-text \\"#{name}\\")"))})

    assert tool_result =~ "rails-ready"
    refute tool_result =~ "<<"
  end

  test "the transcript parser removes controls across chunks and preserves split UTF-8" do
    <<arrow_start::binary-size(2), arrow_end::binary>> = "➜"
    {first, state} = Transcript.feed(Transcript.new(), "\e[38;2;12")

    {second, state} =
      Transcript.feed(state, ";34;56mred\e[0m\e]0;window title" <> <<7>> <> arrow_start)

    {third, state} = Transcript.feed(state, arrow_end <> "\b\r\n\ePignored")
    {fourth, state} = Transcript.feed(state, " payload\e\\done" <> <<15, 7>>)
    {tail, _state} = Transcript.finish(state)

    assert first <> second <> third <> fourth <> tail == "red➜\ndone"
  end

  test "starting a terminal cleans a persisted transcript for Scheme readers" do
    name = "*terminal-migration-#{System.unique_integer([:positive])}*"
    Aimax.Core.create_buffer(name)
    Buffer.append(name, "before\e[31mred\e[0m\b" <> <<7, 15>> <> "after", source: :process)
    {:ok, _} = Terminal.start(name, "cat")

    on_exit(fn ->
      if Terminal.running?(name), do: Terminal.kill(name)
      Aimax.Core.kill_buffer(name)
    end)

    wait_until(fn -> String.printable?(Buffer.text(name)) end)
    assert Buffer.text(name) == "beforeredafter"
    assert Aimax.Scheme.Printer.print(Buffer.text(name)) == ~s{"beforeredafter"}
  end

  test "the PTY advertises color, removes host color suppression, and accepts resize" do
    name =
      start_terminal!(
        "printf 'TERM=%s COLORTERM=%s CLICOLOR=%s NO_COLOR=%s\\n' " <>
          "\"$TERM\" \"$COLORTERM\" \"$CLICOLOR\" \"${NO_COLOR-unset}\"; " <>
          "printf '\\033[38;2;12;34;56mtruecolor\\033[0m\\n'; cat"
      )

    assert {:ok, history} = Terminal.subscribe(name)

    raw =
      receive do
        {:terminal_data, ^name, data} -> history <> data
      after
        2_000 -> flunk("terminal sent no color capability output")
      end

    assert raw =~ "TERM=xterm-256color COLORTERM=truecolor CLICOLOR=1 NO_COLOR=unset"
    assert raw =~ "\e[38;2;12;34;56mtruecolor\e[0m"

    wait_until(fn -> Terminal.resize(name, 117, 39) == :ok end)
    assert Terminal.running?(name)
    assert {^name, _command} = Enum.find(Terminal.list(), fn {buffer, _} -> buffer == name end)
  end

  test "busy output keeps raw history and the plain transcript bounded" do
    name =
      start_terminal!("head -c 900000 /dev/zero | tr '\\000' x; printf '\\nDONE\\n'; sleep 1")

    wait_until(fn -> Buffer.text(name) =~ "DONE" end, 600)
    assert Buffer.byte_size(name) <= 530_000

    assert {:ok, history} = Terminal.subscribe(name)
    assert byte_size(history) <= 512 * 1024
  end
end
