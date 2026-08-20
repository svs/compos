# Minimal LSP server over stdio for tests: Content-Length framing, the
# initialize handshake, full-text sync, and canned language features.
# Uses OTP's :json — no deps, so it runs as `elixir fake_lsp_server.exs`
# straight from a Port.
#
# Behavior the tests lean on:
#   - FAKE_LSP_ENCODING=utf-8 negotiates utf-8 positions (default utf-16)
#   - FAKE_LSP_SPLIT=1 writes each frame in two chunks with a pause
#   - after `initialized` it sends a workspace/configuration request;
#     the client's answer earns a `fake/configAnswered` notification
#   - a didOpen/didChange doc containing "WARNME" earns publishDiagnostics
#     with a warning spanning that token
#   - every didChange earns `fake/sync` %{uri, version, length}
#   - definition/references answer Locations of "TARGET" in the doc;
#     hover answers the doc's first word; completion answers the doc's words
defmodule FakeLSP do
  def run do
    enc = if System.get_env("FAKE_LSP_ENCODING") == "utf-8", do: :utf8, else: :utf16
    loop(%{docs: %{}, enc: enc, next_id: 1000})
  end

  defp loop(state) do
    case read_message() do
      :eof -> :ok
      msg -> loop(handle(msg, state))
    end
  end

  # --- framing ---------------------------------------------------------------

  defp read_message do
    case read_headers("") do
      :eof ->
        :eof

      headers ->
        len =
          headers
          |> String.split(~r/\r?\n/)
          |> Enum.find_value(fn line ->
            case String.split(line, ":", parts: 2) do
              [k, v] ->
                if String.downcase(String.trim(k)) == "content-length",
                  do: String.to_integer(String.trim(v))

              _ ->
                nil
            end
          end)

        case read_bytes(len, "") do
          body when is_binary(body) -> :json.decode(body)
          _ -> :eof
        end
    end
  end

  # Under a Port, stdio is a unicode device: IO.binread fails on multibyte
  # input with :no_translation. Read one character at a time and count the
  # UTF-8 bytes ourselves — Content-Length counts bytes.
  defp read_bytes(n, acc) do
    if byte_size(acc) >= n do
      acc
    else
      case IO.read(:stdio, 1) do
        ch when is_binary(ch) -> read_bytes(n, acc <> ch)
        _ -> :eof
      end
    end
  end

  defp read_headers(acc) do
    case IO.read(:stdio, 1) do
      b when is_binary(b) ->
        acc = acc <> b

        if String.ends_with?(acc, "\r\n\r\n") or String.ends_with?(acc, "\n\n"),
          do: acc,
          else: read_headers(acc)

      _ ->
        :eof
    end
  end

  defp send_msg(msg) do
    body = msg |> :json.encode() |> IO.iodata_to_binary()
    frame = "Content-Length: #{byte_size(body)}\r\n\r\n" <> body

    if System.get_env("FAKE_LSP_SPLIT") == "1" do
      half = div(byte_size(frame), 2)
      IO.binwrite(:stdio, binary_part(frame, 0, half))
      :timer.sleep(30)
      IO.binwrite(:stdio, binary_part(frame, half, byte_size(frame) - half))
    else
      IO.binwrite(:stdio, frame)
    end
  catch
    _, _ -> :ok
  end

  defp reply(id, result), do: send_msg(%{jsonrpc: "2.0", id: id, result: result})
  defp notify(method, params), do: send_msg(%{jsonrpc: "2.0", method: method, params: params})

  # --- protocol --------------------------------------------------------------

  defp handle(%{"method" => "initialize", "id" => id}, state) do
    caps = %{
      textDocumentSync: 1,
      hoverProvider: true,
      definitionProvider: true,
      referencesProvider: true,
      completionProvider: %{}
    }

    caps =
      if state.enc == :utf8, do: Map.put(caps, :positionEncoding, "utf-8"), else: caps

    reply(id, %{capabilities: caps, serverInfo: %{name: "fake-lsp", version: "0.0.1"}})
    state
  end

  defp handle(%{"method" => "initialized"}, state) do
    send_msg(%{
      jsonrpc: "2.0",
      id: state.next_id,
      method: "workspace/configuration",
      params: %{items: [%{section: "fake"}]}
    })

    %{state | next_id: state.next_id + 1}
  end

  # the client answered our configuration request
  defp handle(%{"id" => _id, "result" => result} = msg, state)
       when not is_map_key(msg, "method") do
    notify("fake/configAnswered", %{settings: result})
    state
  end

  defp handle(%{"method" => "textDocument/didOpen", "params" => p}, state) do
    uri = p["textDocument"]["uri"]
    text = p["textDocument"]["text"]
    state = put_in(state, [:docs, uri], text)
    diagnose(uri, text, state)
    state
  end

  defp handle(%{"method" => "textDocument/didChange", "params" => p}, state) do
    uri = p["textDocument"]["uri"]
    version = p["textDocument"]["version"]
    [%{"text" => text} | _] = p["contentChanges"]
    state = put_in(state, [:docs, uri], text)
    notify("fake/sync", %{uri: uri, version: version, length: byte_size(text)})
    diagnose(uri, text, state)
    state
  end

  defp handle(%{"method" => "textDocument/didClose", "params" => p}, state),
    do: %{state | docs: Map.delete(state.docs, p["textDocument"]["uri"])}

  defp handle(%{"method" => "textDocument/definition", "id" => id, "params" => p}, state) do
    uri = p["textDocument"]["uri"]

    case find_ranges(state, uri, "TARGET") do
      [range | _] -> reply(id, %{uri: uri, range: range})
      [] -> reply(id, nil)
    end

    state
  end

  defp handle(%{"method" => "textDocument/references", "id" => id, "params" => p}, state) do
    uri = p["textDocument"]["uri"]
    reply(id, for(r <- find_ranges(state, uri, "TARGET"), do: %{uri: uri, range: r}))
    state
  end

  defp handle(%{"method" => "textDocument/hover", "id" => id, "params" => p}, state) do
    text = state.docs[p["textDocument"]["uri"]] || ""
    word = text |> String.split(~r/\s+/, trim: true) |> List.first() || ""
    reply(id, %{contents: %{kind: "plaintext", value: "hover:" <> word}})
    state
  end

  defp handle(%{"method" => "textDocument/completion", "id" => id, "params" => p}, state) do
    text = state.docs[p["textDocument"]["uri"]] || ""

    items =
      text
      |> String.split(~r/[^A-Za-z0-9_-]+/, trim: true)
      |> Enum.uniq()
      |> Enum.take(5)
      |> Enum.map(&%{label: &1, detail: "word"})

    reply(id, %{isIncomplete: false, items: items})
    state
  end

  defp handle(%{"method" => "shutdown", "id" => id}, state) do
    reply(id, nil)
    state
  end

  defp handle(%{"method" => "exit"}, _state), do: System.halt(0)

  defp handle(%{"method" => _m, "id" => id}, state) do
    send_msg(%{jsonrpc: "2.0", id: id, error: %{code: -32601, message: "method not found"}})
    state
  end

  defp handle(_, state), do: state

  # --- positions -------------------------------------------------------------

  defp diagnose(uri, text, state) do
    case :binary.match(text, "WARNME") do
      :nomatch ->
        notify("textDocument/publishDiagnostics", %{uri: uri, diagnostics: []})

      {idx, len} ->
        notify("textDocument/publishDiagnostics", %{
          uri: uri,
          diagnostics: [
            %{
              range: %{
                start: lsp_pos(text, idx, state.enc),
                end: lsp_pos(text, idx + len, state.enc)
              },
              severity: 2,
              message: "warn me not",
              source: "fake-lsp"
            }
          ]
        })
    end
  end

  defp find_ranges(state, uri, token) do
    text = state.docs[uri] || ""

    for {idx, len} <- :binary.matches(text, token) do
      %{start: lsp_pos(text, idx, state.enc), end: lsp_pos(text, idx + len, state.enc)}
    end
  end

  defp lsp_pos(text, idx, enc) do
    prefix = binary_part(text, 0, idx)
    line = prefix |> :binary.matches("\n") |> length()

    bol =
      case prefix |> :binary.matches("\n") |> List.last() do
        nil -> 0
        {pos, _} -> pos + 1
      end

    line_prefix = binary_part(text, bol, idx - bol)

    character =
      case enc do
        :utf8 ->
          byte_size(line_prefix)

        :utf16 ->
          line_prefix
          |> :unicode.characters_to_binary(:utf8, {:utf16, :big})
          |> byte_size()
          |> div(2)
      end

    %{line: line, character: character}
  end
end

FakeLSP.run()
