defmodule Aimax.BufferLogTest do
  @moduledoc """
  M-x buffer-log (packages/provenance.scm): the list that shows a buffer's
  changes, driven the way a person drives it - through KeyDispatch.

  The rows come from the buffer's history rather than from a revision table, so
  two things read differently than they used to. Adjacent single-character
  inserts are one operation, because the history stores a run rather than a
  keystroke each. And a delete reports how many bytes it took, not the text:
  the text is still in the history, but reading it back means checking out the
  version before the delete.
  """

  use ExUnit.Case, async: false

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp log_text, do: Buffer.text("*buffer-log*")

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    name = "*buffer-log-src-#{System.unique_integer([:positive])}*"
    {:ok, ^name} = Aimax.Core.create_buffer(name, text: "base")

    on_exit(fn ->
      Editor.set_window_buffer("*scratch*")
      Aimax.Core.kill_buffer("*buffer-log*")
      Aimax.Core.kill_buffer("*revision*")
      Aimax.Core.kill_buffer(name)
    end)

    %{name: name}
  end

  test "C-x v l lists every revision of the buffer, oldest first", %{name: name} do
    :ok = Buffer.insert_at(name, 4, "!", source: {:agent, "run-7"})
    eval!(~s{(switch-to-buffer! "#{name}")})

    press(["C-x", "v", "l"])

    assert Buffer.exists?("*buffer-log*")
    text = log_text()

    assert text =~ "Provenance: #{name}"
    assert text =~ "root"
    assert text =~ "edit"
    assert text =~ "agent:run-7"
    # the edit inserted one byte at 4
    assert text =~ "@4 +1 -0"
    # oldest first: the root row precedes the edit row
    [root_at, edit_at] = [:binary.match(text, "root"), :binary.match(text, "@4 +1 -0")]
    assert elem(root_at, 0) < elem(edit_at, 0)
  end

  test "the header names the recording state and the policy that set it", %{name: name} do
    eval!(~s{(switch-to-buffer! "#{name}")})
    press(["C-x", "v", "l"])
    assert log_text() =~ "recording"
    assert log_text() =~ "policy default"

    :ok =
      Buffer.provenance_stop(name, source: :editor, reason: "test", policy_source: "user")

    press("g")
    assert log_text() =~ "stopped"
    assert log_text() =~ "policy user"
  end

  # Three keystrokes in a row are one operation of three bytes, not three of
  # one. The history run-length encodes a run, which is why typing is cheap.
  test "typed work reads as the changeset it formed", %{name: name} do
    for {c, i} <- Enum.with_index(["a", "b", "c"]) do
      :ok = Buffer.insert_at(name, i, c, source: :user)
    end

    eval!(~s{(switch-to-buffer! "#{name}")})
    press(["C-x", "v", "l"])

    assert log_text() =~ "+3 -0"
    assert log_text() =~ "abc"
    assert log_text() =~ "user"
  end

  test "the list shows the text a change inserted", %{name: name} do
    :ok = Buffer.insert_at(name, 4, " and cheese", source: :user)
    eval!(~s{(switch-to-buffer! "#{name}")})
    press(["C-x", "v", "l"])

    assert log_text() =~ "and cheese"
  end

  test "the pointed row previews its revision without leaving the log", %{name: name} do
    :ok = Buffer.insert_at(name, 4, "!", source: {:agent, "run-7"})
    eval!(~s{(switch-to-buffer! "#{name}")})

    press(["C-x", "v", "l"])

    assert Editor.current_buffer() == "*buffer-log*"
    assert Buffer.text("*revision*") =~ "actor    system:buffer"
    assert eval!(~s{(window-showing "*revision*")}) != "#f"

    press("n")

    assert Editor.current_buffer() == "*buffer-log*"
    assert Buffer.text("*revision*") =~ "actor    agent:run-7"
    assert Buffer.text("*revision*") =~ "+ !"
  end

  test "a deletion reads as the bytes it removed", %{name: name} do
    :ok = Buffer.delete_range(name, 0, 4, source: :user)
    eval!(~s{(switch-to-buffer! "#{name}")})
    press(["C-x", "v", "l"])

    assert log_text() =~ "+0 -4"
    assert log_text() =~ "-4B"
  end

  test "a newline in the text does not break the row", %{name: name} do
    :ok = Buffer.insert_at(name, 4, "\nsecond line", source: :user)
    eval!(~s{(switch-to-buffer! "#{name}")})
    press(["C-x", "v", "l"])

    assert log_text() =~ "\\nsecond line"
  end

  test "RET visits the whole revision with every operation and its text", %{name: name} do
    :ok = Buffer.insert_at(name, 4, "!", source: {:agent, "run-7"})
    eval!(~s{(switch-to-buffer! "#{name}")})
    press(["C-x", "v", "l"])
    on_exit(fn -> Aimax.Core.kill_buffer("*revision*") end)

    # the agent revision is the last row
    eval!(~s{(list-goto-index! "*buffer-log*" 1)})
    press("RET")

    assert Editor.current_buffer() == "*revision*"
    text = Buffer.text("*revision*")
    assert text =~ "actor    agent:run-7"
    assert text =~ "@4"
    assert text =~ "+ !"
    # A change names its place in the DAG rather than hashing its result.
    assert text =~ "parent   "
    assert text =~ "lamport  "
  end

  test "RET describes the revision on the line", %{name: name} do
    :ok = Buffer.insert_at(name, 4, "!", source: {:agent, "run-7"})
    eval!(~s{(switch-to-buffer! "#{name}")})
    press(["C-x", "v", "l"])

    press("RET")
    on_exit(fn -> Aimax.Core.kill_buffer("*revision*") end)

    text = Buffer.text("*revision*")
    assert text =~ "root"
    assert text =~ "actor    system:buffer"
    assert text =~ "system"
  end

  test "a buffer with no history says so rather than raising" do
    name = "*buffer-log-absent*"
    eval!(~s{(switch-to-buffer! "*scratch*")})
    press(["C-x", "v", "l"])
    assert Buffer.exists?("*buffer-log*")
    refute log_text() == ""
    refute Buffer.exists?(name)
  end
end
