defmodule Aimax.BackendStubTest.NoTransport do
  @moduledoc "A transport that flunks: proves the stub backend never touches the wire."
  @behaviour Aimax.Core.Agent.Transport

  @impl true
  def open(_cmd, _opts, _owner) do
    send(:persistent_term.get(:stub_test_pid), :transport_opened)
    {:ok, nil}
  end

  @impl true
  def send_frame(_state, _data), do: :ok
  @impl true
  def close(_state), do: :ok
end

defmodule Aimax.BackendStubTest do
  @moduledoc """
  Drives everything ABOVE the backend seam — status machine, event pipeline,
  rendering, permission bookkeeping — through Backend.Stub: chunks, a tool
  card, and a permission round-trip land in a real buffer with no wire.
  """

  use ExUnit.Case

  alias Aimax.Core.{Agent, Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  setup do
    :persistent_term.put(:stub_test_pid, self())
    Application.put_env(:aimax_core, :acp_transport, Aimax.BackendStubTest.NoTransport)

    Editor.minibuffer_close()
    Editor.delete_other_windows()

    on_exit(fn ->
      Application.delete_env(:aimax_core, :acp_transport)
      Enum.each(Agent.list(), &Agent.kill/1)

      Enum.each(Aimax.Core.list_buffers(), fn name ->
        if String.starts_with?(name, "*agent") or Buffer.get_local(name, "agent-slug"),
          do: Aimax.Core.kill_buffer(name)
      end)

      Editor.delete_other_windows()
    end)

    :ok
  end

  test "stub backend: chunks + tool card + permission round-trip, no wire" do
    {:ok, _} =
      Session.eval("""
      (execute* "go" '(backend "stub" script
        (((type chunk text "Hello ")
          (type chunk text "world.\\n")
          (type tool-call id "tc1" title "Read foo.ex" kind "read" status "pending")
          (type tool-update id "tc1" status "completed" text "defmodule Foo\\n")
          (type permission rpc-id 7 title "Write foo.ex" kind "edit"
                options (("opt-allow" "Allow" "allow_once")
                         ("opt-reject" "Reject" "reject_once")))
          (type chunk text "Done.")))))
      """)

    buf = "*chat:a1*"

    # the scripted turn plays into the buffer, pausing at the permission
    assert eventually(fn -> Buffer.text(buf) =~ "needs permission: Write foo.ex" end)
    refute_received :transport_opened

    text = Buffer.text(buf)
    hello = :binary.match(text, "Hello world.") |> elem(0)
    tool = :binary.match(text, "▸ read · Read foo.ex") |> elem(0)
    body = :binary.match(text, "defmodule Foo") |> elem(0)
    assert hello < tool and tool < body

    assert %{status: :needs_attention, permission: perm} = Agent.info("a1")
    assert perm.rpc_id == 7
    assert [{"opt-allow", "Allow", "allow_once"} | _] = perm.options

    # the banner is in the block model while pending
    assert (Buffer.get_local(buf, "agent-blocks") || [])
           |> Enum.any?(&match?([_, _, "permission" | _], &1))

    # answer it — the same keybinding path as ACP threads
    {:ok, _} = Session.eval(~s[(begin (switch-to-buffer! "#{buf}") (end-of-buffer!))])
    press(["C-c", "C-y"])

    # the paused script resumes, finishes the turn, thread goes idle
    assert eventually(fn -> Buffer.text(buf) =~ "Done." end)
    assert eventually(fn -> match?(%{status: :idle}, Agent.info("a1")) end)

    # answered -> banner leaves the rich view; tool body folded away
    assert eventually(fn ->
             not ((Buffer.get_local(buf, "agent-blocks") || [])
                  |> Enum.any?(&match?([_, _, "permission" | _], &1)))
           end)

    assert [{s, e} | _] = Buffer.hidden(buf)
    assert s <= body and body < e
    refute_received :transport_opened
  end

  defp eventually(fun, tries \\ 40) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true ->
        Process.sleep(50)
        eventually(fun, tries - 1)
    end
  end
end
