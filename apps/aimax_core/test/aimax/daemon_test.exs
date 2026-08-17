defmodule Aimax.DaemonTest do
  @moduledoc """
  The restart command's relaunch script is the one place a shell string is
  built from paths, so it gets its own test. The full restart stops the VM,
  which a test cannot run.
  """

  use ExUnit.Case

  alias Aimax.Core.Daemon
  alias Aimax.Core.Session

  test "the respawn script relaunches mix run from the root into the home log" do
    script = Daemon.respawn_script("/src/ai-max.el", "/home/user/.aimax", "12345")

    assert script =~ "setsid sh -c"
    assert script =~ "kill -0 12345"
    assert script =~ "cd '/src/ai-max.el'"
    assert script =~ "mix run --no-halt"
    assert script =~ ">> '/home/user/.aimax/daemon.log' 2>&1"
  end

  test "the respawn script quotes a root path with spaces" do
    script = Daemon.respawn_script("/src/my repo", "/tmp/home", "7")

    assert script =~ "cd '/src/my repo'"
  end

  test "restart-daemon is a registered command with a doc" do
    assert {:ok, ~s{"Save the desktop and restart the daemon"}} =
             Session.eval(~s{(command-doc "restart-daemon")})
  end

  test "the daemon-restart! primitive carries a doc" do
    assert {:ok, doc} = Session.eval(~s{(primitive-doc "daemon-restart!")})
    assert doc =~ "restart the daemon"
  end
end
