defmodule Aimax.OrgTest do
  @moduledoc "Drives org-mode through the same key/command path the GUI uses."

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(str), do: str |> String.graphemes() |> press()

  defp org_buffer(text) do
    name = "org-#{System.unique_integer([:positive])}.org"
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()
    Editor.set_window_buffer(name)
    :ok = Buffer.append(name, text, source: :editor)
    {:ok, _} = Session.eval(~s{(set-mode! "org-mode")})
    name
  end

  @doc false
  # "* a\nbody\n** child\ncbody\n* b\ntail\n"
  #  0123 4..8 9......17 ...   24.. 28..
  defp fixture, do: "* a\nbody\n** child\ncbody\n* b\ntail\n"

  test "org-mode sets up on .org buffers and fontifies headlines" do
    buf = org_buffer(fixture())
    assert Buffer.get_local(buf, "mode-name") == "org-mode"

    ovs = Buffer.overlays(buf)
    assert {0, 3, "org-level-1"} in ovs
    assert {9, 17, "org-level-2"} in ovs
  end

  test "TAB folds and unfolds the subtree at point" do
    buf = org_buffer(fixture())
    :ok = Buffer.goto(buf, 0)

    press("TAB")
    # "* a" subtree = body + child + cbody (bytes 3..23)
    assert Buffer.hidden(buf) == [{3, 23}]

    press("TAB")
    assert Buffer.hidden(buf) == []
  end

  test "S-TAB cycles overview / show-all" do
    buf = org_buffer(fixture())
    :ok = Buffer.goto(buf, 0)

    press("S-TAB")
    refute Buffer.hidden(buf) == []

    press("S-TAB")
    assert Buffer.hidden(buf) == []
  end

  test "C-c C-t cycles TODO -> DONE -> none" do
    buf = org_buffer("* task\n")
    :ok = Buffer.goto(buf, 0)

    press(["C-c", "C-t"])
    assert Buffer.text(buf) == "* TODO task\n"
    assert Enum.any?(Buffer.overlays(buf), fn {_, _, f} -> f == "org-todo" end)

    press(["C-c", "C-t"])
    assert Buffer.text(buf) == "* DONE task\n"

    press(["C-c", "C-t"])
    assert Buffer.text(buf) == "* task\n"
  end

  test "M-RET inserts a headline at the current level" do
    buf = org_buffer("** here\nbody\n")
    :ok = Buffer.goto(buf, 10)

    press("M-RET")
    assert Buffer.text(buf) == "** here\nbody\n** \n"
    type("next")
    assert Buffer.text(buf) == "** here\nbody\n** next\n"
  end

  test "M-arrows promote/demote a headline, de-dent/indent a plain line" do
    buf = org_buffer("** deep\n    indented\n")
    :ok = Buffer.goto(buf, 0)

    press("M-<left>")
    assert Buffer.text(buf) == "* deep\n    indented\n"
    press("M-<left>")
    assert Buffer.text(buf) == "* deep\n    indented\n"

    press("M-<right>")
    assert Buffer.text(buf) == "** deep\n    indented\n"

    # the de-dent extension: plain lines shift by 2 columns
    :ok = Buffer.goto(buf, 10)
    press("M-<left>")
    assert Buffer.text(buf) == "** deep\n  indented\n"
    press("M-<right>")
    assert Buffer.text(buf) == "** deep\n    indented\n"
  end

  test "M-S-<right> demotes the whole subtree" do
    buf = org_buffer("* a\n** kid\nbody\n* b\n")
    :ok = Buffer.goto(buf, 0)

    press("M-S-<right>")
    assert Buffer.text(buf) == "** a\n*** kid\nbody\n* b\n"
  end

  test "M-<down> / M-<up> swap sibling subtrees" do
    buf = org_buffer("* a\nbody-a\n* b\nbody-b\n* c\n")
    :ok = Buffer.goto(buf, 0)

    press("M-<down>")
    assert Buffer.text(buf) == "* b\nbody-b\n* a\nbody-a\n* c\n"
    # point followed the moved subtree's headline
    assert Buffer.point(buf) == 11

    press("M-<up>")
    assert Buffer.text(buf) == "* a\nbody-a\n* b\nbody-b\n* c\n"
    assert Buffer.point(buf) == 0
  end

  test "C-c C-c toggles a checkbox and recounts the parent cookie" do
    buf = org_buffer("* list [0/2]\n- [ ] one\n- [X] two\n")
    :ok = Buffer.goto(buf, 13)

    press(["C-c", "C-c"])
    assert Buffer.text(buf) == "* list [2/2]\n- [X] one\n- [X] two\n"

    press(["C-c", "C-c"])
    assert Buffer.text(buf) == "* list [1/2]\n- [ ] one\n- [X] two\n"
  end

  test "de-dented continuation lines don't break cookie scope" do
    buf = org_buffer("- parent [0/2]\n  - [ ] baz\n  bing\n  - [ ] qux\n")
    :ok = Buffer.goto(buf, 17)

    press(["C-c", "C-c"])
    assert Buffer.text(buf) == "- parent [1/2]\n  - [X] baz\n  bing\n  - [ ] qux\n"
  end

  test "typing a headline refontifies via the change hook" do
    buf = org_buffer("hello\n")
    :ok = Buffer.goto(buf, 6)

    type("* new headline")
    Process.sleep(200)

    assert Enum.any?(Buffer.overlays(buf), fn {s, _e, f} ->
             s == 6 and f == "org-level-1"
           end)
  end

  test "undo heals folds instead of leaving corpses" do
    buf = org_buffer(fixture())
    :ok = Buffer.goto(buf, 0)
    press("TAB")
    assert Buffer.hidden(buf) == [{3, 23}]

    # delete the folded headline's stars so it stops being a headline
    :ok = Buffer.delete_range(buf, 0, 2)
    Process.sleep(200)
    assert Buffer.hidden(buf) == []

    :ok = Buffer.undo(buf)
    Process.sleep(200)
    assert Buffer.text(buf) == fixture()
    assert Buffer.hidden(buf) == []
  end
end
