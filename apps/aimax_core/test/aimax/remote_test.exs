defmodule Aimax.RemoteTest do
  @moduledoc """
  Remote files (/ssh:host:/path) and tail-file, driven through the same Scheme
  the GUI runs. ssh is faked: :ssh_cmd points at a script that executes the
  remote command locally, so "remote" paths live in a tmp dir.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, Proc, Session}

  setup_all do
    dir = Path.join(System.tmp_dir!(), "aimax-remote-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    fake = Path.join(dir, "fake-ssh")

    File.write!(fake, """
    #!/bin/sh
    while [ $# -gt 0 ]; do
      case "$1" in
        -o) shift 2 ;;
        *) break ;;
      esac
    done
    host="$1"; shift
    [ "$host" = "bad" ] && exit 255
    exec /bin/sh -c "$*"
    """)

    File.chmod!(fake, 0o755)

    prev = Application.get_env(:aimax_core, :ssh_cmd)
    Application.put_env(:aimax_core, :ssh_cmd, fake)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:aimax_core, :ssh_cmd, prev),
        else: Application.delete_env(:aimax_core, :ssh_cmd)

      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  defp remote(file), do: "/ssh:testhost:#{file}"
  defp echo, do: Editor.snapshot().echo

  defp wait_until(fun, ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + ms
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(50)
        do_wait(fun, deadline)
    end
  end

  test "visit opens a remote file over ssh", %{dir: dir} do
    file = Path.join(dir, "notes.txt")
    File.write!(file, "hello from afar\n")
    rp = remote(file)

    {:ok, _} = Session.eval(~s{(visit "#{rp}")})

    assert Buffer.exists?(rp)
    assert Buffer.text(rp) == "hello from afar\n"
    assert Buffer.path(rp) == rp
    assert Buffer.point(rp) == 0
    refute Buffer.modified?(rp)
    assert Editor.current_buffer() == rp
  end

  test "save-buffer writes a remote buffer back through ssh", %{dir: dir} do
    file = Path.join(dir, "config.ex")
    File.write!(file, "v1")
    rp = remote(file)

    {:ok, _} = Session.eval(~s{(begin (visit "#{rp}") (end-of-buffer!) (insert! " v2"))})
    assert Buffer.modified?(rp)

    {:ok, _} = Session.eval(~s{(run-command "save-buffer")})

    assert File.read!(file) == "v1 v2"
    refute Buffer.modified?(rp)
    assert echo() =~ "Wrote"
  end

  test "an absent remote file opens empty and is created on save", %{dir: dir} do
    file = Path.join(dir, "fresh.txt")
    rp = remote(file)

    {:ok, _} = Session.eval(~s{(visit "#{rp}")})
    assert Buffer.exists?(rp)
    assert Buffer.text(rp) == ""

    {:ok, _} = Session.eval(~s{(begin (insert! "born remote") (run-command "save-buffer"))})
    assert File.read!(file) == "born remote"
  end

  test "an unreachable host declines the visit, no buffer left behind" do
    rp = "/ssh:bad:/etc/hosts"
    {:ok, _} = Session.eval(~s{(visit "#{rp}")})

    refute Buffer.exists?(rp)
    assert echo() =~ "cannot reach"
  end

  test "a malformed remote path just messages" do
    {:ok, _} = Session.eval(~s{(visit "/ssh:nocolon")})
    refute Buffer.exists?("/ssh:nocolon")
    assert echo() =~ "/ssh:HOST:/PATH"
  end

  test "visiting a remote directory opens dired", %{dir: dir} do
    sub = Path.join(dir, "proj")
    File.mkdir_p!(Path.join(sub, "lib"))
    File.write!(Path.join(sub, "readme.md"), "hi")
    rp = remote(sub)

    {:ok, _} = Session.eval(~s{(visit "#{rp}")})

    assert Editor.current_buffer() == rp
    assert Buffer.get_local(rp, "mode-name") == "Dired"
    text = Buffer.text(rp)
    assert text =~ "readme.md"
    assert text =~ "lib/"
    assert text =~ "-rw"

    Session.eval(~s{(buffer-kill! "#{rp}")})
  end

  test "list-dir and file-stat work on remote paths", %{dir: dir} do
    sub = Path.join(dir, "stats")
    File.mkdir_p!(sub)
    File.write!(Path.join(sub, "a.txt"), "aaa")
    rp = remote(sub)

    {:ok, names} = Session.eval(~s{(list-dir "#{rp}/")})
    assert names =~ "a.txt"

    {:ok, stat} = Session.eval(~s{(file-stat "#{rp}/a.txt")})
    assert stat =~ "-rw"
    assert stat =~ "\"3\""
  end

  test "make-directory! and delete-file! reach through ssh", %{dir: dir} do
    sub = Path.join(dir, "ops")
    File.mkdir_p!(sub)
    target = Path.join(sub, "newdir")

    {:ok, _} = Session.eval(~s{(make-directory! "#{remote(target)}")})
    assert File.dir?(target)

    {:ok, _} = Session.eval(~s{(delete-file! "#{remote(target)}")})
    refute File.exists?(target)

    file = Path.join(sub, "doomed.txt")
    File.write!(file, "x")
    {:ok, _} = Session.eval(~s{(delete-file! "#{remote(file)}")})
    refute File.exists?(file)
  end

  test "tail-open follows a growing local file", %{dir: dir} do
    file = Path.join(dir, "grow.log")
    File.write!(file, "one\n")
    buf = "*tail: #{file}*"

    {:ok, _} = Session.eval(~s{(tail-open "#{file}")})

    assert Buffer.exists?(buf)
    assert Proc.running?(buf)
    assert Buffer.read_only?(buf)
    assert Buffer.get_local(buf, "transient")
    assert wait_until(fn -> Buffer.text(buf) =~ "one" end)

    File.write!(file, "two\n", [:append])
    assert wait_until(fn -> Buffer.text(buf) =~ "two" end)

    # point rode the appends — the window follows the tail
    assert Buffer.point(buf) == Buffer.byte_size(buf)

    # C-x k semantics: killing the buffer kills the tail process
    {:ok, _} = Session.eval(~s{(begin (process-kill! "#{buf}") (buffer-kill! "#{buf}"))})
    refute Proc.running?(buf)
  end

  test "tail-open follows a remote file through ssh", %{dir: dir} do
    file = Path.join(dir, "remote-grow.log")
    File.write!(file, "alpha\n")
    rp = remote(file)
    buf = "*tail: #{rp}*"

    {:ok, _} = Session.eval(~s{(tail-open "#{rp}")})

    assert Proc.running?(buf)
    assert wait_until(fn -> Buffer.text(buf) =~ "alpha" end)

    File.write!(file, "beta\n", [:append])
    assert wait_until(fn -> Buffer.text(buf) =~ "beta" end)

    {:ok, _} = Session.eval(~s{(begin (process-kill! "#{buf}") (buffer-kill! "#{buf}"))})
  end
end
