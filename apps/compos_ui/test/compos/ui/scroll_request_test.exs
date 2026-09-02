defmodule Compos.Ui.ScrollRequestTest do
  @moduledoc """
  A server-driven scroll of a client-scrolled window rides to the browser
  as one data-scroll request on that window's buffer element. Each
  LiveView mount attaches its own frame, so the test scrolls the window
  the view rendered.
  """

  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Compos.Core.Editor

  @endpoint Compos.Ui.Endpoint

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()
    buf = "*scroll-request-#{System.unique_integer([:positive])}*"
    {:ok, _} = Compos.Core.create_buffer(buf)
    Compos.Core.Buffer.append(buf, String.duplicate("line\n", 200), source: :editor)
    Editor.set_window_buffer(buf)
    on_exit(fn -> if Compos.Core.Buffer.exists?(buf), do: Compos.Core.kill_buffer(buf) end)
    {:ok, conn: build_conn()}
  end

  test "scroll_window stamps the lines on the window's buffer element", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    [_, win] = Regex.run(~r/data-win-id="(\d+)"/, html)
    refute html =~ ~r/<div class="buf[^>]*data-scroll=/

    assert :ok = Editor.scroll_window(String.to_integer(win), 5)
    assert has_element?(view, ~s{.window[data-win-id="#{win}"] .buf.client-scroll[data-scroll$=":5"]})
    assert has_element?(view, ~s{.buf[data-manual="true"]})

    assert :ok = Editor.scroll_window(String.to_integer(win), -3)
    [_, first] = Regex.run(~r/data-scroll="(\d+):5"/, html <> render(view)) || [nil, "0"]
    assert has_element?(view, ~s{.buf[data-scroll$=":-3"]})
    refute has_element?(view, ~s{.buf[data-scroll="#{first}:-3"]})
  end
end
