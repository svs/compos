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
    root = Path.join(System.tmp_dir!(), "aimax-wt-#{System.os_time(:nanosecond)}")
    File.rm_rf!(root)
    File.rm_rf!("#{root}-worktrees")
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

  test "the LLM chat name becomes the human project workspace name" do
    workspace = "/tmp/ai-max-worktrees/a1"
    project = "/tmp/ai-max"
    buf = "*chat:workspace-name-test*"

    eval!(
      ~s{(daemon-assign-workspace! "worktree-a1" "http://localhost:4204" "/tmp/a1" "#{workspace}")}
    )

    eval!(
      ~s{(begin (buffer-create "#{buf}") (buffer-set-local! "#{buf}" 'workspace-id "a1") (buffer-set-local! "#{buf}" 'workspace-root "#{workspace}") (buffer-set-local! "#{buf}" 'workspace-project-root "#{project}") (workspace-name-from-chat! "#{buf}" "workspace prompts"))}
    )

    assert eval!(~s{(buffer-local "#{buf}" 'workspace-name)}) == ~s{"workspace prompts"}
    owner = eval!(~s{(daemon-workspace-owner "#{workspace}")})
    assert owner =~ ~s{workspace-project "ai-max"}
    assert owner =~ ~s{workspace-name "workspace prompts"}
  after
    Aimax.Core.kill_buffer("*chat:workspace-name-test*")
  end

  test "new chats inherit the workspace LLM defaults" do
    root = scratch_repo()
    eval!(~s{(worktree-create "#{root}" "defaults")})
    workspace = "#{root}-worktrees/defaults"
    path = "#{workspace}/a.txt"
    chat = "*chat:#{workspace}*"

    eval!(~s{(visit "#{path}")})

    eval!("""
    (begin
      (buffer-set-local! "#{path}" 'chat-presets '(aimax web))
      (buffer-set-local! "#{path}" 'chat-permission-mode 'ask)
      (llm-config-apply! "#{path}" "codex-app-server" "gpt-5.6-terra" "high")
      (group-chat "#{workspace}"))
    """)

    assert eval!(~s{(buffer-local "#{chat}" 'agent-connector)}) == ~s{"codex-app-server"}
    assert eval!(~s{(buffer-local "#{chat}" 'agent-model)}) == ~s{"gpt-5.6-terra"}
    assert eval!(~s{(buffer-local "#{chat}" 'agent-effort)}) == ~s{"high"}
    assert eval!(~s{(buffer-local "#{chat}" 'chat-presets)}) == "(aimax web)"
    assert eval!(~s{(buffer-local "#{chat}" 'chat-permission-mode)}) == "ask"

    # The default record also lives on work buffers. Removing the conversation
    # and opening another one does not fall back to global settings.
    Aimax.Core.kill_buffer(chat)
    eval!(~s{(group-chat "#{workspace}")})

    assert eval!(~s{(buffer-local "#{chat}" 'agent-connector)}) == ~s{"codex-app-server"}
    assert eval!(~s{(buffer-local "#{chat}" 'agent-model)}) == ~s{"gpt-5.6-terra"}
    assert eval!(~s{(buffer-local "#{chat}" 'agent-effort)}) == ~s{"high"}
    assert eval!(~s{(buffer-local "#{chat}" 'chat-presets)}) == "(aimax web)"
    assert eval!(~s{(buffer-local "#{chat}" 'chat-permission-mode)}) == "ask"
  after
    Aimax.Core.list_buffers()
    |> Enum.filter(&String.starts_with?(&1, "*chat:"))
    |> Enum.each(&Aimax.Core.kill_buffer/1)
  end

  test "the *worktrees* buffer lists, diffs, and removes" do
    root = scratch_repo()
    eval!(~s{(worktree-create "#{root}" "t3")})

    # the command resolves the project from the current buffer
    eval!(
      ~s{(begin (delete-other-windows!) (visit "#{root}/a.txt") (run-command "workspace-manage"))}
    )

    text = eval!(~s{(buffer-text "*worktrees*")})
    assert text =~ "agent/t3"
    assert text =~ "primary"
    assert text =~ "no thread"

    # point onto the agent/t3 row through the list's real movement path
    eval!(~s{(list-goto-first-entry "*worktrees*")})
    press(["n"])
    assert eval!("(plist-get (list-current \"*worktrees*\") 'branch)") == ~s{"agent/t3"}

    # a change in the worktree shows up in = (diff vs base)
    File.write!("#{root}-worktrees/t3/a.txt", "changed\n")
    eval!(~s{(daemon-claim-workspace! "#{root}-worktrees/t3")})
    press(["="])
    assert eval!(~s{(buffer-exists? "*workspace diff: t3*")}) == "#t"
    assert eval!(~s{(buffer-text "*workspace diff: t3*")}) =~ "a.txt"

    # dirty refuses removal (x asks first — answer yes, the action refuses)
    eval!(~s{(switch-to-buffer! "*worktrees*")})
    press(["d", "x", "y", "e", "s", "RET"])
    assert File.dir?("#{root}-worktrees/t3")
    assert eval!(~s{(daemon-workspace-owner "#{root}-worktrees/t3")}) =~ "aimax"

    # clean removes
    File.write!("#{root}-worktrees/t3/a.txt", "hello\n")
    eval!(~s{(list-goto-first-entry "*worktrees*")})
    press(["n"])
    press(["d", "x", "y", "e", "s", "RET"])
    refute File.dir?("#{root}-worktrees/t3")
    assert eval!(~s{(daemon-workspace-owner "#{root}-worktrees/t3")}) == "#f"
    assert sh!("git branch --list agent/t3", root) =~ "agent/t3"
  after
    Aimax.Core.kill_buffer("*workspace diff: t3*")
  end

  test "workspace-land merges a committed branch into the primary" do
    root = scratch_repo()
    eval!(~s{(worktree-create "#{root}" "t4")})
    wt = "#{root}-worktrees/t4"
    File.write!(Path.join(wt, "b.txt"), "from t4\n")
    sh!("git add . && git -c user.email=t@t -c user.name=t commit -q -m b", wt)

    eval!(
      ~s{(begin (delete-other-windows!) (visit "#{root}/a.txt") (run-command "workspace-manage"))}
    )

    eval!(~s{(list-goto-first-entry "*worktrees*")})
    press(["n"])
    press(["L"])

    assert File.exists?(Path.join(root, "b.txt"))
  end

  test "workspace-rebase opens its chat and delegates the hard rebase" do
    root = scratch_repo()
    eval!(~s{(worktree-create "#{root}" "t5")})
    wt = "#{root}-worktrees/t5"

    File.write!(Path.join(wt, "feature.txt"), "feature\n")
    sh!("git add . && git -c user.email=t@t -c user.name=t commit -q -m feature", wt)

    File.write!(Path.join(root, "main.txt"), "main\n")
    sh!("git add . && git -c user.email=t@t -c user.name=t commit -q -m main", root)

    {_, 1} = System.cmd("git", ["merge-base", "--is-ancestor", "main", "HEAD"], cd: wt)

    eval!(~s{(visit "#{wt}/a.txt")})
    eval!(~s{(run-command "workspace-diff")})
    assert eval!(~s{(buffer-text "*workspace diff: t5*")}) =~ "feature.txt"

    eval!(~s{(visit "#{wt}/a.txt")})

    eval!("""
    (let ((old-runtime chat-ensure-runtime!)
          (old-send agent-send-msg!))
      (set! chat-ensure-runtime! (lambda (buf) "rebase-test-agent"))
      (set! agent-send-msg!
        (lambda (slug prompt)
          (buffer-set-local! (current-buffer) 'test-rebase-slug slug)
          (buffer-set-local! (current-buffer) 'test-rebase-prompt prompt)
          'sent))
      (run-command "workspace-rebase")
      (set! chat-ensure-runtime! old-runtime)
      (set! agent-send-msg! old-send))
    """)

    chat = "*chat:#{wt}*"
    assert Editor.current_buffer() == chat
    assert eval!(~s{(buffer-local "#{chat}" 'test-rebase-slug)}) == ~s{"rebase-test-agent"}

    prompt = eval!(~s{(buffer-local "#{chat}" 'test-rebase-prompt)})
    assert prompt =~ "Rebase this workspace onto main"
    assert prompt =~ "Resolve conflicts carefully"
    assert prompt =~ "Run the relevant tests"
    assert prompt =~ "use the ask tool"

    # The command itself never performs the dangerous rebase behind the
    # agent's back; the delegated agent owns the operation and its conflicts.
    {_, 1} = System.cmd("git", ["merge-base", "--is-ancestor", "main", "HEAD"], cd: wt)
    refute File.exists?(Path.join(wt, "main.txt"))
  after
    Aimax.Core.kill_buffer("*workspace diff: t5*")

    Aimax.Core.list_buffers()
    |> Enum.filter(&String.starts_with?(&1, "*chat:"))
    |> Enum.each(&Aimax.Core.kill_buffer/1)
  end

  test "agent-worktree-opts isolates by default and accepts an explicit opt-out" do
    root = scratch_repo()
    eval!(~s{(visit "#{root}/a.txt")})
    eval!("(customize-set! 'agent-worktree-isolation #t)")
    on_exit(fn -> eval!("(customize-set! 'agent-worktree-isolation #f)") end)

    # A caller can make a deliberate exception.
    assert eval!(~s{(agent-worktree-opts "#{root}/a.txt" "s2" '(isolated #f))}) ==
             "(isolated #f)"

    refute File.dir?("#{root}-worktrees/s2")

    # The safe default creates a worktree cwd.
    out = eval!(~s{(plist-get (agent-worktree-opts "#{root}/a.txt" "s1" '()) 'cwd)})
    assert out == ~s{"#{root}-worktrees/s1"}
    assert File.dir?("#{root}-worktrees/s1")

    File.write!("#{root}-worktrees/s1/a.txt", "changed\n")
    eval!(~s{(worktree-mode--apply! "#{root}/a.txt")})
    assert eval!(~s{(minor-mode-on? "#{root}/a.txt" "worktree-mode")}) == "#t"
    assert eval!(~s{(buffer-local "#{root}/a.txt" 'header-line)}) =~ "WORKTREE s1"
    assert eval!(~s{(buffer-local "#{root}/a.txt" 'header-line)}) =~ "1 dirty"
    assert eval!(~s{(buffer-local "#{root}/a.txt" 'window-class)}) =~ "workspace-pending"

    eval!(~s{(workspace-finish-reminder! "#{root}/a.txt" "s1")})
    assert Editor.snapshot().echo =~ "workspace s1"
    assert Editor.snapshot().echo =~ "commit to get the land-and-teardown prompt"

    slug = eval!(~s{(execute* "" '(connector "api" isolated #f))}) |> String.trim("\"")
    chat = "*chat:#{slug}*"
    on_exit(fn -> Aimax.Core.kill_buffer(chat) end)
    eval!(~s{(workspace--stamp! "#{chat}" "s1" "#{root}-worktrees/s1" "#{root}")})
    Editor.set_echo("")
    eval!(~s{(agent-handle-event "#{slug}" '(type turn-end stop-reason "end_turn"))})
    assert Editor.snapshot().echo =~ "workspace s1"
    assert eval!(~s{(buffer-local "#{chat}" 'header-line)}) =~ "WORKTREE s1"

    # an explicit cwd wins
    out =
      eval!(~s{(plist-get (agent-worktree-opts "#{root}/a.txt" "s3" '(cwd "/tmp")) 'cwd)})

    assert out == ~s{"/tmp"}
    refute File.dir?("#{root}-worktrees/s3")
  end

  test "visiting one linked-worktree file enables worktree-mode and C-x b identity" do
    root = scratch_repo()
    eval!(~s{(worktree-create "#{root}" "visible")})
    path = "#{root}-worktrees/visible/a.txt"
    on_exit(fn -> File.rm_rf!("#{root}-worktrees") end)

    # Registry state intentionally survives daemon reloads; this temp path can
    # be reused by another BEAM invocation, so it is a new workspace claim.
    eval!(~s{(daemon-release-workspace! "#{root}-worktrees/visible")})
    eval!(~s{(visit "#{path}")})
    port = eval!(~s{(worktree--daemon-port "#{path}")}) |> String.trim(~s{"})

    assert eval!(~s{(minor-mode-on? "#{path}" "worktree-mode")}) == "#t"
    assert eval!(~s{(buffer-local "#{path}" 'header-line)}) =~ "WORKTREE visible"
    assert eval!(~s{(buffer-local "#{path}" 'header-line)}) =~ "PORT #{port}"
    assert eval!(~s{(buffer-local "#{path}" 'window-class)}) =~ "workspace-pending"

    marginalia =
      eval!(~s{(marginalia-row (marginalia-for 'buffer) "#{path}")})

    assert marginalia =~ "worktree visible :#{port}"
  end

  test "a clean committed workspace asks, rebases, lands, and tears down" do
    root = scratch_repo()
    eval!(~s{(worktree-create "#{root}" "finish")})
    workspace = "#{root}-worktrees/finish"
    path = "#{workspace}/a.txt"
    on_exit(fn -> File.rm_rf!("#{root}-worktrees") end)

    # Primary advances after the worktree starts. Teardown must rebase first.
    File.write!(Path.join(root, "main.txt"), "main\n")
    sh!("git add . && git -c user.email=t@t -c user.name=t commit -q -m main", root)

    File.write!(Path.join(workspace, "feature.txt"), "feature\n")
    sh!("git add . && git -c user.email=t@t -c user.name=t commit -q -m feature", workspace)

    eval!(~s{(visit "#{path}")})
    eval!(~s{(workspace-finish-reminder! "#{path}" "finish")})

    assert Editor.snapshot().minibuffer.prompt =~ "Land and teardown workspace finish"
    press(["y"])

    refute File.dir?(workspace)
    assert File.read!(Path.join(root, "feature.txt")) == "feature\n"
    assert Editor.snapshot().echo =~ "landed and tore down workspace finish"
    assert eval!(~s{(daemon-workspace-owner "#{workspace}")}) == "#f"
  end
end
