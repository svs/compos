defmodule Compos.KeyTraceTest do
  @moduledoc """
  trace-key: one keystroke leaves one state row per dispatch phase, and
  the rows show which phase moved point. The chat scenario is the reason
  the tool exists: a point stranded in the hidden transcript snaps to the
  input during pre-command, and the trace shows the move.
  """

  use ExUnit.Case

  alias Compos.Core.{Buffer, Editor, KeyDispatch, Session}

  defp field(row, key) do
    case Enum.find_index(row, &(&1 == {:sym, key})) do
      nil -> nil
      i -> Enum.at(row, i + 1)
    end
  end

  defp row_named(rows, phase), do: Enum.find(rows, &(field(&1, "phase") == phase))

  defp fresh_buffer(name, text) do
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    Editor.set_window_buffer(name)
    :ok = Buffer.append(name, text, source: :editor)
    name
  end

  test "a printable key reports its phases and the point they leave" do
    buf = fresh_buffer("*key-trace-plain*", "seed ")
    {:ok, _} = Session.eval(~s[(begin (switch-to-buffer! "#{buf}") (end-of-buffer!))])
    p0 = Buffer.point(buf)
    size0 = Buffer.byte_size(buf)

    rows = KeyDispatch.trace_keys(["x"])

    assert field(row_named(rows, "key"), "point") == p0
    assert row_named(rows, "self-insert")
    assert row_named(rows, "pre-command")
    done = row_named(rows, "after-command")
    assert field(done, "point") == p0 + 1
    assert field(done, "size") == size0 + 1
  end

  test "a stranded chat point snaps home during pre-command, visibly" do
    marker = "\n>>> you: "
    mark = byte_size("transcript body")
    buf = fresh_buffer("*key-trace-chat*", "transcript body" <> marker)

    {:ok, _} =
      Session.eval("""
      (begin
        (switch-to-buffer! "*key-trace-chat*")
        (buffer-set-local! "*key-trace-chat*" 'render-mode "agent")
        (buffer-set-local! "*key-trace-chat*" 'agent-saved-mark #{mark})
        (buffer-set-local! "*key-trace-chat*" 'agent-marker-bytes #{byte_size(marker)})
        (beginning-of-buffer!))
      """)

    size = Buffer.byte_size(buf)
    rows = KeyDispatch.trace_keys(["a"])

    # the key found point in the hidden transcript
    assert field(row_named(rows, "key"), "point") == 0
    # pre-command snapped it home before any text changed
    pre = row_named(rows, "pre-command")
    assert field(pre, "point") == size
    assert field(pre, "size") == size
    # the insert landed in the input region
    done = row_named(rows, "after-command")
    assert field(done, "point") == size + 1
    assert String.ends_with?(Buffer.text(buf), "a")
  end
end
