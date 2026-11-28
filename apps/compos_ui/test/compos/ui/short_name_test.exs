defmodule Compos.Ui.ShortNameTest do
  @moduledoc "The bare tailnet name on port 80 goes to the HTTPS name; every other request passes."
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Compos.Ui.ShortName

  setup do
    :persistent_term.put({ShortName, :full_name}, "box.tail0.ts.net")
    on_exit(fn -> :persistent_term.erase({ShortName, :full_name}) end)
  end

  defp req(host, port, path, headers \\ []) do
    conn = conn(:get, path) |> Map.merge(%{host: host, port: port})
    Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end) |> ShortName.call([])
  end

  test "http://box/ from a phone goes to the phone client over HTTPS" do
    conn = req("box", 80, "/", [{"user-agent", "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0)"}])
    assert conn.halted
    assert get_resp_header(conn, "location") == ["https://box.tail0.ts.net/m"]
  end

  test "a path and its query stay" do
    conn = req("box", 80, "/b/notes?line=3")
    assert get_resp_header(conn, "location") == ["https://box.tail0.ts.net/b/notes?line=3"]
  end

  test "the proxy's forwarded name counts" do
    conn = req("127.0.0.1", 4004, "/m", [{"x-forwarded-host", "box"}, {"x-forwarded-proto", "http"}])
    assert get_resp_header(conn, "location") == ["https://box.tail0.ts.net/m"]
  end

  test "the daemon's own port, the full name and HTTPS pass" do
    refute req("box", 4004, "/").halted
    refute req("box.tail0.ts.net", 80, "/").halted
    refute req("127.0.0.1", 4004, "/", [{"x-forwarded-host", "box.tail0.ts.net"}, {"x-forwarded-proto", "https"}]).halted
    refute req("localhost", 80, "/").halted
  end
end
