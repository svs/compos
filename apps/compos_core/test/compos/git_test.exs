defmodule Compos.GitTest do
  @moduledoc """
  Compos.Core.Git against a real repository in a temporary directory.

  The parsers are the point: porcelain `-z` pairs a rename across two chunks,
  and the unified diff carries the line tags and the hunk offsets the diff
  buffer reads. The last two tests drive the Scheme primitives, sync and
  async, because that is the surface `packages/git.scm` uses.
  """

  use ExUnit.Case

  alias Compos.Core.{Buffer, Git, Session}

  @twelve_lines Enum.map_join(1..12, fn n -> "line #{n}\n" end)

  setup do
    dir = Path.join(System.tmp_dir!(), "compos-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "sub"))

    git!(dir, ["init", "-q", "-b", "main"])

    File.write!(Path.join(dir, "a.txt"), @twelve_lines)
    File.write!(Path.join(dir, "b.txt"), "b\n")
    File.write!(Path.join(dir, "sub/c.txt"), "c\n")

    git!(dir, ["add", "-A"])
    git!(dir, commit_args("first commit"))

    # one work-tree modification, one staged rename, one untracked file
    File.write!(Path.join(dir, "a.txt"), String.replace(@twelve_lines, "line 10\n", "TENTH\n"))
    git!(dir, ["mv", "b.txt", "b2.txt"])
    File.write!(Path.join(dir, "new.txt"), "new\n")

    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir, real: File.cd!(dir, &File.cwd!/0)}
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end

  # never depend on the machine's global git config
  defp commit_args(subject) do
    [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.com",
      "-c",
      "commit.gpgsign=false",
      "commit",
      "-q",
      "-m",
      subject
    ]
  end

  test "root resolves from a subdirectory", %{dir: dir, real: real} do
    assert {:ok, ^real} = Git.root(Path.join(dir, "sub"))
    assert {:ok, ^real} = Git.root(dir)
  end

  test "root reports a directory that is not a repository" do
    outside = Path.join(System.tmp_dir!(), "compos-git-none-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)

    assert {:error, msg} = Git.root(outside)
    assert msg =~ "not a git repository"
  end

  test "status pairs a rename and tags the columns", %{dir: dir} do
    assert {:ok, entries} = Git.status(dir)

    by_path = Map.new(entries, &{&1.path, &1})
    assert map_size(by_path) == 3

    assert %{index: " ", worktree: "M", orig_path: nil} = by_path["a.txt"]
    assert %{index: "R", worktree: " ", orig_path: "b.txt"} = by_path["b2.txt"]
    assert %{index: "?", worktree: "?", orig_path: nil} = by_path["new.txt"]
  end

  test "status of a clean repository is empty", %{dir: dir} do
    git!(dir, ["checkout", "-q", "--", "a.txt"])
    git!(dir, ["mv", "b2.txt", "b.txt"])
    File.rm!(Path.join(dir, "new.txt"))

    assert {:ok, []} = Git.status(dir)
  end

  test "diff parses one hunk with its offsets and line tags", %{dir: dir} do
    assert {:ok, [file]} = Git.diff(dir, base: "HEAD", path: "a.txt")

    assert file.file_a == "a.txt"
    assert file.file_b == "a.txt"
    refute file.binary?

    assert [hunk] = file.hunks
    assert hunk.header =~ "@@ -7,6 +7,6 @@"
    assert hunk.old_start == 7
    assert hunk.old_count == 6
    assert hunk.new_start == 7
    assert hunk.new_count == 6

    assert Enum.filter(hunk.lines, &(elem(&1, 0) == :del)) == [{:del, "line 10"}]
    assert Enum.filter(hunk.lines, &(elem(&1, 0) == :add)) == [{:add, "TENTH"}]

    context = for {:ctx, text} <- hunk.lines, do: text
    assert context == ["line 7", "line 8", "line 9", "line 11", "line 12"]
  end

  test "diff sees the whole tree and the staged rename", %{dir: dir} do
    assert {:ok, files} = Git.diff(dir, base: "HEAD")
    paths = Enum.map(files, & &1.file_b) |> Enum.sort()

    assert "a.txt" in paths
    assert "b2.txt" in paths

    rename = Enum.find(files, &(&1.file_b == "b2.txt"))
    assert rename.file_a == "b.txt"
    assert rename.hunks == []
  end

  test "diff of the index only shows the staged change", %{dir: dir} do
    assert {:ok, files} = Git.diff(dir, base: "HEAD", staged: true)
    assert Enum.map(files, & &1.file_b) == ["b2.txt"]
  end

  test "diff of a binary file reports binary? and no hunks", %{dir: dir} do
    File.write!(Path.join(dir, "blob.bin"), <<0, 1, 2, 0, 255>>)
    git!(dir, ["add", "blob.bin"])

    assert {:ok, [file]} = Git.diff(dir, base: "HEAD", path: "blob.bin")
    assert file.binary?
    assert file.hunks == []
  end

  test "log returns the commits newest first", %{dir: dir} do
    git!(dir, ["add", "-A"])
    git!(dir, commit_args("second commit"))

    assert {:ok, [second, first]} = Git.log(dir, 5)

    assert second.subject == "second commit"
    assert first.subject == "first commit"
    assert second.author == "Test"
    assert byte_size(second.sha) == 40
    assert second.short_sha == binary_part(second.sha, 0, 7)
    assert second.date =~ ~r/^\d{4}-\d{2}-\d{2}T/
  end

  test "show returns the raw commit text", %{dir: dir} do
    assert {:ok, text} = Git.show(dir, "HEAD")
    assert text =~ "first commit"
    assert text =~ "+line 1"
  end

  # --- the Scheme surface ----------------------------------------------------

  test "git-status returns a plist list", %{dir: dir} do
    {:ok, printed} = Session.eval(~s[(git-status "#{dir}")])

    assert printed =~ "path"
    assert printed =~ "b2.txt"
    assert printed =~ "orig-path"
    assert printed =~ "b.txt"
  end

  test "git-diff returns hunk plists with symbol line tags", %{dir: dir} do
    {:ok, printed} = Session.eval(~s[(git-diff "#{dir}" '(base "HEAD" path "a.txt"))])

    assert printed =~ "new-start"
    assert printed =~ ~s[(del "line 10")]
    assert printed =~ ~s[(add "TENTH")]
  end

  test "git-root through Scheme gives the root, and a bad path gives an error", %{
    dir: dir,
    real: real
  } do
    assert {:ok, ~s["#{real}"]} == Session.eval(~s[(git-root "#{Path.join(dir, "sub")}")])

    {:ok, printed} = Session.eval(~s[(git-root "/")])
    assert printed =~ "error"
  end

  test "a trailing callback answers off the Session process", %{dir: dir, real: real} do
    buf = "*git-async-test*"
    Compos.Core.create_buffer(buf)
    on_exit(fn -> Compos.Core.kill_buffer(buf) end)

    {:ok, _} =
      Session.eval("""
      (git-root "#{dir}" (lambda (r) (buffer-append! "#{buf}" r)))
      """)

    assert wait_for(fn -> Buffer.text(buf) =~ real end)
  end

  defp wait_for(fun, tries \\ 100)
  defp wait_for(_fun, 0), do: false

  defp wait_for(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(20)
      wait_for(fun, tries - 1)
    end
  end
end
