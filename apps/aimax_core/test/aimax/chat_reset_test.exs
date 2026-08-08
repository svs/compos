defmodule Aimax.ChatResetTest.FakeTransport do
  @behaviour Aimax.Core.Agent.Transport

  @impl true
  def open(cmd, _opts, owner) do
    test = :persistent_term.get(:chat_reset_test_pid)
    send(test, {:transport_open, owner})
    send(test, {:transport_cmd, cmd})
    {:ok, test}
  end

  @impl true
  def send_frame(_test, _data), do: :ok

  @impl true
  def close(_test), do: :ok
end

defmodule Aimax.ChatResetTest do
  @moduledoc "chat-reset wipes the conversation but keeps the surface."

  use ExUnit.Case

  alias Aimax.Core.Session

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  test "a rich group chat resets to its meta card, keeping the group" do
    eval!(~s{(begin
      (switch-to-buffer! (group-chat "resetg"))
      (set-mode! "chat-mode")
      (chat-turn-push! (current-buffer) "user" "hello")
      (buffer-append! (current-buffer) "old transcript junk")
      #t)})

    eval!(~s{(run-command "chat-reset")})

    text = eval!(~s{(buffer-text (current-buffer))})
    assert text =~ "companion · resetg"
    refute text =~ "old transcript junk"
    assert eval!(~s{(chat-turns (current-buffer))}) == "()"
    assert eval!(~s{(buffer-group (current-buffer))}) == ~s{"resetg"}
    # rich again: a fresh mark exists and the input marker is in place
    assert eval!(~s{(if (buffer-local (current-buffer) 'agent-saved-mark) #t #f)}) == "#t"
    assert text =~ "you ▸"
  end

  test "a legacy plain chat resets onto the one rich surface" do
    eval!(~s{(begin
      (buffer-create "*plain-reset*")
      (switch-to-buffer! "*plain-reset*")
      (set-mode! "chat-mode")
      (buffer-append! (current-buffer) "### You\\nstale conversation")
      #t)})

    eval!(~s{(run-command "chat-reset")})

    text = eval!(~s{(buffer-text "*plain-reset*")})
    assert text =~ "companion ·"
    assert text =~ "you ▸"
    refute text =~ "stale conversation"
    assert eval!(~s{(if (buffer-local (current-buffer) 'agent-saved-mark) #t #f)}) == "#t"
  end

  test "a saved .chat file revives as a live conversation" do
    dir = Path.join(System.tmp_dir!(), "chat-revive-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "old-talk.chat")
    File.write!(path, "### You\nremember the plan?\n### Assistant\nYes: ship mail.\n### You\n")

    eval!(~s{(visit "#{path}")})
    assert eval!(~s{(buffer-local (current-buffer) 'mode-name)}) == ~s{"chat-mode"}
    assert eval!(~s{(buffer-text (current-buffer))}) =~ "ship mail"
  end

  test "C-x C-s on a rich chat writes the flattened transcript" do
    dir = Path.join(System.tmp_dir!(), "chat-flat-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "rich.chat")

    eval!(~s{(begin
      (switch-to-buffer! (group-chat "flatg"))
      (set-mode! "chat-mode")
      (chat-turn-push! (current-buffer) "user" "what shipped?")
      (chat-turn-push! (current-buffer) "assistant" "the mail client")
      #t)})
    eval!(~s{(run-command "save-buffer")})
    Enum.each(String.graphemes("#{path}"), &Aimax.Core.KeyDispatch.handle_key/1)
    Aimax.Core.KeyDispatch.handle_key("RET")

    saved = File.read!(path)
    assert saved =~ "### You\nwhat shipped?"
    assert saved =~ "### Assistant\nthe mail client"
    # no block-render artifacts in the artifact
    refute saved =~ "you ▸"
    assert eval!("(current-buffer)") == ~s{"#{path}"}
    assert eval!(~s{(buffer-local (current-buffer) 'mode-name)}) == ~s{"chat-mode"}
  end

  test "C-x C-s on a non-file chat converts it to a .chat file buffer" do
    dir = Path.join(System.tmp_dir!(), "chat-cxs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "talk.chat")

    eval!(~s{(begin
      (buffer-create "*cxs-chat*")
      (switch-to-buffer! "*cxs-chat*")
      (set-mode! "chat-mode")
      (buffer-append! (current-buffer) "### You\nsave me properly\n")
      #t)})

    eval!(~s{(run-command "save-buffer")})
    Enum.each(String.graphemes("#{path}"), &Aimax.Core.KeyDispatch.handle_key/1)
    Aimax.Core.KeyDispatch.handle_key("RET")

    assert File.read!(path) =~ "save me properly"
    # the buffer became the file buffer, still a chat, old name gone
    assert eval!("(current-buffer)") == ~s{"#{path}"}
    assert eval!(~s{(buffer-local (current-buffer) 'mode-name)}) == ~s{"chat-mode"}
    assert eval!(~s{(buffer-exists? "*cxs-chat*")}) == "#f"

    # from now on C-x C-s just overwrites
    eval!(~s{(begin (end-of-buffer!) (insert! "more words") #t)})
    eval!(~s{(run-command "save-buffer")})
    assert File.read!(path) =~ "more words"
  end

  test "reset severs a dead ACP backend without erroring" do
    eval!(~s{(begin
      (switch-to-buffer! (group-chat "acp-reset"))
      (set-mode! "chat-mode")
      (buffer-set-local! (current-buffer) 'agent-slug "no-such-agent")
      (buffer-set-local! (current-buffer) 'agent-seed-context #t)
      #t)})
    eval!(~s{(run-command "chat-reset")})
    assert eval!(~s{(buffer-local (current-buffer) 'agent-seed-context)}) == "#f"
    assert eval!(~s{(buffer-text (current-buffer))}) =~ "companion · acp-reset"
  end

  test "seed context carries the conversation, never the meta-card chrome" do
    eval!(~s{(begin (switch-to-buffer! (group-chat "seedg")) #t)})
    # fresh surface: only the meta card — nothing to seed
    assert eval!(~s{(string-trim (agent-conversation-text (current-buffer)))}) == ~s{""}

    eval!(~s{(let* ((buf (current-buffer)) (s (buffer-size buf)))
      (buffer-append! buf "what shipped today?")
      (chat-blocks-push! buf s (buffer-size buf) "user" '())
      (buffer-set-local! buf 'agent-saved-mark (buffer-size buf))
      #t)})
    tail = eval!(~s{(agent-seed-transcript (current-buffer))})
    assert tail =~ "what shipped today?"
    refute tail =~ "companion"
    refute tail =~ "RET sends"

    # with turns present, the seed is the whole flattened chat
    eval!(~s{(begin
      (chat-turn-push! (current-buffer) "user" "what shipped today?")
      (chat-turn-push! (current-buffer) "assistant" "the whole mail client")
      #t)})
    seed = eval!(~s{(agent-seed-transcript (current-buffer))})
    assert seed =~ "### You"
    assert seed =~ "### Assistant"
    assert seed =~ "the whole mail client"
    refute seed =~ "companion"
  end

  test "C-c m on an ACP chat reconnects on the new model" do
    :persistent_term.put(:chat_reset_test_pid, self())
    Application.put_env(:aimax_core, :acp_transport, Aimax.ChatResetTest.FakeTransport)

    on_exit(fn ->
      Application.delete_env(:aimax_core, :acp_transport)
      Aimax.Core.Agent.kill("zz9")
    end)

    eval!(~s{(begin
      (switch-to-buffer! (group-chat "modelg"))
      (set-mode! "chat-mode")
      (buffer-set-local! (current-buffer) 'agent-slug "zz9")
      (buffer-set-local! (current-buffer) 'agent-connector "claude-code")
      #t)})

    eval!(~s{(run-command "chat-set-model")})
    Enum.each(String.graphemes("claude-opus-5"), &Aimax.Core.KeyDispatch.handle_key/1)
    Aimax.Core.KeyDispatch.handle_key("RET")

    # a fresh session spawned on the connector, model pinned and shown
    assert_receive {:transport_open, _}, 1_000
    assert_receive {:transport_cmd, cmd}, 1_000
    assert cmd =~ "claude-code-acp"
    assert eval!(~s{(buffer-local (current-buffer) 'agent-model)}) == ~s{"claude-opus-5"}
    assert eval!(~s{(buffer-local (current-buffer) 'modeline-info)}) =~ "claude-opus-5"
  end

  test "a stale cross-connector model is dropped on revive" do
    :persistent_term.put(:chat_reset_test_pid, self())
    Application.put_env(:aimax_core, :acp_transport, Aimax.ChatResetTest.FakeTransport)

    on_exit(fn ->
      Application.delete_env(:aimax_core, :acp_transport)
      Aimax.Core.Agent.kill("zz8")
    end)

    eval!(~s{(begin
      (switch-to-buffer! (group-chat "staleg"))
      (set-mode! "chat-mode")
      (buffer-set-local! (current-buffer) 'agent-slug "zz8")
      (buffer-set-local! (current-buffer) 'agent-connector "claude-code")
      (buffer-set-local! (current-buffer) 'agent-model "gpt-5.6-luna")
      (agent-revive! "zz8")
      #t)})

    assert_receive {:transport_open, _}, 1_000
    assert eval!(~s{(buffer-local (current-buffer) 'agent-model)}) == "#f"
    modeline = eval!(~s{(buffer-local (current-buffer) 'modeline-info)})
    assert modeline =~ "claude-code"
    refute modeline =~ "gpt-5.6-luna"
  end

  test "switching backends never rebinds keys: RET is agent-send on every lane" do
    eval!(~s{(begin
      (switch-to-buffer! (group-chat "backg"))
      (set-mode! "chat-mode")
      (buffer-set-local! (current-buffer) 'agent-slug "no-such")
      (agent-install-keys! (current-buffer))
      #t)})

    assert Aimax.Core.Editor.lookup_key(["RET"]) == {:command, "agent-send"}

    eval!(~s{(run-command "chat-set-backend")})
    Enum.each(String.graphemes("api"), &Aimax.Core.KeyDispatch.handle_key/1)
    Aimax.Core.KeyDispatch.handle_key("RET")

    # the api lane is a connector like any other: same slug machinery,
    # same keys — the ec8cba3 bug class is structurally gone
    assert eval!(~s{(buffer-local (current-buffer) 'agent-connector)}) == ~s{"api"}
    assert eval!(~s{(buffer-local (current-buffer) 'agent-slug)}) != "#f"
    assert Aimax.Core.Editor.lookup_key(["RET"]) == {:command, "agent-send"}
  end

  test "outside a chat it refuses politely" do
    eval!(~s{(begin (switch-to-buffer! "*scratch*") (run-command "chat-reset"))})
    assert eval!(~s{(buffer-exists? "*scratch*")}) == "#t"
  end
end
