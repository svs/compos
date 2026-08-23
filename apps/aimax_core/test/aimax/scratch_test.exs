defmodule Aimax.ScratchTest do
  @moduledoc "The editor-wide plain scratch buffer command."

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  # the verb by name. Which key reaches it is a preference that moves.
  defp run(command), do: eval!(~s[(run-command "#{command}")])

  # the group a buffer belongs to, by NAME. Groups are records: the
  # legacy 'group local is cleared the moment a buffer has a real
  # membership, so reading it answers nil for a buffer that is in a group.
  defp group_of(name) do
    case eval!(~s{(group-name (buffer-group "#{name}"))}) do
      "#f" -> nil
      quoted -> String.trim(quoted, ~s{"})
    end
  end

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

      Aimax.Core.list_buffers()
      |> Enum.filter(
        &(String.starts_with?(&1, "*scratch:") or String.starts_with?(&1, "*writing:"))
      )
      |> Enum.each(&Aimax.Core.kill_buffer/1)
    end)

    :ok
  end

  test "the scratch opens beside any ordinary buffer and toggles back" do
    owner = fresh_buffer("scratch-any-#{System.unique_integer([:positive])}", "ordinary\n")
    scratch = "*scratch:#{owner}*"

    run("scratch-buffer")

    assert Editor.current_buffer() == scratch
    assert Buffer.text(scratch) == "# Scratch — #{owner}\n\n"
    assert Buffer.get_local(owner, "scratch-buffer") == scratch
    assert Buffer.get_local(scratch, "scratch-owner") == owner
    assert group_of(scratch) == owner
    assert Buffer.get_local(scratch, "mode-name") == "text-mode"
    refute Buffer.get_local(scratch, "render-mode")
    refute Buffer.get_local(scratch, "preview-renderer")
    refute Buffer.get_local(scratch, "visual-line-mode")

    run("scratch-buffer")
    assert Editor.current_buffer() == owner
    assert length(Editor.list_windows()) == 2

    run("scratch-buffer")
    assert Editor.current_buffer() == scratch
    assert length(Editor.list_windows()) == 2
  end

  test "scratch inherits the owner's LLM session without its presentation mode" do
    owner = fresh_buffer("scratch-llm-#{System.unique_integer([:positive])}", "prompt\n")
    scratch = "*scratch:#{owner}*"

    eval!(~s{(enable-minor-mode! "#{owner}" "llm-mode")})
    eval!(~s{(buffer-set-local! "#{owner}" 'llm-model "openai:test-model")})
    eval!(~s{(buffer-set-local! "#{owner}" 'chat-presets '("files" "web"))})
    run("scratch-buffer")

    assert Buffer.get_local(scratch, "minor-modes") == ["llm-mode"]
    assert Buffer.get_local(scratch, "llm-model") == "openai:test-model"
    assert Buffer.get_local(scratch, "chat-presets") == ["files", "web"]
    refute Buffer.get_local(scratch, "render-mode")
  end

  test "backspace and forward delete remove an active region in a scratch buffer" do
    owner = fresh_buffer("scratch-delete-#{System.unique_integer([:positive])}", "owner\n")
    scratch = "*scratch:#{owner}*"

    run("scratch-buffer")
    :ok = Buffer.append(scratch, "keep remove tail", source: :editor)

    prefix = byte_size("# Scratch — #{owner}\n\nkeep ")
    finish = prefix + byte_size("remove ")

    eval!(~s{(begin (goto-char! #{prefix}) (set-mark! (point)) (goto-char! #{finish}))})
    press(["DEL"])

    assert Buffer.text(scratch) == "# Scratch — #{owner}\n\nkeep tail"
    assert Buffer.mark(scratch) == nil

    tail = byte_size("# Scratch — #{owner}\n\nkeep ")
    eval!(~s{(begin (goto-char! #{tail}) (set-mark! (point)) (end-of-buffer!))})
    press(["<delete>"])

    assert Buffer.text(scratch) == "# Scratch — #{owner}\n\nkeep "
    assert Buffer.mark(scratch) == nil
  end

  test "the first use adopts an old writing scratch without changing its text" do
    owner = fresh_buffer("scratch-migrate-#{System.unique_integer([:positive])}.md", "draft\n")
    legacy = "*writing:#{owner}*"
    old_text = "# Scratch — old\n\nKeep this exactly.\n"

    eval!(~s{(buffer-create "#{legacy}")})
    :ok = Buffer.append(legacy, old_text, source: :editor)
    eval!(~s{(buffer-set-local! "#{legacy}" 'preview-renderer "markdown")})
    eval!(~s{(buffer-set-local! "#{legacy}" 'render-mode "markdown")})

    run("scratch-buffer")

    assert Editor.current_buffer() == legacy
    assert Buffer.text(legacy) == old_text
    assert Buffer.get_local(owner, "scratch-buffer") == legacy
    assert Buffer.get_local(legacy, "scratch-owner") == owner
    refute Buffer.get_local(legacy, "render-mode")
    refute Buffer.get_local(legacy, "preview-renderer")
    refute Buffer.exists?("*scratch:#{owner}*")
  end
end
