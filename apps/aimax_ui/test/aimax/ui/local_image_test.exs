defmodule Aimax.Ui.LocalImageTest do
  use ExUnit.Case

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2]

  @endpoint Aimax.Ui.Endpoint

  alias Aimax.Ui.{EditorLive, LocalImage}

  @faces %{}

  test "markdown keeps the absolute path but previews it through a signed URL" do
    path = "/tmp/a pasted image.png"
    html = EditorLive.preview_doc("markdown", "![image](<#{path}>)", 0, @faces, false)

    assert html =~ ~s(src="/local-image/)
    refute html =~ ~s(src="#{path}")
  end

  test "a signed local image URL returns the image bytes" do
    path =
      Path.join(System.tmp_dir!(), "aimax-local-image-#{System.unique_integer([:positive])}.png")

    File.write!(path, "png bytes")
    on_exit(fn -> File.rm(path) end)

    conn = get(build_conn(), LocalImage.url(path))

    assert conn.status == 200
    assert conn.resp_body == "png bytes"
    assert get_resp_header(conn, "content-type") == ["image/png; charset=utf-8"]
    assert get_resp_header(conn, "access-control-allow-origin") == []
  end

  test "a changed token cannot read a local file" do
    path =
      Path.join(System.tmp_dir!(), "aimax-local-image-#{System.unique_integer([:positive])}.png")

    File.write!(path, "private")
    on_exit(fn -> File.rm(path) end)

    conn = get(build_conn(), LocalImage.url(path) <> "changed")

    assert conn.status == 404
    refute conn.resp_body =~ "private"
  end
end
