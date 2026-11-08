defmodule Compos.Core.SpawnDir do
  @moduledoc """
  The check before a process starts in a directory.

  A port with `cd:` set to a path that is not a directory does not fail in
  the caller. The VM's child setup prints "spawn: Could not cd to PATH" to
  the daemon's terminal, and the caller sees only an exit. `check/2` stops
  the spawn first and writes the path and the caller to *Messages*, so the
  caller that passed a file is named.
  """

  require Logger

  @doc """
  `nil` when DIR is nil or a directory. Otherwise the text that names WHERE
  and the path. It writes nothing: a caller that gives the error back to its
  own caller, as a Scheme primitive does, uses this and not `check/2`.
  """
  def problem(nil, _where), do: nil

  def problem(dir, where) do
    path = to_string(dir)

    cond do
      File.dir?(path) -> nil
      File.regular?(path) -> where <> ": cannot start a process in " <> path <> ": it is a file, not a directory"
      true -> where <> ": cannot start a process in " <> path <> ": it is not a directory"
    end
  end

  @doc """
  `:ok` when DIR is nil or a directory. Otherwise `{:error, text}`, and the
  text goes to *Messages* and to the log with WHERE, the caller's name.
  """
  def check(nil, _where), do: :ok

  def check(dir, where) do
    path = to_string(dir)

    if File.dir?(path) do
      :ok
    else
      what = if File.regular?(path), do: "is a file, not a directory", else: "is not a directory"
      text = "#{where}: cannot start a process in #{path}: it #{what}"
      Logger.warning(text)
      Compos.Core.Session.message(text, "error")
      {:error, text}
    end
  end
end
