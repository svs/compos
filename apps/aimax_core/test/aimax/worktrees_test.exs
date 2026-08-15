defmodule Aimax.WorktreesTest do
  @moduledoc "Worktree create/list/list-buffer/remove, and the isolated-attach opts."

  use ExUnit.Case

  alias Aimax.Core.{Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp eval!(code) do
    {:ok, out} = Session.eval(code)
    out
  end

  defp sh!(cmd, dir) do
    {out, 0} = System.cmd("sh", ["-c", cmd], cd: dir, stderr_to_stdout: true)
    out
  end

  # a scratch repository with one commit — worktree add needs a HEAD
  defp scratch_repo do
    root = Path.join(System.tmp_dir!(), "aimax-wt-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    sh!(
      "git init -q -b main . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init",
      root
    )

    File.write!(Path.join(root, "a.txt"), "hello\n")
    sh!("git add . && git -c user.email=t@t -c user.name=t commit -q -m a", root)
    on_exit(fn -> File.rm_rf!(root) end)
    # canonical (/private/var, not /var): git-root canonicalizes, and the
    # worktree paths derive from it
    {real, 0} = System.cmd("pwd", ["-P"], cd: root)
    String.trim(real)
  end

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])

    on_exit(fn ->
      Aimax.Core.kill_buffer("*worktrees*")
      Editor.delete_other_windows()
    end)

    :ok
  end

  test "worktree-create adds a sibling dir on branch agent/NAME and is idempotent" do
    root = scratch_repo()

    dir = eval!(~s{(worktree-create "#{root}" "t1")}) |> String.trim("\"")
    assert dir == "#{root}-worktrees/t1"
    assert File.dir?(dir)
    assert sh!("git branch --show-current", dir) |> String.trim() == "agent/t1"

    # again: reuse, not error
    assert eval!(~s{(worktree-create "#{root}" "t1")}) |> String.trim("\"") == dir
  end

  test "worktree-list parses the porcelain: primary first, then branches" do
    root = scratch_repo()
    eval!(~s{(worktree-create "#{root}" "t2")})

    out = eval!(~s{(map (lambda (w) (plist-get w 'branch)) (worktree-list "#{root}"))})
    assert out == ~s{("main" "agent/t2")}
  end

  test "the *worktrees* buffer lists, diffs, and removes" do
    root = scratch_repo()
    eval!(~s{(worktree-create "#{root}" "t3")})

    # the command resolves the project from the current buffer
    eval!(~s{(begin (delete-other-windows!) (visit "#{root}/a.txt") (run-command "worktrees"))})
    text = eval!(~s{(buffer-text "*worktrees*")})
    assert text =~ "agent/t3"
    assert text =~ "primary"
    assert text =~ "no thread"

    # point onto the agent/t3 row (header + primary row above it)
    eval!(~s{(begin (goto-char! 0) (next-line!) (next-line!) (beginning-of-line!))})
    assert eval!("(plist-get (list-current \"*worktrees*\") 'branch)") == ~s{"agent/t3"}

    # a change in the worktree shows up in = (diff vs base)
    File.write!("#{root}-worktrees/t3/a.txt", "changed\n")
    press(["="])
    assert eval!(~s{(buffer-exists? "*worktree diff: t3*")}) == "#t"
    assert eval!(~s{(buffer-text "*worktree diff: t3*")}) =~ "a.txt"

    # dirty refuses removal (x asks first — answer yes, the action refuses)
    eval!(~s{(switch-to-buffer! "*worktrees*")})
    press(["d", "x", "y", "e", "s", "RET"])
    assert File.dir?("#{root}-worktrees/t3")

    # clean removes
    File.write!("#{root}-worktrees/t3/a.txt", "hello\n")
    eval!(~s{(begin (goto-char! 0) (next-line!) (next-line!) (beginning-of-line!))})
    press(["d", "x", "y", "e", "s", "RET"])
    refute File.dir?("#{root}-worktrees/t3")
  after
    Aimax.Core.kill_buffer("*worktree diff: t3*")
  end

  test "worktree-land merges a committed branch into the primary" do
    root = scratch_repo()
    eval!(~s{(worktree-create "#{root}" "t4")})
    wt = "#{root}-worktrees/t4"
    File.write!(Path.join(wt, "b.txt"), "from t4\n")
    sh!("git add . && git -c user.email=t@t -c user.name=t commit -q -m b", wt)

    eval!(~s{(begin (delete-other-windows!) (visit "#{root}/a.txt") (run-command "worktrees"))})
    eval!(~s{(begin (goto-char! 0) (next-line!) (next-line!) (beginning-of-line!))})
    press(["L"])

    assert File.exists?(Path.join(root, "b.txt"))
  end

  test "agent-worktree-opts adds a cwd only for isolated threads inside a repo" do
    root = scratch_repo()
    eval!(~s{(visit "#{root}/a.txt")})

    # not isolated: untouched
    assert eval!(~s{(agent-worktree-opts "#{root}/a.txt" "s1" '())}) == "()"

    # isolated: a worktree cwd rides in front
    out = eval!(~s{(plist-get (agent-worktree-opts "#{root}/a.txt" "s1" '(isolated #t)) 'cwd)})
    assert out == ~s{"#{root}-worktrees/s1"}
    assert File.dir?("#{root}-worktrees/s1")

    # an explicit cwd wins
    out = eval!(~s{(plist-get (agent-worktree-opts "#{root}/a.txt" "s2" '(isolated #t cwd "/tmp")) 'cwd)})
    assert out == ~s{"/tmp"}
    refute File.dir?("#{root}-worktrees/s2")
  end
end
