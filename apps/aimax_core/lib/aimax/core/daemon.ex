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
    case Aimax.Core.Desktop.save_now() do
      :ok ->
        with :ok <- respawn() do
          schedule_stop()
          :ok
        end

      :error ->
        {:error, :desktop_save_failed}
    end
  end

  # `setsid` puts the relauncher in its own session, so closing this VM does
  # not take it down with us. The wait loop keys on this BEAM's OS pid: the
  # new daemon starts only after this one is gone, so the port and socket are
  # free. The outer shell backgrounds the relauncher and returns at once, so
  # `System.cmd` does not wait for the new daemon to boot.
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

    "setsid sh -c 'while kill -0 #{pid} 2>/dev/null; do sleep 0.1; done; " <>
      "cd #{shq(root)}; nohup mix run --no-halt >> #{shq(log)} 2>&1 </dev/null &' " <>
      "</dev/null >/dev/null 2>&1 &"
  end

  defp shq(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"
end
