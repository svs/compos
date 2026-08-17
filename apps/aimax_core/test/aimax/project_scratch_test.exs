defmodule Aimax.ProjectScratchTest do
  @moduledoc """
  The project's scratch buffer: one conversation for the whole checkout,
  beside the one each file already has.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  # a real project: a directory with .git, holding two files
  defp project do
    root = Path.join(System.tmp_dir!(), "zz-proj-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".git"))
    a = Path.join(root, "a.ex")
    b = Path.join(root, "b.ex")
    File.write!(a, "defmodule A do\nend\n")
    File.write!(b, "defmodule B do\nend\n")

    on_exit(fn ->
      Editor.minibuffer_close()

      for name <- Aimax.Core.list_buffers(),
          String.starts_with?(name, root) or String.contains?(name, root),
          do: Aimax.Core.kill_buffer(name)

      File.rm_rf!(root)
    end)

    # macOS gives /var and /private/var for the same directory; the editor
    # expands paths, so ask it what root it sees
    {root, a, b}
  end

  defp open(path) do
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    eval!(~s{(find-file "#{path}")})
    eval!(~s{(switch-to-buffer! "#{path}")})
    Editor.current_buffer()
  end

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    :ok
  end

  test "C-x p s opens the project's scratch, tags the project's buffers, and toggles back" do
    {_root, a, b} = project()
    buf = open(a)
    eval!(~s{(find-file "#{b}")})
    root = eval!(~s{(buffer-project-root "#{buf}")}) |> String.trim(~s{"})

    press(["C-x", "p", "s"])
    scratch = Editor.current_buffer()

    assert scratch == "*scratch:project #{root}*"
    assert Buffer.text(scratch) =~ "# Scratch — project "
    assert Buffer.get_local(scratch, "group") == root
    assert Buffer.get_local(scratch, "project-scratch-root") == root

    # every open buffer of the project joined the group, so a chat in the
    # scratch can name and edit them
    assert Buffer.get_local(buf, "group") == root
    assert Buffer.get_local(Path.expand(b), "group") == root

    press(["C-x", "p", "s"])
    assert Editor.current_buffer() == buf

    press(["C-x", "p", "s"])
    assert Editor.current_buffer() == scratch
  end

  test "the project scratch keeps the presets it was created with" do
    {_root, a, _b} = project()
    buf = open(a)
    root = eval!(~s{(buffer-project-root "#{buf}")}) |> String.trim(~s{"})

    eval!(~s{(buffer-set-local! "#{buf}" 'chat-presets '(aimax))})
    eval!(~s{(buffer-set-local! "#{buf}" 'llm-model "openai:test-coder")})
    press(["C-x", "p", "s"])
    scratch = Editor.current_buffer()

    assert Buffer.get_local(scratch, "chat-presets") == [sym: "aimax"]
    assert Buffer.get_local(scratch, "llm-model") == "openai:test-coder"

    # a later visit from a buffer with different presets must not rewrite the
    # conversation's identity
    press(["C-x", "p", "s"])
    eval!(~s{(buffer-set-local! "#{buf}" 'chat-presets '(web))})
    press(["C-x", "p", "s"])

    assert Editor.current_buffer() == "*scratch:project #{root}*"
    assert Buffer.get_local(scratch, "chat-presets") == [sym: "aimax"]
  end

  test "the project scratch and the file scratch are two different buffers" do
    {_root, a, _b} = project()
    buf = open(a)
    root = eval!(~s{(buffer-project-root "#{buf}")}) |> String.trim(~s{"})

    press(["C-c", "s"])
    file_scratch = Editor.current_buffer()
    assert file_scratch == "*scratch:#{buf}*"

    press(["C-c", "s"])
    press(["C-x", "p", "s"])

    assert Editor.current_buffer() == "*scratch:project #{root}*"
    assert Buffer.exists?(file_scratch)
  end

  test "a buffer outside any project says so instead of opening a scratch" do
    name = "zz-nowhere-#{System.unique_integer([:positive])}"
    {:ok, _} = Aimax.Core.create_buffer(name, text: "loose\n")
    on_exit(fn -> if Buffer.exists?(name), do: Aimax.Core.kill_buffer(name) end)

    Editor.delete_other_windows()
    Editor.set_window_buffer(name)
    eval!(~s{(buffer-set-local! "#{name}" 'default-directory "/")})

    Editor.set_echo("")
    press(["C-x", "p", "s"])

    assert Editor.current_buffer() == name
    assert Editor.snapshot().echo =~ "No project here"
  end
end
