defmodule Compos.Ui.ShortName do
  @moduledoc """
  `http://HOST/` on the tailnet goes to `https://HOST.TAILNET.ts.net/`.

  Tailscale gives a certificate only for the full MagicDNS name, so a
  browser cannot open `https://HOST`. When `tailscale serve` also answers
  plain HTTP on port 80, a request for the bare name arrives here on port
  80, and this plug sends it to the HTTPS name with the same path. A phone
  that asks for `/` lands on the phone client, `/m`.

  A request on the daemon's own port, by any name, passes as before.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    # tailscale serve may pass the name the browser asked for as
    # X-Forwarded-Host and dial the daemon by its own address
    forwarded = conn |> get_req_header("x-forwarded-host") |> List.first()
    host = (forwarded || conn.host || "") |> String.split(":") |> hd()

    with true <- plain_http?(conn, forwarded),
         true <- bare?(host),
         full when is_binary(full) <- full_name() do
      path = target_path(conn)

      conn
      |> put_resp_header("location", "https://" <> full <> path)
      |> send_resp(302, "")
      |> halt()
    else
      _ -> conn
    end
  end

  # the request came in as plain HTTP on port 80, not on the daemon's port
  defp plain_http?(conn, nil), do: conn.port == 80

  # through the proxy: it says the scheme the browser used
  defp plain_http?(conn, _forwarded) do
    (conn |> get_req_header("x-forwarded-proto") |> List.first()) in [nil, "http"]
  end

  # a name with no dot that is not loopback: the short MagicDNS name
  defp bare?(host), do: not String.contains?(host, ".") and host not in ["localhost", ""]

  defp target_path(conn) do
    path = if conn.request_path == "/" and phone?(conn), do: "/m", else: conn.request_path
    if conn.query_string == "", do: path, else: path <> "?" <> conn.query_string
  end

  defp phone?(conn) do
    ua = conn |> get_req_header("user-agent") |> List.first() || ""
    String.contains?(ua, ["iPhone", "iPad", "Android", "Mobile"])
  end

  @doc "this machine's MagicDNS name, as `tailscale status` gives it, or nil"
  def full_name do
    case :persistent_term.get({__MODULE__, :full_name}, :unknown) do
      :unknown ->
        name = read_full_name()
        :persistent_term.put({__MODULE__, :full_name}, name)
        name

      name ->
        name
    end
  end

  defp read_full_name do
    with exe when is_binary(exe) <- System.find_executable("tailscale"),
         {out, 0} <- System.cmd(exe, ["status", "--self", "--json"], stderr_to_stdout: false),
         {:ok, %{"Self" => %{"DNSName" => dns}}} when is_binary(dns) and dns != "" <- Jason.decode(out) do
      String.trim_trailing(dns, ".")
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
