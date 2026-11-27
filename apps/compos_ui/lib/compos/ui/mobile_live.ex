defmodule Compos.Ui.MobileLive do
  @moduledoc """
  The phone client: one buffer at a time, no keys.

  It attaches a frame of its own, reads `Compos.Core.Editor.render_state/1`,
  and draws the frame's one window. The bar at the bottom has four places:
  the chats, a new chat, the buffers and the groups. The composer under a
  chat sends to it. A prompt the editor opens is a sheet of rows to tap.
  `phone.scm` answers every list and does every tap; this module only
  draws.
  """

  use Phoenix.LiveView
  import Compos.Ui.ComposML, only: [sigil_M: 2]

  alias Compos.Core.{Editor, Events, Input, Session}
  alias Compos.Ui.{EditorLive, LiveShared}

  @window_events LiveShared.window_events()

  # the places of the bar that open a list
  @sheets ["chats", "buffers", "groups"]

  @titles %{"chats" => "Chats", "buffers" => "Buffers", "groups" => "Groups"}
  @hints %{"chats" => "Find a chat", "buffers" => "Find a buffer", "groups" => "Find a group"}

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
        group: "",
        chat: false,
        view_key: nil,
        sheet: nil,
        sheet_rows: [],
        filter: ""
      )

    if connected?(socket) do
      {:ok, fid} = Editor.attach_frame(get_connect_params(socket)["frame"])
      Events.subscribe_frame(fid)
      Input.run(fid, fn -> Session.call_named("frame-attached!", []) end)
      Input.run(fid, fn -> Session.call_named("phone-attach!", []) end)

      if buffer = params["buffer"] do
        Input.run(fid, fn -> Session.call_named("phone-show!", [buffer]) end)
      end

      {:ok, socket |> assign(frame: fid) |> refresh()}
    else
      {:ok, socket}
    end
  end

  # ── input ──────────────────────────────────────────────────────────

  # the composer: the line goes to the chat on show
  @impl true
  def handle_event("compose", %{"text" => text}, socket) when is_binary(text) do
    call(socket, "phone-send!", [shown(socket) || false, text])
    {:noreply, socket |> drain() |> refresh()}
  end

  # the bar opens a list, and the open list's own place closes it again;
  # New chat at the top of the chats starts one at once
  def handle_event("nav", %{"to" => "new"}, socket) do
    call(socket, "phone-new-chat!", [])
    {:noreply, socket |> close_sheet() |> drain() |> refresh()}
  end

  def handle_event("nav", %{"to" => sheet}, socket) when sheet in @sheets do
    socket =
      if socket.assigns.sheet == sheet,
        do: close_sheet(socket),
        else: socket |> assign(sheet: sheet, filter: "") |> load_sheet()

    {:noreply, socket}
  end

  def handle_event("sheet_close", _p, socket), do: {:noreply, close_sheet(socket)}

  # the list's filter: Scheme narrows the rows; RET takes the first row
  def handle_event("sheet_filter", %{"key" => "Enter", "value" => q}, socket) when is_binary(q) do
    socket = socket |> assign(filter: q) |> load_sheet()

    case Enum.flat_map(socket.assigns.sheet_rows, & &1.rows) do
      [r | _] -> handle_event("pick", %{"id" => r.id}, socket)
      [] -> {:noreply, socket}
    end
  end

  def handle_event("sheet_filter", %{"value" => q}, socket) when is_binary(q) do
    {:noreply, socket |> assign(filter: q) |> load_sheet()}
  end

  # a tap on a row of a list
  def handle_event("pick", %{"id" => id}, socket) when is_binary(id) do
    case socket.assigns.sheet do
      "groups" -> call(socket, "phone-group!", [id])
      s when s in ["chats", "buffers"] -> call(socket, "phone-show!", [id])
      _ -> :ok
    end

    {:noreply, socket |> close_sheet() |> drain() |> refresh()}
  end

  # a key from a prompt's sheet: its RET, its cancel, a menu's own key
  def handle_event("key", %{"k" => spec}, socket) when is_binary(spec) do
    Input.dispatch(socket.assigns.frame, spec)
    {:noreply, socket |> drain() |> refresh()}
  end

  # the prompt's field: what was typed, as keys in order
  def handle_event("keys", %{"ks" => specs}, socket) when is_list(specs) do
    Enum.each(specs, fn k -> if is_binary(k), do: Input.dispatch(socket.assigns.frame, k) end)
    {:noreply, socket |> drain() |> refresh()}
  end

  # a tap on a prompt's row: the selection moves there and RET takes it
  def handle_event("cand", %{"i" => i}, socket) do
    with mb when is_map(mb) <- socket.assigns.state.minibuffer,
         {i, ""} <- Integer.parse(to_string(i)) do
      sel = Enum.find_index(mb.candidates, &Map.get(&1, :selected)) || 0
      key = if i > sel, do: "C-n", else: "C-p"
      for _ <- 1..abs(i - sel)//1, do: Input.dispatch(socket.assigns.frame, key)
      Input.dispatch(socket.assigns.frame, "RET")
    end

    {:noreply, socket |> drain() |> refresh()}
  end

  # the rows the one window has room for
  def handle_event("viewport", %{"rows" => rows}, socket) when is_integer(rows) do
    Editor.set_total_rows(rows, socket.assigns.frame)
    {:noreply, socket |> drain() |> refresh()}
  end

  # the window's own events (block clicks, links, the chat's place), as
  # the desktop handles them
  def handle_event(event, params, socket) when event in @window_events do
    case LiveShared.window_event(event, params, socket.assigns.frame) do
      :refresh -> {:noreply, socket |> drain() |> refresh()}
      :quiet -> {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:frame_change, _}, socket), do: {:noreply, socket |> drain() |> refresh()}
  def handle_info({:editor_change, _}, socket), do: {:noreply, socket |> drain() |> refresh()}
  def handle_info({:buffer_display, _}, socket), do: {:noreply, socket |> drain() |> refresh()}
  def handle_info({:buffer_change, _, _}, socket), do: {:noreply, socket |> drain() |> refresh()}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp drain(socket), do: LiveShared.drain(socket)

  defp call(socket, name, args) do
    Input.run(socket.assigns.frame, fn -> Session.call_named(name, args) end)
  end

  defp shown(socket), do: socket.assigns.leaf && socket.assigns.leaf.buffer

  defp close_sheet(socket), do: assign(socket, sheet: nil, sheet_rows: [], filter: "")

  defp refresh(socket) do
    fid = socket.assigns.frame
    {state, effects} = LiveShared.frame_state(fid)
    caret_owner = if state.minibuffer, do: nil, else: state.active
    raw_leaf = LiveShared.find_leaf(state.tree, state.active) || LiveShared.first_leaf(state.tree)

    {leaf, cache} =
      if raw_leaf,
        do: EditorLive.decorate_tree(raw_leaf, socket.assigns.line_cache, state.faces, caret_owner),
        else: {nil, %{}}

    leaf_id = leaf && leaf.id

    # one window: only its cache entries live on
    cache =
      Map.filter(cache, fn
        {{_kind, id}, _} -> id == leaf_id
        {id, _} -> id == leaf_id
      end)

    subscribed =
      if connected?(socket) do
        visible = if leaf, do: MapSet.new([leaf.buffer]), else: MapSet.new()
        LiveShared.resubscribe(socket.assigns.subscribed, visible)
      else
        socket.assigns.subscribed
      end

    socket =
      socket
      |> assign(state: state, leaf: leaf, line_cache: cache, subscribed: subscribed)
      |> header(state, leaf)

    case fid && effects.navigation do
      url when is_binary(url) -> push_event(socket, "navigate", %{url: url})
      _ -> socket
    end
  end

  # the header's group and whether the buffer is a chat: one call when the
  # buffer or the group changes, none per keystroke
  defp header(socket, state, leaf) do
    key = {leaf && leaf.buffer, state.frame_group}

    if key == socket.assigns.view_key do
      socket
    else
      case call(socket, "phone-view", [(leaf && leaf.buffer) || false]) do
        {:ok, [group, chat]} -> assign(socket, group: str(group), chat: chat == true, view_key: key)
        _ -> assign(socket, group: "", chat: false, view_key: key)
      end
    end
  rescue
    _ -> assign(socket, group: "", chat: false)
  end

  # a list's rows, from Scheme, as ((TITLE ROWS) ...); a row is
  # %{id, label, sub, current}
  defp load_sheet(%{assigns: %{sheet: nil}} = socket), do: socket

  defp load_sheet(socket) do
    assign(socket, sheet_rows: fetch_sheet(socket, socket.assigns.sheet, socket.assigns.filter))
  rescue
    _ -> assign(socket, sheet_rows: [])
  end

  defp fetch_sheet(socket, "chats", q),
    do: [%{title: "", rows: rows(call(socket, "phone-chats", [q, shown(socket) || false]))}]

  defp fetch_sheet(socket, "groups", q),
    do: [%{title: "", rows: rows(call(socket, "phone-groups", [q]))}]

  defp fetch_sheet(socket, "buffers", q) do
    for [title, rs] <- ok_list(call(socket, "phone-buffers", [q, shown(socket) || false])) do
      %{title: str(title), rows: rows({:ok, rs})}
    end
  end

  defp rows(answer) do
    for [id, label, sub, cur] <- ok_list(answer) do
      %{id: str(id), label: str(label), sub: str(sub), current: cur == true}
    end
  end

  defp ok_list({:ok, x}) when is_list(x), do: x
  defp ok_list(_), do: []

  defp str(x) when is_binary(x), do: x
  defp str({:sym, s}), do: to_string(s)
  defp str(x) when x in [false, nil], do: ""
  defp str(x), do: to_string(x)

  # ── render ─────────────────────────────────────────────────────────

  def composml(%{state: nil} = assigns) do
    ~M"""
    <c-frame id="hh" class="hh splash" phx-hook="Handheld" data-boot={@boot_id}>
      <c-status class="hh-splash" state="connecting">compos · connecting</c-status>
    </c-frame>
    """
  end

  def composml(assigns) do
    ~M"""
    <c-frame id="hh" class="hh" phx-hook="Handheld" data-boot={@boot_id} data-assets={assets(@boot_id)} data-frame={@frame}>
      <style :if={@state.faces != %{}}><%= Phoenix.HTML.raw(Compos.Ui.FaceCSS.css(@state.faces)) %></style>
      <style :if={@state.styles != %{}}><%= Phoenix.HTML.raw(Enum.join(Map.values(@state.styles), "\n")) %></style>

      <c-modeline class="hh-head">
        <c-field :if={@group != ""} class="hh-head-group" name="group">{@group}</c-field>
        <c-buffer-name class="hh-head-name">{name(@leaf)}</c-buffer-name>
      </c-modeline>

      <c-window class="hh-body" win={@leaf && @leaf.id}>
        <.content leaf={@leaf} />
      </c-window>

      <c-prompt :if={@chat} class="hh-composer">
        <input id="composer" class="hh-input" type="text" autocomplete="off" autocapitalize="sentences" spellcheck="true" enterkeyhint="send" placeholder="Message" />
        <c-action id="composer-send" class="hh-send">Send</c-action>
      </c-prompt>

      <c-echo :if={echo(@state) != ""} class="hh-echo">{echo(@state)}</c-echo>

      <c-tabs class="hh-nav">
        <c-tab :for={{to, glyph, label} <- nav_items()} class={"hh-nav-btn #{if on?(to, @sheet, @chat), do: "on"}"} selected={to_string(on?(to, @sheet, @chat))} data-nav={to} phx-click="nav" phx-value-to={to}>
          <svg class="hh-nav-icon" viewBox="0 0 24 24" aria-hidden="true"><path d={glyph} /></svg>
          <c-label class="hh-nav-label">{label}</c-label>
        </c-tab>
      </c-tabs>

      <.pick :if={@sheet} sheet={@sheet} sections={@sheet_rows} filter={@filter} />
      <.prompt :if={@state.minibuffer} mb={@state.minibuffer} />
      <.menu :if={!@state.minibuffer && @state.transient && @state.transient[:groups]} t={@state.transient} />
    </c-frame>
    """
  end

  defp nav_items,
    do: [
      # each icon one stroked path on a 24 grid: a speech bubble, a page
      # with lines, four squares
      {"chats", "M4 5h16v11H9l-5 4z", "Chats"},
      {"buffers", "M6 3h9l3 3v15H6zM9 10h6M9 14h6M9 18h4", "Buffers"},
      {"groups", "M4 4h7v7H4zM13 4h7v7h-7zM4 13h7v7H4zM13 13h7v7h-7z", "Groups"}
    ]

  defp on?("chats", nil, true), do: true
  defp on?(to, sheet, _chat), do: to == sheet

  defp content(%{leaf: nil} = assigns) do
    ~M"""
    <c-buffer class="hh-content"></c-buffer>
    """
  end

  # a block tree (a chat, a list, a page) draws with the editor's own
  # block renderer; the composer is the input, so the tree's own input hides
  defp content(%{leaf: %{render_mode: "blocks"}} = assigns) do
    ~M"""
    <c-buffer class={"hh-content hh-blocks #{root_class(@leaf)}"} buffer={@leaf.buffer}>
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
    <c-buffer class="hh-content" buffer={@leaf.buffer}>
      <iframe :if={Map.has_key?(@leaf, :preview)} class="hh-preview" id={"prev-#{@leaf.id}"} srcdoc={@leaf.preview} sandbox="allow-same-origin" title={@leaf.buffer}></iframe>
    </c-buffer>
    """
  end

  defp content(%{leaf: %{render_mode: "file"}} = assigns) do
    ~M"""
    <c-buffer class="hh-content" buffer={@leaf.buffer}>
      <iframe :if={Map.has_key?(@leaf, :file_url)} class="hh-preview" src={@leaf.file_url} sandbox="" title={@leaf.buffer}></iframe>
    </c-buffer>
    """
  end

  # text: read only
  defp content(assigns) do
    ~M"""
    <c-buffer class="hh-content hh-lines" id={"lines-#{@leaf.id}"} buffer={@leaf.buffer}>
      <c-line :for={ln <- Map.get(@leaf, :lines, [])} class="hh-line" number={ln.num}>
        <c-text class="hh-line-text"><c-text :for={{txt, cls} <- ln.segs} class={cls}>{txt}</c-text><br :if={ln.segs == []} /></c-text>
      </c-line>
      <c-empty :if={Map.get(@leaf, :lines, []) == []} class="hh-empty">{@leaf.buffer}</c-empty>
    </c-buffer>
    """
  end

  # a list to tap: chats, buffers or groups; the field narrows it and RET
  # there takes the first row
  defp pick(assigns) do
    assigns = assign(assigns, title: @titles[assigns.sheet], hint: @hints[assigns.sheet])

    ~M"""
    <c-group class="hh-layer">
      <c-group class="hh-scrim" phx-click="sheet_close"></c-group>
      <c-list class="hh-sheet" role="dialog" aria-modal="true" data-sheet={@sheet}>
        <c-header class="hh-sheet-head">
          <c-headline class="hh-sheet-title">{@title}</c-headline>
          <c-action class="hh-sheet-quit" phx-click="sheet_close">Close</c-action>
        </c-header>
        <c-field class="hh-filter" name="filter">
          <input id={"filter-#{@sheet}"} class="hh-input" type="search" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" enterkeyhint="go" placeholder={@hint} value={@filter} phx-keyup="sheet_filter" phx-debounce="150" />
        </c-field>
        <c-group class="hh-rows">
          <c-item :if={@sheet == "chats" and @filter == ""} class="hh-row hh-row-new" data-nav="new" phx-click="nav" phx-value-to="new">
            <c-label class="hh-row-label">+ New chat</c-label>
          </c-item>
          <%= for s <- @sections do %>
            <c-headline :if={s.title != "" and s.rows != []} class="hh-section">{s.title}</c-headline>
            <c-item :for={r <- s.rows} class={"hh-row #{if r.current, do: "on"}"} current={to_string(r.current)} phx-click="pick" phx-value-id={r.id}>
              <c-label class="hh-row-label">{r.label}</c-label>
              <c-hint :if={r.sub != ""} class="hh-row-sub">{r.sub}</c-hint>
            </c-item>
          <% end %>
          <c-empty :if={Enum.all?(@sections, &(&1.rows == []))} class="hh-empty">{if @filter == "", do: "Nothing here", else: "Nothing matches"}</c-empty>
        </c-group>
      </c-list>
    </c-group>
    """
  end

  # a prompt of the editor: its question, a field, and its rows to tap
  defp prompt(assigns) do
    ~M"""
    <c-group class="hh-layer hh-prompt-layer">
      <c-group class="hh-scrim" phx-click="key" phx-value-k="C-g"></c-group>
      <c-minibuffer class="hh-sheet" role="dialog" aria-modal="true">
        <c-header class="hh-sheet-head">
          <c-headline class="hh-sheet-title">{String.trim_trailing(@mb.prompt, ": ")}</c-headline>
          <c-action class="hh-sheet-quit" phx-click="key" phx-value-k="C-g">Cancel</c-action>
        </c-header>
        <c-field class="hh-filter" name="answer">
          <input id="mb-input" class="hh-input" type="text" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" enterkeyhint="done" value={Map.get(@mb, :input, "")} />
          <c-action class="hh-send armed" phx-click="key" phx-value-k="RET">OK</c-action>
        </c-field>
        <c-completions class="hh-rows">
          <%= for {c, i} <- Enum.with_index(@mb.candidates) do %>
            <c-headline :if={Map.get(c, :kind) == "separator"} class="hh-section">{c.label}</c-headline>
            <c-completion :if={Map.get(c, :kind) != "separator"} class={"hh-row #{if c.selected, do: "on"}"} selected={to_string(c.selected == true)} phx-click="cand" phx-value-i={i}>
              <c-label class="hh-row-label">{c.label}</c-label>
              <c-hint :if={Map.get(c, :hint) not in [nil, ""]} class="hh-row-sub">{c.hint}</c-hint>
            </c-completion>
          <% end %>
        </c-completions>
      </c-minibuffer>
    </c-group>
    """
  end

  # a menu of the editor: a row runs its own key
  defp menu(assigns) do
    ~M"""
    <c-group class="hh-layer hh-prompt-layer">
      <c-group class="hh-scrim" phx-click="key" phx-value-k="C-g"></c-group>
      <c-list class="hh-sheet" kind="menu" role="dialog" aria-modal="true">
        <c-header class="hh-sheet-head">
          <c-headline class="hh-sheet-title">{@t.title}</c-headline>
          <c-action class="hh-sheet-quit" phx-click="key" phx-value-k="C-g">Cancel</c-action>
        </c-header>
        <c-group class="hh-rows">
          <%= for g <- @t.groups do %>
            <c-headline :if={g.title not in [nil, ""]} class="hh-section">{g.title}</c-headline>
            <c-item :for={item <- g.items} class="hh-row" phx-click="key" phx-value-k={item.key}>
              <c-label class="hh-row-label">{item.description}</c-label>
              <c-hint :if={item.value not in [nil, ""]} class="hh-row-sub">{item.value}</c-hint>
            </c-item>
          <% end %>
        </c-group>
      </c-list>
    </c-group>
    """
  end

  # the page's stylesheet and script as this boot serves them: a page
  # that loaded older ones reloads (mobile.js bootCheck)
  defp assets(boot) do
    Compos.Ui.MobileLayouts.file_version(boot, "mobile.css") <> "/" <>
      Compos.Ui.MobileLayouts.file_version(boot, "mobile.js")
  end

  defp name(nil), do: ""
  defp name(%{modeline_name: n}) when is_binary(n) and n != "", do: n
  defp name(leaf), do: leaf.buffer

  defp echo(%{echo: e}) when is_binary(e), do: e
  defp echo(_), do: ""

  defp root_class(leaf) do
    case Map.get(leaf, :blk_root) do
      %{class: c} when is_binary(c) -> c
      _ -> ""
    end
  end

  @impl true
  def render(assigns), do: Compos.Ui.Representation.live(__MODULE__, assigns)
end
