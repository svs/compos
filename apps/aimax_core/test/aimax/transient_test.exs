defmodule Aimax.TransientTest do
  @moduledoc "Emacs-style Transient menus through the real key dispatcher."

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

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
end
