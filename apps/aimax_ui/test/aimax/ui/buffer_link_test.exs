defmodule Aimax.Ui.BufferLinkTest do
  @moduledoc "Buffer links: copy one, open one, and read one as plain text."

  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint Aimax.Ui.Endpoint

  alias Aimax.Core.{Buffer, Editor, Session}

  setup do
    Editor.minibuffer_close()
    Editor.set_total_rows(40)
    Editor.delete_other_windows()
    {:ok, conn: build_conn()}
  end

  defp fresh_buffer(text) do
    name = "link-#{System.unique_integer([:positive])}"
    Editor.set_window_buffer(name)
    :ok = Buffer.append(name, text, source: :editor)
    name
  end

  defp keys(view, specs) do
    Enum.each(specs, fn k -> view |> element("#editor") |> render_hook("key", %{"k" => k}) end)
    render(view)
  end

  # the test endpoint runs on its own port; a link names the port it came from
  defp base do
    port = Application.get_env(:aimax_ui, Aimax.Ui.Endpoint)[:http][:port]
    "http://localhost:#{port}"
  end

  test "C-c l copies the link to this buffer and line", %{conn: conn} do
    buf = "/tmp/link #{System.unique_integer([:positive])}.txt"
    Editor.set_window_buffer(buf)
    :ok = Buffer.append(buf, "alpha\nbravo\ncharlie\n", source: :editor)
    {:ok, view, _html} = live(conn, "/")

    keys(view, ["M-<", "C-n"])
    keys(view, ["C-c", "l"])

    # the buffer name is one encoded segment, so a path keeps its slashes
    want = "#{base()}/b/#{URI.encode(buf, &URI.char_unreserved?/1)}?line=2"
    assert_push_event(view, "clipboard", %{text: ^want})
    # C-y pastes the same link in a client that cannot write the clipboard
    assert Editor.kill_top() == want
  end

  test "a file buffer keeps its path in one encoded segment" do
    want = ~s{"#{base()}/b/%2Ftmp%2Fa%20b.txt"}
    assert {:ok, ^want} = Session.eval(~s{(buffer-link "/tmp/a b.txt")})
  end

  test "opening a link shows that buffer at that line", %{conn: conn} do
    buf = fresh_buffer("alpha\nbravo\ncharlie\n")
    other = fresh_buffer("elsewhere\n")

    {:ok, view, _html} = live(conn, "/b/#{buf}?line=3")

    assert Editor.current_buffer() == buf
    # the cursor splits its own line, so read a line the cursor is not on
    assert render(view) =~ "bravo"
    # line 3 starts at byte 12
    assert Buffer.point(buf) == 12
    refute Editor.current_buffer() == other
  end

  test "a link with no line shows the buffer and leaves point alone", %{conn: conn} do
    buf = fresh_buffer("alpha\nbravo\n")
    {:ok, _view, _html} = live(conn, "/b/#{buf}")
    assert Editor.current_buffer() == buf
  end

  test "a dead link says so and shows the frame anyway", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/b/no-such-buffer-here")
    assert render(view) =~ "Dead link"
  end

  test "the raw route serves the buffer text", %{conn: conn} do
    buf = fresh_buffer("alpha\nbrävo\n")

    resp = get(conn, "/raw/#{buf}")
    assert resp.status == 200
    assert resp.resp_body == "alpha\nbrävo\n"
    assert ["text/plain; charset=utf-8"] = Plug.Conn.get_resp_header(resp, "content-type")

    # no CORS header: a page you visit cannot read a buffer through this
    assert Plug.Conn.get_resp_header(resp, "access-control-allow-origin") == []
  end

  test "the raw index lists the buffer names", %{conn: conn} do
    buf = fresh_buffer("x\n")
    assert get(conn, "/raw").resp_body =~ buf
  end

  test "the raw route says 404 for a name no buffer has", %{conn: conn} do
    resp = get(conn, "/raw/no-such-buffer-here")
    assert resp.status == 404
  end
end
