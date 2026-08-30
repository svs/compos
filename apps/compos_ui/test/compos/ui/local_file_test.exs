defmodule Compos.Ui.LocalFileTest do
  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [get_resp_header: 2]

  @endpoint Compos.Ui.Endpoint

  alias Compos.Ui.LocalFile

  setup do
    Compos.Core.Editor.minibuffer_close()
    Compos.Core.Editor.delete_other_windows()
    :ok
  end

  test "a signed browser file URL returns image bytes" do
    path =
      Path.join(System.tmp_dir!(), "compos-local-file-#{System.unique_integer([:positive])}.png")

    File.write!(path, "png bytes")
    on_exit(fn -> File.rm(path) end)

    conn = get(build_conn(), LocalFile.url(path))

    assert conn.status == 200
    assert conn.resp_body == "png bytes"
    assert get_resp_header(conn, "content-type") == ["image/png; charset=utf-8"]
  end

  test "the route rejects a signed non-media file" do
    path =
      Path.join(System.tmp_dir!(), "compos-local-file-#{System.unique_integer([:positive])}.json")

    File.write!(path, ~s({"private":true}))
    on_exit(fn -> File.rm(path) end)

    conn = get(build_conn(), LocalFile.url(path))

    assert conn.status == 404
    refute conn.resp_body =~ "private"
  end

  test "common media suffixes missing from the MIME database still render" do
    path =
      Path.join(System.tmp_dir!(), "compos-local-file-#{System.unique_integer([:positive])}.m4a")

    File.write!(path, "audio bytes")
    on_exit(fn -> File.rm(path) end)

    conn = get(build_conn(), LocalFile.url(path))

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["audio/mp4; charset=utf-8"]
  end

  test "a changed token cannot read a media file" do
    path =
      Path.join(System.tmp_dir!(), "compos-local-file-#{System.unique_integer([:positive])}.mp3")

    File.write!(path, "private")
    on_exit(fn -> File.rm(path) end)

    conn = get(build_conn(), LocalFile.url(path) <> "changed")

    assert conn.status == 404
    refute conn.resp_body =~ "private"
  end

  test "opening an image draws the browser file frame" do
    path =
      Path.join(System.tmp_dir!(), "compos-file-view-#{System.unique_integer([:positive])}.png")

    File.write!(path, "png bytes")

    on_exit(fn ->
      Compos.Core.kill_buffer(path)
      File.rm(path)
    end)

    assert {:ok, _} = Compos.Core.Session.eval(~s{(visit "#{path}")})
    {:ok, view, _html} = live(build_conn(), "/")

    assert has_element?(view, ~s(iframe.file-preview[src^="/local-file/"]))
    refute render(view) =~ "png bytes"
  end
end
