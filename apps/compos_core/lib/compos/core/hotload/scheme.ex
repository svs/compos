defmodule Compos.Core.Hotload.Scheme do
  @moduledoc """
  The Scheme half of a hot reload: which forms of a saved file changed
  against the boot manifest, the evaluation of those forms with the
  reload hooks around them, and the stamps a file carries. Hotload decides
  when; Session owns the interpreter this runs against.
  """

  require Logger

  alias Compos.Core.Session
  alias Compos.Scheme
  alias Compos.Scheme.Reader

  # the stamps a file sets while it loads: a form that sets one re-runs on
  # every reload of its file, so later forms see the stamps they were
  # written under
  @reload_context ~w(origin! package! namespace! category! domain! effects!)

  # The stamp is its own eval, so a package's own line numbers stay its own.
  def stamp_load_unit(interp, path, origin) do
    code = "(origin! '#{origin}) (package! '#{Path.basename(path, ".scm")})"

    case Scheme.eval_string(interp, code) do
      {:ok, _, interp2} -> interp2
      {:error, _} -> interp
    end
  end

  def changes(paths, manifest) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      expanded = Session.canonical(path)

      try do
        with {:ok, src} <- File.read(expanded) do
          forms = Reader.read_all(src)
          fingerprints = form_fingerprints(forms)

          changed =
            case Map.fetch(manifest, expanded) do
              {:ok, previous} ->
                package_changed? = fingerprints != previous

                Enum.filter(forms, fn form ->
                  reload_context?(form) or not MapSet.member?(previous, form_fingerprint(form)) or
                    (package_changed? and reload_registration?(form))
                end)

              :error ->
                forms
            end

          {:cont, {:ok, [{expanded, fingerprints, changed} | acc]}}
        else
          {:error, reason} -> {:halt, {:error, "#{expanded}: #{inspect(reason)}"}}
        end
      rescue
        error -> {:halt, {:error, "#{expanded}: #{Exception.message(error)}"}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      error -> error
    end
  end

  # A reload is bracketed by two Scheme hooks. `reload-begin!` opens the
  # record; every `define-mode` and `register-minor-mode!` the reload
  # evaluates names itself in it. `reload-finish!` re-runs mode setup on
  # the buffers that wear one of those modes, so a mode change reaches the
  # buffers already open in it. Without that, a reloaded mode holds the old
  # keys and overlays until a restart, which is the reason a restart was
  # ever needed for a mode change.
  #
  # The hooks run inside the same `Scheme.exec` as the forms, so they see
  # exactly the definitions this reload made. Both are guarded by `boundp`:
  # a reload of `editor.scm` itself starts before either name exists.
  @reload_begin "(if (boundp (quote reload-begin!)) (reload-begin!))"
  @reload_finish "(if (boundp (quote reload-finish!)) (reload-finish!))"

  def eval(files) do
    Scheme.exec(Session.interp(), fn interp ->
      interp = eval_hook(interp, @reload_begin)

      case reduce_reload_files(files, interp) do
        {:ok, value, interp} ->
          {:ok, value, eval_hook(interp, @reload_finish)}

        # The finish hook runs after a failed reload too: the forms that did
        # evaluate can already have redefined a mode, and the record must
        # not carry those names into the next reload.
        {:error, message, interp} ->
          eval_hook(interp, @reload_finish)
          {:error, message}
      end
    end)
  end

  defp reduce_reload_files(files, interp) do
    Enum.reduce_while(files, {:ok, nil, interp}, fn {path, _fingerprints, forms},
                                                    {:ok, _, current} ->
      if unloaded_library?(current, path) do
        {:cont, {:ok, nil, current}}
      else
        current = stamp_load_unit(current, path, reload_origin(path))

        case Scheme.eval_forms(current, forms) do
          {:ok, value, next} -> {:cont, {:ok, value, next}}
          {:error, message} -> {:halt, {:error, message, current}}
        end
      end
    end)
  end

  # A package on the load path that this session has not loaded yet: an
  # autoload stub stands for it, and its first use loads the saved file
  # whole. Replaying its changed forms alone would run a registration
  # against definitions that were never evaluated.
  defp unloaded_library?(interp, path) do
    if path in library_paths() do
      feature = Path.basename(path, ".scm")

      case Scheme.eval_string(interp, "(featurep '#{feature})") do
        {:ok, false, _} -> true
        _ -> false
      end
    else
      false
    end
  end

  defp library_paths do
    home = Session.canonical(Compos.Core.config_dir())

    (project_source_paths() ++ Path.wildcard(Path.join([home, "packages", "**/*.scm"])))
    |> Enum.map(&Session.canonical/1)
  end

  defp eval_hook(interp, src) do
    case Scheme.eval_string(interp, src) do
      {:ok, _, interp2} ->
        interp2

      {:error, message} ->
        Logger.error("reload hook failed: #{message}")
        interp
    end
  end

  defp reload_context?([{:sym, name} | _]), do: name in @reload_context
  defp reload_context?(_), do: false

  # A list registration captures its options by value. Updating the options
  # definition alone leaves the live mode on its old callbacks/settings even
  # though the registration's own source is unchanged. Replay registrations
  # in source order when their package changes, without resetting other state.
  defp reload_registration?([{:sym, "define-list-mode!"} | _]), do: true
  defp reload_registration?(_), do: false

  defp form_fingerprints(forms), do: MapSet.new(forms, &form_fingerprint/1)
  defp form_fingerprint(form), do: :crypto.hash(:sha256, :erlang.term_to_binary(form))

  defp reload_origin(path) do
    user_packages = Path.join(Compos.Core.config_dir(), "packages") |> Session.canonical()

    if String.starts_with?(Session.canonical(path), user_packages <> "/"),
      do: :user,
      else: :bundled
  end

  def manifest do
    source_paths()
    |> Enum.reduce(%{}, fn path, acc ->
      case File.read(path) do
        {:ok, src} ->
          try do
            Map.put(acc, Path.expand(path), form_fingerprints(Reader.read_all(src)))
          rescue
            _ -> acc
          end

        _ ->
          acc
      end
    end)
  end

  # Every file the session evaluates, not only the bundled ones. A file the
  # manifest does not name re-evaluates ALL of its forms on the first save,
  # because changes/2 cannot tell an edited form from an untouched one
  # without a baseline. The config home loads at boot like priv does, so it
  # needs the same baseline.
  def source_paths do
    priv = Session.canonical(Application.app_dir(:compos_core, "priv"))

    Enum.map(Session.bootstrap_files(), &Path.join(priv, &1)) ++
      project_source_paths() ++ config_source_paths()
  end

  # The packages at the project root, `scheme/`, the second entry of the
  # Scheme `load-path`. A release has no project root.
  defp project_source_paths do
    case Compos.Core.project_dir() do
      nil -> []
      root ->
        Path.join([root, "scheme", "**/*.scm"])
        |> Path.wildcard()
        |> Enum.reject(&String.ends_with?(&1, "-test.scm"))
    end
  end

  defp config_source_paths do
    home = Session.canonical(Compos.Core.config_dir())

    Enum.map(Session.user_config_files(), &Path.join(home, &1)) ++
      Path.wildcard(Path.join([home, "packages", "**/*.scm"]))
  end
end
