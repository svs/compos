defmodule Aimax.Core.TreeSitter do
  @moduledoc """
  Runtime grammar management — the compiled-in grammars (elixir, json,
  rust, html) plus any the user installs from the app.

  `install/2` is Emacs's treesit-install-language-grammar: clone the
  grammar repo shallow, find its named grammar, and use `cc -shared` on
  its generated parser (and scanner.c when present). Store the library
  in `~/.aimax/grammars/<name>.<dylib|so>`, copy
  `queries/highlights.scm` alongside, then dlopen it into the NIF's
  registry (`TS.ts_load_grammar/3`). Installed grammars reload at boot
  (`load_installed/0`, a Task in the supervision tree), so a grammar is a
  one-time install.

  Everything returns "ok" or an "error: ..." string — Scheme policy
  (packages/treesit.scm) turns those into echo messages.
  """

  require Logger

  alias Aimax.Core.TS

  # A grammar is part of the reader's setup, not one daemon's state: it is
  # installed once and every daemon on every port reads the same shared
  # object. Keyed to the home instead, a second daemon reported no grammars
  # at all and quietly fell back to the renderer that has none.
  def grammars_dir, do: Path.join(Aimax.Core.config_dir(), "grammars")

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
    # A pasted URL brings its whitespace with it, and git reads everything
    # before "://" as the protocol: one leading space answers
    # "protocol ' https' is not supported", which names neither the space
    # nor the paste.
    name = String.trim(name)
    repo_url = String.trim(repo_url)

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
