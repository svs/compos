defmodule Aimax.Core.TreeSitter do
  @moduledoc """
  Runtime grammar management — the compiled-in grammars (elixir, json,
  rust, html) plus any the user installs from the app.

  `install/2` is Emacs's treesit-install-language-grammar: clone the
  grammar repo shallow, `cc -shared` its generated parser (and scanner.c
  when present) into `~/.aimax/grammars/<name>.<dylib|so>`, copy
  `queries/highlights.scm` alongside, then dlopen it into the NIF's
  registry (`TS.ts_load_grammar/3`). Installed grammars reload at boot
  (`load_installed/0`, a Task in the supervision tree), so a grammar is a
  one-time install.

  Everything returns "ok" or an "error: ..." string — Scheme policy
  (packages/treesit.scm) turns those into echo messages.
  """

  require Logger

  alias Aimax.Core.TS

  def grammars_dir, do: Path.join(Aimax.Core.home(), "grammars")

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

  @doc "Register every installed grammar with the NIF (boot path)."
  def load_installed do
    for name <- installed() do
      case load(name) do
        "ok" -> Logger.info("grammar loaded: #{name}")
        err -> Logger.warning("grammar #{name}: #{err}")
      end
    end

    :ok
  end

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

  @doc "Clone, compile, and load a grammar. Slow — run in a Task."
  def install(name, repo_url) do
    File.mkdir_p!(grammars_dir())
    src = Path.join([grammars_dir(), "src", name])
    File.rm_rf(src)

    with "ok" <- clone(repo_url, src),
         "ok" <- compile(name, src),
         "ok" <- copy_highlights(name, src) do
      load(name)
    end
  end

  defp clone(url, dest) do
    case System.cmd("git", ["clone", "--depth", "1", url, dest], stderr_to_stdout: true) do
      {_, 0} -> "ok"
      {out, _} -> "error: git clone: #{String.slice(out, 0, 300)}"
    end
  end

  defp compile(name, src) do
    csrc = Path.join(src, "src")
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
    q = Path.join([src, "queries", "highlights.scm"])

    if File.exists?(q) do
      File.cp!(q, Path.join(grammars_dir(), name <> "-highlights.scm"))
      "ok"
    else
      "error: repo has no queries/highlights.scm"
    end
  end
end
