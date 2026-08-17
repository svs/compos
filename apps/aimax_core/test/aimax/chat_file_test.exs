defmodule Aimax.ChatFileTest.FakeTransport do
  @moduledoc "ACP seam: frames land in the test process."
  @behaviour Aimax.Core.Agent.Transport

  @impl true
  def open(cmd, _opts, owner) do
    test = :persistent_term.get(:chat_file_test_pid)
    send(test, {:transport_open, owner, cmd})
    {:ok, test}
  end

  @impl true
  def send_frame(test, data) do
    send(test, {:frame, Jason.decode!(IO.iodata_to_binary(data))})
    :ok
  end

  @impl true
  def close(_test), do: :ok
end

defmodule Aimax.ChatFileTest do
  @moduledoc """
  W9: a saved .chat is a conversation, not just text. One optional header
  line carries the chat's identity, so an opened file continues where it
  ran — same backend, same model, same presets — with its turns intact.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(str), do: str |> String.graphemes() |> press()

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp inject(agent, frame), do: send(agent, {:acp_data, Jason.encode!(frame) <> "\n"})

  setup do
    :persistent_term.put(:chat_file_test_pid, self())
    Application.put_env(:aimax_core, :acp_transport, Aimax.ChatFileTest.FakeTransport)

    Editor.minibuffer_close()
    Editor.delete_other_windows()

    dir = Path.join(System.tmp_dir!(), "chatfile-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      Application.delete_env(:aimax_core, :acp_transport)
      Enum.each(Aimax.Core.Agent.list(), &Aimax.Core.Agent.kill/1)

      # a buffer left claiming a slug hands the next suite a stale
      # (agent-buf "a1") — kill every chat this test touched
      Enum.each(Aimax.Core.list_buffers(), fn name ->
        if String.starts_with?(name, "*chat:") or String.ends_with?(name, ".chat") or
             Buffer.get_local(name, "agent-slug"),
           do: Aimax.Core.kill_buffer(name)
      end)

      File.rm_rf(dir)
      Editor.minibuffer_close()
      Editor.delete_other_windows()
    end)

    {:ok, dir: dir}
  end

  test "save writes an identity header; visiting it restores the conversation", %{dir: dir} do
    path = Path.join(dir, "work.chat")

    # a chat with a real identity and a real conversation
    eval!(~s[(begin
      (buffer-create "*chat:save-me*")
      (switch-to-buffer! "*chat:save-me*")
      (set-mode! "chat-mode")
      (chat-task-init! "*chat:save-me*" "t")
      (buffer-set-local! (current-buffer) 'agent-connector "codex")
      (buffer-set-local! (current-buffer) 'agent-model "gpt-5.5")
      (buffer-set-local! (current-buffer) 'agent-effort "high")
      (buffer-set-local! (current-buffer) 'chat-presets '(dev))
      (buffer-set-local! (current-buffer) 'chat-permission-mode 'ask)
      (chat-turn-push! (current-buffer) "user" "what shipped?")
      (chat-turn-push! (current-buffer) "assistant" "the mail client")
      #t)])

    eval!(~s{(run-command "save-buffer")})
    type(path)
    press(["RET"])

    saved = File.read!(path)

    # the header states who was running the chat...
    assert saved =~ ~s{#+chat: (connector "codex" model "gpt-5.5"}
    assert saved =~ "presets (dev)"
    assert saved =~ "permission-mode ask"
    assert saved =~ "effort \"high\""
    # ...above the ordinary portable transcript
    assert saved =~ "### You\nwhat shipped?"
    assert saved =~ "### Assistant\nthe mail client"
    # no rendering artifacts in the file
    refute saved =~ "you: "

    # --- open it fresh, as if after a restart ---------------------------
    eval!(~s[(begin (buffer-kill! "#{path}") #t)])
    eval!(~s[(visit "#{path}")])

    buf = path
    assert Buffer.get_local(buf, "mode-name") == "chat-mode"

    # identity is back
    assert Buffer.get_local(buf, "agent-connector") == "codex"
    assert Buffer.get_local(buf, "agent-model") == "gpt-5.5"
    assert Buffer.get_local(buf, "agent-effort") == "high"
    assert Buffer.get_local(buf, "chat-presets") == [sym: "dev"]
    assert Buffer.get_local(buf, "chat-permission-mode") == {:sym, "ask"}

    # the conversation is back as TURNS, not just text
    assert {:ok, ~s{(("user" "what shipped?") ("assistant" "the mail client"))}} =
             Session.eval(~s{(reverse (chat-turns "#{buf}"))})

    # and as a live surface: rendered cards, an input marker, RET sends
    text = Buffer.text(buf)
    assert text =~ ">>> you: what shipped?"
    assert text =~ "the mail client"
    refute text =~ "#+chat:"
    refute text =~ "### You"
    assert String.ends_with?(text, ">>> you: ")
    assert Buffer.get_local(buf, "agent-saved-mark")
    assert Editor.lookup_key(["RET"]) == {:command, "agent-send"}
  end

  test "RET on an opened .chat continues on ITS connector, seeded", %{dir: dir} do
    path = Path.join(dir, "resume.chat")

    File.write!(path, """
    #+chat: (connector "codex-acp" model "gpt-5.5" permission-mode approve)

    ### You
    remember the plan?

    ### Assistant
    Yes: ship mail.

    ### You
    """)

    eval!(~s[(visit "#{path}")])
    eval!(~s[(begin (switch-to-buffer! "#{path}") (end-of-buffer!))])

    type("what was step two?")
    press(["RET"])

    # it spawned the connector the FILE named, not the default
    assert_receive {:transport_open, agent, cmd}, 1_000
    assert cmd =~ "codex-acp"
    assert cmd =~ "gpt-5.5"

    assert_receive {:frame, %{"method" => "initialize", "id" => iid}}, 1_000
    inject(agent, %{"jsonrpc" => "2.0", "id" => iid, "result" => %{}})
    assert_receive {:frame, %{"method" => "session/new", "id" => nid}}, 1_000
    inject(agent, %{"jsonrpc" => "2.0", "id" => nid, "result" => %{"sessionId" => "sess-1"}})

    # ...and the first prompt carries the file's conversation
    assert_receive {:frame, %{"method" => "session/prompt", "params" => p}}, 1_000
    [%{"text" => sent}] = p["prompt"]
    assert sent =~ "remember the plan?"
    assert sent =~ "ship mail"
    assert sent =~ "what was step two?"
    # the header is file format — a model must never see it
    refute sent =~ "#+chat:"
  end

  test "a headerless .chat behaves exactly as before", %{dir: dir} do
    path = Path.join(dir, "legacy.chat")
    File.write!(path, "### You\nold hand-written notes\n### Assistant\nfine\n")

    eval!(~s[(visit "#{path}")])

    # opens as a chat, text untouched, no surface rebuilt behind the user's back
    assert Buffer.get_local(path, "mode-name") == "chat-mode"
    assert Buffer.text(path) == "### You\nold hand-written notes\n### Assistant\nfine\n"
    assert Buffer.get_local(path, "chat-wire-turns") in [nil, false]
    assert Buffer.get_local(path, "agent-saved-mark") in [nil, false]
  end

  test "a hand-edited header can't execute anything", %{dir: dir} do
    path = Path.join(dir, "evil.chat")

    File.write!(path, """
    #+chat: (connector "api") (buffer-create "*pwned*")

    ### You
    hi
    """)

    eval!(~s[(visit "#{path}")])

    # the header is READ inside a quote, never evaluated
    assert eval!(~s[(buffer-exists? "*pwned*")]) == "#f"
  end

  test "the round trip is stable: save, open, save again", %{dir: dir} do
    path = Path.join(dir, "round.chat")

    eval!(~s[(begin
      (buffer-create "*chat:round*")
      (switch-to-buffer! "*chat:round*")
      (set-mode! "chat-mode")
      (chat-task-init! "*chat:round*" "t")
      (buffer-set-local! (current-buffer) 'agent-connector "api")
      (chat-turn-push! (current-buffer) "user" "one")
      (chat-turn-push! (current-buffer) "assistant" "two")
      #t)])

    eval!(~s{(run-command "save-buffer")})
    type(path)
    press(["RET"])
    first = File.read!(path)

    eval!(~s[(begin (buffer-kill! "#{path}") #t)])
    eval!(~s[(visit "#{path}")])
    eval!(~s[(begin (switch-to-buffer! "#{path}") (run-command "save-buffer"))])

    assert File.read!(path) == first
  end
end
