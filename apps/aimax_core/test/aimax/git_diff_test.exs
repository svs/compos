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

  defp unstaged(file), do: "Unstaged changes|#{file}"

  # the card's own header line: line 1 is a section heading now
  defp card_line(buf, file), do: row_line(buf, "diff --git a/#{file} b/#{file}")

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

  # the card model crosses as plists, so tests read it the way the view does
  defp cards(buf) do
    {:ok, _} = Session.eval(~s{(buffer-set-local! "#{buf}" 'test-layout (diff-layout "#{buf}"))})
    (Buffer.get_local(buf, "test-layout") || []) |> Enum.map(&pl/1)
  end

  # the drawn projection, and helpers to walk it
  defp blocks(buf), do: (Buffer.get_local(buf, "render-blocks") || []) |> Enum.map(&pl/1)

  defp walk_blocks(b), do: [b | Enum.flat_map(b[:children] || [], &walk_blocks/1)]

  defp cells(buf) do
    blocks(buf)
    |> Enum.flat_map(&walk_blocks/1)
    |> Enum.filter(&match?("diff-side" <> _, &1[:class] || ""))
  end

  defp mod_cells(buf), do: Enum.filter(cells(buf), &(&1.class =~ "k-mod"))
  defp cell_no(cell), do: hd(cell.children).text
  defp cell_segs(cell), do: Enum.map(Enum.at(cell.children, 1).segs, fn [c, t] -> {c, t} end)

  # commit rows are plain lists: (LINE SHA SHORT DATE AUTHOR SUBJECT)
  defp commits(buf) do
    for [line, sha, short, date, author, subject] <- Buffer.get_local(buf, "diff-commits") || [] do
      %{line: line, sha: sha, short_sha: short, date: date, author: author, subject: subject}
    end
  end

  defp pl([{:sym, _} | _] = plist) do
    plist
    |> Enum.chunk_every(2)
    |> Map.new(fn [{:sym, k}, v] ->
      {k |> String.replace("-", "_") |> String.to_atom(), pl(v)}
    end)
  end

  defp pl(l) when is_list(l), do: Enum.map(l, &pl/1)
  defp pl({:sym, v}), do: String.to_atom(v)
  defp pl(false), do: nil
  defp pl(v), do: v

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
    assert Buffer.get_local(buf, "render-mode") == "blocks"
    assert Buffer.get_local(buf, "diff-root") == ctx.root
    assert Buffer.get_local(buf, "transient")

    # the mode composed the block tree; the payload carries it whole. The
    # first block is the section heading, chosen by the mode, not the view.
    blocks = Buffer.get_local(buf, "render-blocks")
    assert is_list(blocks) and blocks != []
    first = pl(hd(blocks))
    assert first.class == "diff-section"
    assert first.text =~ "Unstaged changes"

    Editor.set_window_buffer(buf)
    assert leaf(buf).blocks == blocks
  end

  test "the leaf carries cards with hunk offsets and word ranges", ctx do
    buf = open_diff(ctx)
    Editor.set_window_buffer(buf)

    cards = cards(buf)
    assert Enum.map(cards, & &1.file) |> Enum.sort() == ["a.txt", "new.txt"]

    a = Enum.find(cards, &(&1.file == "a.txt"))
    assert a.status == "modified"
    assert unstaged("a.txt") in Buffer.get_local(buf, "diff-open-cards")

    assert [hunk] = a.hunks
    assert hunk.new_start == 7
    assert hunk.old_start == 7

    # the changed line pairs into one row of the drawn grid: old left, new
    # right, only the differing span emphasised, each half knowing its own
    # buffer line for the point mark
    [old_cell, new_cell] = mod_cells(buf)
    assert cell_no(old_cell) == "10"
    assert cell_no(new_cell) == "10"
    assert cell_segs(old_cell) == [{"", "line "}, {"hl", "10"}]
    assert cell_segs(new_cell) == [{"", "line "}, {"hl", "ten"}]
    assert old_cell.lines == [row_line(buf, "-line 10"), row_line(buf, "-line 10")]
    assert new_cell.lines == [row_line(buf, "+line ten"), row_line(buf, "+line ten")]

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
    assert Buffer.text(buf) |> String.split("\n") |> Enum.at(line_of(buf, Buffer.point(buf)) - 1) =~
             "diff --git"
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

    assert unstaged("a.txt") in Buffer.get_local(buf, "diff-open-cards")
    assert Buffer.hidden(buf, "diff") == []

    goto_line(buf, card_line(buf, "a.txt"))
    press("TAB")

    refute unstaged("a.txt") in Buffer.get_local(buf, "diff-open-cards")
    # a closed card draws only its header
    card_b =
      blocks(buf)
      |> Enum.flat_map(&walk_blocks/1)
      |> Enum.find(&(&1[:anchor] == "card-" <> unstaged("a.txt")))

    assert length(card_b.children) == 1
    # the plain view hides the same thing: the card body, not its header
    assert [{s, e}] = Buffer.hidden(buf, "diff")
    assert s > 0 and e > s

    press("TAB")
    assert unstaged("a.txt") in Buffer.get_local(buf, "diff-open-cards")
    assert Buffer.hidden(buf, "diff") == []
  end

  test "a closed card stays closed across a refresh", ctx do
    buf = open_diff(ctx)
    Editor.set_window_buffer(buf)

    goto_line(buf, card_line(buf, "a.txt"))
    press("TAB")
    refute unstaged("a.txt") in Buffer.get_local(buf, "diff-open-cards")

    File.write!(Path.join(ctx.dir, "b.txt"), "b changed\n")
    press("g")

    assert wait_for(fn -> Buffer.text(buf) =~ "b.txt" end)
    # the new file opens, the one the reader closed does not reopen
    refute unstaged("a.txt") in Buffer.get_local(buf, "diff-open-cards")
    assert unstaged("b.txt") in Buffer.get_local(buf, "diff-open-cards")
  end

  test "g picks up a change made outside the editor", ctx do
    buf = open_diff(ctx)
    Editor.set_window_buffer(buf)
    refute Buffer.text(buf) =~ "+second edit"

    File.write!(Path.join(ctx.dir, "a.txt"), @twelve <> "second edit\n")
    press("g")

    assert wait_for(fn -> Buffer.text(buf) =~ "+second edit" end)
  end

  # --- sections --------------------------------------------------------------

  test "a partially staged file appears in both sections", ctx do
    # stage the change to a.txt, then change it again in the working tree
    git!(ctx.dir, ["add", "a.txt"])
    File.write!(Path.join(ctx.dir, "a.txt"), String.replace(@twelve, "line 10\n", "LINE TEN\n"))

    buf = open_diff(ctx)
    Editor.set_window_buffer(buf)

    text = Buffer.text(buf)
    assert text =~ "Unstaged changes ("
    assert text =~ "Staged changes ("
    assert text =~ "Untracked files ("
    assert text =~ "Recent commits"

    cards = cards(buf)
    sections = Map.new(cards, &{&1.key, &1.section})

    # one file, two sections, two independent cards
    assert sections["Unstaged changes|a.txt"] == "Unstaged changes"
    assert sections["Staged changes|a.txt"] == "Staged changes"
    assert sections["Untracked files|new.txt"] == "Untracked files"

    # folding one leaves its twin in the other section open
    {:ok, _} = Session.eval(~s{(diff-toggle-card! "#{buf}" "Staged changes|a.txt")})
    open = Buffer.get_local(buf, "diff-open-cards")
    refute "Staged changes|a.txt" in open
    assert "Unstaged changes|a.txt" in open
  end

  test "TAB inside a hunk folds that hunk, not the file", ctx do
    # two hunks in one file, far enough apart not to merge
    File.write!(
      Path.join(ctx.dir, "a.txt"),
      @twelve |> String.replace("line 2\n", "LINE TWO\n") |> String.replace("line 11\n", "LINE ELEVEN\n")
    )

    buf = open_diff(ctx)
    Editor.set_window_buffer(buf)

    a = Enum.find(cards(buf), &(&1.file == "a.txt"))
    assert length(a.hunks) == 2
    assert Buffer.get_local(buf, "diff-closed-hunks") in [nil, []]

    # point on the second hunk's @@ line
    goto_line(buf, Enum.at(a.hunks, 1).line)
    press("TAB")

    # the card stays open; only the hunk closes
    assert unstaged("a.txt") in Buffer.get_local(buf, "diff-open-cards")
    assert Buffer.get_local(buf, "diff-closed-hunks") == ["Unstaged changes|a.txt|1"]
    # and the plain view hides that hunk's body, nothing else
    assert length(Buffer.hidden(buf, "diff")) == 1

    press("TAB")
    assert Buffer.get_local(buf, "diff-closed-hunks") == []
    assert Buffer.hidden(buf, "diff") == []
  end

  test "the row cursor follows point onto both sides of a change", ctx do
    buf = open_diff(ctx)
    Editor.set_window_buffer(buf)

    # the mod row: one row, two halves, each carrying its own buffer line
    [old_cell, new_cell] = mod_cells(buf)
    assert old_cell.lines == [row_line(buf, "-line 10"), row_line(buf, "-line 10")]
    assert new_cell.lines == [row_line(buf, "+line ten"), row_line(buf, "+line ten")]

    # a context line marks its own cells, on both sides at once
    ctx_line = row_line(buf, " line 12")
    ctx_cells = Enum.filter(cells(buf), &(&1.lines == [ctx_line, ctx_line]))
    assert length(ctx_cells) == 2
    assert Enum.all?(ctx_cells, &(&1.class =~ "k-ctx"))
  end

  # --- scope -----------------------------------------------------------------

  test "a diff opened in a subdirectory shows only that subdirectory", ctx do
    File.mkdir_p!(Path.join(ctx.dir, "sub"))
    File.write!(Path.join(ctx.dir, "sub/inner.txt"), "one\n")
    git!(ctx.dir, ["add", "-A"])
    git!(ctx.dir, commit_args("add sub"))

    # change a file in the subdirectory AND one at the root
    File.write!(Path.join(ctx.dir, "sub/inner.txt"), "two\n")
    File.write!(Path.join(ctx.dir, "b.txt"), "b changed\n")

    scratch = "sub-host-#{System.unique_integer([:positive])}"
    {:ok, _} = Aimax.Core.create_buffer(scratch)
    Editor.set_window_buffer(scratch)

    {:ok, _} =
      Session.eval(~s[(buffer-set-local! "#{scratch}" 'default-directory "#{ctx.dir}/sub/")])

    {:ok, _} = Session.eval(~s[(run-command "git-diff")])

    # the buffer is named for the scope, not the root
    buf = "*git: #{ctx.root}/sub*"
    on_exit(fn -> if Buffer.exists?(buf), do: Aimax.Core.kill_buffer(buf) end)

    assert wait_for(fn -> Buffer.exists?(buf) and Buffer.text(buf) =~ "@@" end)

    text = Buffer.text(buf)
    assert text =~ "sub/inner.txt"
    # a.txt and b.txt changed too, and neither is in this subtree
    refute text =~ "diff --git a/b.txt"
    refute text =~ "diff --git a/a.txt"

    assert Buffer.get_local(buf, "diff-scope") == "sub/"
    assert Buffer.get_local(buf, "diff-root") == ctx.root
  end

  test "cards come newest first", ctx do
    # a.txt is already modified by the setup; touch b.txt after it
    Process.sleep(1100)
    File.write!(Path.join(ctx.dir, "b.txt"), "b changed later\n")

    buf = open_diff(ctx)
    Editor.set_window_buffer(buf)

    unstaged =
      cards(buf)
      |> Enum.filter(&(&1.section == "Unstaged changes"))
      |> Enum.map(& &1.file)

    assert unstaged == ["b.txt", "a.txt"]
  end

  test "C-x g from a repo-less buffer means the most recent repository", ctx do
    # a buffer that lives in the repo, displayed a moment ago
    host = "ctx-host-#{System.unique_integer([:positive])}"
    {:ok, _} = Aimax.Core.create_buffer(host)
    {:ok, _} = Session.eval(~s[(buffer-set-local! "#{host}" 'default-directory "#{ctx.dir}/")])
    Editor.set_window_buffer(host)

    # then a buffer with no repository around it at all
    outside = Path.join(System.tmp_dir!(), "no-repo-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)

    stray = "ctx-stray-#{System.unique_integer([:positive])}"
    {:ok, _} = Aimax.Core.create_buffer(stray)
    {:ok, _} = Session.eval(~s[(buffer-set-local! "#{stray}" 'default-directory "#{outside}/")])
    Editor.set_window_buffer(stray)

    {:ok, _} = Session.eval(~s[(run-command "git-diff")])

    assert wait_for(fn -> Buffer.exists?(ctx.buf) and Buffer.text(ctx.buf) =~ "@@" end),
           "the fallback never found the repository"
  end

  # --- a clean tree ----------------------------------------------------------

  test "a clean tree shows the recent commits, and RET opens one", ctx do
    # commit everything the setup left dirty, so the tree is clean
    git!(ctx.dir, ["add", "-A"])
    git!(ctx.dir, commit_args("second"))
    assert git!(ctx.dir, ["status", "--porcelain"]) == ""

    buf = open_clean(ctx)
    Editor.set_window_buffer(buf)

    text = Buffer.text(buf)
    refute text =~ "diff --git"
    assert text =~ "Recent commits"
    assert text =~ "second"
    assert text =~ "first"

    commits = commits(buf)
    assert length(commits) == 2
    assert hd(commits).subject == "second"
    assert hd(commits).author == "Test"
    assert hd(commits).date =~ ~r/^\d{4}-\d{2}-\d{2}$/
    # the cards are gone, so the client draws the list instead
    assert cards(buf) == []

    # RET on a commit row opens that commit
    goto_line(buf, hd(commits).line)
    press("RET")

    show = "*git show: #{hd(commits).short_sha}*"
    assert wait_for(fn -> Buffer.exists?(show) and Buffer.text(show) =~ "second" end)
    assert Buffer.read_only?(show)

    # a commit renders as the same cards, with its message first
    Editor.set_window_buffer(show)
    # the commit message rides the block tree, parsed out of the preamble
    msg = blocks(show) |> Enum.find(&(&1[:class] == "diff-message"))
    assert msg.text =~ "second"
    assert msg.text =~ "Author: Test"
    refute msg.text =~ "diff --git"
    assert Enum.map(cards(show), & &1.file) |> Enum.sort() == ["a.txt", "new.txt"]
    assert [hunk] = Enum.find(cards(show), &(&1.file == "a.txt")).hunks
    assert hunk.new_start == 7

    Aimax.Core.kill_buffer(show)
  end

  # the setup leaves the tree dirty, so a clean-tree test commits first and
  # waits for the listing rather than for a hunk
  defp open_clean(ctx) do
    scratch = "diff-host-#{System.unique_integer([:positive])}"
    {:ok, _} = Aimax.Core.create_buffer(scratch)
    Editor.set_window_buffer(scratch)
    {:ok, _} = Session.eval(~s[(buffer-set-local! "#{scratch}" 'default-directory "#{ctx.dir}/")])
    {:ok, _} = Session.eval(~s[(run-command "git-diff")])

    assert wait_for(fn ->
             Buffer.exists?(ctx.buf) and Buffer.text(ctx.buf) =~ "Recent commits" and
               not (Buffer.text(ctx.buf) =~ "diff --git")
           end),
           "the commit listing never rendered"

    ctx.buf
  end

  # --- the plain view --------------------------------------------------------

  test "C-c C-v drops to the plain unified diff and back", ctx do
    buf = open_diff(ctx)
    Editor.set_window_buffer(buf)

    press(["C-c", "C-v"])
    assert Buffer.get_local(buf, "render-mode") == false
    assert leaf(buf).blocks == nil
    # the plain view is the same bytes, coloured by overlays
    assert Enum.any?(Buffer.overlays(buf), fn {_s, _e, f} -> f == "diff-add" end)
    assert Enum.any?(Buffer.overlays(buf), fn {_s, _e, f} -> f == "diff-hunk" end)

    press(["C-c", "C-v"])
    assert Buffer.get_local(buf, "render-mode") == "blocks"
  end

  # --- watching --------------------------------------------------------------

  test "w arms the watcher and the buffer refreshes with no keypress", ctx do
    buf = open_diff(ctx)
    Editor.set_window_buffer(buf)

    press("w")
    assert Buffer.get_local(buf, "diff-watch")
    assert ctx.root in Aimax.Core.Watch.watching()

    # fsevents arms a moment late and coalesces, so keep writing until the
    # refresh lands rather than trust one write
    assert wait_for(fn ->
             File.write!(Path.join(ctx.dir, "a.txt"), @twelve <> "watched\n")
             Process.sleep(300)
             Buffer.text(buf) =~ "+watched"
           end, 15)

    press("w")
    refute Buffer.get_local(buf, "diff-watch")
    refute ctx.root in Aimax.Core.Watch.watching()
  end

  # --- restore ---------------------------------------------------------------

  test "the mode setup rebuilds the buffer from its locals", ctx do
    buf = open_diff(ctx)
    Editor.set_window_buffer(buf)

    goto_line(buf, card_line(buf, "a.txt"))
    press("TAB")
    refute unstaged("a.txt") in Buffer.get_local(buf, "diff-open-cards")

    # a restart: the locals survive, the text and the folds do not
    {:ok, _} = Session.eval(~s[(buffer-delete-range! "#{buf}" 0 (buffer-size "#{buf}"))])
    :ok = Buffer.clear_hidden(buf)

    {:ok, _} = Session.eval(~s[(set-mode! "diff-mode")])

    assert wait_for(fn -> Buffer.text(buf) =~ "@@" end)
    refute unstaged("a.txt") in Buffer.get_local(buf, "diff-open-cards")
    assert Buffer.hidden(buf, "diff") != []
    assert Buffer.read_only?(buf)
  end
end
