defmodule Compos.Ui.MouseClipboardTest do
  @moduledoc "Mouse click/drag → point/region, system clipboard paste/copy, chat input focus."

  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint Compos.Ui.Endpoint

  alias Compos.Core.{Buffer, Editor, KeyDispatch, Session}

  setup do
    Editor.minibuffer_close()
    Editor.set_total_rows(40)
    Editor.delete_other_windows()
    {:ok, conn: build_conn()}
  end

  defp fresh_buffer(name, text) do
    Editor.set_window_buffer(name)
    :ok = Buffer.append(name, text, source: :editor)
    name
  end

  defp win_id, do: Editor.render_state().tree.id

  test "mouse click places point at line/col (bytes via the rope)", %{conn: conn} do
    buf =
      fresh_buffer("mc-click-#{System.unique_integer([:positive])}", "alpha\nbrävo\ncharlie\n")

    Buffer.set_mark(buf, 1)
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("#editor")
    |> render_hook("mouse", %{"win" => win_id(), "line" => 2, "col" => 4})

    # line 2 starts at byte 6; "bräv" is 5 bytes (ä is 2)
    assert Buffer.point(buf) == 11
    assert Buffer.mark(buf) == nil
  end

  test "mouse drag mirrors the native selection into mark + point", %{conn: conn} do
    buf = fresh_buffer("mc-drag-#{System.unique_integer([:positive])}", "alpha\nbravo\ncharlie\n")
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("#editor")
    |> render_hook("mouse_sel", %{
      "win" => win_id(),
      "al" => 1,
      "ac" => 2,
      "fl" => 2,
      "fc" => 3
    })

    snap = Buffer.render_snapshot(buf)
    assert snap.mark == 2
    assert snap.point == 9
  end

  test "paste inserts at point and lands on the kill ring", %{conn: conn} do
    buf = fresh_buffer("mc-paste-#{System.unique_integer([:positive])}", "")
    {:ok, view, _html} = live(conn, "/")

    view |> element("#editor") |> render_hook("paste", %{"text" => "från \"clipboard\"\nline2"})

    assert Buffer.text(buf) == "från \"clipboard\"\nline2"
    assert Editor.kill_top() == "från \"clipboard\"\nline2"
  end

  test "paste replaces the active selection and dismisses selection mode", %{conn: conn} do
    buf = fresh_buffer("mc-paste-region-#{System.unique_integer([:positive])}", "hello world")
    Buffer.set_mark(buf, 6)
    Buffer.goto(buf, 11)
    {:ok, view, _html} = live(conn, "/")

    view |> element("#editor") |> render_hook("paste", %{"text" => "there"})

    assert Buffer.text(buf) == "hello there"
    assert Buffer.point(buf) == 11
    assert Buffer.mark(buf) == nil
    assert Editor.kill_top() == "there"
  end

  test "image paste prompts from the buffer directory, creates directories, and inserts Markdown",
       %{
         conn: conn
       } do
    root = Path.join(System.tmp_dir!(), "compos-image-paste-#{System.unique_integer([:positive])}")
    document = Path.join(root, "note.md")
    destination = Path.join([root, "images", "diagram.png"])
    File.mkdir_p!(root)
    File.write!(document, "")

    on_exit(fn ->
      Compos.Core.kill_buffer(document)
      File.rm_rf(root)
    end)

    {:ok, ^document} = Compos.Core.open_file(document)
    Editor.set_window_buffer(document)
    assert {:ok, _} = Session.eval(~s{(run-command "writing-mode")})
    {:ok, view, _html} = live(conn, "/")

    view
    |> element("#editor")
    |> render_hook("paste_image", %{
      "data" => Base.encode64("png bytes"),
      "mime" => "image/png"
    })

    assert Editor.render_state().minibuffer.input == Path.join(root, "image_1.png")

    Editor.minibuffer_set_input(destination)
    KeyDispatch.handle_key("RET")

    assert Editor.render_state().minibuffer.prompt =~
             "Create directory #{Path.dirname(destination)}?"

    KeyDispatch.handle_key("y")

    assert File.read!(destination) == "png bytes"
    # the link is relative to the document: an absolute path names this
    # machine, and the same file read anywhere else finds no picture
    assert Buffer.text(document) == "![image](images/diagram.png)"
  end

  test "copy with an active region replies with it on the clipboard event", %{conn: conn} do
    buf = fresh_buffer("mc-copy-#{System.unique_integer([:positive])}", "hello world")
    Buffer.set_mark(buf, 0)
    Buffer.goto(buf, 5)
    {:ok, view, _html} = live(conn, "/")

    view |> element("#editor") |> render_hook("copy", %{})

    assert_push_event(view, "clipboard", %{text: "hello"})
    assert Editor.kill_top() == "hello"
  end

  test "selecting a chat window snaps point into the input region", %{conn: conn} do
    buf =
      fresh_buffer("*chat: mc-#{System.unique_integer([:positive])}*", "transcript\n>>> you: ")

    marker = "\n>>> you: "
    Buffer.set_local(buf, "render-mode", "agent")
    Buffer.set_local(buf, "agent-slug", "mc")
    Buffer.set_local(buf, "agent-saved-mark", 10)
    Buffer.set_local(buf, "agent-marker-bytes", byte_size(marker))
    Buffer.goto(buf, 3)
    {:ok, view, _html} = live(conn, "/")

    view |> element("#editor") |> render_hook("mouse", %{"win" => win_id()})

    assert Buffer.point(buf) == Buffer.byte_size(buf)
  end

  test "a stranded agent mark is clamped so the input region survives", %{conn: conn} do
    buf =
      fresh_buffer("*chat: mc-heal-#{System.unique_integer([:positive])}*", "text\n>>> you: hi")

    marker = "\n>>> you: "
    Buffer.set_local(buf, "render-mode", "agent")
    Buffer.set_local(buf, "agent-slug", "mc-heal")
    Buffer.set_local(buf, "agent-saved-mark", Buffer.byte_size(buf) + 12)
    Buffer.set_local(buf, "agent-marker-bytes", byte_size(marker))
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "agent-view"
    agent = Editor.render_state().tree.agent
    assert agent.mark == Buffer.byte_size(buf) - byte_size(marker)
  end
end
