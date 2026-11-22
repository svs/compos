defmodule Compos.Ui.LocalFile do
  @moduledoc "Serves signed browser-renderable file paths for file buffers."

  use Plug.Router

  import Plug.Conn

  alias Plug.Crypto.MessageVerifier

  plug(:match)
  plug(:dispatch)

  @allowed_prefixes ["image/", "audio/", "video/"]
  @fallback_mimes %{
    ".jfif" => "image/jpeg",
    ".ogg" => "audio/ogg",
    ".m4a" => "audio/mp4",
    ".flac" => "audio/flac",
    ".m4v" => "video/x-m4v"
  }

  @doc "Return the same-origin URL for a browser-renderable local file."
  def url(path) when is_binary(path) do
    "/local-file/" <> MessageVerifier.sign(Path.expand(path), secret())
  end

  get "/:token" do
    with {:ok, path} <- MessageVerifier.verify(token, secret()),
         true <- Path.type(path) == :absolute,
         true <- File.regular?(path),
         {:ok, %{size: size}} <- File.stat(path),
         mime when is_binary(mime) <- browser_mime(path),
         true <- Enum.any?(@allowed_prefixes, &String.starts_with?(mime, &1)) do
      conn
      |> put_resp_content_type(mime)
      |> put_resp_header("cache-control", "no-store")
      # A browser plays a video it was sent as a page by fetching it again,
      # from inside that page, so the page must allow media from here.
      # Nothing else loads, and the page still runs no script.
      |> put_resp_header("content-security-policy", "default-src 'none'; media-src 'self'; sandbox")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("accept-ranges", "bytes")
      |> send_range(path, size)
    else
      _ -> send_resp(conn, 404, "no such browser-renderable file")
    end
  end

  match _ do
    send_resp(conn, 404, "no")
  end

  # A player does not read a video from the top. It asks for the last bytes
  # to find the index, then seeks, and each seek is another byte range.
  # WebKit will not play a file at all from a server that answers a range
  # request with the whole file, so a range is answered with 206 and the
  # span that was asked for.
  @doc "Send PATH, or the byte range the request asks for, as a player needs."
  def send_range(conn, path, size) do
    case requested_range(conn, size) do
      nil ->
        send_file(conn, 200, path)

      :unsatisfiable ->
        conn
        |> put_resp_header("content-range", "bytes */#{size}")
        |> send_resp(416, "")

      {first, last} ->
        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
        |> send_file(206, path, first, last - first + 1)
    end
  end

  # "bytes=START-END": either end may be absent, so "bytes=500-" is from 500
  # to the end and "bytes=-500" is the last 500 bytes. Anything else — a
  # unit that is not bytes, more than one range, a number that is not one —
  # answers nil, and the whole file is a legal answer to it.
  defp requested_range(conn, size) do
    case get_req_header(conn, "range") do
      ["bytes=" <> spec] -> parse_range(String.split(spec, "-"), size)
      _ -> nil
    end
  end

  defp parse_range([first, ""], size), do: span(to_offset(first), size - 1, size)

  defp parse_range(["", last], size) do
    case to_offset(last) do
      nil -> nil
      count -> span(max(size - count, 0), size - 1, size)
    end
  end

  defp parse_range([first, last], size) do
    case to_offset(last) do
      nil -> nil
      stop -> span(to_offset(first), min(stop, size - 1), size)
    end
  end

  defp parse_range(_spec, _size), do: nil

  defp span(nil, _last, _size), do: nil

  defp span(first, last, size) do
    if first > last or first >= size, do: :unsatisfiable, else: {first, last}
  end

  defp to_offset(text) do
    case Integer.parse(text) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp secret, do: Compos.Ui.Endpoint.config(:secret_key_base)

  # Chrome will not play video/quicktime, the type MIME gives a .mov. A
  # .mov is almost always H.264 or HEVC in an MP4-style container, and
  # Chrome and WebKit both play it when it is served as video/mp4.
  @doc "The type a browser plays PATH as, or nil."
  def browser_mime(path) do
    case MIME.from_path(path) do
      "video/quicktime" ->
        "video/mp4"

      "application/octet-stream" ->
        Map.get(@fallback_mimes, path |> Path.extname() |> String.downcase())

      mime ->
        mime
    end
  end
end
