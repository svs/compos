defmodule Compos.Core.TreeSitter do
  @moduledoc """
  Runtime grammar management — the compiled-in grammars (elixir, json,
  rust, html), the ones bundled as source under `priv/grammars`, and
  any the user installs from the app.

  `install/2` is Emacs's treesit-install-language-grammar: clone the
  grammar repo shallow, find its named grammar, and use `cc -shared` on
  its generated parser (and scanner.c when present). Store the library
  in `~/.compos/grammars/<name>.<dylib|so>`, copy
  `queries/highlights.scm` alongside, then dlopen it into the NIF's
  registry (`TS.ts_load_grammar/3`). Installed grammars reload at boot
  (`load_installed/0`, a Task in the supervision tree), so a grammar is a
  one-time install.

  Everything returns "ok" or an "error: ..." string — Scheme policy
  (packages/treesit.scm) turns those into echo messages.
  """

  require Logger

  alias Compos.Core.TS

  # A grammar is part of the reader's setup, not one daemon's state: it is
  # installed once and every daemon on every port reads the same shared
  # object. Keyed to the home instead, a second daemon reported no grammars
  # at all and quietly fell back to the renderer that has none.
  def grammars_dir, do: Path.join(Compos.Core.config_dir(), "grammars")

  def lib_ext do
    case :os.type() do
      {:unix, :darwin} -> ".dylib"
      _ -> ".so"
    end
  end

  @doc "Names with a compiled library present in the grammars dir."
  def installed do
    grammars_dir()
    |> Path.join("*" <> lib_ext())
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.basename() |> String.replace_suffix(lib_ext(), "")))
    |> Enum.sort()
  end

  # Grammars the editor ships with. A Linux release also carries compiled
  # libraries, so the machine that runs it does not need a C compiler.
  def bundled_dir, do: Application.app_dir(:compos_core, "priv/grammars")

  def bundled, do: bundled_dirs() |> Enum.map(&Path.basename/1) |> Enum.sort()

  defp bundled_dirs do
    bundled_dir()
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&File.exists?(Path.join([&1, "src", "parser.c"])))
  end

  @doc "Compile any bundled grammar whose sources moved, then load them all."
  def load_bundled do
    names =
      for src <- bundled_dirs(), reduce: [] do
        acc ->
          name = Path.basename(src)

          case build_bundled(name, src) do
            "ok" ->
              [name | acc]

            err ->
              Logger.warning("grammar #{name}: #{err}")
              acc
          end
      end

    load_names(names, " (bundled)")
  end

  defp load_names(names, note) do
    for name <- names do
      case load(name) do
        "ok" -> Logger.info("grammar loaded: #{name}#{note}")
        err -> Logger.warning("grammar #{name}: #{err}")
      end
    end

    names
  end

  # Rebuild only when a source moved. A boot that changed nothing
  # costs one stat per file, not one cc per grammar.
  defp build_bundled(name, src) do
    lib = Path.join(grammars_dir(), name <> lib_ext())
    query = Path.join(grammars_dir(), name <> "-highlights.scm")
    sources = Path.wildcard(Path.join([src, "src", "*.c"]))
    highlights = Path.join([src, "queries", "highlights.scm"])

    if stale?(lib, sources) or stale?(query, [highlights]) do
      File.mkdir_p!(grammars_dir())

      with "ok" <- install_bundled(name, src, sources), do: copy_highlights(name, src)
    else
      "ok"
    end
  end

  defp install_bundled(name, src, sources) do
    prebuilt =
      if :os.type() == {:unix, :linux} and
           String.starts_with?(to_string(:erlang.system_info(:system_architecture)), "x86_64") do
        Path.join([src, "prebuilt", "linux_x86_64", "#{name}.so"])
      end

    if prebuilt && File.exists?(prebuilt) && not stale?(prebuilt, sources) do
      File.cp!(prebuilt, Path.join(grammars_dir(), name <> lib_ext()))
      "ok"
    else
      compile(name, src)
    end
  end

  defp stale?(built, sources) do
    case File.stat(built, time: :posix) do
      {:ok, %{mtime: at}} -> Enum.any?(sources, &newer_than?(&1, at))
      _ -> true
    end
  end

  defp newer_than?(path, at) do
    match?({:ok, %{mtime: m}} when m > at, File.stat(path, time: :posix))
  end

  @doc "Register every installed grammar the bundle does not own."
  def load_installed, do: load_names(installed() -- bundled(), "")

  @doc "Register one installed grammar with the NIF."
  def load(name) do
    lib = Path.join(grammars_dir(), name <> lib_ext())
    query = Path.join(grammars_dir(), name <> "-highlights.scm")

    cond do
      not File.exists?(lib) -> "error: not installed: #{name}"
      not File.exists?(query) -> "error: missing #{name}-highlights.scm"
      true -> TS.ts_load_grammar(name, lib, File.read!(query))
    end
  end

  @doc """
  Clone, compile, and load a grammar. Slow — run in a Task.

  A local directory is taken as the checkout itself, so a grammar
  being written is installed from where it is written.
  """
  def install(name, repo_url) do
    # A pasted URL brings its whitespace with it, and git reads everything
    # before "://" as the protocol: one leading space answers
    # "protocol ' https' is not supported", which names neither the space
    # nor the paste.
    name = String.trim(name)
    repo_url = String.trim(repo_url)

    File.mkdir_p!(grammars_dir())

    if File.dir?(repo_url) do
      with "ok" <- compile(name, repo_url),
           "ok" <- copy_highlights(name, repo_url) do
        load(name)
      end
    else
      src = Path.join([grammars_dir(), "src", name])
      File.rm_rf(src)

      with "ok" <- clone(repo_url, src),
           "ok" <- compile(name, src),
           "ok" <- copy_highlights(name, src) do
        load(name)
      end
    end
  end

  defp clone(url, dest) do
    case System.cmd("git", ["clone", "--depth", "1", url, dest], stderr_to_stdout: true) do
      {_, 0} -> "ok"
      {out, _} -> "error: git clone: #{String.slice(out, 0, 300)}"
    end
  end

  defp compile(name, src) do
    csrc = Path.join(grammar_root(name, src), "src")
    parser = Path.join(csrc, "parser.c")
    scanner = Path.join(csrc, "scanner.c")
    out = Path.join(grammars_dir(), name <> lib_ext())

    cond do
      not File.exists?(parser) ->
        "error: no src/parser.c — not a generated tree-sitter grammar repo"

      File.exists?(Path.join(csrc, "scanner.cc")) ->
        "error: C++ scanner not supported yet"

      true ->
        sources = [parser | if(File.exists?(scanner), do: [scanner], else: [])]
        args = ["-fPIC", "-shared", "-O2", "-I", csrc] ++ sources ++ ["-o", out]

        case System.cmd("cc", args, stderr_to_stdout: true) do
          {_, 0} -> "ok"
          {err, _} -> "error: cc: #{String.slice(err, 0, 300)}"
        end
    end
  end

  defp copy_highlights(name, src) do
    q = Path.join([grammar_root(name, src), "queries", "highlights.scm"])

    if File.exists?(q) do
      File.cp!(q, Path.join(grammars_dir(), name <> "-highlights.scm"))
      "ok"
    else
      "error: repo has no queries/highlights.scm"
    end
  end

  # Most repositories contain one grammar at the root. Some repositories,
  # such as Markdown, contain named grammar directories in one checkout.
  defp grammar_root(name, src) do
    [src, Path.join(src, "tree-sitter-#{name}"), Path.join(src, name)]
    |> Enum.find(src, &File.exists?(Path.join([&1, "src", "parser.c"])))
  end
end
