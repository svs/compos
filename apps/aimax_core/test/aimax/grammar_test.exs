defmodule Aimax.GrammarTest do
  @moduledoc "Runtime grammar loading: NIF registry, install plumbing, mode wiring."

  use ExUnit.Case

  alias Aimax.Core.{Session, TreeSitter, TS}

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

  test "scheme-mode wires ts-lang for .scm buffers" do
    on_exit(fn -> Aimax.Core.kill_buffer("*zz-scm*") end)

    {:ok, _} =
      Session.eval(~s{(begin (buffer-create "*zz-scm*")
                             (switch-to-buffer! "*zz-scm*")
                             (set-mode! "scheme-mode")
                             (buffer-local "*zz-scm*" 'ts-lang))})

    assert {:ok, ~s{"scheme"}} = Session.eval(~s{(buffer-local "*zz-scm*" 'ts-lang)})
  end

  test "html-mode wires ts-lang, and the html grammar is compiled in" do
    on_exit(fn -> Aimax.Core.kill_buffer("*zz-html*") end)

    {:ok, _} =
      Session.eval(~s{(begin (buffer-create "*zz-html*")
                             (switch-to-buffer! "*zz-html*")
                             (set-mode! "html-mode"))})

    assert {:ok, ~s{"html"}} = Session.eval(~s{(buffer-local "*zz-html*" 'ts-lang)})

    spans = TS.ts_highlight("html", ~s|<body class="x"><!-- c --></body>|)
    scopes = spans |> Enum.map(&elem(&1, 2)) |> Enum.uniq() |> Enum.sort()
    assert "tag" in scopes
    assert "attribute" in scopes
    assert "string" in scopes
    assert "comment" in scopes
  end

  test "the install command surface is registered" do
    {:ok, out} = Session.eval("(ts-known-url \"scheme\")")
    assert out =~ "6cdh/tree-sitter-scheme"
    {:ok, markdown} = Session.eval("(ts-known-url \"markdown\")")
    assert markdown =~ "tree-sitter-grammars/tree-sitter-markdown"
    {:ok, langs} = Session.eval("(ts-langs)")
    assert langs =~ "elixir"
  end
end
