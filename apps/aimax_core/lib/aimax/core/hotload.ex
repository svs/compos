defmodule Aimax.Core.Hotload do
  @moduledoc """
  Put a saved source change into the running daemon, without a restart.

  One filesystem watcher covers the project's Elixir and Scheme sources and
  the user's config home. A save arms a short debounce, and the burst then
  goes to the reloader that fits the file:

    * `.scm` reloads through `Aimax.Core.Session.reload_files/1`. That
      evaluates only the top-level forms whose text changed, then re-runs
      mode setup on the buffers that wear a mode the reload redefined.
    * `.ex` and `.heex` recompile through `Aimax.Core.Hotload.Compile`. A
      child `mix compile` writes the new beams; the VM then swaps in only
      the modules whose code changed, and it loads each new version before
      it purges the old one. A compile error changes nothing in the VM.

  Neither path stops the VM. Buffers, windows, processes, agents, and the
  Scheme store all survive, so the change reaches the editor with no
  restart and nothing lost.

  Three changes still need `M-x restart-daemon`, because nothing reloads
  them in place: a new dependency, a change to a supervision tree, and a
  NIF rebuild. Everything else is this module's job.

  Policy stays in Scheme. This module decides nothing about what a reload
  means; it names the changed files and calls the two reloaders.
  """

  use GenServer

  require Logger

  alias Aimax.Core.Hotload.Compile
  alias Aimax.Core.Session

  # 200 ms after the last event in a burst. One editor save is one burst,
  # and so is a formatter that rewrites nine files.
  @debounce_ms 200

  # ...but a long write stream must not hold the reload forever.
  @max_wait_ms 2_000

  @source_exts ~w(.scm .ex .heex)

  # The config home also holds this session's state, which the daemon writes
  # to constantly. None of it is source.
  #
  # `grammars` is the one that does not look like state: installing a
  # tree-sitter grammar drops <lang>-highlights.scm beside the shared
  # object, and a highlights query is Scheme only to look at. Reading one
  # as editor Scheme answers "unbound variable: [" for the query's
  # alternation, then "unbound variable: atx_heading" for a node name.
  @config_noise ~w(buffers chats worktree-daemons grammars)

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The watched roots, sorted."
  def roots(server \\ __MODULE__), do: GenServer.call(server, :roots)

  @doc """
  Reload PATHS now, as a save would. Returns a one-line report.

  This is the whole mechanism: the watcher only decides when to call it.
  """
  def reload(paths, server \\ __MODULE__), do: GenServer.call(server, {:reload, paths}, 120_000)

  @impl true
  def init(opts) do
    # a watcher backend that dies must not take this process with it
    Process.flag(:trap_exit, true)

    case opts[:roots] || default_roots() do
      [] ->
        :ignore

      roots ->
        state = %{roots: roots, pids: %{}, pending: MapSet.new(), timer: nil, burst_start: nil}
        {:ok, Enum.reduce(roots, state, &start_watch/2)}
    end
  end

  @impl true
  def handle_call(:roots, _from, state), do: {:reply, Enum.sort(state.roots), state}

  def handle_call({:reload, paths}, _from, state), do: {:reply, apply_changes(paths), state}

  @impl true
  def handle_info({:file_event, _pid, {path, _events}}, state) do
    if source?(path), do: {:noreply, arm(state, path)}, else: {:noreply, state}
  end

  def handle_info({:file_event, _pid, :stop}, state), do: {:noreply, state}

  def handle_info(:hotload_flush, state) do
    paths = state.pending |> MapSet.to_list() |> Enum.sort()
    report = apply_changes(paths)
    if report, do: announce(report)
    {:noreply, %{state | pending: MapSet.new(), timer: nil, burst_start: nil}}
  end

  # the backend went away: forget its root rather than die with it
  def handle_info({:EXIT, pid, reason}, state) do
    case state.pids[pid] do
      nil ->
        {:noreply, state}

      root ->
        if reason != :normal,
          do: Logger.warning("Aimax.Core.Hotload: the watcher for #{root} stopped")

        {:noreply, %{state | pids: Map.delete(state.pids, pid), roots: state.roots -- [root]}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- what to watch ---------------------------------------------------------

  # The seam: a test passes its own roots and drives :file_event itself, so
  # the filter and the debounce run without fsevents underneath.
  defp backend, do: Application.get_env(:aimax_core, :fs_backend, FileSystem)

  defp default_roots do
    if Application.get_env(:aimax_core, :hotload, false),
      do: project_roots() ++ config_roots(),
      else: []
  end

  # The daemon runs from the checkout, so the sources are under the working
  # directory. A release has no checkout and watches nothing here. Each
  # app's `lib` and this app's `priv` are named directly: `apps` as a whole
  # would also cover the Rust build directory, which writes thousands of
  # files per cargo run.
  defp project_roots do
    root = File.cwd!()

    if File.exists?(Path.join(root, "mix.exs")) do
      Enum.filter(
        Path.wildcard(Path.join(root, "apps/*/lib")) ++
          [Path.join(root, "apps/aimax_core/priv")],
        &File.dir?/1
      )
    else
      []
    end
  end

  # The user's own Scheme: init.scm, ai-config.scm, custom.scm, and
  # ~/.aimax/packages. Editing config in the editor applies it on save.
  defp config_roots do
    dir = Aimax.Core.config_dir()
    if File.dir?(dir), do: [dir], else: []
  end

  defp start_watch(root, state) do
    case backend().start_link(dirs: [root]) do
      {:ok, pid} ->
        backend().subscribe(pid)
        %{state | pids: Map.put(state.pids, pid, root)}

      {:error, reason} ->
        Logger.warning("Aimax.Core.Hotload: cannot watch #{root}: #{inspect(reason)}")
        %{state | roots: state.roots -- [root]}
    end
  end

  # --- the filter ------------------------------------------------------------

  @doc false
  def source?(path) do
    base = Path.basename(path)

    Path.extname(path) in @source_exts and
      not String.starts_with?(base, ".") and
      # an editor's own scratch file is not a save: Emacs writes `.#name`
      # and `name~`, and a partial write is not compilable Elixir
      not String.ends_with?(base, "~") and
      not String.starts_with?(base, "#") and
      not noisy?(path)
  end

  defp noisy?(path) do
    parts = Path.split(path)

    Enum.any?(~w(_build deps node_modules target .git), &(&1 in parts)) or
      Enum.any?(@config_noise, &(&1 in parts))
  end

  # --- the debounce ----------------------------------------------------------

  defp arm(state, path) do
    if state.timer, do: Process.cancel_timer(state.timer)
    start = state.burst_start || now()
    wait = min(@debounce_ms, max(0, start + @max_wait_ms - now()))

    %{
      state
      | pending: MapSet.put(state.pending, path),
        burst_start: start,
        timer: Process.send_after(self(), :hotload_flush, wait)
    }
  end

  defp now, do: System.monotonic_time(:millisecond)

  # --- the reloaders ---------------------------------------------------------

  # Elixir first: a Scheme package can call a primitive the same save added,
  # so the module must be loaded before the form that uses it runs.
  defp apply_changes([]), do: nil

  defp apply_changes(paths) do
    {scheme, elixir} = Enum.split_with(paths, &(Path.extname(&1) == ".scm"))

    [recompile(elixir), reload_scheme(scheme)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> case do
      "" -> nil
      report -> report
    end
  end

  # The compiler is configuration, not a call, so a test can name a stub.
  # config.exs names `{Aimax.Core.Hotload.Compile, :compile, []}` for dev:
  # an MFA that writes new beams and answers :ok or {:error, text}. It must
  # not touch the loaded code. The swap after it is the only step that does,
  # and it never leaves a module missing. Never compile in this VM: an
  # in-process `mix compile` unloads a stale module before it compiles the
  # new one, and a compile error then leaves that module gone.
  defp recompile([]), do: nil

  defp recompile(_paths) do
    case Application.get_env(:aimax_core, :hotload_recompile) do
      {m, f, a} ->
        case apply(m, f, a) do
          :ok ->
            %{reloaded: reloaded, removed: removed} = Compile.swap(Compile.ebins())
            # A swap replaces the module version the Scheme primitives were
            # captured from. Rebind them before anything evaluates, or the
            # next keystroke raises "function #Function<...> is invalid".
            refresh_primitives()

            case length(reloaded) + length(removed) do
              0 -> "recompiled, no module changed"
              n -> "#{count(n, "module")} recompiled"
            end

          {:error, output} ->
            Logger.error("Aimax.Core.Hotload: compile failed\n#{output}")
            "compile failed: #{first_error(output)}"

          other ->
            "compile failed: #{short(other)}"
        end

      _ ->
        nil
    end
  rescue
    e -> "compile failed: #{Exception.message(e)}"
  end

  defp refresh_primitives do
    if Session.ready?(), do: Session.refresh_primitives()
  rescue
    e -> Logger.error("Aimax.Core.Hotload: rebinding primitives failed: #{Exception.message(e)}")
  catch
    :exit, _ -> :ok
  end

  defp reload_scheme([]), do: nil

  defp reload_scheme(paths) do
    if Session.ready?() do
      case Session.reload_files(paths) do
        {:ok, %{files: files, forms: forms}} ->
          "#{count(files, "file")}, #{count(forms, "form")} reloaded"

        {:error, reason} ->
          Logger.error("Aimax.Core.Hotload: reload failed: #{inspect(reason)}")
          "reload failed: #{short(reason)}"
      end
    end
  rescue
    e -> "reload failed: #{Exception.message(e)}"
  catch
    :exit, _ -> "reload failed: the session did not answer"
  end

  # The echo area and *Messages*, the same report a command gives. Scheme
  # owns the display; this passes the text as a value, never as source.
  defp announce(report) do
    if Session.ready?(), do: Session.call_named("message", [report])
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp count(n, noun) when is_integer(n), do: "#{n} #{noun}#{if n == 1, do: "", else: "s"}"
  defp count(list, noun) when is_list(list), do: count(length(list), noun)

  defp first_error(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.find(&String.contains?(&1, "error"))
    |> case do
      nil -> short(output)
      line -> short(line)
    end
  end

  defp first_error(other), do: short(other)

  defp short(text) when is_binary(text), do: text |> String.trim() |> String.slice(0, 160)
  defp short(other), do: other |> inspect() |> String.slice(0, 160)
end
