defmodule Aimax.Core.Hotload.Compile do
  @moduledoc """
  Recompile Elixir for the running daemon without a gap in the loaded code.

  An in-process `mix compile` deletes the beam of every stale module and
  unloads the module before it compiles the new source. While the compile
  runs, and forever if the compile fails, a call to that module raises
  "module is not available". `Aimax.Core.Editor` died that way twice on
  2026-08-29, and the core supervisor gave up after the restarts.

  This module keeps the two steps apart:

    * `compile/0` runs `mix compile` in a child OS process. It writes the
      new beams to the same `_build`, under Mix's build lock. The running
      VM keeps every module it has. A compile error changes nothing here.
    * `swap/1` compares each beam on disk with the module the VM has
      loaded. For a module whose code changed it loads the new beam first
      and purges the old version after. A caller always finds a current
      version. A beam that is gone unloads its module.
  """

  require Logger

  @doc "Compile the project in a child OS process. Returns :ok or {:error, output}."
  @spec compile() :: :ok | {:error, String.t()}
  def compile do
    env = if Code.ensure_loaded?(Mix), do: to_string(Mix.env()), else: "dev"

    case System.cmd("mix", ["compile", "--no-all-warnings"],
           cd: File.cwd!(),
           stderr_to_stdout: true,
           env: [{"MIX_ENV", env}]
         ) do
      {_out, 0} -> :ok
      {out, _code} -> {:error, out}
    end
  rescue
    e -> {:error, "could not run mix compile: #{Exception.message(e)}"}
  end

  @doc """
  The ebin directories the project compiles into: one per umbrella app, and
  the consolidated protocols. Only these can change on a recompile.
  """
  @spec ebins() :: [String.t()]
  def ebins do
    if Code.ensure_loaded?(Mix.Project) and Mix.Project.get() != nil do
      build = Mix.Project.build_path()

      apps =
        case Mix.Project.apps_paths() do
          nil -> [Mix.Project.config()[:app]]
          paths -> Map.keys(paths)
        end

      [Path.join(build, "consolidated") | Enum.map(apps, &Path.join([build, "lib", to_string(&1), "ebin"]))]
      |> Enum.filter(&File.dir?/1)
    else
      []
    end
  end

  @doc """
  Put the beams under `ebins` into the VM. Returns the modules it reloaded
  and the modules it unloaded because their beam is gone.

  A module the VM never loaded needs nothing: the first call loads the new
  beam. A loaded module whose beam has the same code md5 is left alone.
  """
  @spec swap([String.t()]) :: %{reloaded: [module()], removed: [module()]}
  def swap(ebins) do
    ebins = Enum.map(ebins, &Path.expand/1)

    reloaded =
      for ebin <- ebins, {mod, file} <- changed_in(ebin), reload(mod, file) == :ok, do: mod

    removed = for ebin <- ebins, mod <- removed_from(ebin), unload(mod) == :ok, do: mod

    %{reloaded: reloaded, removed: removed}
  end

  defp changed_in(ebin) do
    for file <- Path.wildcard(Path.join(ebin, "*.beam")),
        mod = module_of(file),
        loaded?(mod),
        {:ok, {^mod, md5}} <- [:beam_lib.md5(String.to_charlist(file))],
        md5 != mod.module_info(:md5),
        do: {mod, file}
  end

  defp removed_from(ebin) do
    for {mod, path} <- :code.all_loaded(),
        is_list(path),
        path = to_string(path),
        Path.dirname(path) == ebin,
        not File.exists?(path),
        do: mod
  end

  # Load first, purge after: between the two a call reaches one version or
  # the other, never nothing. `:code.purge` before the load removes a
  # version an earlier swap left behind; the VM refuses a third version.
  defp reload(mod, file) do
    if :code.purge(mod),
      do: Logger.warning("Aimax.Core.Hotload: killed processes still running an old #{inspect(mod)}")

    case :code.load_abs(String.to_charlist(Path.rootname(file))) do
      {:module, ^mod} ->
        :code.soft_purge(mod)
        :ok

      {:error, reason} ->
        Logger.error("Aimax.Core.Hotload: could not load #{inspect(mod)}: #{inspect(reason)}")
        :error
    end
  end

  defp unload(mod) do
    :code.purge(mod)
    :code.delete(mod)
    :ok
  end

  defp module_of(file), do: file |> Path.basename(".beam") |> String.to_atom()

  defp loaded?(mod), do: :code.is_loaded(mod) != false
end
