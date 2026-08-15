defmodule Aimax.Ui.AppServerTest do
  @moduledoc "The app origin: it serves running apps, and refuses everything else."

  use ExUnit.Case

  import Plug.Test
  import Plug.Conn

  alias Aimax.Core.Buffer
  alias Aimax.Ui.AppServer

  @doc_html ~s{<html><body><h1>hi</h1><script src="app.js"></script></body></html>}

  setup do
    dir = Path.join(System.tmp_dir!(), "aimax-app-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    index = Path.join(dir, "index.html")
    File.write!(index, @doc_html)
    File.write!(Path.join(dir, "app.js"), "console.log(1)")
    File.write!(Path.join(Path.dirname(dir), "outside.txt"), "secret")

    {:ok, name} = Aimax.Core.open_file(index)
    Buffer.set_local(name, "render-mode", "app")

    on_exit(fn ->
      Aimax.Core.kill_buffer(name)
      File.rm_rf!(dir)
    end)

    %{buffer: name, dir: dir}
  end

  defp get(path), do: AppServer.call(conn(:get, path), AppServer.init([]))

  defp url(buffer, rest), do: "/a/#{AppServer.token()}/b/#{URI.encode(buffer, &URI.char_unreserved?/1)}#{rest}"

  test "serves the buffer's live text as the app document", %{buffer: b} do
    Buffer.insert_at(b, 0, "<!-- unsaved -->")

    conn = get(url(b, "/"))

    assert conn.status == 200
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    # the buffer, not the file: what you typed is what the app runs
    assert conn.resp_body =~ "<!-- unsaved -->"
    assert conn.resp_body =~ "<h1>hi</h1>"
    # and the bridge the editor talks to the app over
    assert conn.resp_body =~ ~s{aimax==="scroll"}
  end

  test "serves a sibling file from the app's own directory", %{buffer: b} do
    conn = get(url(b, "/app.js"))

    assert conn.status == 200
    assert conn.resp_body == "console.log(1)"
    assert get_resp_header(conn, "content-type") == ["text/javascript; charset=utf-8"]
  end

  test "an open buffer's unsaved text outranks the file on disk", %{buffer: b, dir: dir} do
    {:ok, js} = Aimax.Core.open_file(Path.join(dir, "app.js"))
    Buffer.insert_at(js, 0, "// edited\n")

    assert get(url(b, "/app.js")).resp_body =~ "// edited"

    Aimax.Core.kill_buffer(js)
  end

  test "refuses a path outside the app's directory", %{buffer: b} do
    assert get(url(b, "/../outside.txt")).status == 404
    assert get(url(b, "/%2e%2e/outside.txt")).status == 404
  end

  test "refuses without the boot token", %{buffer: b} do
    assert get("/a/wrong-token/b/#{URI.encode(b, &URI.char_unreserved?/1)}/").status == 404
  end

  test "refuses a buffer that is not running as an app", %{buffer: b} do
    Buffer.set_local(b, "render-mode", "html")
    assert get(url(b, "/")).status == 404

    Buffer.set_local(b, "render-mode", "app")
    assert get(url(b, "/")).status == 200
  end

  test "refuses a buffer that does not exist" do
    assert get(url("*no-such-buffer*", "/")).status == 404
  end

  test "sends the slashless URL to the slashed one, so relative URLs resolve", %{buffer: b} do
    conn = get(url(b, "") <> "?v=3")

    assert conn.status == 302
    assert [location] = get_resp_header(conn, "location")
    assert location =~ "/b/"
    assert String.ends_with?(location, "/?v=3")
  end

  test "the URL carries the buffer and the generation", %{buffer: b} do
    assert AppServer.app_url(b, 7) =~ "http://127.0.0.1:"
    assert AppServer.app_url(b, 7) =~ AppServer.token()
    assert String.ends_with?(AppServer.app_url(b, 7), "/?v=7")
  end
end
