defmodule Aimax.Core.Daemon do
  @moduledoc """
  Self-restart: save the desktop, respawn the daemon, and stop this VM.

  The daemon runs via `mix run --no-halt` from the project root. A restart
  saves the desktop, then hands a detached shell the same launch command
  `mix aimax.restart` uses. The shell waits for this BEAM to exit, then
  relaunches. The new daemon never fights the old one for the port or the
  socket.
  """

  @doc "Save the desktop, respawn the daemon, and stop this VM. Returns :ok or an error tuple."
  def restart do
    # Compile BEFORE the handover, while this daemon still serves. The
    # respawn then boots in seconds instead of minutes, and a tree that
    # does not compile refuses the restart instead of leaving no daemon.
    with :ok <- precompile(),
         :ok <- save_desktop(),
         :ok <- respawn() do
      schedule_stop()
      :ok
    end
  end

  defp save_desktop do
    case Aimax.Core.Desktop.save_now() do
      :ok -> :ok
      :error -> {:error, :desktop_save_failed}
    end
  end

  defp precompile do
    {out, code} =
      System.cmd("mix", ["compile"],
        cd: File.cwd!(),
        stderr_to_stdout: true,
        env: [{"MIX_ENV", to_string(Mix.env())}]
      )

    if code == 0 do
      :ok
    else
      {:error, {:compile_failed, String.slice(out, -2000, 2000) || out}}
    end
  rescue
    # no mix on PATH (a release build): the respawn does not compile either
    _ -> :ok
  end

  @doc "Start or reuse a daemon whose code and cwd come from a workspace."
  def provision_workspace(workspace, name) do
    workspace = Path.expand(workspace)

    case Application.get_env(:aimax_core, :workspace_daemon_provisioner) do
      fun when is_function(fun, 2) -> fun.(workspace, name)
      _ -> provision_workspace!(workspace, name)
    end
  end

  defp provision_workspace!(workspace, name) do
    with true <- File.dir?(workspace) || {:error, :missing_workspace},
         true <- File.exists?(Path.join(workspace, "mix.exs")) || {:error, :not_aimax_checkout} do
      registry =
        Application.get_env(
          :aimax_core,
          :daemon_registry_path,
          Path.expand("~/.aimax/daemons.json")
        )

      digest =
        :crypto.hash(:sha256, workspace) |> Base.encode16(case: :lower) |> binary_part(0, 12)

      home = Path.join([Path.dirname(registry), "worktree-daemons", digest])
      conf = Path.join(home, "daemon.conf")

      {port, app_port} = existing_ports(conf) || available_port_pair()
      url = "http://localhost:#{port}"
      File.mkdir_p!(home)
      deps = Path.join(File.cwd!(), "deps")
      build = Path.join(home, "_build")

      File.write!(
        conf,
        Enum.join(
          [
            "home = #{home}",
            "port = #{port}",
            "app_port = #{app_port}",
            "name = worktree-#{name}",
            "workspace = #{workspace}",
            "registry = #{registry}"
          ],
          "\n"
        ) <> "\n"
      )

      if tcp_up?(port) do
        {:ok, %{url: url, home: home, port: port}}
      else
        log = Path.join(home, "daemon.log")

        command =
          "nohup env AIMAX_HOME=#{shq(home)} MIX_DEPS_PATH=#{shq(deps)} " <>
            "MIX_BUILD_PATH=#{shq(build)} mix run --no-halt >> #{shq(log)} 2>&1 </dev/null &"

        case System.cmd("/bin/sh", ["-c", command], cd: workspace, stderr_to_stdout: true) do
          {_out, 0} -> wait_for_port(port, url, home, 600)
          {out, code} -> {:error, {:spawn_failed, code, out}}
        end
      end
    end
  rescue
    e -> {:error, {:provision_failed, Exception.message(e)}}
  end

  defp existing_ports(path) do
    with {:ok, text} <- File.read(path),
         [port] <- Regex.run(~r/^port\s*=\s*(\d+)$/m, text, capture: :all_but_first),
         [app_port] <- Regex.run(~r/^app_port\s*=\s*(\d+)$/m, text, capture: :all_but_first) do
      {String.to_integer(port), String.to_integer(app_port)}
    else
      _ -> nil
    end
  end

  defp available_port_pair do
    Enum.find_value(4204..65_532//2, fn port ->
      if port_free?(port) and port_free?(port + 1), do: {port, port + 1}
    end) || raise "no free daemon port pair"
  end

  defp port_free?(port) do
    case :gen_tcp.listen(port, [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true]) do
      {:ok, socket} -> :gen_tcp.close(socket) == :ok
      {:error, _} -> false
    end
  end

  defp tcp_up?(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 100) do
      {:ok, socket} -> :gen_tcp.close(socket) == :ok
      {:error, _} -> false
    end
  end

  defp wait_for_port(_port, url, home, 0),
    do: {:error, {:boot_timeout, url, Path.join(home, "daemon.log")}}

  defp wait_for_port(port, url, home, tries) do
    if tcp_up?(port) do
      {:ok, %{url: url, home: home, port: port}}
    else
      Process.sleep(100)
      wait_for_port(port, url, home, tries - 1)
    end
  end

  # `nohup` keeps the relauncher alive after this VM closes. Do not use
  # `setsid`: macOS does not provide it. The wait loop checks this BEAM's PID.
  # The new daemon starts after the port and socket are free. All relauncher
  # descriptors point away from System.cmd, so it returns at once.
  defp respawn do
    script = respawn_script(File.cwd!(), Aimax.Core.home(), System.pid())

    case System.cmd("/bin/sh", ["-c", script], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:spawn_failed, code, out}}
    end
  rescue
    e -> {:error, {:spawn_failed, Exception.message(e)}}
  end

  defp schedule_stop do
    Task.start(fn ->
      Process.sleep(200)
      System.stop(0)
    end)
  end

  @doc false
  def respawn_script(root, home, pid) do
    log = Path.join(home, "daemon.log")

    relaunch =
      "while kill -0 #{pid} 2>/dev/null; do sleep 0.1; done; " <>
        "cd #{shq(root)}; " <>
        "exec env AIMAX_HOME=#{shq(home)} mix run --no-halt >> #{shq(log)} 2>&1"

    "nohup /bin/sh -c #{shq(relaunch)} </dev/null >/dev/null 2>&1 &"
  end

  defp shq(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"
end
