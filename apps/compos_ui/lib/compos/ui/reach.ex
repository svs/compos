defmodule Compos.Ui.Reach do
  @moduledoc """
  Who may reach the editor port.

  The endpoint listens on every interface so a browser on a private network
  can open the editor, and this plug admits only two kinds of client: this
  machine (loopback) and an address in the trusted networks. Every other
  address gets 403 before the router.

  The trusted networks are CIDR strings in `config :compos_ui,
  :trusted_networks`. The default is Tailscale: 100.64.0.0/10 and
  fd7a:115c:a1e0::/48. A WireGuard network sets its own subnet with
  `COMPOS_TRUSTED_NETWORKS` or `trusted_networks` in daemon.conf (see
  config/runtime.exs). A malformed entry matches no address.

  `local_origin?/1` is the same rule for a WebSocket Origin header: the
  page came from localhost, from this host's name, from this host's
  MagicDNS name, or from an address in the trusted networks.
  """

  @behaviour Plug

  import Bitwise
  import Plug.Conn

  @default_networks ["100.64.0.0/10", "fd7a:115c:a1e0::/48"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if allowed_ip?(conn.remote_ip) do
      conn
    else
      conn
      |> send_resp(403, "this editor answers loopback and its trusted networks only")
      |> halt()
    end
  end

  @doc "True for loopback and for an address in the trusted networks."
  def allowed_ip?(ip) do
    ip = unmap(ip)
    loopback?(ip) or Enum.any?(networks(), &in_network?(ip, &1))
  end

  @doc "The trusted networks, parsed. A malformed entry is left out."
  def networks do
    :compos_ui
    |> Application.get_env(:trusted_networks, @default_networks)
    |> Enum.map(&parse_network/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Parses "ADDRESS/BITS" into `{width, bits, prefix}`, or nil when the text
  is not a CIDR. A bare address means the one host.
  """
  def parse_network(text) when is_binary(text) do
    {addr, bits} =
      case String.split(String.trim(text), "/", parts: 2) do
        [addr, bits] -> {addr, Integer.parse(bits)}
        [addr] -> {addr, :host}
      end

    with {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(addr)),
         width = width(ip),
         bits = if(bits == :host, do: {width, ""}, else: bits),
         {bits, ""} when bits >= 0 and bits <= width <- bits do
      {width, bits, prefix(ip, bits)}
    else
      _ -> nil
    end
  end

  def parse_network(_), do: nil

  defp in_network?(ip, {width, bits, prefix}) do
    width(ip) == width and prefix(ip, bits) == prefix
  end

  defp width(ip) when tuple_size(ip) == 4, do: 32
  defp width(ip) when tuple_size(ip) == 8, do: 128

  defp prefix(ip, bits) do
    part = if tuple_size(ip) == 4, do: 8, else: 16
    value = ip |> Tuple.to_list() |> Enum.reduce(0, fn p, acc -> (acc <<< part) + p end)
    value >>> (width(ip) - bits)
  end

  # an IPv4 client on a dual-stack socket
  defp unmap({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: {hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}
  defp unmap(ip), do: ip

  @doc """
  True when a WebSocket Origin names this machine: a loopback spelling,
  this host's name, its MagicDNS name (HOST.*.ts.net), or an address in
  the trusted networks.
  """
  def local_origin?(%URI{host: host}) when is_binary(host) do
    name = hostname()

    cond do
      host in ["localhost", "127.0.0.1", "[::1]", "::1"] -> true
      host == name -> true
      String.starts_with?(host, name <> ".") and String.ends_with?(host, ".ts.net") -> true
      true -> trusted_address?(host)
    end
  end

  def local_origin?(_), do: false

  defp hostname do
    {:ok, name} = :inet.gethostname()
    name |> to_string() |> String.split(".") |> hd() |> String.downcase()
  end

  defp trusted_address?(host) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]")

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> allowed_ip?(ip) and not loopback?(unmap(ip))
      _ -> false
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false
end
