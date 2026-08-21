defmodule Aimax.MorgTodosTest do
  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  @todos "*Morg TODOs*"

  defp press(key), do: KeyDispatch.handle_key(key)

  setup do
    dir = Path.join(System.tmp_dir!(), "aimax-morg-todos-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()

    on_exit(fn ->
      Session.eval("(set! morg-agenda-files (list))")
      if Buffer.exists?(@todos), do: Aimax.Core.kill_buffer(@todos)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp open_todos(dir) do
    {:ok, _} = Session.eval(~s[(set! morg-agenda-files (list "#{dir}"))])
    {:ok, _} = Session.eval(~s[(run-command "morg-todos")])
    assert Editor.current_buffer() == @todos
    @todos
  end

  test "lists every TODO heading and RET opens its source", %{dir: dir} do
    path = Path.join(dir, "work.md")

    File.write!(path, """
    # TODO First task
    # DONE Finished task

    \`\`\`scheme
    # TODO Fenced example
    \`\`\`

    ## TODO Undated task
    """)

    buf = open_todos(dir)
    text = Buffer.text(buf)

    assert text =~ "First task"
    assert text =~ "Undated task"
    refute text =~ "Finished task"
    refute text =~ "Fenced example"

    Editor.set_window_buffer(buf)
    press("RET")
    assert Editor.current_buffer() == path
  end

  test "g re-reads all TODO files", %{dir: dir} do
    path = Path.join(dir, "work.md")
    File.write!(path, "# TODO First task\n")

    buf = open_todos(dir)
    assert Buffer.text(buf) =~ "First task"

    File.write!(path, "# TODO Replacement task\n")
    Editor.set_window_buffer(buf)
    press("g")

    assert Buffer.text(buf) =~ "Replacement task"
    refute Buffer.text(buf) =~ "First task"
  end
end
