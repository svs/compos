defmodule Aimax.Ui.LocalImage do
  @moduledoc "Serves signed absolute image paths used by document previews."

  use Plug.Router

  import Plug.Conn

  alias Plug.Crypto.MessageVerifier

  plug(:match)
  plug(:dispatch)

  @doc "Return the same-origin URL for an absolute local image path."
  def url(path) when is_binary(path) do
    "/local-image/" <> MessageVerifier.sign(Path.expand(path), secret())
  end

  get "/:token" do
    with {:ok, path} <- MessageVerifier.verify(token, secret()),
         true <- Path.type(path) == :absolute,
         true <- File.regular?(path),
         mime when is_binary(mime) <- MIME.from_path(path),
         true <- String.starts_with?(mime, "image/") do
      conn
      |> put_resp_content_type(mime)
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_file(200, path)
    else
      _ -> send_resp(conn, 404, "no such image")
    end
  end

  match _ do
    send_resp(conn, 404, "no")
  end

  defp secret, do: Aimax.Ui.Endpoint.config(:secret_key_base)
end
