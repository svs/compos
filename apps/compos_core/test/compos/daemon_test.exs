defmodule Compos.DaemonTest do
  @moduledoc """
  The restart command's relaunch script is the one place a shell string is
  built from paths, so it gets its own test. The full restart stops the VM,
  which a test cannot run.
  """

  use ExUnit.Case

  alias Compos.Core.Daemon
  alias Compos.Core.Session

  test "the respawn script relaunches mix run from the root into the home log" do
    script = Daemon.respawn_script("/src/compos.el", "/home/user/.compos", "12345")

    assert script =~ "nohup /bin/sh -c"
    refute script =~ "setsid"
    assert script =~ "kill -0 12345"
    assert script =~ "/src/compos.el"
    assert script =~ "COMPOS_HOME="
    assert script =~ "/home/user/.compos"
    assert script =~ "mix run --no-halt"
    assert script =~ "/home/user/.compos/daemon.log"
    assert script =~ "2>&1"
  end

  test "the respawn script is valid shell with quoted paths" do
    script = Daemon.respawn_script("/src/my repo", "/tmp/user's home", "7")

    assert {"", 0} = System.cmd("/bin/sh", ["-n", "-c", script], stderr_to_stdout: true)
  end

  test "restart-daemon is a registered command with a doc" do
    assert {:ok, ~s{"Save the desktop and restart the daemon"}} =
             Session.eval(~s{(command-doc "restart-daemon")})
  end

  test "the daemon-restart! primitive carries a doc" do
    assert {:ok, doc} = Session.eval(~s{(primitive-doc "daemon-restart!")})
    assert doc =~ "restart the daemon"
  end

  test "the workspace primitive returns the daemon built from that checkout" do
    Application.put_env(:compos_core, :workspace_daemon_provisioner, fn workspace, name ->
      assert workspace == "/tmp/feature"
      assert name == "a1"
      {:ok, %{url: "http://localhost:4204", home: "/tmp/a1-home", port: 4204}}
    end)

    on_exit(fn -> Application.delete_env(:compos_core, :workspace_daemon_provisioner) end)

    assert {:ok, result} =
             Session.eval(~s{(daemon-provision-workspace! "/tmp/feature" "a1")})

    assert result == ~s{("http://localhost:4204" "/tmp/a1-home" 4204)}
  end
end
