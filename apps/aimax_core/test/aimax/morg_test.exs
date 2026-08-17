defmodule Aimax.MorgTest do
  @moduledoc "Drives morg-mode through the same key/command path the GUI uses."

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

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

  test "morg-mode fontifies headings with the org level faces" do
    buf = morg_buffer(fixture())
    assert Buffer.get_local(buf, "mode-name") == "morg-mode"

    ovs = Buffer.overlays(buf)
    assert {0, 3, "org-level-1"} in ovs
    assert {9, 17, "org-level-2"} in ovs
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
