defmodule Compos.TransientTest do
  @moduledoc "Emacs-style Transient menus through the real key dispatcher."

  use ExUnit.Case

  alias Compos.Core.{Buffer, Editor, KeyDispatch, Session}

  defp eval!(source) do
    assert {:ok, value} = Session.eval(source)
    value
  end

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)
  defp type(text), do: text |> String.graphemes() |> press()

  setup do
    Session.run_command("transient-quit-all")
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()
    Editor.set_window_buffer("transient-source-#{System.unique_integer([:positive])}")
    Session.eval("(set-frame-local! 'llm-config-more #f)")

    # a menu left open holds the frame's overriding map, and every key of
    # the next test module would answer to it
    on_exit(fn ->
      Session.run_command("transient-quit-all")
      Editor.minibuffer_close()
    end)

    :ok
  end

  test "a prefix keeps the source selected and displays in the command modal" do
    source = Editor.current_buffer()

    eval!("""
    (define transient-test-ran #f)
    (define-command "transient-test-run" (lambda ()
      (set! transient-test-ran (transient-args "transient-test"))))
    (transient-define-prefix "transient-test" "Test menu"
      (list
        (list "Arguments"
          (transient-switch "v" "Verbose" "--verbose"))
        (list "Actions"
          (transient-suffix "x" "Run" "transient-test-run"))))
    """)

    Session.run_command("transient-test")

    assert Editor.current_buffer() == source
    assert length(Editor.list_windows()) == 1
    assert Editor.render_state().transient.title == "Test menu"

    assert [%{title: "Arguments", items: [verbose]}, %{title: "Actions"}] =
             Editor.render_state().transient.groups

    assert %{description: "Verbose", value: "off"} = verbose

    press("v")
    assert eval!("(transient-value \"--verbose\")") == "#t"
    assert hd(hd(Editor.render_state().transient.groups).items).value == "on"

    press("x")
    assert eval!("transient-test-ran") == ~s{("--verbose")}
    assert Editor.current_buffer() == source
    assert length(Editor.list_windows()) == 1
    assert Editor.render_state().transient == nil
  end

  test "M-x opens the LLM menu: presets left, config right, keys in the footer" do
    eval!("(set! *llm-bundles* '())")
    press("M-x")
    type("llm-configure")
    press("RET")

    menu = Editor.render_state().transient
    assert menu.title == "LLM setup"
    assert menu.layout == "split"
    assert menu.context =~ "this buffer"
    # a chat on no preset is a row of its own, and the menu opens on it
    assert [["Presets"], [config]] = menu.columns
    assert config == "this chat · config"
    assert selected().description == "this chat"
    assert selected().value == "selected"
    assert Enum.any?(menu.legend, &(&1.key == "ESC C-g"))

    # right goes into the config; no key closes the menu but ESC, C-g, C-q
    press("<right>")
    assert selected().key == "b"
    assert Editor.render_state().transient.title == "LLM setup"

    press("RET")
    mb = Editor.render_state().minibuffer
    assert mb.prompt == "Backend: "
    assert mb.note =~ "RET puts the backend"

    # C-g in the picker goes back to the menu, and the menu stays
    press("C-g")
    assert Editor.render_state().transient.title == "LLM setup"
    press("<left>")
    assert selected().description == "this chat"
    press("ESC")
    assert Editor.render_state().transient == nil
  end

  test "undefined keys stay active, nested prefixes return with C-g" do
    eval!("""
    (transient-define-prefix "transient-child" "Child"
      (list (list "Child actions"
        (transient-suffix "c" "Close" "transient-quit-all"))))
    (transient-define-prefix "transient-parent" "Parent"
      (list (list "Menus"
        (transient-suffix "s" "Submenu" "transient-child"))))
    """)

    Session.run_command("transient-parent")
    press("z")
    assert Editor.snapshot().echo == "z is not a transient suffix"
    assert Editor.render_state().transient.title == "Parent"

    press("s")
    assert Editor.render_state().transient.title == "Child"
    press("C-g")
    assert Editor.render_state().transient.title == "Parent"
    press("C-g")
    assert Editor.render_state().transient == nil
  end

  test "history, navigation, suspend, and resume preserve infix state" do
    eval!("""
    (define-command "transient-history-done" (lambda () #t))
    (transient-define-prefix "transient-history-test" "History"
      (list (list "Arguments"
              (transient-switch "a" "All" "--all")
              (transient-choice "f" "Format" "--format="
                (list (list "short" "short") (list "long" "long"))))
            (list "Actions"
              (transient-suffix "x" "Done" "transient-history-done"))))
    """)

    Session.run_command("transient-history-test")
    press("a")
    press("x")

    Session.run_command("transient-history-test")
    assert eval!("(transient-value \"--all\")") == "#f"
    press("C-M-p")
    assert eval!("(transient-value \"--all\")") == "#t"

    press("C-z")
    assert Editor.render_state().transient == nil
    Session.run_command("transient-resume")
    assert eval!("(transient-value \"--all\")") == "#t"

    press("<down>")
    press("M-RET")
    assert eval!("(transient-value \"--format=\")") == ~s{"long"}
    press("C-q")
  end

  test "overriding maps are independent between frames" do
    eval!("""
    (transient-define-prefix "transient-frame-test" "Frame menu"
      (list (list "Arguments" (transient-switch "t" "Toggle" "--toggle"))))
    """)

    {:ok, other} = Editor.attach_frame(nil)

    try do
      Session.run_command("transient-frame-test", "f-main")
      KeyDispatch.handle_key(other, "t")

      other_buffer = Editor.current_buffer(other)
      assert Buffer.text(other_buffer) == "t"
      assert Session.eval("(transient-value \"--toggle\")", "f-main") == {:ok, "#f"}

      KeyDispatch.handle_key("f-main", "t")
      assert Session.eval("(transient-value \"--toggle\")", "f-main") == {:ok, "#t"}
    after
      Session.run_command("transient-quit-all", "f-main")
      Editor.delete_frame(other)
      Editor.select_frame("f-main")
    end
  end

  test "the LLM menu turns tool presets on and off in the config, and ESC applies them" do
    buf = "*zz-transient-chat*"
    on_exit(fn -> Compos.Core.kill_buffer(buf) end)

    eval!("""
    (buffer-create "#{buf}")
    (buffer-set-local! "#{buf}" 'mode-name "chat-mode")
    (buffer-set-local! "#{buf}" 'chat-presets '())
    (define-preset! 'zztransient "a test preset" '())
    (set! *llm-bundles* '())
    """)

    Editor.set_window_buffer(buf)
    Session.run_command("llm-configure")

    # the editor bridge is always on, so the tools read editor only
    assert row("tools").value == "editor only"

    # the field keys answer in the config column; in the presets they filter
    press("<right>")
    press("p")
    assert Editor.render_state().minibuffer.prompt == "Preset: "

    assert %{hint: "○ a test preset"} =
             Enum.find(Editor.render_state().minibuffer.candidates,
               &(&1.label == "zztransient"))

    type("zztransient")
    press("RET")

    # the preset is in the config; the chat has it only when the menu closes
    assert row("tools").value == "editor only → zztransient"
    assert Buffer.get_local(buf, "chat-presets") == []

    # the picker stays open for the next toggle
    assert Editor.render_state().minibuffer.prompt == "Preset: "

    # compos is the editor bridge: it never turns off
    type("compos")
    press("RET")
    assert Editor.snapshot().echo =~ "stays on"

    press("C-g")
    press("ESC")
    assert Editor.render_state().transient == nil
    assert Buffer.get_local(buf, "chat-presets") == [sym: "zztransient", sym: "compos"]
  end

  test "C-g and ESC both close the LLM menu and apply the config" do
    buf = Editor.current_buffer()
    on_exit(fn -> Session.run_command("transient-quit-all") end)

    eval!(~s{
      (set! *llm-bundles* '())
      (llm-config-apply! "#{buf}" "codex-app-server" "gpt-5.6-terra" "high")
    })

    Session.run_command("llm-configure")
    press("<right>")
    press("m")
    type("gpt-5.6-luna")
    press("RET")
    assert Buffer.get_local(buf, "llm-model") == "gpt-5.6-terra"
    press("C-g")
    assert Editor.render_state().transient == nil
    assert Buffer.get_local(buf, "llm-model") == "gpt-5.6-luna"
    eval!(~s{(llm-config-apply! "#{buf}" "codex-app-server" "gpt-5.6-terra" "high")})

    Session.run_command("llm-configure")
    press("<right>")
    press("m")
    type("gpt-5.6-luna")
    press("RET")
    # an action row keeps the menu open too
    press("+")
    press("d")
    assert Editor.render_state().transient.title == "LLM setup"
    press("ESC")
    assert Buffer.get_local(buf, "llm-model") == "gpt-5.6-luna"
  end

  test "typing filters the presets, RET selects one, ESC gives it to the chat" do
    buf = "*zz-transient-preset-chat*"
    eval!(~s{(buffer-create "#{buf}")})

    on_exit(fn ->
      Session.run_command("transient-quit-all")
      eval!(~s{
        (let ((slug (buffer-local "#{buf}" 'agent-slug)))
          (when slug (llm-session-close! slug)))
        (set! *llm-bundles* '())
      })
      Compos.Core.kill_buffer(buf)
    end)

    eval!(~s{
      (buffer-set-local! "#{buf}" 'mode-name "chat-mode")
      (buffer-set-local! "#{buf}" 'agent-connector "api")
      (buffer-set-local! "#{buf}" 'agent-saved-mark 0)
      (set! *llm-bundles* '())
      (llm-bundle-save! "zz-luna" '(connector "api" model "openai:gpt-5.6-luna" effort "high"))
    })

    Editor.set_window_buffer(buf)
    Session.run_command("llm-configure")
    type("lu")
    assert selected().description == "zz-luna"
    assert row("model").value == "openai:gpt-5.6-luna"
    press("RET")
    assert selected().value == "selected"
    assert Editor.render_state().transient.subtitle =~ "selected: zz-luna"
    assert Buffer.get_local(buf, "agent-model") != "openai:gpt-5.6-luna"

    press("ESC")
    assert Buffer.get_local(buf, "agent-connector") == "api"
    assert Buffer.get_local(buf, "agent-model") == "openai:gpt-5.6-luna"
    assert Buffer.get_local(buf, "agent-effort") == "high"
  end

  # the row under the cursor
  defp selected do
    Editor.render_state().transient.groups
    |> Enum.flat_map(& &1.items)
    |> Enum.find(& &1.selected)
  end

  # one row of the active transient, by its description
  defp row(description) do
    Editor.render_state().transient.groups
    |> Enum.flat_map(& &1.items)
    |> Enum.find(&(&1.description == description))
  end
end
