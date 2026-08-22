defmodule Aimax.BufferLogTest do
  @moduledoc """
  M-x buffer-log (packages/provenance.scm): the list that shows a buffer's
  accepted revisions, driven the way a person drives it - through KeyDispatch.
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

  test "RET describes the revision on the line", %{name: name} do
    :ok = Buffer.insert_at(name, 4, "!", source: {:agent, "run-7"})
    eval!(~s{(switch-to-buffer! "#{name}")})
    press(["C-x", "v", "l"])

    press("RET")
    echo = Editor.snapshot().echo

    assert echo =~ "root"
    assert echo =~ "actor system:buffer"
    assert echo =~ "system"
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
