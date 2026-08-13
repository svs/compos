defmodule Aimax.GitDiffTest do
  @moduledoc """
  diff-mode against a real repository, driven through the same key path the
  GUI uses.

  The buffer text is the unified diff and everything else is a projection of
  it, so most assertions read the text or the leaf payload. The render is
  asynchronous by design — the Session must never block on git — so the
  tests wait for it rather than assume it already happened.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, Git, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  @twelve Enum.map_join(1..12, fn n -> "line #{n}\n" end)

  setup do
    dir = Path.join(System.tmp_dir!(), "aimax-diff-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q", "-b", "main"])

    File.write!(Path.join(dir, "a.txt"), @twelve)
    File.write!(Path.join(dir, "b.txt"), "b\n")
    git!(dir, ["add", "-A"])
    git!(dir, commit_args("first"))

    # one modified line, one untracked file
    File.write!(Path.join(dir, "a.txt"), String.replace(@twelve, "line 10\n", "line ten\n"))
    File.write!(Path.join(dir, "new.txt"), "fresh\n")

    {:ok, root} = Git.root(dir)
    buf = "*git: #{root}*"

    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()

    on_exit(fn ->
      Session.eval(~s[(unwatch-path! "#{root}")])
      if Buffer.exists?(buf), do: Aimax.Core.kill_buffer(buf)
      File.rm_rf!(dir)
    end)

    %{dir: dir, root: root, buf: buf}
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end

  defp commit_args(subject) do
    ["-c", "user.name=Test", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false",
     "commit", "-q", "-m", subject]
  end

  # open the diff the way a user does: a buffer whose directory is the repo,
  # then M-x git-diff
  defp open_diff(ctx) do
    scratch = "diff-host-#{System.unique_integer([:positive])}"
    {:ok, _} = Aimax.Core.create_buffer(scratch)
    Editor.set_window_buffer(scratch)
    {:ok, _} = Session.eval(~s[(buffer-set-local! "#{scratch}" 'default-directory "#{ctx.dir}/")])
    {:ok, _} = Session.eval(~s[(run-command "git-diff")])

    assert wait_for(fn -> Buffer.exists?(ctx.buf) and Buffer.text(ctx.buf) =~ "@@" end),
           "the diff never rendered"

    ctx.buf
  end

  defp leaf(buf) do
    payload = Editor.render_state()
    find_leaf(payload.tree, buf)
  end

  defp find_leaf(%{type: :leaf, buffer: b} = l, b), do: l
  defp find_leaf(%{type: :leaf}, _), do: nil
  defp find_leaf(%{type: :split, children: cs}, b), do: Enum.find_value(cs, &find_leaf(&1, b))

  defp line_of(buf, pos), do: Aimax.Core.Text.line_index(Buffer.text(buf), pos) + 1

  defp goto_line(buf, n) do
    pos =
      Buffer.text(buf)
      |> String.split("\n")
      |> Enum.take(n - 1)
      |> Enum.reduce(0, fn l, acc -> acc + byte_size(l) + 1 end)

    :ok = Buffer.goto(buf, pos)
  end

  defp wait_for(fun, tries \\ 150)
  defp wait_for(_fun, 0), do: false

  defp wait_for(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(20)
      wait_for(fun, tries - 1)
    end
  end

  # --- the buffer ------------------------------------------------------------

  test "git-diff renders the unified diff and the untracked file", ctx do
    buf = open_diff(ctx)
    text = Buffer.text(buf)

    assert text =~ "diff --git a/a.txt b/a.txt"
    assert text =~ "@@ -7,6 +7,6 @@"
    assert text =~ "-line 10"
    assert text =~ "+line ten"

    # git diff HEAD cannot see an untracked file; git status can
    assert text =~ "diff --git a/new.txt b/new.txt"

    assert Buffer.read_only?(buf)
    assert Buffer.get_local(buf, "render-mode") == "diff"
    assert Buffer.get_local(buf, "git-root") == ctx.root
    assert Buffer.get_local(buf, "transient")
  end

  test "the leaf carries cards with hunk offsets and word ranges", ctx do
    buf = open_diff(ctx)
    Editor.set_window_buffer(buf)

    cards = leaf(buf).diff.cards
    assert Enum.map(cards, & &1.file) |> Enum.sort() == ["a.txt", "new.txt"]

    a = Enum.find(cards, &(&1.file == "a.txt"))
    assert a.status == "modified"
    assert a.open

    assert [hunk] = a.hunks
    assert hunk.new_start == 7
    assert hunk.old_start == 7

    # the changed line pairs into one row, old on the left and new on the right
    mod = Enum.find(hunk.rows, &(&1.kind == :mod))
    assert mod.old == "line 10"
    assert mod.new == "line ten"
    assert mod.old_no == 10
    assert mod.new_no == 10
    # "line " is common; only what differs is emphasised
    assert mod.old_words == {5, 7}
    assert mod.new_words == {5, 8}

    untracked = Enum.find(cards, &(&1.file == "new.txt"))
    assert untracked.status == "untracked"
  end

  # --- keys ------------------------------------------------------------------

  test "n and p walk the hunks, N and P the files", ctx do
    buf = open_diff(ctx)
    Editor.set_window_buffer(buf)
    :ok = Buffer.goto(buf, 0)

    press("n")
    assert Buffer.text(buf) |> String.split("\n") |> Enum.at(line_of(buf, Buffer.point(buf)) - 1) =~
             "@@"

    press("N")
    assert Buffer.text(buf) |> String.split("\n") |> Enum.at(line_of(buf, Buffer.point(buf)) - 1) =~
             "diff --git"

    press("P")
    assert line_of(buf, Buffer.point(buf)) == 1
  end

  test "RET opens the file at the line the row belongs to", ctx do
    buf = open_diff(ctx)
    Editor.set_window_buffer(buf)

    # the "+line ten" row
    added = row_line(buf, "+line ten")
    goto_line(buf, added)
    press("RET")

    target = Path.join(ctx.root, "a.txt")
    assert Editor.current_buffer() == target
    assert line_of(target, Buffer.point(target)) == 10

    # you came to read it: a file reached from the browser opens read-only
    assert Buffer.read_only?(target)

    # C-x C-q is the way out
    press(["C-x", "C-q"])
    refute Buffer.read_only?(target)
  end

  test "RET on a context row below the change lands one line further", ctx do
    buf = open_diff(ctx)
    Editor.set_window_buffer(buf)

    goto_line(buf, row_line(buf, " line 11"))
    press("RET")

    target = Path.join(ctx.root, "a.txt")
    assert line_of(target, Buffer.point(target)) == 11
  end

  defp row_line(buf, prefix) do
    buf
    |> Buffer.text()
    |> String.split("\n")
    |> Enum.find_index(&(&1 == prefix))
    |> Kernel.+(1)
  end

  # --- folding ---------------------------------------------------------------

  test "TAB folds the card in both projections", ctx do
    buf = open_diff(ctx)
    Editor.set_window_buffer(buf)

    assert "a.txt" in Buffer.get_local(buf, "diff-open-cards")
    assert Buffer.hidden(buf, "diff") == []

    goto_line(buf, 1)
    press("TAB")

    refute "a.txt" in Buffer.get_local(buf, "diff-open-cards")
    refute leaf(buf).diff.cards |> Enum.find(&(&1.file == "a.txt")) |> Map.fetch!(:open)
    # the plain view hides the same thing: the card body, not its header
    assert [{s, e}] = Buffer.hidden(buf, "diff")
    assert s > 0 and e > s

    press("TAB")
    assert "a.txt" in Buffer.get_local(buf, "diff-open-cards")
    assert Buffer.hidden(buf, "diff") == []
  end

  test "a closed card stays closed across a refresh", ctx do
    buf = open_diff(ctx)
    Editor.set_window_buffer(buf)

    goto_line(buf, 1)
    press("TAB")
    refute "a.txt" in Buffer.get_local(buf, "diff-open-cards")

    File.write!(Path.join(ctx.dir, "b.txt"), "b changed\n")
    press("g")

    assert wait_for(fn -> Buffer.text(buf) =~ "b.txt" end)
    # the new file opens, the one the reader closed does not reopen
    refute "a.txt" in Buffer.get_local(buf, "diff-open-cards")
    assert "b.txt" in Buffer.get_local(buf, "diff-open-cards")
  end

  test "g picks up a change made outside the editor", ctx do
    buf = open_diff(ctx)
    Editor.set_window_buffer(buf)
    refute Buffer.text(buf) =~ "+second edit"

    File.write!(Path.join(ctx.dir, "a.txt"), @twelve <> "second edit\n")
    press("g")

    assert wait_for(fn -> Buffer.text(buf) =~ "+second edit" end)
  end

  # --- the plain view --------------------------------------------------------

  test "C-c C-v drops to the plain unified diff and back", ctx do
    buf = open_diff(ctx)
    Editor.set_window_buffer(buf)

    press(["C-c", "C-v"])
    assert Buffer.get_local(buf, "render-mode") == false
    assert leaf(buf).diff == nil
    # the plain view is the same bytes, coloured by overlays
    assert Enum.any?(Buffer.overlays(buf), fn {_s, _e, f} -> f == "diff-add" end)
    assert Enum.any?(Buffer.overlays(buf), fn {_s, _e, f} -> f == "diff-hunk" end)

    press(["C-c", "C-v"])
    assert Buffer.get_local(buf, "render-mode") == "diff"
  end

  # --- watching --------------------------------------------------------------

  test "w arms the watcher and the buffer refreshes with no keypress", ctx do
    buf = open_diff(ctx)
    Editor.set_window_buffer(buf)

    press("w")
    assert Buffer.get_local(buf, "git-watch")
    assert ctx.root in Aimax.Core.Watch.watching()

    # fsevents arms a moment late and coalesces, so keep writing until the
    # refresh lands rather than trust one write
    assert wait_for(fn ->
             File.write!(Path.join(ctx.dir, "a.txt"), @twelve <> "watched\n")
             Process.sleep(300)
             Buffer.text(buf) =~ "+watched"
           end, 15)

    press("w")
    refute Buffer.get_local(buf, "git-watch")
    refute ctx.root in Aimax.Core.Watch.watching()
  end

  # --- restore ---------------------------------------------------------------

  test "the mode setup rebuilds the buffer from its locals", ctx do
    buf = open_diff(ctx)
    Editor.set_window_buffer(buf)

    goto_line(buf, 1)
    press("TAB")
    refute "a.txt" in Buffer.get_local(buf, "diff-open-cards")

    # a restart: the locals survive, the text and the folds do not
    {:ok, _} = Session.eval(~s[(buffer-delete-range! "#{buf}" 0 (buffer-size "#{buf}"))])
    :ok = Buffer.clear_hidden(buf)

    {:ok, _} = Session.eval(~s[(set-mode! "git-diff")])

    assert wait_for(fn -> Buffer.text(buf) =~ "@@" end)
    refute "a.txt" in Buffer.get_local(buf, "diff-open-cards")
    assert Buffer.hidden(buf, "diff") != []
    assert Buffer.read_only?(buf)
  end
end
