defmodule Compos.ProjectScratchTest do
  @moduledoc """
  The project's scratch buffer: one conversation for the whole checkout,
  beside the one each file already has.
  """

  use ExUnit.Case

  alias Compos.Core.{Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  # the verbs by name. Which key reaches one is a preference that moves.
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

      for name <- Compos.Core.list_buffers(),
          String.starts_with?(name, root) or String.contains?(name, root),
          do: Compos.Core.kill_buffer(name)

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
    # the frame's group and the last one visited are global editor state:
    # a module that entered a group leaves the next one starting inside it
    Compos.Core.Session.eval(
      "(begin (set-frame-local! 'current-group #f) (set-frame-local! 'previous-group #f))"
    )
    Editor.minibuffer_close()
    Editor.set_pending([])
    :ok
  end

  test "the project scratch opens, tags the project's buffers, and toggles back" do
    {_root, a, b} = project()
    buf = open(a)
    eval!(~s{(find-file "#{b}")})
    root = eval!(~s{(buffer-project-root "#{buf}")}) |> String.trim(~s{"})

    run("project-scratch")
    scratch = Editor.current_buffer()

    assert scratch == "*scratch:project #{root}*"
    assert Buffer.text(scratch) =~ "# Scratch — project "
    assert group_of(scratch) == root
    assert Buffer.get_local(scratch, "project-scratch-root") == root

    # every open buffer of the project joined the group, so a chat in the
    # scratch can name and edit them
    assert group_of(buf) == root
    assert group_of(Path.expand(b)) == root

    run("project-scratch")
    assert Editor.current_buffer() == buf

    run("project-scratch")
    assert Editor.current_buffer() == scratch
  end

  test "the project scratch keeps the presets it was created with" do
    {_root, a, _b} = project()
    buf = open(a)
    root = eval!(~s{(buffer-project-root "#{buf}")}) |> String.trim(~s{"})

    eval!(~s{(buffer-set-local! "#{buf}" 'chat-presets '(compos))})
    eval!(~s{(buffer-set-local! "#{buf}" 'llm-model "openai:test-coder")})
    run("project-scratch")
    scratch = Editor.current_buffer()

    assert Buffer.get_local(scratch, "chat-presets") == [sym: "compos"]
    assert Buffer.get_local(scratch, "llm-model") == "openai:test-coder"

    # a later visit from a buffer with different presets must not rewrite the
    # conversation's identity
    run("project-scratch")
    eval!(~s{(buffer-set-local! "#{buf}" 'chat-presets '(web))})
    run("project-scratch")

    assert Editor.current_buffer() == "*scratch:project #{root}*"
    assert Buffer.get_local(scratch, "chat-presets") == [sym: "compos"]
  end

  test "the project scratch and the file scratch are two different buffers" do
    {_root, a, _b} = project()
    buf = open(a)
    root = eval!(~s{(buffer-project-root "#{buf}")}) |> String.trim(~s{"})

    run("scratch-buffer")
    file_scratch = Editor.current_buffer()
    assert file_scratch == "*scratch:#{buf}*"

    run("scratch-buffer")
    run("project-scratch")

    assert Editor.current_buffer() == "*scratch:project #{root}*"
    assert Buffer.exists?(file_scratch)
  end

  test "a buffer outside any project says so instead of opening a scratch" do
    name = "zz-nowhere-#{System.unique_integer([:positive])}"
    {:ok, _} = Compos.Core.create_buffer(name, text: "loose\n")
    on_exit(fn -> if Buffer.exists?(name), do: Compos.Core.kill_buffer(name) end)

    Editor.delete_other_windows()
    Editor.set_window_buffer(name)
    eval!(~s{(buffer-set-local! "#{name}" 'default-directory "/")})

    Editor.set_echo("")
    run("project-scratch")

    assert Editor.current_buffer() == name
    assert Editor.snapshot().echo =~ "No project here"
  end
end
