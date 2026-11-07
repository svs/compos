defmodule Compos.TestRun do
  @moduledoc """
  The files of one test run.

  config/config.exs gives each test run its own home, RPC socket, desktop
  file and daemon registry. The suffix of each path ends in `-r` and the OS
  pid of the VM that started the run (COMPOS_TEST_RUN). That VM removes the
  files when it exits. A child VM that shares the run leaves them alone.

  A path without the `-r` part is from a run that started before the
  per-run suffix, and this module never touches it.
  """

  @prefixes ~w(compos-test-home- compos-rpc-test- compos-desktop-test- compos-daemons-test-)

  @doc "Remove the files of this run when the VM exits, if this VM started the run."
  def clean_at_exit do
    if owner?(), do: System.at_exit(fn _ -> Enum.each(paths(), &File.rm_rf/1) end)
    :ok
  end

  @doc "True when this VM started the run, and false in a child VM that shares it."
  def owner?, do: System.get_env("COMPOS_TEST_RUN") == System.pid()

  @doc "The files of this run: the configured paths that carry this run's suffix."
  def paths do
    mark = "-r" <> System.pid()

    [
      Application.get_env(:compos_core, :home),
      Application.get_env(:compos_rpc, :socket_path),
      # Compos.Rpc.McpServer listens beside the RPC socket
      with(s when is_binary(s) <- Application.get_env(:compos_rpc, :socket_path), do: s <> "-mcp"),
      Application.get_env(:compos_core, :desktop_path),
      Application.get_env(:compos_core, :daemon_registry_path)
    ]
    |> Enum.filter(&(is_binary(&1) and String.contains?(&1, mark)))
  end

  @doc """
  Remove the files of earlier runs whose VM is gone. A run killed with no
  exit hook leaves its files; a live run keeps them.
  """
  def sweep_dead do
    tmp = "/tmp"

    for name <- File.ls!(tmp),
        String.starts_with?(name, @prefixes),
        [_, pid] <- [Regex.run(~r/-r(\d+)(?:\.[\w-]+)?$/, name)],
        pid != System.pid(),
        not alive?(pid) do
      File.rm_rf(Path.join(tmp, name))
    end

    :ok
  end

  defp alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))
end
