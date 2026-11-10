defmodule Compos.Core.Daemon do
  @moduledoc """
  Self-restart: save the desktop, respawn the daemon, and stop this VM.

  The daemon runs via `mix run --no-halt` from the project root. A restart
  saves the desktop, then hands a detached shell the same launch command
  The daemon lifecycle uses. The shell waits for this BEAM to exit, then
  relaunches. The new daemon never fights the old one for the port or the
  socket.

  This module also names the daemon's listen sockets — the JSON-RPC unix
  socket, the HTTP endpoint, and the app-preview server — so Scheme can
  list and bounce one listener without a full daemon restart. The owning
  supervisors live in other apps; this module reaches them by registered
  name, never by a compile-time call.
  """

  # Every agent adapter holds a few pipes. With the macOS default of 256
  # descriptors, about 35 open chats use them all, and then no port opens:
  # no shell, no git, no file watcher. Raise the soft limit before launch.
  @raise_fd_limit "ulimit -n 65536 2>/dev/null || ulimit -n 10240 2>/dev/null; "

  # listener name => {supervisor name, child id}. Every child is
  # restartable in place: terminate_child then restart_child.
  @listeners [
    {"rpc", Compos.Rpc.Supervisor, Compos.Rpc.Server},
    {"http", Compos.Ui.Supervisor, Compos.Ui.Endpoint},
    {"app", Compos.Ui.Supervisor, :compos_app_server}
  ]

  @doc """
  The daemon's listen sockets as `%{name, status, address}`.

  Status is "up" when the supervised child runs, "off" when the listener is
  not configured (the app server with `app_port: nil`, or an app that is not
  started), and "down" when it should run but does not.
  """
  def listeners do
    for {name, sup, id} <- @listeners do
      %{name: name, status: listener_status(name, sup, id), address: listener_address(name)}
    end
  end

  @doc "Stop and start one listen socket. Returns :ok or an error tuple."
  def restart_listener(name) do
    case List.keyfind(@listeners, name, 0) do
      {^name, sup, id} ->
        if is_pid(Process.whereis(sup)) do
          Supervisor.terminate_child(sup, id)

          case Supervisor.restart_child(sup, id) do
            {:ok, _} -> :ok
            {:ok, _, _} -> :ok
            {:error, reason} -> {:error, reason}
          end
        else
          {:error, :not_running}
        end

      nil ->
        {:error, :unknown_listener}
    end
  end

  defp listener_status("app", _sup, _id) do
    if Application.get_env(:compos_ui, :app_port) == nil,
      do: "off",
      else: listener_status(nil, Compos.Ui.Supervisor, :compos_app_server)
  end

  defp listener_status(_name, sup, id) do
    with sup_pid when is_pid(sup_pid) <- Process.whereis(sup),
         {_, pid, _, _} when is_pid(pid) <-
           sup_pid |> Supervisor.which_children() |> List.keyfind(id, 0) do
      "up"
    else
      nil -> if listener_configured?(sup), do: "down", else: "off"
      _ -> "down"
    end
  end

  # a supervisor that never started (its app is absent in this node) makes
  # the listener "off", not "down" — nothing is broken
  defp listener_configured?(sup), do: is_pid(Process.whereis(sup))

  defp listener_address("rpc") do
    Application.get_env(:compos_rpc, :socket_path, Path.join(Compos.Core.home(), "sock"))
    |> Path.expand()
  end

  defp listener_address("http"), do: :persistent_term.get(:compos_editor_url, "")

  defp listener_address("app") do
    case Application.get_env(:compos_ui, :app_port) do
      nil -> ""
      port -> "http://127.0.0.1:#{port}"
    end
  end

  @doc "Save the desktop, respawn the daemon, and stop this VM. Returns :ok or an error tuple."
  def restart do
    if Compos.Core.project_dir(), do: restart_checkout(), else: restart_release()
  end

  # A release respawns its own executable, the one Burrito started it from.
  # Nothing else supervises it.
  defp restart_release do
    with {:ok, bin} <- release_bin(),
         :ok <- save_desktop(),
         :ok <- run_relauncher(release_respawn_script(bin, Compos.Core.home(), System.pid())) do
      schedule_stop()
      :ok
    end
  end

  defp release_bin do
    case System.get_env("__BURRITO_BIN_PATH") do
      bin when is_binary(bin) and bin != "" -> {:ok, bin}
      _ -> {:error, :no_release_executable}
    end
  end

  @doc """
  Install the release executable SRC at BIN, the path the stable compos runs from.
  Copies beside BIN and renames over it, so a running BIN is never half
  written. Prunes the unpacked releases of other builds next to the one this
  VM runs from. Returns :ok or an error tuple; restarting is the caller's.
  """
  def install_release(src, bin) do
    src = Path.expand(src)
    bin = Path.expand(bin)
    tmp = bin <> ".new"

    cond do
      not File.regular?(src) ->
        {:error, {:missing, src}}

      src == bin ->
        {:error, :same_file}

      true ->
        with :ok <- File.mkdir_p(Path.dirname(bin)),
             :ok <- File.cp(src, tmp),
             :ok <- File.chmod(tmp, 0o755),
             :ok <- File.rename(tmp, bin) do
          prune_unpacked_releases()
          :ok
        end
    end
  end

  # Burrito unpacks each build once, into a directory named for its version.
  # Keep the one this VM runs from; the next start unpacks the new build.
  defp prune_unpacked_releases do
    with root when is_binary(root) <- System.get_env("RELEASE_ROOT"),
         "1" <- System.get_env("__BURRITO") do
      parent = Path.dirname(root)

      for dir <- Path.wildcard(Path.join(parent, "compos_erts-*")), dir != root do
        File.rm_rf(dir)
      end
    end

    :ok
  end

  defp restart_checkout do
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
    case Compos.Core.Desktop.save_now() do
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

    # A test stub answers first. Then the switch: a test VM starts no
    # daemon of its own, so a visit of a file in a worktree checkout never
    # waits for one to boot.
    case Application.get_env(:compos_core, :workspace_daemon_provisioner) do
      fun when is_function(fun, 2) ->
        fun.(workspace, name)

      _ ->
        if Application.get_env(:compos_core, :workspace_daemons, true),
          do: provision_workspace!(workspace, name),
          else: {:error, :disabled}
    end
  end

  defp provision_workspace!(workspace, name) do
    with true <- File.dir?(workspace) || {:error, :missing_workspace},
         true <- File.exists?(Path.join(workspace, "mix.exs")) || {:error, :not_compos_checkout} do
      registry =
        Application.get_env(
          :compos_core,
          :daemon_registry_path,
          Path.expand("~/.compos/daemons.json")
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
          @raise_fd_limit <>
            "nohup env COMPOS_HOME=#{shq(home)} MIX_DEPS_PATH=#{shq(deps)} " <>
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
    run_relauncher(respawn_script(File.cwd!(), Compos.Core.home(), System.pid()))
  end

  defp run_relauncher(script) do
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
        @raise_fd_limit <>
        "exec env COMPOS_HOME=#{shq(home)} mix run --no-halt >> #{shq(log)} 2>&1"

    "nohup /bin/sh -c #{shq(relaunch)} </dev/null >/dev/null 2>&1 &"
  end

  # The new executable must not inherit this VM's release environment: Burrito
  # and the release scripts would take RELEASE_ROOT, an unpacked directory an
  # install may have pruned, as given.
  @doc false
  def release_respawn_script(bin, home, pid) do
    log = Path.join(home, "daemon.log")

    relaunch =
      "while kill -0 #{pid} 2>/dev/null; do sleep 0.1; done; " <>
        "unset $(env | awk -F= '/^(RELEASE_|__BURRITO|BINDIR=|ROOTDIR=|EMU=|PROGNAME=)/{print $1}'); " <>
        @raise_fd_limit <>
        "exec env COMPOS_HOME=#{shq(home)} #{shq(bin)} >> #{shq(log)} 2>&1"

    "nohup /bin/sh -c #{shq(relaunch)} </dev/null >/dev/null 2>&1 &"
  end

  defp shq(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"
end
