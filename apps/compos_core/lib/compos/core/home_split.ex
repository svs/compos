defmodule Compos.Core.HomeSplit do
  @moduledoc """
  The compos home holds the user's data only, so it can be synced and
  backed up as it is: the todo files, the groups, the packages, the
  skills, init.scm, custom.scm, the secrets, the chats.

  The rest has a place of its own. State, which the daemon must keep but
  nobody syncs, is in `Compos.Core.state_dir/0`. What compos can build
  again is in `Compos.Core.cache_dir/0`, or in
  `Compos.Core.machine_cache_dir/0` when every daemon on the machine
  shares it.

  `run/0` runs once at boot, before anything opens a file. It fixes the
  state folder and moves what an older compos left in the home to its
  place. An entry that is already at its place stays where it was, and
  the log says so.
  """

  require Logger

  # what a daemon must keep and never syncs
  @state ~w(buffers buffers-quarantine docs desktop.etf desktop.etf.bak desktop-backups
            events.db events.db-wal events.db-shm meta.db meta.db-wal meta.db-shm
            provenance.sqlite3 peer-id daemons.json llm-usage.jsonl agent-listeners.scd
            web-history web-visited welcome-seen site-app-tabs.json linear-last-seen
            transient-values.scm pdf-edit-undo fast-code-trace.jsonl fast-code-log.jsonl)

  # logs and pid files, by their ending
  @state_suffixes ~w(.log .pid)

  # what this daemon builds again
  @cache ~w(models needle model-catalog.scm llmdb.json llm-connector-tests.scm
            tool-results tmp chrome-profile codex-home dsh-home mermaid skills-view
            pdf-cache web-etags browse-files)

  # what every daemon on the machine builds once and shares
  @machine_cache ~w(grammars llm_db)

  # the sockets of the daemon that ran before: this one binds its own
  @stale ~w(sock sock-mcp)

  @doc "Fix the state folder and move what the home holds that is not data."
  def run do
    unless Application.get_env(:compos_core, :state_dir),
      do: Application.put_env(:compos_core, :state_dir, Compos.Core.default_state_dir())

    home = Path.expand(Compos.Core.home())

    if Path.expand(Compos.Core.state_dir()) != home do
      Enum.each(moves(home), &move/1)
      Enum.each(@stale, &File.rm(Path.join(home, &1)))
    end

    :ok
  end

  @doc "Every `{from, to}` move HOME needs, from the names it holds now."
  def moves(home) do
    case File.ls(home) do
      {:ok, names} ->
        for name <- Enum.sort(names), dir = place(name), do: {Path.join(home, name), Path.join(dir, name)}

      _ ->
        []
    end
  end

  @doc "The folder NAME belongs in, or nil when it is data and stays in the home."
  def place(name) do
    cond do
      name in @state -> Compos.Core.state_dir()
      String.ends_with?(name, @state_suffixes) -> Compos.Core.state_dir()
      name in @cache -> Compos.Core.cache_dir()
      name in @machine_cache -> Compos.Core.machine_cache_dir()
      true -> nil
    end
  end

  defp move({from, to}) do
    if File.exists?(to) do
      Logger.warning("home split: #{to} is there already, so #{from} stays")
    else
      File.mkdir_p!(Path.dirname(to))

      case File.rename(from, to) do
        :ok ->
          Logger.info("home split: moved #{from} to #{to}")

        # another disk: copy, then remove the original only when the copy is whole
        {:error, :exdev} ->
          with {:ok, _} <- File.cp_r(from, to),
               {:ok, _} <- File.rm_rf(from) do
            Logger.info("home split: copied #{from} to #{to}")
          else
            error -> Logger.error("home split: could not move #{from}: #{inspect(error)}")
          end

        {:error, why} ->
          Logger.error("home split: could not move #{from}: #{why}")
      end
    end
  end
end
