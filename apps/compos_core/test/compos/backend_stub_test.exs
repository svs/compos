defmodule Compos.BackendStubTest.NoTransport do
  @moduledoc "A transport that flunks: proves the stub backend never touches the wire."
  @behaviour Compos.Core.Agent.Transport

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

defmodule Compos.BackendStubTest do
  @moduledoc """
  Drives everything ABOVE the backend seam — status machine, event pipeline,
  rendering, permission bookkeeping — through Backend.Stub: chunks, a tool
  card, and a permission round-trip land in a real buffer with no wire.
  """

  use Compos.Case

  alias Compos.Core.{Agent, Buffer, Editor, Session}

  setup do
    :persistent_term.put(:stub_test_pid, self())
    Application.put_env(:compos_core, :acp_transport, Compos.BackendStubTest.NoTransport)

    Editor.minibuffer_close()
    Compos.TestHelpers.one_window!()

    on_exit(fn ->
      Application.delete_env(:compos_core, :acp_transport)
      Enum.each(Agent.list(), &Agent.kill/1)

      Enum.each(Compos.Core.list_buffers(), fn name ->
        if String.starts_with?(name, "*agent") or Buffer.get_local(name, "agent-slug"),
          do: Compos.Core.kill_buffer(name)
      end)

      Compos.TestHelpers.one_window!()
    end)

    :ok
  end

  test "stub backend: chunks + tool card + permission round-trip, no wire" do
    {slug, buf} =
      spawn_chat!("""
      (execute* "go" '(permission-mode ask backend "stub" script
        (((type chunk text "Hello ")
          (type chunk text "world.\\n")
          (type tool-call id "tc1" title "Read foo.ex" kind "read" status "pending")
          (type tool-update id "tc1" status "completed" text "defmodule Foo\\n")
          (type permission rpc-id 7 title "Run make" kind "execute"
                options (("opt-allow" "Allow" "allow_once")
                         ("opt-reject" "Reject" "reject_once")))
          (type chunk text "Done.")))))
      """)

    # the scripted turn plays into the buffer, pausing at the permission
    assert eventually(fn -> Buffer.text(buf) =~ "needs permission: Run make" end)
    refute_received :transport_opened

    text = Buffer.text(buf)
    hello = :binary.match(text, "Hello world.") |> elem(0)
    tool = :binary.match(text, "▸ read · Read foo.ex") |> elem(0)
    body = :binary.match(text, "defmodule Foo") |> elem(0)
    assert hello < tool and tool < body

    assert %{status: :needs_attention, permission: perm} = Agent.info(slug)
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
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)

    # answered -> banner leaves the rich view; tool body folded away
    assert eventually(fn ->
             not ((Buffer.get_local(buf, "agent-blocks") || [])
                  |> Enum.any?(&match?([_, _, "permission" | _], &1)))
           end)

    assert [{s, e} | _] = Buffer.hidden(buf)
    assert s <= body and body < e
    refute_received :transport_opened
  end

  test "prose after a completed tool stays outside its fold; the waiting overlay dies with its line" do
    {slug, buf} =
      spawn_chat!("""
      (execute* "go" '(backend "stub" script
        (((type user-msg text "go")
          (type tool-call id "tc1" title "Read foo.ex" kind "read" status "pending")
          (type tool-update id "tc1" status "completed" text "defmodule Foo\\n")
          (type chunk text "The answer is 42.\\n")))))
      """)

    assert eventually(fn -> Buffer.text(buf) =~ "The answer is 42." end)
    assert eventually(fn -> match?(%{status: :idle}, Agent.info(slug)) end)

    text = Buffer.text(buf)
    body = :binary.match(text, "defmodule Foo") |> elem(0)
    answer = :binary.match(text, "The answer is 42.") |> elem(0)

    # the tool body folds away; the reply that streamed at the fold's end
    # boundary stays visible
    hidden = Buffer.hidden(buf)
    assert Enum.any?(hidden, fn {s, e} -> s <= body and body < e end)
    refute Enum.any?(hidden, fn {s, e} -> s <= answer and answer < e end)

    # the waiting line left the text AND the overlay local: a stale entry
    # re-applies its face over whatever text replaced the line
    refute text =~ "⋯ thinking"

    ovs = Buffer.get_local(buf, "agent-overlays") || []
    refute Enum.any?(ovs, fn [s, e | _] -> s <= answer and answer < e end)
  end

  # 5 s: the first test of a run shares the VM with the boot warmup
  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true ->
        Process.sleep(50)
        eventually(fun, tries - 1)
    end
  end
end
