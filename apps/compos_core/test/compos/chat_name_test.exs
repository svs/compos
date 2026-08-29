defmodule Compos.ChatNameTest do
  @moduledoc """
  The two rename tests Scheme cannot hold.

  How a chat gets its name is Scheme policy and lives in
  priv/tests/chat-name-test.scm. One test here starts an agent and reads
  the buffer ref its session holds. The other presses C-c s.
  """

  use ExUnit.Case

  alias Compos.Core.{Agent, Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp buffer(name, text) do
    {:ok, _} = Compos.Core.create_buffer(name, text: text)

    on_exit(fn ->
      for n <- [name | Compos.Core.list_buffers()],
          n == name or String.starts_with?(n, "*zz-named"),
          Buffer.exists?(n),
          do: Compos.Core.kill_buffer(n)
    end)

    name
  end

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    :ok
  end

  describe "the rename itself" do
    test "a live LLM session follows a renamed chat into its second turn" do
      old = buffer("*zz-live-chat*", "conversation\n")
      slug = "rename-#{System.unique_integer([:positive])}"
      ref = Buffer.ref(old)
      id = Buffer.id(ref)

      {:ok, _agent} =
        Agent.start(slug, %{
          "backend" => "stub",
          "buffer" => old,
          "mark" => Buffer.byte_size(old),
          "script" => []
        })

      on_exit(fn -> Agent.kill(slug) end)

      assert eval!(~s{(rename-buffer! "#{old}" "*zz-named-live-chat*")}) ==
               ~s{"*zz-named-live-chat*"}

      # The session owns the immutable ref. No rename notification/rebinding
      # is involved: the same handle resolves to the renamed buffer object.
      assert Buffer.id("*zz-named-live-chat*") == id
      assert Buffer.name(ref) == "*zz-named-live-chat*"
      assert eval!(~s{(agent-append! "#{slug}" "second turn\n")}) =~ ~r/^\d+$/
      assert Buffer.text("*zz-named-live-chat*") =~ "second turn"
      assert Agent.info(slug).buffer == "*zz-named-live-chat*"
      assert Agent.info(slug).buffer_id == id
    end

    test "a renamed scratch is still its owner's scratch, so C-c s keeps toggling" do
      owner = "zz-owner-#{System.unique_integer([:positive])}"
      {:ok, _} = Compos.Core.create_buffer(owner, text: "code\n")
      Editor.delete_other_windows()
      Editor.set_window_buffer(owner)

      on_exit(fn ->
        for n <- Compos.Core.list_buffers(),
            n == owner or String.starts_with?(n, "*scratch:") or
              String.starts_with?(n, "*zz-named"),
            do: Compos.Core.kill_buffer(n)
      end)

      press(["C-c", "s"])
      scratch = Editor.current_buffer()
      assert scratch == "*scratch:#{owner}*"

      assert eval!(~s{(rename-buffer! "#{scratch}" "*zz-named-scratch*")}) ==
               ~s{"*zz-named-scratch*"}

      assert Buffer.get_local(owner, "scratch-buffer") == "*zz-named-scratch*"

      # from the renamed scratch, back to the owner; and back again to the
      # same buffer, not to a second one under the old name
      Editor.set_window_buffer("*zz-named-scratch*")
      press(["C-c", "s"])
      assert Editor.current_buffer() == owner

      press(["C-c", "s"])
      assert Editor.current_buffer() == "*zz-named-scratch*"
      refute Buffer.exists?(scratch)
    end

  end
end
