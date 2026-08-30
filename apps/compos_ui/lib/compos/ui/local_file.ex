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
         mime when is_binary(mime) <- browser_mime(path),
         true <- Enum.any?(@allowed_prefixes, &String.starts_with?(mime, &1)) do
      conn
      |> put_resp_content_type(mime)
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_file(200, path)
    else
      _ -> send_resp(conn, 404, "no such browser-renderable file")
    end
  end

  match _ do
    send_resp(conn, 404, "no")
  end

  defp secret, do: Compos.Ui.Endpoint.config(:secret_key_base)

  defp browser_mime(path) do
    case MIME.from_path(path) do
      "application/octet-stream" ->
        Map.get(@fallback_mimes, path |> Path.extname() |> String.downcase())

      mime ->
        mime
    end
  end
end
