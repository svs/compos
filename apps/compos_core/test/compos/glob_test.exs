defmodule Compos.Core.GlobTest do
  use ExUnit.Case, async: true

  alias Compos.Core.Glob

  setup do
    root = Path.join(System.tmp_dir!(), "zz-glob-#{System.unique_integer([:positive])}")

    for dir <- ~w(a a/b skipped a/.hidden) do
      File.mkdir_p!(Path.join(root, dir))
      File.write!(Path.join([root, dir, "todos.md"]), "")
    end

    File.write!(Path.join(root, "a/notes.md"), "")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: Path.expand(root)}
  end

  test "** matches any depth, none included, shallow first", %{root: root} do
    File.write!(Path.join(root, "todos.md"), "")

    assert Glob.files(root <> "/**/todos.md", ["skipped"]) ==
             Enum.map(~w(todos.md a/todos.md a/b/todos.md), &Path.join(root, &1))
  end

  test "** enters a folder that SKIP does not name", %{root: root} do
    assert Path.join(root, "skipped/todos.md") in Glob.files(root <> "/**/todos.md")
  end

  test "* matches within one name and never a leading dot", %{root: root} do
    assert Glob.files(root <> "/a/*.md") ==
             Enum.map(~w(a/notes.md a/todos.md), &Path.join(root, &1))

    assert Glob.files(root <> "/a/*/todos.md") == [Path.join(root, "a/b/todos.md")]
  end

  test "a literal name can start with a dot", %{root: root} do
    assert Glob.files(root <> "/a/.hidden/todos.md") == [Path.join(root, "a/.hidden/todos.md")]
  end

  test "a folder is not a file, and a missing folder names nothing", %{root: root} do
    assert Glob.files(root <> "/a") == []
    assert Glob.files(root <> "/none/**/todos.md") == []
  end

  test "a link that points up does not make the walk endless", %{root: root} do
    File.ln_s!(root, Path.join(root, "a/up"))
    files = Glob.files(root <> "/**/notes.md")
    assert Path.join(root, "a/notes.md") in files
  end
end
