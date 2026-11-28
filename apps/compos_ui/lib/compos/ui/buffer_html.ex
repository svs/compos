defmodule Compos.Ui.BufferHtml do
  @moduledoc """
  Render any compos buffer to its real editor HTML and collect the live
  editor stylesheets (composml.css, editor.css, FaceCSS, and mode styles).

  Reuses `Compos.Core.BufferView`, `Compos.Core.Display`, and
  `Compos.Ui.EditorLive` so rendered cards match the live editor across
  block modes (chat, chat-list, todos, ibuffer, messages), markdown/HTML
  previews, and syntax-highlighted code buffers.
  """

  alias Compos.Core.{Buffer, BufferView, Editor, Text}
  alias Compos.Ui.{EditorLive, FaceCSS}

  @max_follow_children 14
  @max_list_children 28

  @doc """
  The complete CSS that renders compos buffers: custom-element layout rules,
  editor chrome/content tokens, live face variables, and every mode stylesheet.
  """
  def styles_css do
    composml = read_static("priv/static/composml.css")
    editor = read_static("priv/static/editor.css")
    faces = Editor.faces() |> FaceCSS.css()
    styles = Editor.styles() |> Map.values() |> Enum.join("\n")
    Enum.join([composml, editor, faces, styles], "\n")
  end

  @doc """
  Render BUFFER in its real compos mode to an HTML fragment map, or `nil`
  when the buffer does not exist.
  """
  def render(name, opts \\ []) when is_binary(name) do
    case snapshot(name) do
      nil ->
        nil

      snap ->
        rows = Keyword.get(opts, :rows) || 32
        point = Keyword.get(opts, :point) || snap.point
        locals = snap.locals || %{}
        rm = effective_render_mode(locals)
        faces = Editor.faces()
        leaf = build_leaf(name, snap, locals, rm, point, rows)
        {decorated, _cache} = EditorLive.decorate_tree(leaf, %{}, faces, false)
        {html, follow?} = leaf_to_html(decorated, rm, locals)

        %{
          name: name,
          shortName: short_name(name),
          renderMode: rm || "text",
          mode: decorated.mode,
          windowClass: decorated.window_class || "",
          lineNumbers: decorated.line_numbers,
          style: decorated.style || "",
          follow: follow?,
          line: decorated.line,
          pointLine: decorated.line,
          totalLines: decorated.total_lines,
          point: point,
          modified: decorated.modified,
          version: decorated.version,
          ts: System.monotonic_time(:millisecond),
          html: rewrite_asset_urls(html)
        }
    end
  catch
    :exit, _ -> nil
  end

  defp snapshot(name) do
    case BufferView.snapshot(name, nil, ["render-blocks"]) do
      nil ->
        if Buffer.exists?(name), do: Buffer.render_snapshot(name, nil), else: nil

      snap ->
        snap
    end
  end

  defp effective_render_mode(%{"render-mode" => "blocks"} = locals) do
    case Map.get(locals, "render-blocks") do
      [_ | _] -> "blocks"
      other -> if BufferView.big_ref?(other), do: "blocks", else: nil
    end
  end

  # Terminal buffers draw in xterm on the main page; render their text lines
  # cleanly in static HTML so shell output stays visible on canvas cards.
  defp effective_render_mode(%{"render-mode" => "terminal"}), do: nil
  defp effective_render_mode(locals), do: Map.get(locals, "render-mode")

  defp build_leaf(name, snap, locals, rm, point, rows) do
    text = snap.text
    size = Map.get(snap, :size) || byte_size(text)
    clamped_pt = point |> max(0) |> min(size)
    total_lines = Map.get(snap, :total_lines) || 1
    cl = if clamped_pt == snap.point, do: snap.cursor_line, else: Text.line_index(text, clamped_pt)
    top = max(0, min(cl - div(rows, 2), max(total_lines - rows, 0)))

    %{
      type: :leaf,
      id: :erlang.phash2({:ov, name}, 1_000_000) + 1,
      buffer: name,
      path: snap.path,
      read_only: snap.read_only,
      editing: false,
      arrow_keys: false,
      dismissible: false,
      text: text,
      rope: Map.get(snap, :rope),
      size: size,
      point: clamped_pt,
      mark: snap.mark,
      version: snap.version,
      modified: snap.modified,
      mode: Map.get(locals, "mode-name") || "fundamental-mode",
      header_line: Map.get(locals, "header-line"),
      footer_line: Map.get(locals, "footer-line"),
      footer_line_blocks: Map.get(locals, "footer-line-blocks"),
      ts_lang: if(Map.get(locals, "ts-faces") == false, do: nil, else: Map.get(locals, "ts-lang")),
      plain_source: Map.get(locals, "plain-source") == true,
      overlays: snap.overlays,
      overlay_gen: snap.overlay_gen,
      hidden_lines: MapSet.new(),
      narrow_lines: nil,
      line: cl + 1,
      col: snap.col,
      style: Map.get(locals, "style"),
      render_mode: rm,
      anchor: nil,
      visual_line_mode: Map.get(locals, "visual-line-mode") == true,
      hl_line: Map.get(locals, "hl-line-mode") != "off",
      blocks: if(rm == "blocks", do: Map.get(locals, "render-blocks") || [], else: nil),
      blocks_input: blocks_input(locals, rm),
      blocks_follow: if(rm == "blocks", do: %{stick: true, top: 0, anchor: nil, offset: 0, seq: 0}, else: nil),
      blocks_root: Map.get(locals, "render-root"),
      text_root: Map.get(locals, "render-text-root"),
      semantic_records: Map.get(locals, "render-records"),
      minor_modes: Map.get(locals, "minor-modes") || [],
      preview_authored: Map.get(locals, "preview-authored") == true,
      whitespace_mode: Map.get(locals, "whitespace-mode"),
      preview_csv_files: Map.get(locals, "preview-csv-files"),
      cursor_visible: false,
      app_gen: Map.get(locals, "app-generation") || 0,
      web_url: Map.get(locals, "web-url"),
      top: top,
      manual: false,
      ctop: 0,
      rows: rows,
      total_lines: total_lines,
      line_numbers: Map.get(locals, "line-numbers") != "off",
      window_class: Map.get(locals, "window-class") || nil,
      window_style: Map.get(locals, "window-style") || nil
    }
  end

  defp blocks_input(%{"render-input" => name} = locals, "blocks") when is_binary(name) do
    case Map.get(locals, name) do
      n when is_integer(n) -> n
      _ -> nil
    end
  end

  defp blocks_input(_, _), do: nil

  defp leaf_to_html(decorated, "blocks", _locals) do
    blk = Map.get(decorated, :blk) || []
    line = Map.get(decorated, :blk_line, 0)
    {trimmed, follow?} = trim_blocks(blk, line)
    html = EditorLive.render_static_body(%{decorated | blk: trimmed})
    {html, follow?}
  end

  defp leaf_to_html(decorated, rm, _locals) when rm in ["markdown", "html"] do
    doc = Map.get(decorated, :preview) || ""
    {inline_preview_html(doc), false}
  end

  defp leaf_to_html(decorated, rm, locals) when rm in ["app", "web", "file"] do
    detail =
      case rm do
        "web" -> Map.get(locals, "web-url") || decorated.buffer
        "file" -> decorated.path || decorated.buffer
        _ -> decorated.mode
      end

    esc_rm = escape_html(rm)
    esc_detail = escape_html(to_string(detail || ""))

    html =
      ~s(<div class="ov-external-card"><span class="ov-ext-kind">#{esc_rm}</span><div class="ov-ext-detail">#{esc_detail}</div></div>)

    {html, false}
  end

  defp leaf_to_html(decorated, _rm, _locals) do
    {EditorLive.render_static_body(decorated), false}
  end

  # Keep card DOM fast even for 5,000-line chats or long lists: slice huge
  # isolated lists to the newest tail (follow) or a window around point.
  defp trim_blocks(blocks, line) when is_list(blocks) do
    Enum.map_reduce(blocks, false, fn b, f_acc ->
      {b2, f} = trim_block(b, line)
      {b2, f_acc or f}
    end)
  end

  defp trim_block(%{isolate: true, children: children} = b, line) when is_list(children) do
    follow? = b.follow == true
    limit = if follow?, do: @max_follow_children, else: @max_list_children

    sliced =
      cond do
        length(children) <= limit ->
          children

        follow? ->
          Enum.take(children, -limit)

        true ->
          idx = find_current_index(children, line)
          start = max(0, min(idx - div(limit, 3), length(children) - limit))
          Enum.slice(children, start, limit)
      end

    {%{b | children: sliced}, follow?}
  end

  defp trim_block(%{children: children} = b, line) when is_list(children) and children != [] do
    {cs, f} = trim_blocks(children, line)
    {%{b | children: cs}, f or b.follow == true}
  end

  defp trim_block(b, _line), do: {b, Map.get(b, :follow) == true}

  defp find_current_index(children, line) when is_integer(line) and line > 0 do
    Enum.find_index(children, fn c ->
      case Map.get(c, :lines) do
        [a, b] when is_integer(a) and is_integer(b) -> line >= a and line <= b
        _ -> false
      end
    end) || 0
  end

  defp find_current_index(_, _), do: 0

  # Extract style and body from a preview document so HTML-in-Canvas draws it
  # directly as DOM without a nested iframe.
  defp inline_preview_html(doc) when is_binary(doc) do
    styles =
      Regex.scan(~r/<style[^>]*>.*?<\/style>/is, doc)
      |> Enum.map(&hd/1)
      |> Enum.map(&scope_preview_style/1)
      |> Enum.join("\n")

    body =
      case Regex.run(~r/<body[^>]*>(.*)<\/body>/is, doc) do
        [_, inner] -> inner
        _ -> doc
      end

    ~s(<div class="ov-preview-doc">#{styles}#{body}</div>)
  end

  defp scope_preview_style(style_tag) do
    case Regex.run(~r/<style[^>]*>(.*)<\/style>/is, style_tag) do
      [_, inner] ->
        body =
          inner
          |> String.replace(~r/\bhtml\b/, "&")
          |> String.replace(~r/\bbody\b/, "&")

        "<style>.ov-preview-doc{#{body}}</style>"

      _ ->
        ""
    end
  end

  defp rewrite_asset_urls(html) when is_binary(html) do
    base = :persistent_term.get(:compos_editor_url, "http://localhost:4004")

    html
    |> String.replace(~s(src="/local-image/), ~s(src="#{base}/local-image/))
    |> String.replace(~s(src="/local-file/), ~s(src="#{base}/local-file/))
    |> String.replace(~s(src="/logo), ~s(src="#{base}/logo))
  end

  defp read_static(rel) do
    path = Application.app_dir(:compos_ui, rel)
    if File.regular?(path), do: File.read!(path), else: ""
  end

  defp short_name("/" <> _ = path), do: Path.basename(path)
  defp short_name(name), do: name

  defp escape_html(s) do
    s |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end
end
