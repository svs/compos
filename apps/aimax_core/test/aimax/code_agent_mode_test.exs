defmodule Aimax.CodeAgentModeTest do
  @moduledoc "code-agent-mode: a chat moves to the coding preset when its agent edits code."

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Session}

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp fresh_chat(name) do
    eval!(~s{(begin (buffer-create "#{name}") (buffer-set-local! "#{name}" 'agent-saved-mark 0))})

    on_exit(fn ->
      if Buffer.exists?(name), do: Aimax.Core.kill_buffer(name)
    end)

    name
  end

  setup do
    on_exit(fn ->
      {:ok, _} =
        Session.eval("""
        (for-each
          (lambda (b)
            (when (minor-mode-on? b "code-agent-mode")
              (disable-minor-mode! b "code-agent-mode")))
          (buffer-list))
        """)

      eval!("(customize-set! 'code-agent-auto #t)")
      eval!(~s{(customize-set! 'code-agent-connector "codex-app-server")})
      eval!(~s{(customize-set! 'code-agent-model "gpt-5.6-sol")})
      eval!(~s{(customize-set! 'code-agent-effort "medium")})
    end)

    :ok
  end

  test "the coding preset defaults to codex-app-server · gpt-5.6-sol · medium" do
    assert eval!("code-agent-connector") == ~s{"codex-app-server"}
    assert eval!("code-agent-model") == ~s{"gpt-5.6-sol"}
    assert eval!("code-agent-effort") == ~s{"medium"}
  end

  test "a structural code edit turns the mode on and pins the coding preset" do
    chat = fresh_chat("*cam-detect-#{System.unique_integer([:positive])}*")

    eval!(~s{(code-agent-note-tool! "#{chat}" "eval-scheme" "" "(code-replace! \\"a.ex\\" 3 \\"x\\")")})

    assert "code-agent-mode" in Buffer.get_local(chat, "minor-modes")
    # no live runtime: only the identity locals change; the next send attaches
    assert Buffer.get_local(chat, "agent-connector") == "codex-app-server"
    assert Buffer.get_local(chat, "agent-model") == "gpt-5.6-sol"
    assert Buffer.get_local(chat, "agent-effort") == "medium"
  end

  test "an ACP edit-kind tool call triggers too" do
    chat = fresh_chat("*cam-edit-#{System.unique_integer([:positive])}*")

    eval!(~s{(code-agent-note-tool! "#{chat}" "write foo.ex" "edit" "")})

    assert "code-agent-mode" in Buffer.get_local(chat, "minor-modes")
  end

  test "a read tool call, or a text edit to a prose buffer, does not trigger" do
    chat = fresh_chat("*cam-quiet-#{System.unique_integer([:positive])}*")
    prose = "cam-prose-#{System.unique_integer([:positive])}.txt"
    eval!(~s{(buffer-create "#{prose}")})
    on_exit(fn -> if Buffer.exists?(prose), do: Aimax.Core.kill_buffer(prose) end)

    eval!(~s{(code-agent-note-tool! "#{chat}" "eval-scheme" "" "(code-outline \\"a.ex\\")")})
    eval!(~s{(code-agent-note-tool! "#{chat}" "eval-scheme" "" "(buffer-replace! \\"#{prose}\\" \\"a\\" \\"b\\")")})

    assert Buffer.get_local(chat, "minor-modes") in [nil, false, []]
  end

  test "code-agent-auto #f keeps the chat on its own connector" do
    chat = fresh_chat("*cam-off-#{System.unique_integer([:positive])}*")

    eval!("(customize-set! 'code-agent-auto #f)")
    eval!(~s{(code-agent-note-tool! "#{chat}" "eval-scheme" "" "(code-replace! \\"a.ex\\" 3 \\"x\\")")})

    assert Buffer.get_local(chat, "minor-modes") in [nil, false, []]
    assert Buffer.get_local(chat, "agent-connector") in [nil, false]
  end

  test "a writing workspace never moves to the coding preset" do
    doc = "cam-doc-#{System.unique_integer([:positive])}.md"
    chat = fresh_chat("*cam-writing-#{System.unique_integer([:positive])}*")

    eval!(~s{(begin (buffer-create "#{doc}") (buffer-set-local! "#{doc}" 'group "#{doc}"))})
    eval!(~s{(buffer-set-local! "#{chat}" 'group "#{doc}")})
    eval!(~s{(enable-minor-mode! "#{doc}" "writing-mode")})

    on_exit(fn ->
      eval!(~s{(when (buffer-exists? "#{doc}") (disable-minor-mode! "#{doc}" "writing-mode"))})
      if Buffer.exists?(doc), do: Aimax.Core.kill_buffer(doc)
    end)

    eval!(~s{(code-agent-note-tool! "#{chat}" "eval-scheme" "" "(code-replace! \\"a.ex\\" 3 \\"x\\")")})

    assert Buffer.get_local(chat, "minor-modes") in [nil, false, []]
  end

  test "a switch requested mid-turn waits for the turn to end" do
    chat = fresh_chat("*cam-turn-#{System.unique_integer([:positive])}*")

    eval!(~s{(buffer-set-local! "#{chat}" 'chat-turn-active #t)})
    eval!(~s{(code-agent-note-tool! "#{chat}" "eval-scheme" "" "(code-replace! \\"a.ex\\" 3 \\"x\\")")})

    assert "code-agent-mode" in Buffer.get_local(chat, "minor-modes")
    assert Buffer.get_local(chat, "code-agent-switch-pending") == true
    assert Buffer.get_local(chat, "agent-connector") in [nil, false]

    eval!(~s{(buffer-set-local! "#{chat}" 'chat-turn-active #f)})
    eval!(~s{(code-agent-apply-pending! "#{chat}")})

    assert Buffer.get_local(chat, "code-agent-switch-pending") == false
    assert Buffer.get_local(chat, "agent-connector") == "codex-app-server"
    assert Buffer.get_local(chat, "agent-model") == "gpt-5.6-sol"
  end

  test "enabling the mode pushes the code-editing skill onto the next message" do
    chat = fresh_chat("*cam-skill-#{System.unique_integer([:positive])}*")

    assert Buffer.get_local(chat, "chat-note-once") in [nil, false]

    eval!(~s{(enable-minor-mode! "#{chat}" "code-agent-mode")})

    note = Buffer.get_local(chat, "chat-note-once")
    assert note =~ ~s{(skill "code-editing")}
    assert note =~ "code-outline"
    assert note =~ "smallest edit"
  end

  test "disabling the mode restores the connector, model, and presets" do
    chat = fresh_chat("*cam-restore-#{System.unique_integer([:positive])}*")

    eval!(~s{(buffer-set-local! "#{chat}" 'agent-connector "api")})
    eval!(~s{(buffer-set-local! "#{chat}" 'agent-model "claude-sonnet-5")})
    eval!(~s{(buffer-set-local! "#{chat}" 'agent-effort "high")})
    eval!(~s{(buffer-set-local! "#{chat}" 'chat-presets '(project))})

    eval!(~s{(enable-minor-mode! "#{chat}" "code-agent-mode")})
    assert Buffer.get_local(chat, "agent-connector") == "codex-app-server"
    assert Buffer.get_local(chat, "agent-model") == "gpt-5.6-sol"
    assert Buffer.get_local(chat, "agent-effort") == "medium"
    assert Buffer.get_local(chat, "chat-presets") == [sym: "aimax", sym: "project"]

    eval!(~s{(disable-minor-mode! "#{chat}" "code-agent-mode")})
    assert Buffer.get_local(chat, "agent-connector") == "api"
    assert Buffer.get_local(chat, "agent-model") == "claude-sonnet-5"
    assert Buffer.get_local(chat, "agent-effort") == "high"
    assert Buffer.get_local(chat, "chat-presets") == [sym: "project"]
    assert Buffer.get_local(chat, "code-agent-saved") == false
  end

  test "restore re-runs setup without undoing a model the user chose meanwhile" do
    chat = fresh_chat("*cam-rerun-#{System.unique_integer([:positive])}*")

    eval!(~s{(enable-minor-mode! "#{chat}" "code-agent-mode")})
    eval!(~s{(buffer-set-local! "#{chat}" 'agent-model "gpt-5.6-terra")})
    eval!(~s{(restore-minor-modes! "#{chat}")})

    assert Buffer.get_local(chat, "agent-model") == "gpt-5.6-terra"
  end

  test "a second code edit is a no-op once the mode is on" do
    chat = fresh_chat("*cam-idem-#{System.unique_integer([:positive])}*")

    eval!(~s{(code-agent-note-tool! "#{chat}" "eval-scheme" "" "(code-replace! \\"a.ex\\" 3 \\"x\\")")})
    eval!(~s{(buffer-set-local! "#{chat}" 'agent-model "gpt-5.6-terra")})
    eval!(~s{(code-agent-note-tool! "#{chat}" "eval-scheme" "" "(code-sexp-replace! \\"a.ex\\" \\"y\\" \\"z\\")")})

    assert Buffer.get_local(chat, "agent-model") == "gpt-5.6-terra"
  end
end
