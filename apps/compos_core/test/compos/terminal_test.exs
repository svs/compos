defmodule Compos.TerminalTest do
  use Compos.Case

  alias Compos.Core.{Buffer, Session, Terminal}
  alias Compos.Core.Terminal.Transcript

  defp start_terminal!(command) do
    name = "*terminal-test-#{System.unique_integer([:positive])}*"
    {:ok, _} = Terminal.start(name, command)

    on_exit(fn ->
      if Terminal.running?(name), do: Terminal.kill(name)
      Compos.Core.kill_buffer(name)
    end)

    name
  end

  test "the size rides with the transcript, so a client replays at the width that wrote it" do
    name = start_terminal!("cat")
    assert {80, 24} = Terminal.size(name), "the PTY starts at the size the wrapper pins"

    # the reply says whether the ioctl reached the PTY; the recorded size is
    # what a client reads back, and a replay needs it either way
    _ = Terminal.resize(name, 166, 48)
    assert {166, 48} = Terminal.size(name), "a client's size is the size the bytes wrap at"
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
    Compos.Core.create_buffer(name)
    Buffer.append(name, "before\e[31mred\e[0m\b" <> <<7, 15>> <> "after", source: :process)
    {:ok, _} = Terminal.start(name, "cat")

    on_exit(fn ->
      if Terminal.running?(name), do: Terminal.kill(name)
      Compos.Core.kill_buffer(name)
    end)

    wait_until(fn -> String.printable?(Buffer.text(name)) end)
    assert Buffer.text(name) == "beforeredafter"
    assert Compos.Scheme.Printer.print(Buffer.text(name)) == ~s{"beforeredafter"}
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

  test "a comint process runs dumb, strips escapes, moves its mark, and restarts as comint" do
    name = "*terminal-comint-#{System.unique_integer([:positive])}*"

    {:ok, _} =
      Terminal.start(name, "printf 'TERM=%s \\033[31mred\\033[0m\\n' \"$TERM\"; cat", raw: false)

    on_exit(fn ->
      if Terminal.running?(name), do: Terminal.kill(name)
      Compos.Core.kill_buffer(name)
    end)

    wait_until(fn -> Buffer.text(name) =~ "red" end)
    assert Buffer.text(name) =~ "TERM=dumb red"
    refute Buffer.text(name) =~ "\e["
    assert Terminal.mark(name) == Buffer.byte_size(name)

    assert :ok = Terminal.send_text(name, "typed\n")
    wait_until(fn -> Buffer.text(name) =~ "typed" end)
    # pty echo is off: cat answers once and the pty does not repeat the line
    Process.sleep(100)
    assert length(String.split(Buffer.text(name), "typed")) == 2

    assert {:ok, _} = Terminal.restart(name)
    wait_until(fn -> length(String.split(Buffer.text(name), "TERM=dumb")) == 3 end)
    assert Terminal.mark(name) == Buffer.byte_size(name)
  end

  test "a command with quotes and && runs under this platform's script" do
    name = start_terminal!("printf '%s\\n' 'it''s-ready' && echo done; cat")
    wait_until(fn -> Buffer.text(name) =~ "its-ready" and Buffer.text(name) =~ "done" end)
    assert Terminal.running?(name)
  end

  test "a terminal does not inherit the host's tmux" do
    System.put_env("TMUX", "/tmp/tmux-test,1,0")
    on_exit(fn -> System.delete_env("TMUX") end)
    name = start_terminal!("printf 'TMUX=%s\\n' \"${TMUX-unset}\"; cat")
    wait_until(fn -> Buffer.text(name) =~ "TMUX=unset" end)
  end
end
