defmodule Aimax.MorgTest do
  @moduledoc """
  What morg-mode does that Scheme cannot reach: a block that runs a shell
  or tangles to disk, and the preview toggle on C-c C-v.

  The mode itself is Scheme — folding, the TODO cycle, the org faces, the
  fenced-code grammar and the Markdown structural API all live in
  priv/tests/morg-test.scm, where a test runs the command that the key
  runs and reads the buffer back.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(text), do: text |> String.graphemes() |> press()

  defp morg_buffer(text) do
    name = "morg-#{System.unique_integer([:positive])}.md"
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()
    Editor.set_window_buffer(name)
    :ok = Buffer.append(name, text, source: :editor)
    {:ok, _} = Session.eval(~s{(set-mode! "morg-mode")})
    name
  end

  @doc false
  # "# a\nbody\n## child\ncbody\n# b\ntail\n"
  #  0123 4..8 9......17 ...   24.. 28..
  defp fixture, do: "# a\nbody\n## child\ncbody\n# b\ntail\n"

  # markdown-mode does not exist: no define-mode registers it, and set-mode!
  # has no teardown hook, so morg's folds, keys, and overlays survive the
  # switch. The contract below is the design; building it needs the mode, a
  # major-mode teardown in set-mode!, and a morg teardown that undoes them.
  @tag :skip
  test "markdown-mode is separate and keeps the Earmark preview" do
    buf = morg_buffer("# title\n\nbody\n")

    {:ok, _} = Session.eval(~s{(set-mode! "markdown-mode")})

    assert Buffer.get_local(buf, "mode-name") == "markdown-mode"
    assert Buffer.get_local(buf, "preview-renderer") == "markdown"
    refute Enum.any?(Buffer.overlays(buf), fn {_, _, face} -> face =~ "org-level" end)

    press(["C-c", "C-v"])
    assert Buffer.get_local(buf, "render-mode") == "markdown"
  end


  @tag :skip
  test "switching from morg to markdown removes Morg behavior" do
    buf = morg_buffer(fixture())
    :ok = Buffer.goto(buf, 0)
    press("TAB")
    assert Buffer.hidden(buf) != []

    {:ok, _} = Session.eval(~s{(set-mode! "markdown-mode")})

    assert Buffer.hidden(buf) == []
    refute Enum.any?(Editor.local_keys(buf), fn {_key, command} ->
             command in [
               "morg-cycle",
               "morg-global-cycle",
               "morg-babel",
               "morg-tangle"
             ]
           end)

    :ok = Buffer.insert_at(buf, 0, "x", source: :user)
    refute Enum.any?(Buffer.overlays(buf), fn {_, _, face} -> face =~ "org-level" end)
  end


  test "C-c C-c runs a sh block into a result block" do
    buf = morg_buffer("```sh\necho hi\n```\n")
    :ok = Buffer.goto(buf, 7)

    press(["C-c", "C-c"])
    assert Buffer.text(buf) == "```sh\necho hi\n```\n```result\nhi\n```\n"
  end


  test "C-c C-x tangles marked blocks relative to the Morg file" do
    dir = Path.join(System.tmp_dir!(), "morg-tangle-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    text = """
    # Program
    ```elixir :tangle lib/demo.ex
    defmodule Demo do
    ```
    ```elixir :tangle lib/demo.ex
    end
    ```
    ```sh :tangle no
    echo skip
    ```
    """

    buf = morg_buffer(text)
    :ok = Buffer.set_local(buf, "default-directory", dir <> "/")

    press(["C-c", "C-x"])

    assert File.read!(Path.join(dir, "lib/demo.ex")) == "defmodule Demo do\nend\n"
    refute File.exists?(Path.join(dir, "no"))
  end


  test "a second run replaces the result block" do
    buf = morg_buffer("```sh\necho hi\n```\n")
    :ok = Buffer.goto(buf, 7)

    press(["C-c", "C-c"])
    press(["C-c", "C-c"])
    assert Buffer.text(buf) == "```sh\necho hi\n```\n```result\nhi\n```\n"
  end


  test "a scheme block evaluates in the editor's interpreter" do
    buf = morg_buffer("```scheme\n(+ 1 2)\n```\n")
    :ok = Buffer.goto(buf, 11)

    press(["C-c", "C-c"])
    assert Buffer.text(buf) == "```scheme\n(+ 1 2)\n```\n```result\n3\n```\n"
  end


  test "C-c C-c outside a block does not edit the buffer" do
    buf = morg_buffer(fixture())
    :ok = Buffer.goto(buf, 5)

    press(["C-c", "C-c"])
    assert Buffer.text(buf) == fixture()
  end


  test "the result block is not runnable" do
    buf = morg_buffer("```result\nold\n```\n")
    :ok = Buffer.goto(buf, 11)

    press(["C-c", "C-c"])
    assert Buffer.text(buf) == "```result\nold\n```\n"
  end


end
