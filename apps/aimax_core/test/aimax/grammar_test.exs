defmodule Aimax.GrammarTest do
  @moduledoc """
  The NIF and the install plumbing.

  Which grammar a mode declares, and what the install surface offers, are
  Scheme policy and live in priv/tests/treesit-test.scm. These tests stay
  because they call the Rust side directly: a library that will not load,
  a repository that is not a grammar, and the scopes a highlight answers
  with.
  """

  use ExUnit.Case

  alias Aimax.Core.{TreeSitter, TS}

  test "ts_load_grammar reports failures instead of crashing" do
    assert TS.ts_load_grammar("zz", "/no/such/lib.dylib", "(comment) @comment") =~ "error: open"

    # a real dylib without the tree_sitter_<name> symbol
    [libm | _] =
      Path.wildcard("/usr/lib/libSystem*.dylib") ++ ["/usr/lib/libSystem.B.dylib"]

    assert TS.ts_load_grammar("zz", libm, "(comment) @comment") =~ "error: no symbol"
  end

  test "load/1 wants both the library and the query file" do
    assert TreeSitter.load("zz-none") =~ "error: not installed"
  end

  test "install rejects repos that are not generated grammars" do
    tmp = Path.join(System.tmp_dir!(), "zz-fake-grammar-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, ".git"))
    File.write!(Path.join(tmp, "README"), "not a grammar")

    # file:// clone of a repo lacking src/parser.c
    {_, 0} = System.cmd("git", ["init", "-q", tmp])
    {_, 0} = System.cmd("git", ["-C", tmp, "add", "-A"])

    {_, 0} = System.cmd("git", ["-C", tmp, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "x"])

    assert TreeSitter.install("zz-fake", "file://#{tmp}") =~ "error: no src/parser.c"
    File.rm_rf!(tmp)
  end

  test "the html grammar is compiled in, and answers with its scopes" do
    spans = TS.ts_highlight("html", ~s|<body class="x"><!-- c --></body>|)
    scopes = spans |> Enum.map(&elem(&1, 2)) |> Enum.uniq() |> Enum.sort()
    assert "tag" in scopes
    assert "attribute" in scopes
    assert "string" in scopes
    assert "comment" in scopes
  end
end
