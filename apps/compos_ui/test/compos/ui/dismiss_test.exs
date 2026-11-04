defmodule Compos.Ui.DismissTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Compos.Core.{Buffer, Editor, Session}
  @endpoint Compos.Ui.Endpoint

  setup do
    Editor.minibuffer_close()
    Editor.completion_dismiss()
    {:ok, _} = Compos.Core.Session.eval("(test-one-window!)")
    name = "zz-dismiss-ui-#{System.unique_integer([:positive])}"
    {:ok, _} = Compos.Core.create_buffer(name)
    Buffer.append(name, "A reading surface\n")
    Editor.set_window_buffer(name)
    on_exit(fn -> Compos.Core.kill_buffer(name) end)
    %{conn: build_conn(), name: name}
  end

  test "dismissible reading chrome hides the cursor until caret browsing", %{
    conn: conn,
    name: name
  } do
    assert {:ok, _} = Session.eval(~s{(buffer-set-read-only! "#{name}" #t)})
    {:ok, view, _} = live(conn, "/")
    # the q is the whole cue: no Reading title, no Back label, no row
    assert has_element?(view, ".window.dismissible .dismiss-action kbd", "q")
    refute has_element?(view, ".dismiss-title")
    refute has_element?(view, ".dismiss-bar")
    refute has_element?(view, ".window.active .buf .cursor")
    refute has_element?(view, ".window.active .buf[contenteditable]")
    assert {:ok, _} = Session.eval("(run-command \"caret-browsing-mode\")")
    assert has_element?(view, ".window.active .buf .cursor")
    assert {:ok, _} = Session.eval("(run-command \"caret-browsing-mode\")")
    refute has_element?(view, ".window.active .buf .cursor")
  end

  test "ibuffer exposes the standard corner q dismissal", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    assert {:ok, _} = Session.eval(~S{(run-command "ibuffer")})
    assert has_element?(view, ".window.active.dismissible .dismiss-action kbd", "q")
    assert has_element?(view, "buffers c-headline[face=fixed-pitch]")
    assert has_element?(view, "buffers c-headline.line.semantic-direct > buffer-icon")
    assert has_element?(view, "buffers c-headline.line.semantic-direct > c-label.f-fixed-pitch.f-bold")
    refute has_element?(view, "buffers c-headline .line-content > div")
    refute has_element?(view, "buffers c-label.f-variable-pitch")
    assert has_element?(view, ".window.active .buffer-footer .c-keymap kbd", "p")
    assert has_element?(view, ".window.active .buffer-footer .c-keymap-cmd", "preview")
    assert has_element?(view, ".window.active .buffer-footer .c-keymap-cmd", "next/previous group")
    assert has_element?(view, ".window.active .buffer-footer .c-keymap-cmd", "all bindings")
    assert {:ok, _} = Session.eval(~S{(set-mode! "ibuffer-mode")})
    assert has_element?(view, ".window.active .buffer-footer .c-keymap kbd", "p")
    view |> element(".window.active .dismiss-action") |> render_click()
    refute has_element?(view, ".window.active buffers")
  end

  test "writable text retains its editing surface and no dismissal badge", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    refute has_element?(view, ".window.active .dismiss-action")
    assert has_element?(view, ".window.active .buf[contenteditable]")
    view |> element("#editor") |> render_hook("key", %{"k" => "q"})
    assert Buffer.text(Editor.current_buffer()) =~ "q"
  end

  test "the prominent button dismisses the child and reveals its parent", %{
    conn: conn,
    name: parent
  } do
    child = parent <> "-child"
    on_exit(fn -> if Buffer.exists?(child), do: Compos.Core.kill_buffer(child) end)

    assert {:ok, _} =
             Session.eval("""
             (buffer-set-read-only! "#{parent}" #t)
             (buffer-create "#{child}") (buffer-append! "#{child}" "Child\n")
             (switch-to-buffer! "#{child}") (buffer-set-read-only! "#{child}" #t)
             (buffer-child! "#{parent}" "#{child}")
             """)

    {:ok, view, _} = live(conn, "/")
    view |> element(".window.active .dismiss-action") |> render_click()
    assert has_element?(view, ~s(.window.active[data-buffer="#{parent}"]))
    assert Buffer.exists?(parent)
    # The LiveView attached a second frame. Dismiss only this frame's view;
    # the original frame still displays the shared child.
    assert Buffer.exists?(child)
    refute has_element?(view, ~s(.window[data-buffer="#{child}"]))
  end
end
