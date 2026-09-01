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

  test "M-x opens a transient and RET invokes its selected row" do
    press("M-x")
    type("llm-configure")
    press("RET")

    assert Editor.render_state().transient.title == "Configure this buffer's language model"

    press("RET")
    assert Editor.render_state().transient.title == "Configure this buffer's language model"
    assert Editor.render_state().minibuffer.prompt == "Backend: "

    press("C-g")
    assert Editor.render_state().transient.title == "Configure this buffer's language model"
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

  test "the LLM menu turns tool presets on and off and counts what they serve" do
    buf = "*zz-transient-chat*"
    on_exit(fn -> Compos.Core.kill_buffer(buf) end)

    eval!("""
    (buffer-create "#{buf}")
    (buffer-set-local! "#{buf}" 'mode-name "chat-mode")
    (buffer-set-local! "#{buf}" 'chat-presets '())
    (define-preset! 'zztransient "a test preset" '())
    """)

    Editor.set_window_buffer(buf)
    Session.run_command("llm-configure")

    # the editor bridge is always on, so it is always in the value
    assert row("Presets").value == "compos"
    assert row("Tools").value =~ ~r/^\d+ tools$/

    press("p")
    assert Editor.render_state().minibuffer.prompt == "Preset: "

    assert %{hint: "○ a test preset"} =
             Enum.find(Editor.render_state().minibuffer.candidates,
               &(&1.label == "zztransient"))

    type("zztransient")
    press("RET")

    # the preset lands on the session and the menu stays open, changed
    assert Buffer.get_local(buf, "chat-presets") == [sym: "zztransient", sym: "compos"]
    assert row("Presets").value == "zztransient compos"

    # the same key turns it back off
    press("p")
    type("zztransient")
    press("RET")
    assert Buffer.get_local(buf, "chat-presets") == [sym: "compos"]
    assert row("Presets").value == "compos"

    # compos is the editor bridge: it never turns off
    press("p")
    type("compos")
    press("RET")
    assert Editor.snapshot().echo =~ "stays on"
    assert row("Presets").value == "compos"

    press("C-q")
  end

  test "the LLM menu applies a previously selected combination" do
    buf = Editor.current_buffer()

    on_exit(fn ->
      Session.run_command("transient-quit-all")
      eval!("(set! *llm-config-history* '())")
    end)

    eval!(~s{(llm-config-apply! "#{buf}" "api" "openai:gpt-5.6-luna" "medium")})
    eval!(~s{
      (set! *llm-config-history*
        '(("codex-app-server" "gpt-5.6-terra" "high")))
    })

    Session.run_command("llm-configure")

    assert [%{title: "Arguments"}, %{title: "Recent combinations", items: recent}] =
             Editor.render_state().transient.groups

    assert hd(recent).description == "codex-app-server · gpt-5.6-terra · high"

    press("1")

    assert Buffer.get_local(buf, "llm-connector") == "codex-app-server"
    assert Buffer.get_local(buf, "llm-model") == "gpt-5.6-terra"
    assert Buffer.get_local(buf, "llm-effort") == "high"
    assert Editor.render_state().transient == nil
    assert eval!("*llm-config-history*") =~
             ~s{(("codex-app-server" "gpt-5.6-terra" "high"))}
  end

  test "the LLM menu records only a confirmed final combination" do
    buf = Editor.current_buffer()

    on_exit(fn ->
      Session.run_command("transient-quit-all")
      eval!("(set! *llm-config-history* '())")
    end)

    eval!(~s{
      (set! *llm-config-history* '())
      (llm-config-apply! "#{buf}" "codex-app-server" "gpt-5.6-terra" "high")
    })

    # Opening and cancelling a picker does not create history.
    Session.run_command("llm-configure")
    press("m")
    press("C-g")
    press("C-g")
    assert eval!("*llm-config-history*") == "()"

    # A confirmed model changes the buffer immediately. History commits only
    # when C-g closes the configuration selector.
    Session.run_command("llm-configure")
    press("m")
    type("gpt-5.6-luna")
    press("RET")

    assert Buffer.get_local(buf, "llm-model") == "gpt-5.6-luna"
    assert eval!("*llm-config-history*") == "()"

    press("C-g")

    assert eval!("*llm-config-history*") ==
             ~s{(("codex-app-server" "gpt-5.6-luna" "default"))}
  end

  test "an exiting LLM menu row commits the confirmed combination" do
    buf = Editor.current_buffer()

    on_exit(fn ->
      Session.run_command("transient-quit-all")
      eval!("(set! *llm-config-history* '())")
    end)

    eval!(~s{
      (set! *llm-config-history* '())
      (llm-config-apply! "#{buf}" "codex-app-server" "gpt-5.6-terra" "high")
    })

    Session.run_command("llm-configure")
    press("m")
    type("gpt-5.6-luna")
    press("RET")
    press("t")

    assert Editor.render_state().transient == nil
    assert eval!("*llm-config-history*") ==
             ~s{(("codex-app-server" "gpt-5.6-luna" "default"))}
  end

  test "the LLM menu applies a previous combination to a chat" do
    buf = "*zz-transient-history-chat*"
    eval!(~s{(buffer-create "#{buf}")})

    on_exit(fn ->
      Session.run_command("transient-quit-all")
      eval!(~s{
        (let ((slug (buffer-local "#{buf}" 'agent-slug)))
          (when slug (llm-session-close! slug)))
        (set! *llm-config-history* '())
      })
      Compos.Core.kill_buffer(buf)
    end)

    eval!(~s{
      (buffer-set-local! "#{buf}" 'mode-name "chat-mode")
      (buffer-set-local! "#{buf}" 'agent-connector "api")
      (buffer-set-local! "#{buf}" 'agent-saved-mark 0)
      (set! *llm-config-history*
        '(("api" "openai:gpt-5.6-luna" "high")
          ("api" "default" "default")))
    })

    Editor.set_window_buffer(buf)
    Session.run_command("llm-configure")
    press("1")

    assert Buffer.get_local(buf, "agent-connector") == "api"
    assert Buffer.get_local(buf, "agent-model") == "openai:gpt-5.6-luna"
    assert Buffer.get_local(buf, "agent-effort") == "high"
  end

  # one row of the active transient, by its description
  defp row(description) do
    Editor.render_state().transient.groups
    |> Enum.flat_map(& &1.items)
    |> Enum.find(&(&1.description == description))
  end
end
