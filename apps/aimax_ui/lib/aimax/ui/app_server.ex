defmodule Aimax.Ui.AppServer do
  @moduledoc """
  The origin an HTML app runs in.

  The editor is one origin (localhost:4004). A previewed app is a different
  one (127.0.0.1:4005). The browser keeps the two apart, so the app runs its
  own JavaScript, keeps its own storage, and cannot read the editor. This
  server answers two things and nothing else: the live text of a buffer in
  "app" render-mode, and the files beside that buffer's file.

  The URL carries a boot token in its PATH, not in a query string, because
  every relative URL in the app (`<script src="app.js">`, `fetch("d.json")`)
  must inherit it. A page you browse can also reach a loopback port; without
  the token this server tells that page nothing.
  """

  use Plug.Router

  alias Aimax.Core.Buffer

  plug(:match)
  plug(:dispatch)

  @doc "The boot token. The Application puts it; every URL repeats it."
  def token, do: :persistent_term.get(:aimax_app_token, "")

  @doc "The URL of BUFFER's app document. GEN busts the browser cache."
  def app_url(buffer, gen) do
    port = Application.get_env(:aimax_ui, :app_port) || 4005
    name = URI.encode(buffer, &URI.char_unreserved?/1)
    "http://127.0.0.1:#{port}/a/#{token()}/b/#{name}/?v=#{gen}"
  end

  get "/a/:tok/b/:buf/*rest" do
    cond do
      not Plug.Crypto.secure_compare(tok, token()) ->
        send_resp(conn, 404, "no")

      # No trailing slash: "app.js" beside the document would resolve to
      # /a/<tok>/b/app.js, one directory above it. Plug strips the trailing
      # slash from path_info, so the raw path is what tells the two apart.
      rest == [] and not String.ends_with?(conn.request_path, "/") ->
        conn
        |> put_resp_header("location", conn.request_path <> "/?" <> (conn.query_string || ""))
        |> send_resp(302, "")

      true ->
        serve(conn, buf, rest)
    end
  end

  match _ do
    send_resp(conn, 404, "no")
  end

  # The app document itself is the BUFFER, not the file: what you type is
  # what the reload runs, saved or not.
  defp serve(conn, buffer, []) do
    case app_text(buffer) do
      nil -> send_resp(conn, 404, "no such app buffer")
      text -> respond(conn, "text/html", with_bridge(text))
    end
  end

  # A sibling file, confined to the app document's own directory.
  defp serve(conn, buffer, rest) do
    with true <- app_buffer?(buffer),
         path when is_binary(path) <- safe_path(buffer, rest) do
      respond(conn, MIME.from_path(path), file_text(path))
    else
      _ -> send_resp(conn, 404, "no such file")
    end
  end

  # Only a buffer the editor is showing as an app answers here. Preview is
  # the grant: this port serves nothing you did not open with `app-preview`.
  defp app_text(buffer), do: if(app_buffer?(buffer), do: Buffer.text(buffer))

  defp app_buffer?(buffer) do
    Buffer.exists?(buffer) and Buffer.locals(buffer)["render-mode"] == "app"
  catch
    :exit, _ -> false
  end

  defp safe_path(buffer, rest) do
    with path when is_binary(path) <- buffer_path(buffer) do
      root = path |> Path.expand() |> Path.dirname()
      want = Path.expand(Path.join([root | rest]))

      if inside?(root, want) and File.regular?(want), do: want
    end
  end

  defp inside?(root, want), do: want == root or String.starts_with?(want, root <> "/")

  # An unsaved edit to app.js must reach the reload too, so a buffer that
  # visits this file outranks the bytes on disk.
  defp file_text(path) do
    case buffer_visiting(path) do
      nil -> File.read!(path)
      buffer -> Buffer.text(buffer)
    end
  end

  defp buffer_visiting(path) do
    Enum.find(Aimax.Core.list_buffers(), fn b -> buffer_path(b) == path end)
  end

  defp buffer_path(buffer) do
    case Buffer.exists?(buffer) and Buffer.path(buffer) do
      p when is_binary(p) -> Path.expand(p)
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  defp respond(conn, type, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type(type)
    |> send_resp(200, body)
  end

  # The app is a document in another origin, so the editor cannot reach into
  # it: the keys that scroll a preview, and the C-g that gives the keyboard
  # back, both travel as messages. This is the app's half of that wire.
  @bridge """
  <script>(function(){
  var t=null;
  function el(){return document.scrollingElement||document.documentElement}
  addEventListener("message",function(e){
    if(e.data&&e.data.aimax==="scroll"){el().scrollTop=e.data.top}
  });
  addEventListener("scroll",function(){
    clearTimeout(t);
    t=setTimeout(function(){
      parent.postMessage({aimax:"scroll",top:Math.round(el().scrollTop)},"*")
    },250)
  },true);
  addEventListener("keydown",function(e){
    if(e.ctrlKey&&e.key==="g"){e.preventDefault();parent.postMessage({aimax:"release"},"*")}
  },true);
  })()</script>
  """

  defp with_bridge(text) do
    case String.split(text, ~r{</body>}i, parts: 2) do
      [before, rest] -> before <> @bridge <> "</body>" <> rest
      [_] -> text <> @bridge
    end
  end
end
