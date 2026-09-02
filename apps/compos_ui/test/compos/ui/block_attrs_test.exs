defmodule Compos.Ui.BlockAttrsTest do
  @moduledoc """
  A blocks-mode buffer may carry SVG tags and presentation attributes. The
  renderer draws the tags it knows and drops every attribute outside its
  allowlist, so a mode can chart but never script.
  """

  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Compos.Core.{Editor, Session}

  @endpoint Compos.Ui.Endpoint

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()
    buf = "*block-attrs-#{System.unique_integer([:positive])}*"
    {:ok, _} = Compos.Core.create_buffer(buf)
    on_exit(fn -> if Compos.Core.Buffer.exists?(buf), do: Compos.Core.kill_buffer(buf) end)
    {:ok, conn: build_conn(), buf: buf}
  end

  test "svg blocks render their geometry and keep only safe attributes", %{conn: conn, buf: buf} do
    {:ok, _} =
      Session.eval(~s[
        (begin
          (buffer-set-local! "#{buf}" 'render-mode "blocks")
          (buffer-set-local! "#{buf}" 'render-blocks
            (list (list 'tag "svg" 'class "chart"
                        'attrs (list (list "viewBox" "0 0 20 100")
                                     (list "onload" "alert(1)"))
                        'children (list (list 'tag "path" 'attrs (list (list "d" "M0,100 L10,50")))))
                  (list 'tag "div" 'class "bar"
                        'attrs (list (list "style" "width:40%") (list "href" "http://x")))
                  (list 'tag "script" 'text "alert(2)"))))
      ])

    Editor.set_window_buffer(buf)
    {:ok, _view, html} = live(conn, "/")

    [svg] = Regex.run(~r/<svg[^>]*class="chart"[^>]*>.*?<\/svg>/s, html)
    assert svg =~ ~s(viewBox="0 0 20 100")
    assert svg =~ ~r/<path[^>]*d="M0,100 L10,50"/
    refute svg =~ "onload"
    [bar] = Regex.run(~r/<div[^>]*class="bar"[^>]*>/, html)
    assert bar =~ ~s(style="width:40%")
    refute bar =~ "href"
    refute html =~ "<script>alert(2)"
    assert html =~ ~r/<div[^>]*>alert\(2\)<\/div>/
  end
end
