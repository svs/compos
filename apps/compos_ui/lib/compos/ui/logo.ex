defmodule Compos.Ui.Logo do
  @moduledoc """
  This daemon's logo, at /logo. Several daemons run at once, so each one
  may wear its own: the tab icon, the frame header and the compos preset
  all draw this route.

  Scheme sets it with the `compos-logo` setting, which publishes three
  chrome values: `logo-file` (an image to serve as it is), `logo-tint` (a
  colour the stock logo is recoloured to) and `logo-label` (up to three
  letters in a badge on its corner). With none of them it is the stock logo.
  """

  use Plug.Router

  import Plug.Conn

  plug(:match)
  plug(:dispatch)

  @doc "The logo's URL under CHROME, the frame chrome map: it changes when the logo does."
  def url(chrome) when is_map(chrome) do
    "/logo?v=" <> Integer.to_string(:erlang.phash2(spec(chrome)))
  end

  def url(_), do: "/logo"

  @doc "The version of the logo under CHROME: it changes when the logo does."
  def version(chrome) when is_map(chrome), do: Integer.to_string(:erlang.phash2(spec(chrome)))
  def version(_), do: version(%{})

  @doc """
  Keep PNG as the app icon of logo VERSION. A page draws /logo onto a
  canvas and sends it here, because an installed app's icon must be a PNG
  and the tinted logo is an SVG. A PNG for a logo that is no longer the
  current one is dropped.
  """
  def store_icon(version, <<137, 80, 78, 71, _::binary>> = png)
      when is_binary(version) and byte_size(png) < 4_000_000 do
    if version == current_version() and stored_version() != version do
      File.write!(icon_path(), png)
      File.write!(icon_path() <> ".v", version)
    end

    :ok
  end

  def store_icon(_, _), do: :error

  defp current_version, do: version(Compos.Core.Editor.chrome())

  defp stored_version do
    case File.read(icon_path() <> ".v") do
      {:ok, v} -> v
      _ -> nil
    end
  end

  defp icon_path, do: Path.join(Compos.Core.config_dir(), "logo-icon.png")

  get "/" do
    case spec(Compos.Core.Editor.chrome()) do
      {file, _, _} when file != "" -> send_image(conn, file)
      {_, "", ""} -> send_stock(conn)
      {_, tint, label} -> send_svg(conn, tinted(tint, label))
    end
  end

  # The installed app's icon (macOS shows it in the Dock and the app
  # switcher): the PNG a page drew of the current logo, else the stock one.
  get "/icon.png" do
    if stored_version() == current_version() and File.regular?(icon_path()),
      do: conn |> headers("image/png") |> send_file(200, icon_path()),
      else: send_stock(conn)
  end

  # This daemon's web app manifest: the static one, with the icon above.
  # Each daemon is its own origin, so each installs as its own app.
  get "/manifest", do: send_manifest(conn, %{})

  # the phone's app: it opens on /m and stays there
  get "/manifest/phone" do
    send_manifest(conn, %{"id" => "/m", "start_url" => "/m", "scope" => "/m", "name" => "compos phone",
      "display" => "standalone", "display_override" => ["standalone"]})
  end

  defp send_manifest(conn, overrides) do
    manifest =
      Application.app_dir(:compos_ui, "priv/static/manifest.webmanifest")
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("icons", [
        %{
          "src" => "/logo/icon.png?v=" <> current_version(),
          "sizes" => "512x512",
          "type" => "image/png",
          "purpose" => "any"
        }
      ])
      |> Map.merge(overrides)

    conn
    |> put_resp_content_type("application/manifest+json", nil)
    |> put_resp_header("cache-control", "no-cache")
    |> send_resp(200, Jason.encode!(manifest))
  end

  match _ do
    send_resp(conn, 404, "no")
  end

  defp spec(chrome) do
    {text(chrome, "logo-file"), color(text(chrome, "logo-tint")),
     text(chrome, "logo-label") |> String.graphemes() |> Enum.take(3) |> Enum.join()}
  end

  defp text(chrome, key) do
    case Map.get(chrome || %{}, key) do
      v when is_binary(v) -> String.trim(v)
      _ -> ""
    end
  end

  # only a colour reaches the SVG: #rgb to #rrggbbaa, or a CSS colour name
  defp color(c) do
    if Regex.match?(~r/\A(#[0-9a-fA-F]{3,8}|[a-zA-Z]{3,20})\z/, c), do: c, else: ""
  end

  defp send_image(conn, path) do
    mime = MIME.from_path(path)

    if File.regular?(path) and String.starts_with?(mime, "image/") do
      conn
      |> headers(mime)
      |> send_file(200, path)
    else
      send_stock(conn)
    end
  end

  defp send_stock(conn) do
    conn
    |> headers("image/png")
    |> send_file(200, stock_path())
  end

  defp send_svg(conn, svg) do
    conn
    |> headers("image/svg+xml")
    |> send_resp(200, svg)
  end

  defp headers(conn, mime) do
    conn
    |> put_resp_content_type(mime, nil)
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("x-content-type-options", "nosniff")
  end

  defp stock_path, do: Application.app_dir(:compos_ui, "priv/static/images/compos-logo.png")

  defp stock_data do
    case :persistent_term.get({__MODULE__, :stock}, nil) do
      nil ->
        data = "data:image/png;base64," <> Base.encode64(File.read!(stock_path()))
        :persistent_term.put({__MODULE__, :stock}, data)
        data

      data ->
        data
    end
  end

  # The stock logo, recoloured to TINT with its own light and shade, and
  # LABEL in a badge on the lower right corner.
  defp tinted(tint, label) do
    filter =
      if tint == "",
        do: "",
        else: """
        <filter id="tint" color-interpolation-filters="sRGB">
          <feColorMatrix in="SourceGraphic" type="saturate" values="0" result="grey"/>
          <feFlood flood-color="#{tint}" result="ink"/>
          <feBlend in="ink" in2="grey" mode="color" result="inked"/>
          <feComposite in="inked" in2="SourceAlpha" operator="in"/>
        </filter>
        """

    image_filter = if tint == "", do: "", else: ~s[ filter="url(#tint)"]

    badge =
      if label == "" do
        ""
      else
        w = 14 + 15 * String.length(label)
        fill = if tint == "", do: "#c0392b", else: tint

        """
        <rect x="#{64 - w}" y="34" width="#{w}" height="30" rx="6" fill="#{fill}" stroke="#fff" stroke-width="2"/>
        <text x="#{64 - w / 2}" y="57" text-anchor="middle" font-family="-apple-system, Helvetica, Arial, sans-serif" font-size="24" font-weight="700" fill="#fff">#{escape(label)}</text>
        """
      end

    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">
      <defs>#{filter}</defs>
      <image href="#{stock_data()}" x="0" y="0" width="64" height="64"#{image_filter}/>
      #{badge}
    </svg>
    """
  end

  defp escape(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
