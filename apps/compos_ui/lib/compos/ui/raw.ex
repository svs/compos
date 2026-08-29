defmodule Compos.Ui.Raw do
  @moduledoc """
  A buffer as plain text, at the address its link names.

  A buffer link is one string that two readers can follow. A person opens
  `/b/NAME` and the editor shows the buffer. A terminal or an agent reads
  `/raw/NAME` and gets the text, no editor and no socket needed.

  `GET /raw` lists the buffer names, one per line, so a reader that holds
  one link can find the rest.

  The reply carries no CORS header, so a page you visit cannot read a
  buffer through this route. The port is loopback only.
  """

  use Plug.Router

  alias Compos.Core.Buffer

  plug(:match)
  plug(:dispatch)

  get "/" do
    text(conn, Enum.join(Compos.Core.list_buffers(), "\n") <> "\n")
  end

  get "/:buffer" do
    if Buffer.exists?(buffer),
      do: text(conn, Buffer.text(buffer)),
      else: send_resp(conn, 404, "no such buffer: #{buffer}")
  end

  match _ do
    send_resp(conn, 404, "no")
  end

  defp text(conn, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, body)
  end
end
