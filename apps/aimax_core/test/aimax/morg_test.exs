defmodule Aimax.MorgTest do
  @moduledoc "Drives morg-mode through the same key/command path the GUI uses."

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

  test ".md files open in morg-mode" do
    {:ok, printed} = Session.eval(~s{(auto-mode-for "notes.md")})
    assert printed == ~s{"morg-mode"}
  end

  test "morg-mode enables writing-mode, which keeps visual lines on" do
    buf = morg_buffer(fixture())

    assert Buffer.get_local(buf, "visual-line-mode") == true
    assert "writing-mode" in Buffer.get_local(buf, "minor-modes")
  end

  test "markdown-mode is separate and keeps the Earmark preview" do
    buf = morg_buffer("# title\n\nbody\n")

    {:ok, _} = Session.eval(~s{(set-mode! "markdown-mode")})

    assert Buffer.get_local(buf, "mode-name") == "markdown-mode"
    assert Buffer.get_local(buf, "preview-renderer") == "markdown"
    assert Buffer.get_local(buf, "ts-lang") == "markdown"
    refute Enum.any?(Buffer.overlays(buf), fn {_, _, face} -> face =~ "org-level" end)

    press(["C-c", "C-v"])
    assert Buffer.get_local(buf, "render-mode") == "markdown"
  end

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

  test "morg-mode fontifies headings with the org level faces" do
    buf = morg_buffer(fixture())
    assert Buffer.get_local(buf, "mode-name") == "morg-mode"
    assert Buffer.get_local(buf, "ts-lang") == "markdown"

    ovs = Buffer.overlays(buf)
    assert {0, 3, "org-level-1"} in ovs
    assert {9, 17, "org-level-2"} in ovs
  end

  test "C-c C-t cycles TODO, DONE, and no state" do
    buf = morg_buffer("# task\n")
    :ok = Buffer.goto(buf, 0)

    press(["C-c", "C-t"])
    assert Buffer.text(buf) == "# TODO task\n"
    assert {2, 6, "org-todo"} in Buffer.overlays(buf)

    press(["C-c", "C-t"])
    assert Buffer.text(buf) == "# DONE task\n"
    assert {2, 6, "org-done"} in Buffer.overlays(buf)

    press(["C-c", "C-t"])
    assert Buffer.text(buf) == "# task\n"
    refute Enum.any?(Buffer.overlays(buf), fn {_, _, face} ->
             face in ["org-todo", "org-done"]
           end)
  end

  test "C-c C-t does not change a body line" do
    text = "# task\nbody\n"
    buf = morg_buffer(text)
    :ok = Buffer.goto(buf, 8)

    press(["C-c", "C-t"])
    assert Buffer.text(buf) == text
  end

  test "TODO cycling keeps a folded task folded and undoes in one step" do
    buf = morg_buffer("# task\nbody\n")
    :ok = Buffer.goto(buf, 0)
    press("TAB")
    assert Buffer.hidden(buf) == [{6, 12}]

    press(["C-c", "C-t"])
    assert Buffer.text(buf) == "# TODO task\nbody\n"
    assert Buffer.hidden(buf) == [{11, 17}]

    press("C-/")
    assert Buffer.text(buf) == "# task\nbody\n"
  end

  test "TAB folds and unfolds the heading subtree at point" do
    buf = morg_buffer(fixture())
    :ok = Buffer.goto(buf, 0)

    press("TAB")
    # "# a" subtree = body + child + cbody (bytes 3..23)
    assert Buffer.hidden(buf) == [{3, 23}]

    press("TAB")
    assert Buffer.hidden(buf) == []
  end

  test "S-TAB cycles overview / show-all" do
    buf = morg_buffer(fixture())
    :ok = Buffer.goto(buf, 0)

    press("S-TAB")
    refute Buffer.hidden(buf) == []

    press("S-TAB")
    assert Buffer.hidden(buf) == []
  end

  test "M-x morg-outline folds every heading body" do
    buf = morg_buffer(fixture())
    :ok = Buffer.goto(buf, 9)
    press("TAB")
    :ok = Buffer.goto(buf, 5)

    press("M-x")
    type("morg-outline")
    press("RET")

    assert Buffer.get_local(buf, "morg-folds") == [0, 9, 24]
    assert Buffer.hidden(buf) == [{3, 8}, {17, 23}, {27, 33}]
    assert Buffer.point(buf) == 0

    press("M-x")
    type("morg-outline")
    press("RET")

    assert Buffer.get_local(buf, "morg-folds") == [0, 9, 24]
  end

  test "TAB toggles one heading without leaving outline mode" do
    buf = morg_buffer(fixture())

    press("M-x")
    type("morg-outline")
    press("RET")

    :ok = Buffer.goto(buf, 9)
    press("TAB")

    assert Buffer.get_local(buf, "morg-outline") == true
    assert Buffer.get_local(buf, "morg-folds") == [0, 24]
    assert Buffer.hidden(buf) == [{3, 8}, {27, 33}]

    press("TAB")
    assert Buffer.hidden(buf) == [{3, 8}, {17, 23}, {27, 33}]
  end

  test "TAB on a fence folds the code block" do
    buf = morg_buffer("```elixir\n1 + 1\n```\n# next\n")
    :ok = Buffer.goto(buf, 0)

    press("TAB")
    # open fence eol (9) .. end of the close fence line (19)
    assert Buffer.hidden(buf) == [{9, 19}]

    press("TAB")
    assert Buffer.hidden(buf) == []
  end

  test "TAB inside a block body folds the enclosing block" do
    buf = morg_buffer("```elixir\n1 + 1\n```\n")
    :ok = Buffer.goto(buf, 12)

    press("TAB")
    assert Buffer.hidden(buf) == [{9, 19}]
  end

  test "a # line inside a fenced block is not a heading" do
    buf = morg_buffer("# real\n```sh\n# comment\n```\n")

    ovs = Buffer.overlays(buf)
    assert {0, 6, "org-level-1"} in ovs
    refute Enum.any?(ovs, fn {s, _, f} -> s == 13 and f =~ "org-level" end)

    # the fold from the heading swallows the whole block: no second heading
    :ok = Buffer.goto(buf, 0)
    press("TAB")
    assert Buffer.hidden(buf) == [{6, 27}]
  end

  test "fenced code renders with the theme's ts faces" do
    buf = morg_buffer("```elixir\ndef foo do\n  :ok\nend\n```\n")

    assert Enum.any?(Buffer.overlays(buf), fn {_, _, f} ->
             String.starts_with?(f, "ts-")
           end)
  end

  test "an unknown language renders plain, without error" do
    buf = morg_buffer("```brainfuck\n+++\n```\n")

    refute Enum.any?(Buffer.overlays(buf), fn {_, _, f} ->
             String.starts_with?(f, "ts-")
           end)
  end

  test "C-c C-c runs a sh block into a result block" do
    buf = morg_buffer("```sh\necho hi\n```\n")
    :ok = Buffer.goto(buf, 7)

    press(["C-c", "C-c"])
    assert Buffer.text(buf) == "```sh\necho hi\n```\n```result\nhi\n```\n"
  end

  test "morg-babel and morg-tangle load as Morg package extensions" do
    assert {:ok, commands} =
             Session.eval(~s{(list (member "morg-babel" (command-names))
                                   (member "morg-tangle" (command-names)))})

    assert commands =~ "morg-babel"
    assert commands =~ "morg-tangle"

    assert {:ok, babel} = Session.eval(~s{(catalog-entry 'command "morg-babel")})
    assert babel =~ ~s{package "morg-babel"}

    assert {:ok, tangle} = Session.eval(~s{(catalog-entry 'command "morg-tangle")})
    assert tangle =~ ~s{package "morg-tangle"}
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

  test "folds re-anchor through edits above them" do
    buf = morg_buffer(fixture())
    :ok = Buffer.goto(buf, 0)

    press("TAB")
    assert Buffer.hidden(buf) == [{3, 23}]

    # an insert before the fold pushes the hidden range down
    :ok = Buffer.insert_at(buf, 0, "x", source: :user)
    assert Buffer.hidden(buf) == [{4, 24}]
  end

  test "mode setup re-derives folds from the surviving local" do
    buf = morg_buffer(fixture())
    :ok = Buffer.goto(buf, 0)
    press("TAB")
    assert Buffer.hidden(buf) == [{3, 23}]

    # a restart drops hidden ranges but keeps locals: simulate, re-setup
    {:ok, _} = Session.eval(~s{(fold-set! "#{buf}" 'morg '())})
    assert Buffer.hidden(buf) == []
    {:ok, _} = Session.eval(~s{(set-mode! "morg-mode")})
    assert Buffer.hidden(buf) == [{3, 23}]
  end
end
