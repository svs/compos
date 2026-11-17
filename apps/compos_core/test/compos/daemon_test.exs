defmodule Compos.DaemonTest do
  @moduledoc """
  The restart command's relaunch script is the one place a shell string is
  built from paths, so it gets its own test. The full restart stops the VM,
  which a test cannot run.
  """

  use ExUnit.Case

  alias Compos.Core.Daemon
  alias Compos.Core.Session

  test "the respawn script relaunches mix run from the root into the state log" do
    script =
      Daemon.respawn_script("/src/compos.el", "/home/user/.compos", "12345", "/home/user/.local/state/compos")

    assert script =~ "nohup /bin/sh -c"
    refute script =~ "setsid"
    assert script =~ "kill -0 12345"
    assert script =~ "/src/compos.el"
    assert script =~ "COMPOS_HOME="
    assert script =~ "/home/user/.compos"
    assert script =~ "mix run --no-halt"
    assert script =~ "/home/user/.local/state/compos/daemon.log"
    assert script =~ "2>&1"
  end

  test "the respawn script is valid shell with quoted paths" do
    script = Daemon.respawn_script("/src/my repo", "/tmp/user's home", "7")

    assert {"", 0} = System.cmd("/bin/sh", ["-n", "-c", script], stderr_to_stdout: true)
  end

  test "the release respawn script relaunches the executable into the home log" do
    script = Daemon.release_respawn_script("/Users/me/.local/bin/compos stable", "/tmp/user's home", "42")

    assert script =~ "kill -0 42"
    assert script =~ "compos stable"
    assert script =~ "--no-halt"
    assert script =~ "daemon.log"
    assert script =~ "RELEASE_"
    refute script =~ "mix run"
    assert {"", 0} = System.cmd("/bin/sh", ["-n", "-c", script], stderr_to_stdout: true)
  end

  test "a workspace daemon starts without the live daemon's COMPOS_* variables" do
    live = %{
      "COMPOS_PORT" => "4104",
      "COMPOS_APP_PORT" => "4105",
      "COMPOS_NAME" => "dev",
      "COMPOS_HOME" => "/tmp/live-home",
      "COMPOS_SOCK" => "/tmp/live.sock",
      "COMPOS_DAEMON_REGISTRY" => "/tmp/live-registry.json"
    }

    prefix = Daemon.workspace_env("/tmp/wt home", "/tmp/deps", "/tmp/build", live)
    {out, 0} = System.cmd("/bin/sh", ["-c", prefix <> " env"], env: Map.to_list(live))

    vars =
      for line <- String.split(out, "\n"),
          [key, value] <- [String.split(line, "=", parts: 2)],
          into: %{},
          do: {key, value}

    assert vars["COMPOS_HOME"] == "/tmp/wt home"
    assert vars["MIX_DEPS_PATH"] == "/tmp/deps"
    assert vars["MIX_BUILD_PATH"] == "/tmp/build"

    for key <- Map.keys(live) -- ["COMPOS_HOME"] do
      refute Map.has_key?(vars, key), "#{key} leaked into the workspace daemon"
    end
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
  test "opening the running checkout claims an empty registry without provisioning" do
    prior_registry = Application.get_env(:compos_core, :daemon_registry_path)
    registry = Path.join(System.tmp_dir!(), "compos-owner-#{System.unique_integer([:positive])}.json")
    Application.put_env(:compos_core, :daemon_registry_path, registry)
    Application.put_env(:compos_core, :workspace_daemon_provisioner, fn _, _ ->
      flunk("the running checkout must not start a second daemon")
    end)

    on_exit(fn ->
      if prior_registry, do: Application.put_env(:compos_core, :daemon_registry_path, prior_registry),
        else: Application.delete_env(:compos_core, :daemon_registry_path)
      Application.delete_env(:compos_core, :workspace_daemon_provisioner)
      File.rm(registry)
    end)

    assert {:ok, "#t"} = Session.eval(~S|
      (equal? (worktree--daemon-owner! "*scratch*" "current" (daemon-source-root))
              (editor-url))
    |)
    assert File.exists?(registry)
  end

end
