defmodule Compos.Ui.AppServer do
  @moduledoc """
  The origin an HTML app runs in.

  The editor is one origin (localhost:4004). A previewed app is a different
  one (127.0.0.1:4005). The browser keeps the two apart, so the app runs its
  own JavaScript, keeps its own storage, and cannot read the editor. This
  server answers three things and nothing else: the live text of a buffer
  in "app" render-mode, the files beside that buffer's file (or in the
  'app-directory of a buffer with no file), and the app bridge
  (`_compos/app`), which hands a request to the package's Scheme handler.

  The URL carries a boot token in its PATH, not in a query string, because
  every relative URL in the app (`<script src="app.js">`, `fetch("d.json")`)
  must inherit it. A page you browse can also reach a loopback port; without
  the token this server tells that page nothing.
  """

  use Plug.Router

  alias Compos.Core.{Buffer, Session}

  plug(:match)
  plug(:dispatch)

  @doc "The boot token. The Application puts it; every URL repeats it."
  def token, do: :persistent_term.get(:compos_app_token, "")

  @doc "The URL of BUFFER's app document. GEN busts the browser cache."
  def app_url(buffer, gen) do
    port = Application.get_env(:compos_ui, :app_port) || 4005
    name = URI.encode(buffer, &URI.char_unreserved?/1)
    "http://127.0.0.1:#{port}/a/#{token()}/b/#{name}/?v=#{gen}"
  end

  get "/a/:tok/_compos/bridge.js" do
    if Plug.Crypto.secure_compare(tok, token()) do
      path = Application.app_dir(:compos_ui, "priv/static/app-bridge.js")
      respond(conn, "text/javascript", File.read!(path))
    else
      send_resp(conn, 404, "no")
    end
  end

  # The app bridge: the page talks back to the package that made it. The
  # method and the body go to Scheme as data (app-request, preview.scm),
  # and the package's handler answers (STATUS BODY).
  get "/a/:tok/b/:buf/_compos/app" do
    app_request(conn, tok, buf, "GET", "")
  end

  put "/a/:tok/b/:buf/_compos/app" do
    with_body(conn, fn conn, body -> app_request(conn, tok, buf, "PUT", body) end)
  end

  post "/a/:tok/b/:buf/_compos/app" do
    with_body(conn, fn conn, body -> app_request(conn, tok, buf, "POST", body) end)
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
    Enum.find_value(app_roots(buffer), fn root ->
      want = Path.expand(Path.join([root | rest]))

      if inside?(root, want) and File.regular?(want), do: want
    end)
  end

  # The directories an app's relative files come from, first match wins:
  # its file's own, or, for a buffer with no file (a page a package
  # writes), the 'app-directory local the package sets. That local is one
  # directory or a list, so a slide deck's images resolve beside the deck.
  defp app_roots(buffer) do
    case buffer_path(buffer) do
      path when is_binary(path) ->
        [Path.dirname(path)]

      nil ->
        Buffer.locals(buffer)["app-directory"]
        |> List.wrap()
        |> Enum.filter(&(is_binary(&1) and File.dir?(&1)))
        |> Enum.map(&Path.expand/1)
    end
  catch
    :exit, _ -> []
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
    Enum.find(Compos.Core.list_buffers(), fn b -> buffer_path(b) == path end)
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

  # An app cannot write files from its isolated origin. The bridge sends
  # its request to Scheme, where the package that owns the buffer decides.
  defp app_request(conn, tok, buffer, method, body) do
    with true <- Plug.Crypto.secure_compare(tok, token()),
         true <- app_buffer?(buffer),
         {:ok, [status, response]} when is_integer(status) and is_binary(response) <-
           Session.call_named("app-request", [buffer, method, body], nil, 30_000, {:app, buffer}) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type("application/json")
      |> send_resp(status, response)
    else
      _ -> send_resp(conn, 404, ~s({"error":"no app answers"}))
    end
  end

  defp with_body(conn, fun) do
    case read_request_body(conn) do
      {:ok, body, conn} -> fun.(conn, body)
      {:error, conn} -> send_resp(conn, 413, ~s({"error":"the request is too large"}))
    end
  end

  defp read_request_body(conn, acc \\ "") do
    case Plug.Conn.read_body(conn,
           length: 20_000_000,
           read_length: 1_000_000,
           read_timeout: 15_000
         ) do
      {:ok, body, conn} -> {:ok, acc <> body, conn}
      {:more, body, conn} -> read_request_body(conn, acc <> body)
      {:error, _} -> {:error, conn}
    end
  end

  # The app is a document in another origin, so the editor cannot reach into
  # it: the keys that scroll a preview, and the C-g that gives the keyboard
  # back, both travel as messages. This is the app's half of that wire, a
  # static file (priv/static/app-bridge.js) this origin serves under the
  # token; the boot id in its URL makes a new boot load it again.
  defp bridge do
    boot = :persistent_term.get(:compos_boot_id, "dev")
    ~s(<script src="/a/#{token()}/_compos/bridge.js?v=#{URI.encode_www_form(boot)}"></script>)
  end

  defp with_bridge(text) do
    case String.split(text, ~r{</body>}i, parts: 2) do
      [before, rest] -> before <> bridge() <> "</body>" <> rest
      [_] -> text <> bridge()
    end
  end
end
