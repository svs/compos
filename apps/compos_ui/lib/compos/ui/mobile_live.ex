defmodule Compos.Ui.MobileLive do
  @moduledoc """
  The handheld client: one column, one window, and no chords.

  A second client of the same payload the desktop draws. It attaches a
  frame, reads `Compos.Core.Editor.render_state/1`, and draws the frame's
  selected window. The bar at the bottom reaches the group's chat, its
  buffers, the groups, and the commands; each of the last three is a sheet
  of rows to tap. The composer is the chat's input. A prompt or a
  transient the editor opens is a sheet too. Nothing here is editor
  logic: `handheld.scm` decides what every tap does and what each sheet
  lists.
  """

  use Phoenix.LiveView
  import Compos.Ui.ComposML, only: [sigil_M: 2]

  alias Compos.Core.{Editor, Events, Input, Session}
  alias Compos.Ui.EditorLive

  @empty_view %{group: "", chat: false}

  # the sheets the bar opens, in the bar's order after the chat
  @sheets ["buffers", "groups", "commands"]

  @impl true
  def mount(params, _session, socket) do
    socket =
      assign(socket,
        frame: nil,
        state: nil,
        leaf: nil,
        subscribed: MapSet.new(),
        line_cache: %{},
        boot_id: :persistent_term.get(:compos_boot_id, "dev"),
        view: @empty_view,
        view_key: nil,
        sheet: nil,
        sheet_rows: [],
        filter: ""
      )

    if connected?(socket) do
      requested = get_connect_params(socket)["frame"]
      {:ok, fid} = Editor.attach_frame(requested)
      Events.subscribe_frame(fid)
      Input.run(fid, fn -> Session.call_named("frame-attached!", []) end)

      if buffer = params["buffer"] do
        Input.run(fid, fn ->
          Session.call_named("open-buffer-link!", [buffer, line_param(params)])
        end)
      end

      {:ok, socket |> assign(frame: fid) |> refresh()}
    else
      {:ok, socket}
    end
  end

  # ── input ──────────────────────────────────────────────────────────

  # a key from a sheet: a prompt's RET or C-g, a transient's own key
  @impl true
  def handle_event("key", %{"k" => spec}, socket) when is_binary(spec) do
    Input.dispatch(socket.assigns.frame, spec)
    {:noreply, socket |> drain() |> refresh()}
  end

  # keys in order through the same queue: the composer feeding a prompt
  def handle_event("keys", %{"ks" => specs}, socket) when is_list(specs) or is_binary(specs) do
    specs = if is_binary(specs), do: String.split(specs, " ", trim: true), else: specs
    Enum.each(specs, fn k -> if is_binary(k), do: Input.dispatch(socket.assigns.frame, k) end)
    {:noreply, socket |> drain() |> refresh()}
  end

  # the composer: the line goes to the group's chat
  def handle_event("compose", %{"text" => text}, socket) when is_binary(text) do
    call(socket, "handheld-compose!", [text])
    {:noreply, socket |> close_sheet() |> drain() |> refresh()}
  end

  # the bar: the chat at once, or a sheet; the open sheet's own button
  # closes it again
  def handle_event("nav", %{"to" => "chat"}, socket) do
    call(socket, "handheld-chat!", [])
    {:noreply, socket |> close_sheet() |> drain() |> refresh()}
  end

  def handle_event("nav", %{"to" => sheet}, socket) when sheet in @sheets do
    socket =
      if socket.assigns.sheet == sheet,
        do: close_sheet(socket),
        else: socket |> assign(sheet: sheet, filter: "") |> load_sheet()

    {:noreply, refresh(socket)}
  end

  def handle_event("sheet_close", _p, socket), do: {:noreply, socket |> close_sheet() |> refresh()}

  # RET in the sheet's filter takes the first row it leaves
  def handle_event("sheet_filter", %{"key" => "Enter", "value" => q}, socket) when is_binary(q) do
    socket = assign(socket, filter: q)
    socket = if socket.assigns.sheet == "commands", do: load_sheet(socket), else: socket

    case socket.assigns.sheet_rows |> shown_sections(socket.assigns.sheet, q) |> Enum.flat_map(& &1.rows) do
      [r | _] -> handle_event("pick", %{"kind" => r.kind, "id" => r.id}, socket)
      [] -> {:noreply, refresh(socket)}
    end
  end

  # the sheet's filter: groups and buffers narrow here, commands ask Scheme
  def handle_event("sheet_filter", %{"value" => q}, socket) when is_binary(q) do
    socket = assign(socket, filter: q)
    socket = if socket.assigns.sheet == "commands", do: load_sheet(socket), else: socket
    {:noreply, refresh(socket)}
  end

  # a tap on a row of a sheet
  def handle_event("pick", %{"kind" => kind, "id" => id}, socket) when is_binary(id) do
    case kind do
      "group" -> call(socket, "handheld-group!", [id])
      "buffer" -> call(socket, "handheld-buffer!", [id])
      "command" -> call(socket, "handheld-run-command!", [id])
      _ -> :ok
    end

    {:noreply, socket |> close_sheet() |> drain() |> refresh()}
  end

  # a tap on a menu row: Scheme selects it and invokes it, as RET does
  def handle_event("trow", %{"i" => i}, socket) do
    with {i, ""} <- Integer.parse(to_string(i)), do: call(socket, "handheld-transient-tap!", [i])
    {:noreply, socket |> drain() |> refresh()}
  end

  # a tap on a line: point goes there; on point's own line it opens
  def handle_event("line", %{"n" => n}, socket) do
    with {n, ""} <- Integer.parse(to_string(n)), do: call(socket, "handheld-tap-line!", [n])
    {:noreply, socket |> drain() |> refresh()}
  end

  # the point rail: a fraction of the buffer becomes a line number here,
  # and Scheme moves point to it
  def handle_event("rail", %{"frac" => frac}, socket) when is_number(frac) do
    leaf = socket.assigns.leaf

    if leaf do
      total = max(Compos.Core.Buffer.line_of(leaf.buffer, byte_size(leaf.text)) || 1, 1)
      frac = frac |> max(0.0) |> min(1.0)
      n = round(frac * (total - 1)) + 1
      call(socket, "handheld-scrub!", [n])
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # a tap on a prompt candidate: move the selection there and accept.
  # The rows are the frame's own slice, so the distance is relative to
  # the selected row and no new primitive is needed.
  def handle_event("cand", %{"i" => i}, socket) do
    with mb when is_map(mb) <- socket.assigns.state.minibuffer,
         {i, ""} <- Integer.parse(to_string(i)) do
      rows = mb.candidates
      sel = Enum.find_index(rows, &Map.get(&1, :selected)) || 0
      key = if i > sel, do: "C-n", else: "C-p"

      for _ <- 1..abs(i - sel)//1, do: Input.dispatch(socket.assigns.frame, key)
      Input.dispatch(socket.assigns.frame, "RET")
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # the client's row count for the one window it draws
  def handle_event("viewport", %{"rows" => rows}, socket) when is_integer(rows) do
    Editor.set_total_rows(rows, socket.assigns.frame)
    {:noreply, socket |> drain() |> refresh()}
  end

  # ── the transcript's own events, as the desktop handles them ──────

  def handle_event("ui_cmd", %{"win" => win} = params, socket) do
    with {id, ""} <- Integer.parse(to_string(win)) do
      Input.run(socket.assigns.frame, fn ->
        Editor.set_active(id)
        Session.call_named("ui-command!", [params["cmd"] || false, params["buf"] || false])
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # the reader's place in a followed block list, as the editor keeps it
  def handle_event("follow_place", %{"buf" => buf, "stick" => stick, "top" => top} = params, socket)
      when is_boolean(stick) and is_integer(top) do
    if Compos.Core.Buffer.exists?(buf) do
      anchor = if is_integer(params["anchor"]), do: params["anchor"], else: false
      offset = if is_integer(params["offset"]), do: params["offset"], else: 0
      Compos.Core.Buffer.set_local(buf, "follow-place", [not stick, top, anchor, offset])
    end

    {:noreply, socket}
  end

  def handle_event("block_click", %{"win" => win, "id" => id}, socket) do
    with {wid, ""} <- Integer.parse(to_string(win)) do
      Input.run(socket.assigns.frame, fn ->
        Editor.set_active(wid)
        Compos.Core.SchemeAPI.block_click(Editor.current_buffer(), id)
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  def handle_event("preview_link", %{"win" => win, "href" => href}, socket)
      when is_binary(href) and byte_size(href) <= 2000 do
    with {id, ""} <- Integer.parse(to_string(win)) do
      Input.run(socket.assigns.frame, fn ->
        Session.call_named("preview-follow-link!", [id, href])
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  def handle_event("preview_link_to_group", %{"win" => win, "href" => href}, socket)
      when is_binary(href) and byte_size(href) <= 2000 do
    with {id, ""} <- Integer.parse(to_string(win)) do
      Input.run(socket.assigns.frame, fn ->
        Session.call_named("link-follow-to-group", [id, href])
      end)
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:frame_change, _}, socket), do: {:noreply, socket |> drain() |> refresh()}
  def handle_info({:editor_change, _}, socket), do: {:noreply, socket |> drain() |> refresh()}
  def handle_info({:buffer_change, _, _}, socket), do: {:noreply, socket |> drain() |> refresh()}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp drain(socket) do
    receive do
      {:frame_change, _} -> drain(socket)
      {:editor_change, _} -> drain(socket)
      {:buffer_change, _, _} -> drain(socket)
    after
      0 -> socket
    end
  end


  # ── state ──────────────────────────────────────────────────────────

  defp call(socket, name, args) do
    Input.run(socket.assigns.frame, fn -> Session.call_named(name, args) end)
  end

  defp close_sheet(socket), do: assign(socket, sheet: nil, sheet_rows: [], filter: "")

  defp refresh(socket) do
    fid = socket.assigns.frame
    state = Editor.render_state(fid)

    state =
      if fid && state.frame != fid do
        {:ok, ^fid} = Editor.attach_frame(fid)
        Editor.render_state(fid)
      else
        state
      end

    caret_owner = if state.minibuffer, do: nil, else: state.active

    {tree, cache} =
      EditorLive.decorate_tree(state.tree, socket.assigns.line_cache, state.faces, caret_owner)

    leaf = find_leaf(tree, state.active) || first_leaf(tree)
    leaf_id = leaf && leaf.id

    # the phone draws one window: only its cache entries live on
    cache =
      Map.filter(cache, fn
        {{_kind, id}, _} -> id == leaf_id
        {id, _} -> id == leaf_id
      end)

    subscribed =
      if connected?(socket) do
        visible = if leaf, do: MapSet.new([leaf.buffer]), else: MapSet.new()

        socket.assigns.subscribed
        |> MapSet.difference(visible)
        |> Enum.each(&Events.unsubscribe/1)

        visible
        |> MapSet.difference(socket.assigns.subscribed)
        |> Enum.each(&Events.subscribe/1)

        visible
      else
        socket.assigns.subscribed
      end

    {view, view_key} = view_for(socket, state, leaf)

    # a prompt or a transient owns the screen: a sheet of ours closes under it
    sheet = if state.minibuffer || state.transient, do: nil, else: socket.assigns.sheet

    socket =
      assign(socket,
        state: state,
        leaf: leaf,
        line_cache: cache,
        subscribed: subscribed,
        view: view,
        view_key: view_key,
        sheet: sheet
      )

    case fid && Editor.take_navigation(fid) do
      url when is_binary(url) -> push_event(socket, "navigate", %{url: url})
      _ -> socket
    end
  end

  # what the header names. One call per change of the shown buffer, its
  # mode, or the group; nothing per keystroke.
  defp view_for(socket, state, leaf) do
    key = {leaf && leaf.buffer, leaf && leaf.mode, state.frame_group}

    if key == socket.assigns.view_key do
      {socket.assigns.view, key}
    else
      {fetch_view(socket, leaf && leaf.buffer), key}
    end
  end

  defp fetch_view(_socket, nil), do: @empty_view

  defp fetch_view(socket, buf) do
    case call(socket, "handheld-view", [buf]) do
      {:ok, [group, chat]} -> %{group: str(group), chat: chat == true}
      _ -> @empty_view
    end
  rescue
    _ -> @empty_view
  end

  # a sheet's rows, from Scheme: ((TITLE ROWS) ...), a row being
  # %{kind, id, label, sub, current}
  defp load_sheet(%{assigns: %{sheet: nil}} = socket), do: socket

  defp load_sheet(socket) do
    buf = socket.assigns.leaf && socket.assigns.leaf.buffer
    assign(socket, sheet_rows: fetch_sheet(socket, socket.assigns.sheet, buf, socket.assigns.filter))
  rescue
    _ -> assign(socket, sheet_rows: [])
  end

  defp fetch_sheet(socket, "groups", _buf, _q) do
    rows =
      for [id, label, cur] <- ok_list(call(socket, "handheld-groups", [])) do
        %{kind: "group", id: str(id), label: str(label), sub: "", current: cur == true}
      end

    [%{title: "", rows: rows}]
  end

  defp fetch_sheet(socket, "buffers", buf, _q) do
    for [title, rows] <- ok_list(call(socket, "handheld-buffers", [buf || false])) do
      rows =
        for [name, label, sub, cur] <- list(rows) do
          %{kind: "buffer", id: str(name), label: str(label), sub: str(sub), current: cur == true}
        end

      %{title: str(title), rows: rows}
    end
  end

  defp fetch_sheet(socket, "commands", buf, q) do
    if String.trim(q) == "" do
      for [title, rows] <- ok_list(call(socket, "handheld-commands", [buf || false])) do
        %{title: str(title), rows: command_rows(rows)}
      end
    else
      [%{title: "matches", rows: command_rows(ok_list(call(socket, "handheld-search", [buf || false, q])))}]
    end
  end

  defp fetch_sheet(_socket, _sheet, _buf, _q), do: []

  defp command_rows(rows) do
    for [name, doc] <- list(rows) do
      %{kind: "command", id: str(name), label: str(name), sub: str(doc), current: false}
    end
  end

  # groups and buffers narrow on the client's side of the call: every
  # word of the filter must be in the row's label or its line below
  defp shown_sections(sections, sheet, q) when sheet in ["groups", "buffers"] do
    terms = q |> String.downcase() |> String.split(" ", trim: true)

    if terms == [] do
      sections
    else
      for s <- sections do
        hay = fn r -> String.downcase(r.label <> " " <> r.sub) end
        %{s | rows: Enum.filter(s.rows, fn r -> Enum.all?(terms, &String.contains?(hay.(r), &1)) end)}
      end
    end
  end

  defp shown_sections(sections, _sheet, _q), do: sections

  defp ok_list({:ok, x}) when is_list(x), do: x
  defp ok_list(_), do: []

  defp list(x) when is_list(x), do: x
  defp list(_), do: []

  defp str(x) when is_binary(x), do: x
  defp str({:sym, s}), do: to_string(s)
  defp str(false), do: ""
  defp str(nil), do: ""
  defp str(x), do: to_string(x)

  defp find_leaf(%{type: :leaf, id: id} = leaf, id), do: leaf
  defp find_leaf(%{type: :split, children: kids}, id), do: Enum.find_value(kids, &find_leaf(&1, id))
  defp find_leaf(_, _), do: nil

  defp first_leaf(%{type: :leaf} = leaf), do: leaf
  defp first_leaf(%{type: :split, children: [kid | _]}), do: first_leaf(kid)
  defp first_leaf(_), do: nil

  defp line_param(params) do
    case Integer.parse(to_string(params["line"] || "")) do
      {n, ""} when n > 0 -> n
      _ -> false
    end
  end

  # ── render ─────────────────────────────────────────────────────────

  def composml(%{state: nil} = assigns) do
    ~M"""
    <c-frame id="hh" class="hh splash" phx-hook="Handheld" data-boot={@boot_id}>
      <c-group class="hh-splash">compos — connecting…</c-group>
    </c-frame>
    """
  end

  def composml(assigns) do
    ~M"""
    <c-frame id="hh" class="hh" phx-hook="Handheld" data-boot={@boot_id} data-frame={@frame} data-mb={to_string(@state.minibuffer != nil)}>
      <style :if={@state.faces != %{}}><%= Phoenix.HTML.raw(Compos.Ui.FaceCSS.css(@state.faces)) %></style>
      <style :if={@state.styles != %{}}><%= Phoenix.HTML.raw(Enum.join(Map.values(@state.styles), "\n")) %></style>

      <.head leaf={@leaf} view={@view} />

      <c-group class="hh-body">
        <c-group :if={rail?(@leaf)} class="hh-rail" data-rail="1">
          <c-group class="hh-rail-mark" style={"top: #{rail_top(@leaf)}%"}></c-group>
        </c-group>
        <.content leaf={@leaf} />
      </c-group>

      <c-prompt class={"hh-composer #{if @state.minibuffer, do: "prompting"}"}>
        <c-group class="hh-input-row">
          <c-text :if={@state.minibuffer} class="hh-prompt">{String.trim_trailing(@state.minibuffer.prompt, " ")}</c-text>
          <input
            id="composer"
            class="hh-input"
            type="text"
            autocomplete="off"
            autocorrect="off"
            autocapitalize="sentences"
            spellcheck="true"
            enterkeyhint="send"
            placeholder={placeholder(@view, @state)}
          />
          <c-text id="composer-send" class="hh-send">{if @state.minibuffer, do: "OK", else: "Send"}</c-text>
        </c-group>
        <c-group :if={echo(@state) != ""} class={"hh-echo #{if echo_error?(@state.echo), do: "err"}"}>{echo(@state)}</c-group>
      </c-prompt>

      <c-group class="hh-nav">
        <c-group class={"hh-nav-btn #{if @view.chat and @sheet == nil, do: "on"}"} data-nav="chat" phx-click="nav" phx-value-to="chat">
          <c-text class="hh-nav-glyph">✎</c-text>
          <c-text class="hh-nav-label">Chat</c-text>
        </c-group>
        <c-group :for={{to, glyph, label} <- nav_items()} class={"hh-nav-btn #{if @sheet == to, do: "on"}"} data-nav={to} phx-click="nav" phx-value-to={to}>
          <c-text class="hh-nav-glyph">{glyph}</c-text>
          <c-text class="hh-nav-label">{label}</c-text>
        </c-group>
      </c-group>

      <.pick_sheet :if={@sheet} sheet={@sheet} sections={shown_sections(@sheet_rows, @sheet, @filter)} filter={@filter} view={@view} />

      <.sheet :if={@state.minibuffer || (@state.transient && @state.transient[:groups])} state={@state} />
    </c-frame>
    """
  end

  defp nav_items, do: [{"buffers", "☰", "Buffers"}, {"groups", "◫", "Groups"}, {"commands", "⌘", "Commands"}]

  # the header: the group above, the buffer below. A tap lists the
  # group's buffers.
  defp head(assigns) do
    ~M"""
    <c-modeline class="hh-head" phx-click="nav" phx-value-to="buffers">
      <c-group class="hh-head-main">
        <c-text :if={@view.group != ""} class="hh-head-group">{@view.group}</c-text>
        <c-buffer-name class="hh-head-name">{ml_name(@leaf)}</c-buffer-name>
      </c-group>
      <c-text :if={info(@leaf) != ""} class="hh-head-info">{info(@leaf)}</c-text>
      <c-text :if={dirty?(@leaf, @view)} class="hh-head-dirty">●</c-text>
      <c-text class="hh-head-chev">▾</c-text>
    </c-modeline>
    """
  end

  defp content(%{leaf: nil} = assigns) do
    ~M"""
    <c-buffer class="hh-content"></c-buffer>
    """
  end

  # a block tree draws with the editor's own block renderer. The composer
  # below is the handheld's input, so the tree's caret input stays empty.
  defp content(%{leaf: %{render_mode: "blocks"}} = assigns) do
    ~M"""
    <c-buffer class={"hh-content hh-blocks #{hh_root_class(@leaf)}"} buffer={@leaf.buffer}>
      <EditorLive.blk
        :for={b <- Map.get(@leaf, :blk, [])}
        b={b}
        line={Map.get(@leaf, :blk_line, 0)}
        win={@leaf.id}
        ctx={%{live: true, buf: @leaf.buffer, follow: Map.get(@leaf, :blocks_follow)}}
      />
    </c-buffer>
    """
  end

  defp content(%{leaf: %{render_mode: rm}} = assigns) when rm in ["html", "markdown"] do
    ~M"""
    <c-buffer class="hh-content">
      <iframe
        :if={Map.has_key?(@leaf, :preview)}
        class="hh-preview"
        id={"prev-#{@leaf.id}"}
        srcdoc={@leaf.preview}
        sandbox="allow-same-origin"
        title={@leaf.buffer}
      ></iframe>
    </c-buffer>
    """
  end

  defp content(%{leaf: %{render_mode: "file"}} = assigns) do
    ~M"""
    <c-buffer class="hh-content">
      <iframe :if={Map.has_key?(@leaf, :file_url)} class="hh-preview" src={@leaf.file_url} sandbox="" title={@leaf.buffer}></iframe>
    </c-buffer>
    """
  end

  # lines: a tap moves point to the line, a tap on point's line opens it
  defp content(assigns) do
    ~M"""
    <c-buffer class="hh-content hh-lines" id={"lines-#{@leaf.id}"}>
      <c-group :for={ln <- Map.get(@leaf, :lines, [])} class={"hh-line #{if ln.current, do: "cur"}"} data-s={ln.start} phx-click="line" phx-value-n={ln.num}>
        <c-text class="hh-line-text"><c-text :for={{txt, cls} <- ln.segs} class={cls}>{txt}</c-text><br :if={ln.segs == []} /></c-text>
      </c-group>
      <c-group :if={Map.get(@leaf, :lines, []) == []} class="hh-empty">{@leaf.buffer} · {@leaf.mode}</c-group>
    </c-buffer>
    """
  end

  # a sheet of rows to tap: the group's buffers, the groups, or the
  # commands. The field on top narrows it; RET there takes the first row.
  defp pick_sheet(assigns) do
    ~M"""
    <c-group class="hh-pick-layer">
      <c-group class="hh-sheet-scrim" phx-click="sheet_close"></c-group>
      <c-group class="hh-sheet hh-pick" role="dialog" aria-modal="true" data-sheet={@sheet}>
        <c-group class="hh-sheet-head">
          <c-text class="hh-kicker">{sheet_title(@sheet, @view)}</c-text>
          <c-text class="hh-spacer"></c-text>
          <c-text class="hh-sheet-quit" phx-click="sheet_close">Close</c-text>
        </c-group>
        <c-group class="hh-pick-filter">
          <input
            id={"pick-filter-#{@sheet}"}
            class="hh-input"
            type="search"
            autocomplete="off"
            autocorrect="off"
            autocapitalize="off"
            spellcheck="false"
            enterkeyhint="go"
            placeholder={filter_hint(@sheet)}
            value={@filter}
            phx-keyup="sheet_filter"
            phx-debounce="120"
          />
        </c-group>
        <c-group class="hh-sheet-rows">
          <%= for s <- @sections do %>
            <c-group :if={s.title != "" and s.rows != []} class="hh-group-title">{s.title}</c-group>
            <c-group :for={r <- s.rows} class={"hh-row #{if r.current, do: "on"}"} phx-click="pick" phx-value-kind={r.kind} phx-value-id={r.id}>
              <c-group class="hh-row-main">
                <c-group class="hh-row-label">{r.label}</c-group>
                <c-group :if={r.sub != ""} class="hh-row-sub">{r.sub}</c-group>
              </c-group>
              <c-text :if={r.current} class="hh-row-here">here</c-text>
            </c-group>
          <% end %>
          <c-group :if={Enum.all?(@sections, &(&1.rows == []))} class="hh-empty">{empty_word(@sheet, @filter)}</c-group>
        </c-group>
      </c-group>
    </c-group>
    """
  end

  defp sheet_title("buffers", %{group: g}) when g != "", do: "Buffers · " <> g
  defp sheet_title("buffers", _view), do: "Buffers"
  defp sheet_title("groups", _view), do: "Groups"
  defp sheet_title("commands", _view), do: "Commands"

  defp filter_hint("buffers"), do: "Filter buffers"
  defp filter_hint("groups"), do: "Filter groups"
  defp filter_hint("commands"), do: "Search every command"

  defp empty_word("commands", ""), do: "Type to search every command"
  defp empty_word(_sheet, ""), do: "Nothing here yet"
  defp empty_word(_sheet, _q), do: "Nothing matches"

  defp sheet(%{state: %{minibuffer: mb}} = assigns) when is_map(mb) do
    assigns = assign(assigns, mb: mb, split: mb_split(mb))

    ~M"""
    <c-group class="hh-sheet-layer">
      <c-group class="hh-sheet-scrim" phx-click="key" phx-value-k="C-g"></c-group>
      <c-group class="hh-sheet" role="dialog" aria-modal="true">
        <c-group class="hh-sheet-head">
          <c-text class="hh-kicker">{sheet_kicker(@state)}</c-text>
          <c-text class="hh-spacer"></c-text>
          <c-text class="hh-sheet-quit" phx-click="key" phx-value-k="C-g">C-g</c-text>
        </c-group>
        <c-group class="hh-sheet-title">{String.trim_trailing(@mb.prompt, ": ")}</c-group>
        <c-group class="hh-sheet-hint">{sheet_hint(@mb)}</c-group>
        <c-group class="hh-sheet-input">
          <c-text class="hh-prompt">›</c-text>
          <c-text class="hh-mb-input"><%= with {pre, cur, post} <- @split do %>{pre}<c-cursor class="cursor">{cur}</c-cursor>{post}<% end %></c-text>
          <c-text class="hh-spacer"></c-text>
          <c-text class="hh-count">{count_text(@mb)}</c-text>
        </c-group>
        <c-group class="hh-sheet-rows">
          <%= for {c, i} <- Enum.with_index(@mb.candidates) do %>
            <%= if Map.get(c, :kind) == "separator" do %>
              <c-group class="hh-sep">{c.label}</c-group>
            <% else %>
              <c-group class={"hh-row #{if c.selected, do: "on"}"} phx-click="cand" phx-value-i={i}>
                <c-text class="hh-row-box">{if c.selected, do: "●", else: ""}</c-text>
                <c-group class="hh-row-main">
                  <c-group class="hh-row-label">{c.label}</c-group>
                  <c-group :if={Map.get(c, :hint) not in [nil, ""]} class="hh-row-sub">{c.hint}</c-group>
                </c-group>
              </c-group>
            <% end %>
          <% end %>
        </c-group>
        <c-group :if={@mb.legend != []} class="hh-sheet-legend">
          <c-text :for={row <- @mb.legend} class="hh-legend"><b>{row.key}</b> {row.label}</c-text>
        </c-group>
      </c-group>
    </c-group>
    """
  end

  defp sheet(%{state: %{transient: t}} = assigns) do
    # each row's place over every group, the index the menu selects by
    {groups, _} =
      Enum.map_reduce(t.groups, 0, fn g, i ->
        {%{g | items: Enum.with_index(g.items, i)}, i + length(g.items)}
      end)

    assigns = assign(assigns, t: t, groups: groups)

    ~M"""
    <c-group class="hh-sheet-layer">
      <c-group class="hh-sheet-scrim" phx-click="key" phx-value-k="C-g"></c-group>
      <c-group class="hh-sheet" role="dialog" aria-modal="true">
        <c-group class="hh-sheet-head">
          <c-text class="hh-kicker">{if @state.pending != [], do: Enum.join(@state.pending, " ") <> " · ", else: ""}transient</c-text>
          <c-text class="hh-spacer"></c-text>
          <c-text class="hh-sheet-quit" phx-click="key" phx-value-k="C-g">C-g</c-text>
        </c-group>
        <c-group class="hh-sheet-title">{@t.title}</c-group>
        <c-group :if={@t[:subtitle] not in [nil, ""]} class="hh-sheet-hint">{@t.subtitle}</c-group>
        <c-group :if={@t[:chips] not in [nil, []]} class="hh-tchips">
          <c-text :for={chip <- @t.chips} class={"hh-tchip #{if chip.active, do: "on"}"}>{chip.label}</c-text>
        </c-group>
        <c-group class="hh-sheet-rows">
          <%= for group <- @groups do %>
            <c-group class="hh-group-title">{group.title}</c-group>
            <c-group
              :for={{item, i} <- group.items}
              class={"hh-trow #{if item.selected, do: "on"} #{item.behavior}"}
              phx-click="trow"
              phx-value-i={i}
            >
              <c-text class="hh-tkey">{item.key}</c-text>
              <c-group class="hh-row-main">
                <c-group class="hh-trow-desc">{item.description}</c-group>
                <c-group :if={item.value != ""} class="hh-trow-value">{item.value}</c-group>
              </c-group>
              <c-text class="hh-chev">›</c-text>
            </c-group>
          <% end %>
          <c-group :if={@t[:detail]} class="hh-detail">
            <c-group class="hh-group-title">{@t.detail.title}</c-group>
            <c-group :for={row <- @t.detail.rows} class={"hh-detail-row #{row.tone}"}>
              <c-text class="hh-detail-k">{row.k}</c-text>
              <c-text class="hh-detail-v">{row.v}</c-text>
            </c-group>
            <c-group :if={@t.detail.note != ""} class="hh-detail-note">{@t.detail.note}</c-group>
          </c-group>
        </c-group>
        <c-group class="hh-sheet-legend">
          <%= if @t[:legend] not in [nil, []] do %>
            <c-text :for={row <- @t.legend} class="hh-legend" phx-click="keys" phx-value-ks={row.key}><b>{row.key}</b> {row.label}</c-text>
          <% else %>
            <c-text class="hh-legend" phx-click="key" phx-value-k="RET"><b>RET</b> invoke</c-text>
            <c-text class="hh-legend" phx-click="key" phx-value-k="C-g"><b>C-g</b> quit</c-text>
          <% end %>
        </c-group>
      </c-group>
    </c-group>
    """
  end

  # ── small helpers ──────────────────────────────────────────────────

  defp rail?(nil), do: false
  defp rail?(leaf), do: leaf.render_mode not in ["blocks", "html", "markdown", "file", "app", "terminal"]

  defp ml_name(nil), do: ""
  defp ml_name(%{modeline_name: name}) when is_binary(name) and name != "", do: name
  defp ml_name(leaf), do: leaf.buffer

  defp info(%{modeline_info: info}) when is_binary(info), do: info
  defp info(_leaf), do: ""

  defp dirty?(nil, _view), do: false
  defp dirty?(leaf, view), do: not view.chat and leaf.modified == true and leaf.read_only != true

  defp echo(%{echo: echo}) when is_binary(echo), do: echo
  defp echo(_state), do: ""

  defp rail_top(nil), do: 0

  defp rail_top(leaf) do
    total = max(Compos.Core.Buffer.line_of(leaf.buffer, byte_size(leaf.text)) || 1, 1)
    line = max(Map.get(leaf, :line) || 1, 1)
    if total <= 1, do: 0, else: round((line - 1) / (total - 1) * 100)
  end

  defp placeholder(_view, %{minibuffer: mb}) when is_map(mb), do: "Type to narrow"
  defp placeholder(%{chat: true}, _state), do: "Message the chat"
  defp placeholder(%{group: g}, _state) when g != "", do: "Ask the " <> g <> " chat"
  defp placeholder(_view, _state), do: "Message the chat"

  defp hh_root_class(leaf) do
    case Map.get(leaf, :blk_root) do
      %{class: c} when is_binary(c) -> c
      _ -> ""
    end
  end

  defp echo_error?(echo) when is_binary(echo),
    do: echo == "Quit" or String.ends_with?(echo, "is undefined") or String.starts_with?(echo, "No ")

  defp echo_error?(_), do: false

  defp sheet_kicker(%{pending: [_ | _] = pending}), do: Enum.join(pending, " ")
  defp sheet_kicker(%{minibuffer: %{style: style}}) when is_binary(style), do: style
  defp sheet_kicker(_), do: "prompt"

  defp sheet_hint(%{style: "question"}), do: "y answers yes · n answers no · C-g quits"
  defp sheet_hint(%{style: "filter"}), do: "type to narrow · empty removes it · RET keeps it"
  defp sheet_hint(%{completing: true}), do: "Tap a row to take it, or type to narrow."
  defp sheet_hint(_), do: "Type in the field below and press RET."

  defp count_text(%{total: total, sel: sel}) when is_integer(total) and total > 0 do
    "#{min((sel || 0) + 1, total)}/#{total}"
  end

  defp count_text(_), do: ""

  defp mb_split(%{input: input, point: point}) when is_binary(input) and is_integer(point) do
    point = point |> min(byte_size(input)) |> max(0)
    rest = binary_part(input, point, byte_size(input) - point)

    case String.next_grapheme(rest) do
      nil -> {binary_part(input, 0, point), " ", ""}
      {g, post} -> {binary_part(input, 0, point), g, post}
    end
  end

  defp mb_split(mb), do: {Map.get(mb, :input, ""), " ", ""}

  @impl true
  def render(assigns), do: Compos.Ui.Representation.live(__MODULE__, assigns)
end
