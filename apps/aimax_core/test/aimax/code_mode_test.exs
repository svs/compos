defmodule Aimax.CodeModeTest do
  @moduledoc "code-mode: the agent coding workspace over a source buffer."

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(str), do: str |> String.graphemes() |> press()

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp fresh_buffer(name, text) do
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    Editor.set_window_buffer(name)
    :ok = Buffer.append(name, text, source: :editor)
    name
  end

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])

    on_exit(fn ->
      Editor.minibuffer_close()

      {:ok, _} =
        Session.eval("""
        (for-each
          (lambda (b)
            (when (minor-mode-on? b "code-mode")
              (disable-minor-mode! b "code-mode"))
            (when (minor-mode-on? b "browser-mode")
              (disable-minor-mode! b "browser-mode")))
          (buffer-list))
        """)

      eval!("(customize-set! 'code-presets '(aimax))")
      eval!(~s{(customize-set! 'code-model "")})

      Aimax.Core.list_buffers()
      |> Enum.filter(&String.starts_with?(&1, "*scratch:"))
      |> Enum.each(&Aimax.Core.kill_buffer/1)
    end)

    :ok
  end

  test "M-x code-mode joins a group, loads the coding presets, and turns on llm-mode" do
    buf = fresh_buffer("cm-mx-#{System.unique_integer([:positive])}.ex", "defmodule A do\nend\n")

    press(["M-x"])
    type("code-mode")
    press(["RET"])

    assert Enum.sort(Buffer.get_local(buf, "minor-modes")) == ["code-mode", "llm-mode"]
    assert Buffer.get_local(buf, "group") == buf
    assert Buffer.get_local(buf, "chat-presets") == [sym: "aimax"]
    assert Buffer.get_local(buf, "modeline-info") == "code · aimax"
  end

  test "the coding presets ride over the buffer's own, and a removed one does not linger" do
    buf = fresh_buffer("cm-presets-#{System.unique_integer([:positive])}.ex", "code\n")

    eval!(~s{(buffer-set-local! "#{buf}" 'chat-presets '(project))})
    eval!("(customize-set! 'code-presets '(aimax web))")
    eval!(~s{(run-command "code-mode")})

    assert Buffer.get_local(buf, "chat-presets") == [sym: "aimax", sym: "web", sym: "project"]
    assert Buffer.get_local(buf, "modeline-info") == "code · aimax web project"

    # A live customization rebuilds from the buffer's own pre-mode value, so a
    # preset the user removes from the setting disappears at once.
    eval!("(customize-set! 'code-presets '(aimax))")
    assert Buffer.get_local(buf, "chat-presets") == [sym: "aimax", sym: "project"]

    eval!(~s{(run-command "code-mode")})
    assert Buffer.get_local(buf, "chat-presets") == [sym: "project"]
  end

  test "C-c s opens a scratch chat that carries the coding presets" do
    buf = fresh_buffer("cm-scratch-#{System.unique_integer([:positive])}.ex", "code\n")
    scratch = "*scratch:#{buf}*"

    eval!(~s{(run-command "code-mode")})
    press(["C-c", "s"])

    assert Editor.current_buffer() == scratch
    assert Buffer.get_local(scratch, "chat-presets") == [sym: "aimax"]
    assert Buffer.get_local(scratch, "group") == buf
    assert "llm-mode" in Buffer.get_local(scratch, "minor-modes")
  end

  test "the scratch chat's system prompt names the buffer the agent must edit" do
    buf = fresh_buffer("cm-note-#{System.unique_integer([:positive])}.ex", "code\n")
    scratch = "*scratch:#{buf}*"

    eval!(~s{(run-command "code-mode")})
    press(["C-c", "s"])

    note = eval!(~s{(llm-mode--group-note "#{scratch}")})
    assert note =~ buf
    assert note =~ scratch
    assert note =~ "buffer-replace!"

    # a buffer in no group says nothing: M-o on a lone document keeps the
    # system prompt it always had
    lone = "cm-lone-#{System.unique_integer([:positive])}"
    eval!(~s{(begin (buffer-create "#{lone}") (buffer-set-local! "#{lone}" 'group #f))})
    on_exit(fn -> if Buffer.exists?(lone), do: Aimax.Core.kill_buffer(lone) end)
    assert eval!(~s{(llm-mode--group-note "#{lone}")}) == ~s{""}
  end

  test "code-mode asks before it assigns this frame a worktree, group, and chat" do
    root = Path.join(System.tmp_dir!(), "cm-proj-#{System.os_time(:nanosecond)}")
    File.rm_rf!(root)
    File.rm_rf!("#{root}-worktrees")
    File.mkdir_p!(root)

    {root, 0} = System.cmd("pwd", ["-P"], cd: root)
    root = String.trim(root)

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", "."], cd: root)
    path = Path.join(root, "one.ex")
    File.write!(path, "defmodule One do\nend\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: root)

    {_, 0} =
      System.cmd(
        "git",
        ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "one"],
        cd: root
      )

    on_exit(fn ->
      Aimax.Core.list_buffers()
      |> Enum.filter(
        &(String.starts_with?(&1, root) or String.contains?(&1, "#{root}-worktrees"))
      )
      |> Enum.each(&Aimax.Core.kill_buffer/1)

      Aimax.Core.list_buffers()
      |> Enum.filter(&String.starts_with?(&1, "*chat:#{root}"))
      |> Enum.each(&Aimax.Core.kill_buffer/1)

      File.rm_rf!(root)
      File.rm_rf!("#{root}-worktrees")
    end)

    eval!(~s{(find-file "#{path}")})
    eval!(~s{(switch-to-buffer! "#{path}")})

    # The current checkout is the safe default until the user chooses a
    # separate worktree through the real one-key prompt.
    press(["M-x"])
    type("code-mode")
    press(["RET"])

    assert Editor.snapshot().minibuffer.prompt == "Create a new worktree for code mode? (y or n) "
    refute File.dir?("#{root}-worktrees/a1")
    press("n")

    assert Editor.current_buffer() == path
    assert Buffer.get_local(path, "workspace-isolation-choice") == "current"
    assert Buffer.get_local(path, "group") == root
    refute File.dir?("#{root}-worktrees/a1")
    assert eval!(~s{(plist-get (agent-worktree-opts "#{path}" "a1" '()) 'cwd)}) == "#f"

    eval!(~s{(run-command "code-mode")})
    press(["M-x"])
    type("code-mode")
    press(["RET"])
    assert Editor.snapshot().minibuffer.prompt == "Create a new worktree for code mode? (y or n) "
    press("y")

    task_file = Editor.current_buffer()
    workspace = Buffer.get_local(task_file, "workspace-root")
    daemon_url = eval!("(editor-url)") |> String.trim("\"")

    assert workspace == "#{root}-worktrees/a1"
    assert task_file == "#{workspace}/one.ex"
    assert Buffer.get_local(task_file, "workspace-project-root") == root
    assert Buffer.get_local(task_file, "workspace-id") == "a1"
    assert Buffer.get_local(task_file, "workspace-daemon") == daemon_url
    assert Buffer.get_local(task_file, "group") == workspace
    assert Buffer.get_local(task_file, "modeline-info") == "code · a1 · aimax"

    # The ordinary editor tool changes the task buffer. Saving cannot touch
    # the primary checkout because the displayed buffer is the worktree copy.
    eval!(~s{(buffer-replace! "#{task_file}" "One" "TaskOne")})
    press(["C-x", "C-s"])
    assert File.read!(path) == "defmodule One do\nend\n"
    assert File.read!(task_file) == "defmodule TaskOne do\nend\n"
    assert Buffer.get_local(path, "group") in [nil, false]

    press(["C-c", "c"])
    chat = Editor.current_buffer()

    assert chat == "*chat:#{workspace}*"
    assert Buffer.get_local(chat, "group") == workspace
    assert Buffer.get_local(chat, "workspace-root") == workspace
    assert Buffer.get_local(chat, "workspace-project-root") == root
    assert Buffer.get_local(chat, "workspace-id") == "a1"
    assert Buffer.get_local(chat, "workspace-daemon") == daemon_url

    cwd = eval!(~s{(plist-get (agent-worktree-opts "#{chat}" "a1" '()) 'cwd)})
    assert cwd == ~s{"#{workspace}"}
    assert eval!(~s{(group-chat "#{workspace}")}) == ~s{"#{chat}"}

    # The project is the parent, not the group. A second coding task gets a
    # sibling workspace with its own group and chat.
    eval!(~s{(switch-to-buffer! "#{path}")})
    press(["M-x"])
    type("workspace-init")
    press(["RET"])

    second_file = Editor.current_buffer()
    second_workspace = Buffer.get_local(second_file, "workspace-root")
    assert second_workspace == "#{root}-worktrees/a2"
    assert Buffer.get_local(second_file, "group") == second_workspace

    press(["C-c", "c"])
    second_chat = Editor.current_buffer()
    assert second_chat == "*chat:#{second_workspace}*"
    assert second_chat != chat
    assert Buffer.exists?(chat)
    assert eval!(~s{(length (worktree-list "#{root}"))}) == "3"
  end

  test "a scratch that is already open picks up the presets when code-mode turns on" do
    buf = fresh_buffer("cm-live-#{System.unique_integer([:positive])}.ex", "code\n")
    scratch = "*scratch:#{buf}*"

    press(["C-c", "s"])
    assert Buffer.get_local(scratch, "chat-presets") == false

    press(["C-c", "s"])
    assert Editor.current_buffer() == buf
    eval!(~s{(run-command "code-mode")})

    assert Buffer.get_local(scratch, "chat-presets") == [sym: "aimax"]
    assert "llm-mode" in Buffer.get_local(scratch, "minor-modes")
  end

  test "code-model pins the model for the buffer and its scratch chat" do
    buf = fresh_buffer("cm-model-#{System.unique_integer([:positive])}.ex", "code\n")
    scratch = "*scratch:#{buf}*"

    eval!(~s{(customize-set! 'code-model "openai:test-coder")})
    eval!(~s{(run-command "code-mode")})
    press(["C-c", "s"])

    assert Buffer.get_local(buf, "llm-model") == "openai:test-coder"
    assert Buffer.get_local(scratch, "llm-model") == "openai:test-coder"

    # clearing the setting gives the buffer the editor's default model back
    eval!(~s{(customize-set! 'code-model "")})
    assert Buffer.get_local(buf, "llm-model") == false
  end

  test "disabling code-mode restores what it changed" do
    buf = fresh_buffer("cm-off-#{System.unique_integer([:positive])}.ex", "code\n")

    eval!(~s{(run-command "code-mode")})
    eval!(~s{(run-command "code-mode")})

    # the mode restores each local to the value it found: absent reads as #f
    assert Buffer.get_local(buf, "minor-modes") == []
    assert Buffer.get_local(buf, "chat-presets") == false
    assert Buffer.get_local(buf, "group") == false
    assert Buffer.get_local(buf, "modeline-info") == false
    assert Buffer.get_local(buf, "code-mode-saved") == false
  end

  test "code-mode keeps an llm-mode the user turned on first" do
    buf = fresh_buffer("cm-llm-#{System.unique_integer([:positive])}.ex", "code\n")

    eval!(~s{(enable-minor-mode! "#{buf}" "llm-mode")})
    eval!(~s{(run-command "code-mode")})
    eval!(~s{(run-command "code-mode")})

    assert Buffer.get_local(buf, "minor-modes") == ["llm-mode"]
  end

  test "restore-minor-modes! re-runs setup idempotently (reload path)" do
    buf = fresh_buffer("cm-restore-#{System.unique_integer([:positive])}.ex", "code\n")

    eval!(~s{(run-command "code-mode")})
    eval!(~s{(buffer-set-local! "#{buf}" 'chat-presets '(aimax project))})
    eval!(~s{(restore-minor-modes! "#{buf}")})

    assert Enum.sort(Buffer.get_local(buf, "minor-modes")) == ["code-mode", "llm-mode"]
    assert Buffer.get_local(buf, "group") == buf
    assert Buffer.get_local(buf, "modeline-info") == "code · aimax"
  end
end
