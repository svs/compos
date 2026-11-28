defmodule Compos.Ui.BufferHtmlTest do
  @moduledoc "Rendered buffer HTML and gated AppServer endpoints for canvas-overview."

  use ExUnit.Case

  import Plug.Test
  import Plug.Conn

  alias Compos.Core.Buffer
  alias Compos.Ui.{AppServer, BufferHtml}

  defp get(path), do: AppServer.call(conn(:get, path), AppServer.init([]))

  defp post(path, body),
    do: AppServer.call(conn(:post, path, body), AppServer.init([]))

  defp url(buffer, rest),
    do: "/a/#{AppServer.token()}/b/#{URI.encode(buffer, &URI.char_unreserved?/1)}#{rest}"

  test "styles_css includes composml, editor.css, and face variables" do
    css = BufferHtml.styles_css()
    assert css =~ "--surface-canvas"
    assert css =~ "c-window"
    assert css =~ ":root"
  end

  test "renders blocks buffers using compos block markup" do
    name = "*zz-bh-blocks-#{System.unique_integer([:positive])}*"
    {:ok, _} = Compos.Core.create_buffer(name)
    Buffer.set_local(name, "render-mode", "blocks")

    Buffer.set_local(name, "render-blocks", [
      [
        {:sym, "tag"}, "div",
        {:sym, "class"}, "bh-sample-card",
        {:sym, "text"}, "Rendered block content"
      ]
    ])

    on_exit(fn -> Compos.Core.kill_buffer(name) end)

    res = BufferHtml.render(name)
    assert res.renderMode == "blocks"
    assert res.html =~ "blocks-view"
    assert res.html =~ "bh-sample-card"
    assert res.html =~ "Rendered block content"
  end

  test "renders markdown buffers as inline rendered HTML, not raw markdown" do
    name = "*zz-bh-md-#{System.unique_integer([:positive])}*"
    {:ok, _} = Compos.Core.create_buffer(name)
    Buffer.append(name, "# Overview Title\n\nHello **bold** world.\n", source: :editor)
    Buffer.set_local(name, "render-mode", "markdown")
    on_exit(fn -> Compos.Core.kill_buffer(name) end)

    res = BufferHtml.render(name)
    assert res.renderMode == "markdown"
    assert res.html =~ "ov-preview-doc"
    assert res.html =~ "<h1"
    assert res.html =~ "Overview Title"
    assert res.html =~ "<strong"
    assert res.html =~ "bold"
    refute res.html =~ "**bold**"
  end

  test "renders code/text buffers with real c-line markup" do
    name = "*zz-bh-code-#{System.unique_integer([:positive])}*"
    {:ok, _} = Compos.Core.create_buffer(name)
    Buffer.append(name, "(define (hi) 42)\n", source: :editor)
    on_exit(fn -> Compos.Core.kill_buffer(name) end)

    res = BufferHtml.render(name)
    assert res.renderMode == "text"
    assert res.html =~ "<c-line"
    assert res.html =~ "(define (hi) 42)"
  end

  test "AppServer gates _compos/editor.css and _compos/render behind app-allow-render" do
    app_buf = "*zz-bh-app-#{System.unique_integer([:positive])}*"
    target_buf = "*zz-bh-target-#{System.unique_integer([:positive])}*"
    {:ok, _} = Compos.Core.create_buffer(app_buf)
    {:ok, _} = Compos.Core.create_buffer(target_buf)
    Buffer.append(app_buf, "<html><body>ok</body></html>", source: :editor)
    Buffer.set_local(app_buf, "render-mode", "app")
    Buffer.set_local(target_buf, "render-mode", "blocks")

    Buffer.set_local(target_buf, "render-blocks", [
      [{:sym, "tag"}, "div", {:sym, "class"}, "gated-card", {:sym, "text"}, "Live card"]
    ])

    on_exit(fn ->
      Compos.Core.kill_buffer(app_buf)
      Compos.Core.kill_buffer(target_buf)
    end)

    # Untrusted app without app-allow-render is refused
    assert get(url(app_buf, "/_compos/editor.css")).status == 404
    assert post(url(app_buf, "/_compos/render"), Jason.encode!(%{buffers: [target_buf]})).status == 404

    # Trusted editor surface with app-allow-render is served
    Buffer.set_local(app_buf, "app-allow-render", true)

    css_conn = get(url(app_buf, "/_compos/editor.css"))
    assert css_conn.status == 200
    assert get_resp_header(css_conn, "content-type") == ["text/css; charset=utf-8"]
    assert css_conn.resp_body =~ "--surface-canvas"

    render_conn = post(url(app_buf, "/_compos/render"), Jason.encode!(%{buffers: [target_buf]}))
    assert render_conn.status == 200
    %{"ok" => true, "buffers" => [rendered]} = Jason.decode!(render_conn.resp_body)
    assert rendered["name"] == target_buf
    assert rendered["renderMode"] == "blocks"
    assert rendered["html"] =~ "gated-card"
    assert rendered["html"] =~ "Live card"
  end
end
