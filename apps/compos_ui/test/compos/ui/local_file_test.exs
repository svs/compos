defmodule Compos.Ui.LocalFileTest do
  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]

  @endpoint Compos.Ui.Endpoint

  alias Compos.Ui.LocalFile

  setup do
    Compos.Core.Editor.minibuffer_close()
    {:ok, _} = Compos.Core.Session.eval("(test-one-window!)")
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

  test "a player asking for one byte range gets that range only" do
    path = media_file("mp4", "0123456789")

    conn =
      build_conn()
      |> put_req_header("range", "bytes=2-5")
      |> get(LocalFile.url(path))

    assert conn.status == 206
    assert conn.resp_body == "2345"
    assert get_resp_header(conn, "content-range") == ["bytes 2-5/10"]
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
  end

  test "a player asking for the last bytes gets them" do
    path = media_file("mp4", "0123456789")

    conn =
      build_conn()
      |> put_req_header("range", "bytes=-4")
      |> get(LocalFile.url(path))

    assert conn.status == 206
    assert conn.resp_body == "6789"
    assert get_resp_header(conn, "content-range") == ["bytes 6-9/10"]
  end

  test "a range past the end of the file is refused, and says how long the file is" do
    path = media_file("mp4", "0123456789")

    conn =
      build_conn()
      |> put_req_header("range", "bytes=20-30")
      |> get(LocalFile.url(path))

    assert conn.status == 416
    assert get_resp_header(conn, "content-range") == ["bytes */10"]
  end

  test "the whole file says that it takes ranges" do
    path = media_file("mov", "0123456789")

    conn = get(build_conn(), LocalFile.url(path))

    assert conn.status == 200
    assert conn.resp_body == "0123456789"
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
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

  defp media_file(suffix, bytes) do
    path =
      Path.join(
        System.tmp_dir!(),
        "compos-local-file-#{System.unique_integer([:positive])}.#{suffix}"
      )

    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
