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
              (disable-minor-mode! b "code-mode")))
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

  test "the shared policy lets a code workspace chat restart the daemon" do
    buf = fresh_buffer("cm-restart-#{System.unique_integer([:positive])}.ex", "code\n")
    eval!(~s{(run-command "code-mode")})
    chat = eval!(~s{(group-chat "#{buf}")}) |> String.trim("\"")

    assert eval!(~s{(*permission-policy* "#{chat}" "restart-daemon" "command" "")}) ==
             "allow-always"
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

  test "the code instructions ride in both prompt paths, and only for code buffers" do
    buf = fresh_buffer("cm-instr-#{System.unique_integer([:positive])}.ex", "code\n")

    plain = eval!(~s{(chat-preamble-body "#{buf}" (list "#{buf}"))})
    refute plain =~ "code-outline"
    assert plain =~ "writing companion"

    eval!(~s{(run-command "code-mode")})

    # the chat lane
    preamble = eval!(~s{(chat-preamble-body "#{buf}" (list "#{buf}"))})
    assert preamble =~ "coding companion"
    assert preamble =~ "(code-outline \\\"BUF\\\")"
    assert preamble =~ "(code-replace! \\\"BUF\\\" LINE NEW)"
    assert preamble =~ "(buffer-insert-after! \\\"BUF\\\" ANCHOR TEXT)"
    refute preamble =~ "Match the document's voice"

    # and M-o, on the same words
    assert eval!(~s{(llm-mode--group-note "#{buf}")}) =~ "(code-outline \\\"BUF\\\")"

    # the user owns the words
    eval!("(define zz-code-instructions code-instructions)")
    on_exit(fn -> eval!("(customize-set! 'code-instructions zz-code-instructions)") end)
    eval!(~s{(customize-set! 'code-instructions "")})
    refute eval!(~s{(llm-mode--group-note "#{buf}")}) =~ "code-outline"
  end

  test "a code-mode file in a project joins the project's group" do
    root = Path.join(System.tmp_dir!(), "cm-proj-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".git"))
    path = Path.join(root, "one.ex")
    File.write!(path, "defmodule One do\nend\n")

    on_exit(fn ->
      if Buffer.exists?(path), do: Aimax.Core.kill_buffer(path)
      File.rm_rf!(root)
    end)

    eval!(~s{(find-file "#{path}")})
    eval!(~s{(switch-to-buffer! "#{path}")})
    buf = Editor.current_buffer()
    eval!(~s{(run-command "code-mode")})

    # a change touches more than one file, so the group is the checkout
    assert Buffer.get_local(buf, "group") == eval!(~s{(buffer-project-root "#{buf}")})
                                             |> String.trim(~s{"})
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
