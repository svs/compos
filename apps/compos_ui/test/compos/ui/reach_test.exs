defmodule Compos.Ui.ReachTest do
  # the trusted networks are application env, which one test changes
  use ExUnit.Case, async: false

  import Plug.Test

  alias Compos.Ui.Reach

  defp from(ip) do
    conn(:get, "/") |> Map.put(:remote_ip, ip) |> Reach.call([])
  end

  defp with_networks(networks, fun) do
    old = Application.fetch_env(:compos_ui, :trusted_networks)
    Application.put_env(:compos_ui, :trusted_networks, networks)

    try do
      fun.()
    after
      case old do
        {:ok, value} -> Application.put_env(:compos_ui, :trusted_networks, value)
        :error -> Application.delete_env(:compos_ui, :trusted_networks)
      end
    end
  end

  test "loopback and tailnet addresses pass; the LAN and the internet get 403" do
    refute from({127, 0, 0, 1}).halted
    refute from({0, 0, 0, 0, 0, 0, 0, 1}).halted
    refute from({100, 93, 101, 79}).halted
    refute from({0xFD7A, 0x115C, 0xA1E0, 0, 0, 0x4E01, 0x654F, 1}).halted
    refute from({0, 0, 0, 0, 0, 0xFFFF, 100 * 256 + 93, 101 * 256 + 79}).halted

    assert from({192, 168, 1, 20}).halted
    assert from({192, 168, 1, 20}).status == 403
    assert from({100, 20, 0, 1}).halted
    assert from({8, 8, 8, 8}).halted
  end

  test "an origin is local when it names loopback, this host, or a tailnet address" do
    {:ok, raw} = :inet.gethostname()
    name = raw |> to_string() |> String.split(".") |> hd() |> String.downcase()

    assert Reach.local_origin?(URI.parse("http://localhost:4004"))
    assert Reach.local_origin?(URI.parse("http://127.0.0.1:4004"))
    assert Reach.local_origin?(URI.parse("http://#{name}:4004"))
    assert Reach.local_origin?(URI.parse("http://#{name}.tail1cc8f.ts.net:4004"))
    assert Reach.local_origin?(URI.parse("http://100.93.101.79:4004"))

    refute Reach.local_origin?(URI.parse("http://other.tail1cc8f.ts.net:4004"))
    refute Reach.local_origin?(URI.parse("http://192.168.1.20:4004"))
    refute Reach.local_origin?(URI.parse("https://evil.example"))
    refute Reach.local_origin?(nil)
  end

  test "a configured WireGuard subnet replaces the tailnet" do
    with_networks(["10.10.69.0/24", "10.10.67.4", "fd00:69::/64"], fn ->
      refute from({10, 10, 69, 7}).halted
      refute from({10, 10, 67, 4}).halted
      refute from({0xFD00, 0x69, 0, 0, 0, 0, 0, 5}).halted
      refute from({0, 0, 0, 0, 0, 0xFFFF, 10 * 256 + 10, 69 * 256 + 7}).halted
      refute from({127, 0, 0, 1}).halted

      assert from({10, 10, 67, 5}).halted
      assert from({10, 10, 70, 1}).halted
      assert from({100, 93, 101, 79}).halted
      assert from({192, 168, 1, 20}).halted

      assert Reach.local_origin?(URI.parse("http://10.10.69.1:4004"))
      refute Reach.local_origin?(URI.parse("http://100.93.101.79:4004"))
      refute Reach.local_origin?(URI.parse("http://10.10.70.1:4004"))
    end)
  end

  test "a malformed network matches no address" do
    for bad <- ["10.10.69.0/33", "10.10.69/24", "10.10.69.0/x", "host.example/24", "", "::1/129"] do
      assert Reach.parse_network(bad) == nil, bad
    end

    with_networks(["not-a-network", "10.10.69.0/24"], fn ->
      refute from({10, 10, 69, 7}).halted
      assert from({100, 93, 101, 79}).halted
    end)

    with_networks([], fn ->
      refute from({127, 0, 0, 1}).halted
      assert from({10, 10, 69, 7}).halted
    end)
  end
end
