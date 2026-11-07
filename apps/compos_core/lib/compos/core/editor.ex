defmodule Compos.Core.Editor do
  @moduledoc """
  Editor state holder: frames (each a tiling window tree + minibuffer + echo
  + viewport geometry), keymap table, kill ring. **Policy-free by design** —
  every command and default keybinding is Scheme (`priv/editor.scm`); this
  process only stores state and applies small mutations. Key routing lives in
  `Compos.Core.KeyDispatch`, which runs outside this server so Scheme
  primitives can call back in without deadlock.

  A frame is one client's view: its own window tree and selection, sharing
  buffers, faces and the kill ring with every other frame (keymaps are
  Scheme data, editor.scm). Frame
  ids are short stable strings; window ids are integers, globally unique
  across all frames, so a bare window id always names one window.

  Windows: a frame is one row of leaves, `%{type: :leaf, id, buffer, top,
  manual, share, dock}`, left to right. `share` is a leaf's part of the
  row's width; a `dock` leaf spans the frame under the row, and its share
  is its part of the height.
  TODO: per-window points, window resizing.

  Calls that take a frame accept nil, resolved server-side to the
  last-active frame (the fallback for async callers with no frame context).
  """

  use GenServer

  alias Compos.Core.{Buffer, Candidates, Events, Frame, Recent, Session}

  # Emacs window-configuration-change-hook, by its Scheme name
  @config_hook "window-configuration-changed!"

  # every frame has its own minibuffer backing buffer, " *minibuf-<fid>*"
  # (Emacs-style: prompt input IS a buffer, so point motion, kill/yank, undo
  # and local keymaps all just work; per-frame so two prompts can be open at
  # once). Space-prefixed = hidden from buffer lists, like Emacs. The bare
  # " *minibuf*" is the shared local-KEYMAP namespace: binds and lookups on
  # any frame's minibuf buffer normalize to it, so editor.scm binds the
  # prompt keys once for all frames.

  @doc "The calling frame's minibuffer buffer name."
  def minibuf_name(fid \\ nil), do: GenServer.call(__MODULE__, {:minibuf_name, fid(fid)})

  @scratch "*scratch*"
  @main_frame "f-main"
  @frame_fields [:echo, :pending, :prefix_arg, :key_capture, :last_command, :this_command, :last_keys]
  # what a window is worth in columns before the client has measured one
  @default_cols 100

  # the keymap every read-only buffer inherits. No buffer holds this name:
  # a space prefix keeps it out of the buffer lists, as " *minibuf*" is.

  # A preview draws no lines, so a scroll in lines becomes a scroll in
  # pixels. This is the client's prose line-height, and it only has to be
  # close: the reader judges a page scroll by eye, not by the row count.
  @preview_line_px 22

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # readers
  def snapshot(fid \\ nil), do: GenServer.call(__MODULE__, {:snapshot, fid(fid)})

  def current_buffer(fid \\ nil) do
    Compos.Core.Frame.buffer_context() ||
      GenServer.call(__MODULE__, {:current_buffer, fid(fid)})
  end

  def render_state(fid \\ nil), do: GenServer.call(__MODULE__, {:render_state, fid(fid)})

  @doc """
  Read-only view for desktop save (S15): the frame's tree with each
  leaf's top and effective per-window point, plus faces — none of
  render_state's write-back.
  """
  def desktop_view(fid \\ nil), do: GenServer.call(__MODULE__, {:desktop_view, fid(fid)})

  # frames
  @doc """
  Attach a client: nil -> fresh frame; known id -> reattach; unknown id -> create with it.

  The caller is the frame's client and is monitored. A frame whose client
  is gone for `:frame_grace_ms` (default 30 minutes) is handed to Scheme's
  `frame-client-lost!`, which deletes it: a closed browser tab is a dead
  display, and Emacs deletes the frame of a dead display. `client: nil`
  attaches with no client (a desktop restore); such a frame expires on the
  same clock unless a client claims it first.
  """
  def attach_frame(id, opts \\ []),
    do: GenServer.call(__MODULE__, {:attach_frame, id, Keyword.get(opts, :client, :caller)})

  @doc "Returns {:ok, closed_minibuffer | nil}; minibuffer.scm runs the prompt's cancel handler."
  def delete_frame(id), do: GenServer.call(__MODULE__, {:delete_frame, id})

  def frame_list, do: GenServer.call(__MODULE__, :frame_list)
  def last_active_frame, do: GenServer.call(__MODULE__, :last_active_frame)
  def select_frame(id), do: GenServer.call(__MODULE__, {:select_frame, id})
  def frame_of_window(win_id), do: GenServer.call(__MODULE__, {:frame_of_window, win_id})

  @doc """
  A window's point (Emacs window-point): the buffer's own point for the
  window whose point is swapped in, the stored one for every other window.
  """
  def window_point(win_id), do: GenServer.call(__MODULE__, {:window_point, win_id})

  @doc """
  Place a window's point (Emacs set-window-point). A redraw that rewrote a
  buffer's text puts every window showing it back on its row through this;
  a buffer point alone reaches only the selected window.
  """
  def set_window_point(win_id, pos),
    do: GenServer.call(__MODULE__, {:set_window_point, win_id, pos})

  @doc "Bump a frame in the MRU without broadcasting — the top of every input dispatch."
  def touch_frame(id), do: GenServer.call(__MODULE__, {:touch_frame, id})

  @doc "The open prompt snapshot of every frame."
  def all_minibuffers, do: GenServer.call(__MODULE__, :all_minibuffers)

  @doc "All windows across all frames, frame-MRU order: [{win_id, buffer, frame_id}]."
  def list_windows_all, do: GenServer.call(__MODULE__, :list_windows_all)

  @doc """
  Set any window's buffer, any frame, without selecting it. BUMP? false
  leaves the buffer list as it was (a look); Scheme keeps the window's
  history and quit record (window.scm).
  """
  def window_set_buffer(win_id, buffer, bump? \\ true) do
    with {:ok, _} <- wake(buffer),
         do: GenServer.call(__MODULE__, {:window_set_buffer, win_id, buffer, bump?})
  end

  @doc "How many buffers WIN holds, for its header line; Scheme counts them."
  def set_window_stack(win_id, n),
    do: GenServer.call(__MODULE__, {:set_window_stack, win_id, n})

  @doc """
  The frame's overriding map, or nil to clear it. LOCK? makes an unbound
  key undefined instead of falling through (Transient). UNTIL_COMMAND?
  drops the map when the next ordinary command finishes (the prefix
  argument's map).
  """
  def set_overriding_map(name, lock? \\ false, until_command? \\ false, fid \\ nil),
    do: GenServer.call(__MODULE__, {:set_overriding_map, name, lock?, until_command?, fid(fid)})

  def overriding_map(fid \\ nil), do: GenServer.call(__MODULE__, {:overriding_map, fid(fid)})
  # --- keys, asked of Scheme -------------------------------------------------
  # Keymaps are Scheme data (editor.scm, the keymaps section). These four
  # are the readers a test or an RPC client had in Elixir; each asks
  # Scheme and never touches Editor state.

  @doc "What SEQ (a key list) runs in the frame's buffer: {:command, name}, :prefix or :none."
  def lookup_key(seq, fid \\ nil) do
    case Compos.Core.Session.call_named("key-binding", [seq], fid, 5_000, :ui) do
      {:ok, name} when is_binary(name) -> {:command, name}
      {:ok, {:sym, "prefix"}} -> :prefix
      _ -> :none
    end
  end

  @doc "Every binding that answers in BUFFER besides the global ones, as {keys, command}."
  def local_keys(buffer) do
    case Compos.Core.Session.call_named("local-keys", [buffer], nil, 5_000, :ui) do
      {:ok, rows} when is_list(rows) -> Enum.map(rows, fn [k, c] -> {k, c} end)
      _ -> []
    end
  end

  @doc "The parent of BUFFER's own keymap (the mode's map), or nil."
  def buffer_local_map(buffer) do
    case Compos.Core.Session.call_named("buffer-local-map", [buffer], nil, 5_000, :ui) do
      {:ok, name} when is_binary(name) -> name
      _ -> nil
    end
  end

  @doc "Bind SEQ (a key list) to COMMAND in BUFFER's own keymap."
  def local_bind_key(buffer, seq, command) do
    {:ok, _} = Compos.Core.Session.call_named("local-set-key*", [buffer, seq, command], nil, 5_000, :ui)
    :ok
  end

  @doc "The frame's overriding map with its lock, %{map:, lock:, until_command:}, or nil."
  def overriding_map_state(fid \\ nil),
    do: GenServer.call(__MODULE__, {:overriding_map_state, fid(fid)})

  @doc """
  What a key lookup needs from the frame, in one call: the buffer the key
  acts on (the minibuffer while a prompt is up, else the selected
  window's), and the overriding map with its lock, or nil.
  """
  def key_context(fid \\ nil), do: GenServer.call(__MODULE__, {:key_context, fid(fid)})

  @doc """
  One fact of the calling frame the key loop keeps: :echo, :pending,
  :prefix_arg, :key_capture, :last_command, :this_command or :last_keys.
  nil when unset. Scheme owns what each means (editor.scm).
  """
  def frame_get(field, fid \\ nil) when field in @frame_fields,
    do: GenServer.call(__MODULE__, {:frame_get, field, fid(fid)})

  @doc "Set one `frame_get/2` fact; the echo and the pending prefix repaint."
  def frame_put(field, value, fid \\ nil) when field in @frame_fields,
    do: GenServer.call(__MODULE__, {:frame_put, field, value, fid(fid)})

  def set_pending(seq, fid \\ nil), do: frame_put(:pending, seq, fid)
  def set_echo(msg, fid \\ nil), do: frame_put(:echo, msg, fid)
  def set_prefix_arg(arg, fid \\ nil), do: frame_put(:prefix_arg, arg, fid)

  @doc "Record the command and clear its one-shot prefix unless KEEP_PREFIX is true."
  def finish_command(name, keep_prefix, fid \\ nil),
    do: GenServer.call(__MODULE__, {:finish_command, name, keep_prefix, fid(fid)})

  @doc "Set the calling frame's rendered Transient menu, or clear it with nil."
  def set_transient(menu, fid \\ nil),
    do: GenServer.call(__MODULE__, {:set_transient, menu, fid(fid)})

  @doc "Echo a message in every frame (async sources: agents, timers)."
  def set_echo_all(msg), do: GenServer.call(__MODULE__, {:set_echo_all, msg})

  @doc """
  Put TEXT on the OS clipboard of one frame's client.

  A browser page writes the clipboard only from its own process, so a
  command cannot write it directly. The command leaves the text here; the
  frame's client takes it on the next render and writes it. Nothing else
  reads this slot, and a frame with no client drops the text at the next
  write.
  """
  def put_clipboard(text, fid \\ nil),
    do: GenServer.call(__MODULE__, {:put_clipboard, text, fid(fid)})

  @doc "Take FRAME's pending clipboard text, or nil. The take clears it."
  def take_clipboard(fid), do: GenServer.call(__MODULE__, {:take_clipboard, fid(fid)})

  @doc "Ask one frame's browser client to navigate to URL."
  def navigate(url, fid \\ nil),
    do: GenServer.call(__MODULE__, {:navigate, url, fid(fid)})

  @doc "Take FRAME's pending navigation URL, or nil. The take clears it."
  def take_navigation(fid), do: GenServer.call(__MODULE__, {:take_navigation, fid(fid)})

  @doc """
  Ask one frame's client to slide its panes on the next render. DIR is
  "forward" (the new pane comes in from the right or the bottom) or
  "backward". The client animates the change that the same render
  applies, so the user sees which pane went out and which came in.
  """
  def slide(dir, fid \\ nil), do: GenServer.call(__MODULE__, {:slide, dir, fid(fid)})

  @doc "Take FRAME's pending slide direction, or nil. The take clears it."
  def take_slide(fid), do: GenServer.call(__MODULE__, {:take_slide, fid(fid)})

  @doc """
  Ask one frame's editable surface to move or extend its selection by the
  browser's own layout: ALTER is "move" or "extend", DIR "forward" or
  "backward", GRANULARITY "character" | "word" | "line" | "lineboundary" |
  "paragraph" | "documentboundary". The client answers with a `sel` event.
  """
  # COUNT is part of the request, not a repeat of it: a frame holds ONE
  # pending selection request, so N asks collapse to the last one and a
  # page moved a single row. The client applies the move COUNT times.
  def select_request(alter, dir, granularity, count \\ 1, fid \\ nil),
    do:
      GenServer.call(
        __MODULE__,
        {:select_request, {alter, dir, granularity, count}, fid(fid)}
      )

  @doc "Take FRAME's pending selection request, or nil. The take clears it."
  def take_select(fid), do: GenServer.call(__MODULE__, {:take_select, fid(fid)})

  # one global always-visible segment in the echo bar (agent attention etc.)
  def set_modeline_extra(s), do: GenServer.call(__MODULE__, {:set_modeline_extra, s})

  @doc """
  Set the frame chrome value KEY to VALUE. Scheme composes the chrome
  (the echo area's key hints, the mode-line format, the workspace bar's
  help); every frame's render carries the map and the view draws it.
  """
  def set_chrome(key, value), do: GenServer.call(__MODULE__, {:set_chrome, key, value})

  # minibuffer
  def minibuffer_set_input(input, fid \\ nil), do: prompt_op(:input, [input], fid)

  @doc """
  One operation OP with ARGS on the calling frame's prompt: :facts,
  :filtered, :selected, :sync, :move DELTA, :input TEXT, :candidates
  LIST, :set KEY VALUE (KEY :style, :rail or :tabs); or on its popup:
  :start, :query TEXT, :accept, :cmove DELTA. nil when none is open.
  """
  def prompt_op(op, args \\ [], fid \\ nil), do: GenServer.call(__MODULE__, {:prompt_op, op, args, fid(fid)})

  @doc "Open the frame's prompt snapshot: PROMPT, CANDIDATES and the VIEW map Scheme composes."
  def minibuffer_show(prompt, candidates, view, fid \\ nil),
    do: GenServer.call(__MODULE__, {:mb_show, prompt, candidates, view, fid(fid)})

  def minibuffer_close(fid \\ nil), do: GenServer.call(__MODULE__, {:mb_close, fid(fid)})

  @doc "While false, current_buffer ignores an active minibuffer (handler escape hatch)."
  def set_mb_redirect(bool, fid \\ nil),
    do: GenServer.call(__MODULE__, {:mb_redirect, bool, fid(fid)})

  @doc "Record the group context this frame stands in; nil clears it."
  def set_frame_group_label(label, fid \\ nil),
    do: GenServer.call(__MODULE__, {:set_group_label, label, fid(fid)})

  @doc "Record the group label and accent color for this frame."
  def set_frame_group_style(label, color, fid \\ nil),
    do: GenServer.call(__MODULE__, {:set_group_style, label, color, fid(fid)})

  @doc "Give frame FID its own face map FACES and a SKIN stylesheet; nil FACES gives it the global faces again."
  def set_own_faces(faces, skin, fid \\ nil),
    do: GenServer.call(__MODULE__, {:set_own_faces, faces, skin, fid(fid)})

  # commands that manage their own undo boundaries (Scheme registers them;
  # KeyDispatch skips its automatic break for these — "undo" is one from birth)
  def add_undo_exempt(name), do: GenServer.call(__MODULE__, {:add_undo_exempt, name})
  def undo_exempt?(name), do: GenServer.call(__MODULE__, {:undo_exempt?, name})

  # completion-at-point popup (anchored at a buffer position)
  def completion_show(start, tail, candidates, fid \\ nil),
    do: GenServer.call(__MODULE__, {:completion_show, start, tail, candidates, fid(fid)})

  def completion_dismiss(fid \\ nil), do: prompt_op(:dismiss, [], fid)

  # the face and style maps the page renders. Scheme owns the tables
  # (themes.scm): the merge, the clear, a theme and a frame's own theme.
  # These doors only set the maps, and a change that changes nothing
  # renders nothing. Faces carry colors; styles carry structure (grids,
  # cards, spacing).
  @doc "Put CHANGES, `[{name, attrs | nil}]` in order, into the global faces, or into frame FID's own faces when FID names a frame that has them; nil drops the face."
  def put_faces(changes, fid \\ nil), do: GenServer.call(__MODULE__, {:put_faces, changes, fid})
  @doc "The global faces the page renders: name -> attrs."
  def faces, do: GenServer.call(__MODULE__, :faces)
  @doc "The attrs face NAME renders with, or nil."
  def face(name), do: GenServer.call(__MODULE__, {:face, name})
  @doc "Put stylesheet NAME's CSS on the page."
  def put_style(name, css), do: GenServer.call(__MODULE__, {:put_style, name, css})
  @doc "The stylesheets the page renders: name -> CSS."
  def styles, do: GenServer.call(__MODULE__, :styles)
  @doc "The CSS stylesheet NAME renders, or nil."
  def style(name), do: GenServer.call(__MODULE__, {:style, name})

  # windows
  @doc "A window right of the selected one, on its buffer, with 1 - RATIO of the selected one's share. A frame is a row: DIR does not stack."
  def split(dir, ratio \\ 0.5, fid \\ nil) when dir in [:h, :v],
    do: GenServer.call(__MODULE__, {:split, ratio, fid(fid)})

  @doc """
  A dock under the frame's row, and its window id. It spans the frame and
  takes 1 - RATIO of the height, so it takes rows from the row rather than
  covering them. Deleting the window gives them back.
  """
  def dock(ratio \\ 0.5, fid \\ nil), do: GenServer.call(__MODULE__, {:dock, ratio, fid(fid)})

  def delete_window_by_id(id), do: GenServer.call(__MODULE__, {:delete_window_by_id, id})
  def list_windows(fid \\ nil), do: GenServer.call(__MODULE__, {:list_windows, fid(fid)})
  def window_rects(fid \\ nil), do: GenServer.call(__MODULE__, {:window_rects, fid(fid)})

  @doc "Selecting a window selects its frame (Emacs: windows live on frames)."
  def set_active(id), do: GenServer.call(__MODULE__, {:set_active, id})

  def active_window(fid \\ nil), do: GenServer.call(__MODULE__, {:active_window, fid(fid)})

  @doc "A window id no window holds and none will be given again; it makes no window."
  def new_window_id, do: GenServer.call(__MODULE__, :new_window_id)

  @doc """
  Lay the frame out as one line of windows along DIR (:h or :v). An item
  is a window id on screen, or [ID, BUFFER]: that window, made on BUFFER
  when no window holds ID. The first pane takes RATIO; each later split
  divides the rest evenly. A window not in ITEMS is deleted: the panes
  model keeps what it needs of a window off the screen.
  """
  def arrange(spec, fid \\ nil) do
    fid = fid(fid)

    # the Editor names the buffers its new windows need; they wake here
    # and the line is asked for again, once
    case GenServer.call(__MODULE__, {:arrange, spec, fid, true}) do
      {:wake, buffers} ->
        Enum.each(buffers, &wake/1)
        GenServer.call(__MODULE__, {:arrange, spec, fid, false})

      reply ->
        reply
    end
  end

  def other_window(fid \\ nil), do: GenServer.call(__MODULE__, {:other_window, fid(fid)})

  @doc "A buffer is dying: swap every window showing it (any frame) onto a live one."
  def release_buffer(buffer), do: GenServer.call(__MODULE__, {:release_buffer, buffer})

  @doc """
  What is on screen: `%{visible: buffers-in-any-window, current: each
  frame's active-window buffer}`. The Reactor gates background work on it.
  """
  def visible_buffers, do: GenServer.call(__MODULE__, :visible_buffers)

  @doc "Carry windows and the recent order across a buffer rename; Scheme carries the keymaps."
  def rename_buffer(old, new), do: GenServer.call(__MODULE__, {:rename_buffer, old, new})

  def set_window_buffer(buffer, fid \\ nil) do
    with {:ok, _} <- wake(buffer),
         do: GenServer.call(__MODULE__, {:set_window_buffer, buffer, fid(fid)})
  end

  @doc "Replace a frame's window tree from a `Compos.Core.WindowSpec` spec."
  def restore_tree(spec, active_buffer, fid \\ nil) do
    spec |> Compos.Core.WindowSpec.buffers() |> Enum.uniq() |> Enum.each(&wake/1)
    GenServer.call(__MODULE__, {:restore_tree, spec, active_buffer, fid(fid), true})
  end

  # A dormant buffer named to a window wakes HERE, in the caller, through
  # the one door (Compos.Core.ensure_buffer): never inside the Editor,
  # whose handlers only ask whether a buffer is live (live/1). A wake
  # reads the store and starts a process; a store call from a handler
  # stalls the Editor and takes the UI down. The runtime rebuild
  # of a woken buffer is queued on the buffer's own lane, as it was when
  # the Editor woke it, so nothing waits for it.
  defp wake(buffer) do
    if Buffer.exists?(buffer) do
      {:ok, buffer}
    else
      dormant? = Compos.Core.BufferStore.known?(buffer)

      case Compos.Core.ensure_buffer(buffer, restore: false) do
        {:ok, _} = ok ->
          if dormant?, do: Compos.Core.restore_runtime_later(buffer)
          ok

        other ->
          other
      end
    end
  end

  # Only a live buffer enters a window. A registry read, no message.
  defp live(buffer),
    do: if(Buffer.exists?(buffer), do: {:ok, buffer}, else: {:error, :not_live})

  # viewport: each client reports how many text rows fit its frame; wheel
  # scrolls server-side; any key re-enables point auto-follow
  def set_total_rows(rows, fid \\ nil),
    do: GenServer.call(__MODULE__, {:set_total_rows, rows, fid(fid)})

  @doc "Per-window measured rows (%{win_id => rows}) — line height varies per buffer."
  def set_window_rows(map, fid \\ nil),
    do: GenServer.call(__MODULE__, {:set_window_rows, map, fid(fid)})

  @doc "Per-window measured columns (%{win_id => cols}); true when the measurement changed."
  def set_window_cols(map, fid \\ nil),
    do: GenServer.call(__MODULE__, {:set_window_cols, map, fid(fid)})

  @doc """
  The wrap maps the client measured after its last paint, per window:
  `%{win_id => {version, row_starts}}`. `row_starts` are the byte offsets
  where each visual row begins; `version` is the buffer version the page
  showed. The client is the only party that knows where proportional
  text wraps; what a key means on those rows is Scheme's decision.
  """
  def set_wrap_maps(map, fid \\ nil),
    do: GenServer.call(__MODULE__, {:set_wrap_maps, map, fid(fid)})

  @doc "One window's wrap map, from Scheme: a test or a headless driver measuring for itself."
  def set_wrap_map(win, version, rows, fid \\ nil),
    do: GenServer.call(__MODULE__, {:set_wrap_map, win, version, rows, fid(fid)})

  @doc "The wrap map of WIN (the active window when nil): {version, row_starts} or nil."
  def wrap_map(win \\ nil, fid \\ nil),
    do: GenServer.call(__MODULE__, {:wrap_map, win, fid(fid)})

  def scroll_active(delta_lines, fid \\ nil),
    do: GenServer.call(__MODULE__, {:scroll_active, delta_lines, fid(fid)})

  def scroll_window(id, delta_lines),
    do: GenServer.call(__MODULE__, {:scroll_window, id, delta_lines})

  @doc "Mirror a client-scrolled window's pixel offset into its leaf (S1)."
  def set_client_top(id, px, fid \\ nil),
    do: GenServer.call(__MODULE__, {:set_client_top, id, px, fid(fid)})

  @doc """
  Every window that shows BUFFER, in every frame, drops its scroll pin and
  follows point again: `manual` off, `top` and `ctop` at 0. A page that
  replaced its text and put point at the start calls this, so a window
  the reader had scrolled down the old page opens the new one at the top.
  """
  def windows_follow_point(buffer),
    do: GenServer.call(__MODULE__, {:windows_follow_point, buffer})

  # mouse: place point at (logical line, char col) in a window's buffer;
  # or set a region from a drag's anchor/focus positions
  def mouse_goto(id, line, col), do: GenServer.call(__MODULE__, {:mouse_goto, id, line, col})

  def mouse_region(id, al, ac, fl, fc),
    do: GenServer.call(__MODULE__, {:mouse_region, id, al, ac, fl, fc})

  # Cmd-C with no native selection: the active region (pushed onto the kill
  # ring, Emacs kill-ring-save) or, without one, the kill-ring top
  def user_acted(fid \\ nil), do: GenServer.call(__MODULE__, {:user_acted, fid(fid)})
  @doc "Text rows of WIN, or of the active window when WIN is nil."
  def window_rows(win \\ nil, fid \\ nil),
    do: GenServer.call(__MODULE__, {:window_rows, win, fid(fid)})

  @doc "Columns of WIN, or of the active window when WIN is nil."
  def window_cols(win \\ nil, fid \\ nil),
    do: GenServer.call(__MODULE__, {:window_cols, win, fid(fid)})

  @doc "Estimated usable columns across the whole frame."
  def frame_cols(fid \\ nil), do: GenServer.call(__MODULE__, {:frame_cols, fid(fid)})

  @doc "Columns of a window showing BUF, in any frame — else the active window's."
  def buffer_cols(buf, fid \\ nil),
    do: GenServer.call(__MODULE__, {:buffer_cols, buf, fid(fid)})

  def recenter(fid \\ nil), do: GenServer.call(__MODULE__, {:recenter, fid(fid)})

  # explicit nil beats an unset pdict; the server resolves nil -> last active
  defp fid(nil), do: Frame.current()
  defp fid(fid), do: fid

  # --- server ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    # *scratch* is named, not made: editor.scm makes it at boot
    frame = %{
      id: @main_frame,
      tree: [%{type: :leaf, id: 1, buffer: @scratch, top: 0, manual: false}],
      active: 1,
      pending: [],
      prefix_arg: nil,
      key_capture: nil,
      # Emacs this-command / last-command / last-keys, per frame: two clients
      # are two users, and one's yank-pop must not read the other's yank
      this_command: "",
      last_command: "",
      last_keys: [],
      # Emacs overriding-terminal-local-map: %{map:, lock:, until_command:}
      overriding: nil,
      transient: nil,
      minibuffer: nil,
      mb_redirect: true,
      echo: "",
      completion: nil,
      total_rows: 40,
      win_rows: %{},
      # the group this frame stands in, by NAME. Naming and membership are
      # Scheme policy; rendering uses this only to compact a buffer's groups.
      group_label: nil,
      group_color: nil,
      win_cols: %{},
      wrap_maps: %{}
    }

    {:ok,
     %{
       frames: %{@main_frame => frame},
       frame_mru: [@main_frame],
       # frame id => {client pid, monitor ref}: the one LiveView showing it
       frame_clients: %{},
       # frame id => timer ref: the grace running since its client left
       frame_timers: %{},
       # the one window whose point is swapped into its buffer (the selected
       # window of the last-active frame): {frame_id, win_id, buffer}
       swapped: nil,
       next_win: 2,
       modeline_extra: "",
       chrome: %{},
       faces: %{},
       styles: %{},
       undo_exempt: MapSet.new(["undo"]),
       # frame id => text a command wants on that client's OS clipboard
       clips: %{},
       # frame id => URL for same-tab navigation on the next client render
       navigations: %{},
       # frame id => "forward" | "backward": the client slides its panes
       slides: %{},
       # frame id => a Selection.modify request for the editable surface
       selects: %{}
     }}
  end

  # --- frame lifecycle --------------------------------------------------------

  @impl true
  def handle_call({:attach_frame, id, client}, {caller, _}, state) do
    client = if client == :caller, do: caller, else: client

    case state.frames[id] do
      %{} ->
        state = state |> bump_frame(id) |> resync_swap() |> frame_client(id, client)
        {:reply, {:ok, id}, state}

      nil ->
        id = if valid_frame_id?(id), do: id, else: gen_frame_id()
        buffer = Recent.find_buffer(&Buffer.exists?/1) || @scratch

        frame = %{
          id: id,
          tree: [%{type: :leaf, id: state.next_win, buffer: buffer, top: 0, manual: false}],
          active: state.next_win,
          pending: [],
          prefix_arg: nil,
          key_capture: nil,
          # Emacs this-command / last-command / last-keys, per frame: two clients
          # are two users, and one's yank-pop must not read the other's yank
          this_command: "",
          last_command: "",
          last_keys: [],
          # Emacs overriding-terminal-local-map: %{map:, lock:, until_command:}
          overriding: nil,
          transient: nil,
          minibuffer: nil,
          mb_redirect: true,
          echo: "",
          completion: nil,
          total_rows: 40,
          win_rows: %{},
          group_label: nil,
          group_color: nil,
          win_cols: %{},
          wrap_maps: %{}
        }

        state = %{state | frames: Map.put(state.frames, id, frame), next_win: state.next_win + 1}
        state = state |> bump_frame(id) |> resync_swap() |> frame_client(id, client)
        changed({:ok, id}, state, id)
    end
  end

  def handle_call({:delete_frame, id}, _from, state) do
    cond do
      state.frames[id] == nil ->
        {:reply, {:error, :no_frame}, state}

      map_size(state.frames) == 1 ->
        {:reply, {:error, :last_frame}, state}

      true ->
        # hand the closed prompt back; minibuffer.scm has already run its
        # cancel handler (this server must never call into Session)
        f = state.frames[id]

        # async: kill_buffer heals windows through Editor.release_buffer,
        # which must not be called from inside this server (self-call)
        mb_buf = minibuf_of(f)

        Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
          Compos.Core.kill_buffer(mb_buf)
        end)

        Enum.each(leaf_ids_buffers(f.tree), fn {win, buf} ->
          if Buffer.exists?(buf), do: wp_safely(fn -> Buffer.drop_win_point(buf, win) end)
        end)

        state = %{
          state
          | frames: Map.delete(state.frames, id),
            frame_mru: List.delete(state.frame_mru, id)
        }

        state = state |> drop_frame_client(id) |> cancel_frame_timer(id)
        changed({:ok, f.minibuffer}, resync_swap(state), id)
    end
  end

  def handle_call(:frame_list, _from, state), do: {:reply, state.frame_mru, state}

  def handle_call(:last_active_frame, _from, state),
    do: {:reply, hd(state.frame_mru), state}

  def handle_call({:select_frame, id}, _from, state) do
    if state.frames[id],
      do: changed(:ok, state |> bump_frame(id) |> resync_swap(), id),
      else: {:reply, {:error, :no_frame}, state}
  end

  def handle_call({:frame_of_window, win_id}, _from, state),
    do: {:reply, (f = find_window_frame(state, win_id)) && f.id, state}

  def handle_call({:window_point, win_id}, _from, state) do
    case window_leaf(state, win_id) do
      nil ->
        {:reply, {:error, :no_window}, state}

      {f, leaf} ->
        point =
          if state.swapped == {f.id, win_id, leaf.buffer},
            do: Buffer.point(leaf.buffer),
            else: Buffer.win_point(leaf.buffer, win_id)

        {:reply, {:ok, point}, state}
    end
  end

  def handle_call({:set_window_point, win_id, pos}, _from, state) do
    case window_leaf(state, win_id) do
      nil ->
        {:reply, {:error, :no_window}, state}

      {f, leaf} ->
        if state.swapped == {f.id, win_id, leaf.buffer},
          do: Buffer.goto(leaf.buffer, pos),
          else: Buffer.set_win_point(leaf.buffer, win_id, pos)

        changed(:ok, state, f.id)
    end
  end

  def handle_call({:touch_frame, id}, _from, state) do
    if state.frames[id],
      do: {:reply, :ok, state |> bump_frame(id) |> resync_swap()},
      else: {:reply, :ok, state}
  end

  def handle_call(:all_minibuffers, _from, state),
    do: {:reply, for({_id, f} <- state.frames, f.minibuffer, do: f.minibuffer), state}

  def handle_call(:list_windows_all, _from, state) do
    reply =
      for fid <- state.frame_mru,
          {id, buf} <- leaf_ids_buffers(state.frames[fid].tree),
          do: {id, buf, fid}

    {:reply, reply, state}
  end

  def handle_call({:window_set_buffer, win_id, buffer, bump?}, _from, state) do
    case {find_window_frame(state, win_id), live(buffer)} do
      {nil, _} ->
        {:reply, {:error, :no_window}, state}

      # a buffer that cannot start stays out of the window, and the
      # window keeps what it showed
      {_f, {:error, reason}} ->
        {:reply, {:error, reason}, state}

      # a look shows the buffer from its top and leaves the ring as it was
      {f, _started} when not bump? ->
        Buffer.touch(buffer)
        leaf = find_leaf(f.tree, win_id)
        shown = %{leaf | buffer: buffer, top: 0, manual: false} |> Map.put(:ctop, 0)
        changed(:ok, put_frame(state, %{f | tree: replace_leaf(f.tree, win_id, shown)}), f.id)

      {f, _started} ->
        leaf = find_leaf(f.tree, win_id)
        tree = replace_leaf(f.tree, win_id, visit_buffer(leaf, buffer))
        # a use like any other: the ring, the saved history and meta.db
        changed(:ok, resync_swap(put_frame(bump_mru(state, buffer), %{f | tree: tree})), f.id)
    end
  end

  # --- frame-scoped state -----------------------------------------------------

  def handle_call({:snapshot, fid}, _from, state) do
    f = frame(state, fid)

    snap =
      Map.take(f, [
        :pending,
        :minibuffer,
        :echo,
        :active,
        :completion,
        :transient,
        :key_capture
      ])
      |> Map.put(:prefix_arg, Map.get(f, :prefix_arg))

    # expose the selection flag KeyDispatch needs without leaking the list
    snap =
      case snap.minibuffer do
        nil -> snap
        mb -> %{snap | minibuffer: Map.put(mb, :sel_touched, mb.list.touched)}
      end

    {:reply, snap, state}
  end

  # while a prompt is active the minibuffer IS the current buffer (Emacs:
  # the minibuffer window is selected) — all point-relative primitives and
  # the local-keymap lookup route there. with-window-buffer flips
  # mb_redirect off so a handler can act on the window's buffer instead
  # (Emacs' with-minibuffer-selected-window).
  def handle_call({:current_buffer, fid}, _from, state) do
    f = frame(state, fid)

    reply =
      case f do
        %{minibuffer: %{}, mb_redirect: true} -> minibuf_of(f)
        _ -> find_leaf(f.tree, f.active).buffer
      end

    {:reply, reply, state}
  end

  def handle_call({:minibuf_name, fid}, _from, state),
    do: {:reply, minibuf_of(frame(state, fid)), state}

  def handle_call({:mb_redirect, bool, fid}, _from, state) do
    f = frame(state, fid)
    {:reply, :ok, put_frame(state, %{f | mb_redirect: bool})}
  end

  def handle_call({:desktop_view, fid}, _from, state) do
    f = frame(state, fid)

    active =
      case find_leaf(f.tree, f.active) do
        %{buffer: b} -> b
        _ -> nil
      end

    {:reply,
     %{
       tree: dtree(f.tree),
       active_buffer: active,
       faces: frame_faces(state, f)
     }, state}
  end

  def handle_call({:set_overriding_map, name, lock?, until?, fid}, _from, state) do
    f = frame(state, fid)

    over =
      if name,
        do: %{map: name, lock: lock? == true, until_command: until? == true},
        else: nil

    {:reply, :ok, put_frame(state, Map.put(f, :overriding, over))}
  end

  def handle_call({:overriding_map_state, fid}, _from, state),
    do: {:reply, Map.get(frame(state, fid), :overriding), state}

  def handle_call({:key_context, fid}, _from, state) do
    f = frame(state, fid)
    buffer = if f.minibuffer, do: minibuf_of(f), else: find_leaf(f.tree, f.active).buffer
    # a prompt reads its own keys: the overriding map waits while the
    # minibuffer is up (Emacs transient--suspend-override)
    over = if f.minibuffer, do: nil, else: Map.get(f, :overriding)
    {:reply, %{buffer: buffer, overriding: over}, state}
  end

  def handle_call({:overriding_map, fid}, _from, state) do
    case Map.get(frame(state, fid), :overriding) do
      %{map: m} -> {:reply, m, state}
      _ -> {:reply, nil, state}
    end
  end

  def handle_call({:render_state, fid}, _from, state) do
    f = frame(state, fid)
    {tree, rendered} = render_row(f.tree, f.total_rows, f.win_rows, Map.get(f, :group_label), Map.get(f, :win_stacks, %{}))
    state = put_frame(state, %{f | tree: tree})

    {:reply,
     %{
       frame: f.id,
       frame_group: Map.get(f, :group_label),
       frame_group_color: Map.get(f, :group_color),
       tree: rendered,
       active: f.active,
       pending: f.pending,
       minibuffer: f.minibuffer && render_minibuffer(f.minibuffer, minibuf_of(f)),
       transient: Map.get(f, :transient),
       # a pending prefix has which-key rows; the client asks Scheme for
       # them (which-key-rows) once its idle delay has passed, so a fast
       # chord never pays for them
       which_key: if(f.pending == [], do: nil, else: :pending),
       completion: f.completion && render_completion(f.completion),
       echo: f.echo,
       workspace: workspace_context(),
       modeline_extra: state.modeline_extra,
       chrome: Map.get(state, :chrome, %{}),
       faces: frame_faces(state, f),
       styles: frame_styles(state, f)
     }, state}
  end

  def handle_call({:set_group_label, label, fid}, _from, state) do
    f = frame(state, fid)

    updated =
      f
      |> Map.put(:group_label, label)
      |> then(fn frame ->
        if is_nil(label), do: Map.put(frame, :group_color, nil), else: frame
      end)

    if updated == f do
      {:reply, :ok, state}
    else
      changed(:ok, put_frame(state, updated), f.id)
    end
  end

  def handle_call({:set_group_style, label, color, fid}, _from, state) do
    f = frame(state, fid)

    if Map.get(f, :group_label) == label and Map.get(f, :group_color) == color do
      {:reply, :ok, state}
    else
      updated = f |> Map.put(:group_label, label) |> Map.put(:group_color, color)
      changed(:ok, put_frame(state, updated), f.id)
    end
  end

  # a frame's own theme: the whole face map Scheme made for it, or nil for
  # the global faces. Scheme sends a later global change on face by face.
  def handle_call({:set_own_faces, faces, skin, fid}, _from, state) do
    f = frame(state, fid)

    if Map.get(f, :own_faces) == faces and Map.get(f, :skin) == skin do
      {:reply, :ok, state}
    else
      updated = f |> Map.put(:own_faces, faces) |> Map.put(:skin, skin)
      changed(:ok, put_frame(state, updated), f.id)
    end
  end

  def handle_call({:set_total_rows, rows, fid}, _from, state) do
    f = frame(state, fid)
    {:reply, :ok, put_frame(state, %{f | total_rows: rows |> max(5) |> min(500)})}
  end

  # no-op guard: the client re-reports after every patch; only real changes
  # may broadcast or this loops forever
  def handle_call({:set_window_rows, map, fid}, _from, state) when is_map(map) do
    f = frame(state, fid)

    if f.win_rows == map,
      do: {:reply, :ok, state},
      else: changed(:ok, put_frame(state, %{f | win_rows: map}), f.id)
  end

  # the width the client measured, for anything that lays out in columns.
  # It moves no window, so it never broadcasts; it answers whether the
  # measurement CHANGED, and the caller tells Scheme so the tables can
  # lay themselves out again.
  #
  # A report names only the windows the client could measure: a window
  # that shows no text lines (a chat) is left out. So a report updates the
  # windows it names and keeps the last width of the others. Dropping them
  # made the next table in such a window draw at an estimate, then reflow
  # when its real width arrived: a visible second draw.
  def handle_call({:set_window_cols, map, fid}, _from, state) when is_map(map) do
    f = frame(state, fid)
    old = Map.get(f, :win_cols, %{})

    cond do
      # an empty report forgets every width; the client never sends one
      map == %{} ->
        {:reply, old != %{}, put_frame(state, Map.put(f, :win_cols, %{}))}

      Enum.all?(map, fn {id, n} -> Map.get(old, id) == n end) ->
        {:reply, false, state}

      true ->
        live = for [id | _] <- leaf_rects(f.tree), do: id
        cols = old |> Map.take(live) |> Map.merge(map)
        {:reply, true, put_frame(state, Map.put(f, :win_cols, cols))}
    end
  end

  # what the client measured after its last paint. It moves nothing and
  # draws nothing, so it never broadcasts: a key that arrives later reads
  # it through Scheme, and a map that is behind the buffer is ignored
  # there. The client sends every visual-line window each time, so the
  # whole map is replaced.
  def handle_call({:set_wrap_maps, map, fid}, _from, state) when is_map(map) do
    f = frame(state, fid)
    {:reply, :ok, put_frame(state, Map.put(f, :wrap_maps, map))}
  end

  def handle_call({:set_wrap_map, win, version, rows, fid}, _from, state) do
    f = frame(state, fid)
    maps = Map.put(Map.get(f, :wrap_maps, %{}), win, {version, rows})
    {:reply, :ok, put_frame(state, Map.put(f, :wrap_maps, maps))}
  end

  def handle_call({:wrap_map, win, fid}, _from, state) do
    f = frame(state, fid)
    {:reply, Map.get(Map.get(f, :wrap_maps, %{}), win || f.active), state}
  end

  # a list lays itself out for the window it is IN, whichever frame that
  # is: the frame running the command is not always the frame showing the
  # buffer
  def handle_call({:buffer_cols, buf, fid}, _from, state) do
    f = frame(state, fid)

    cols =
      frame_buffer_cols(f, buf) ||
        Enum.find_value(Map.values(state.frames), &frame_buffer_cols(&1, buf)) ||
        Map.get(Map.get(f, :win_cols, %{}), f.active, @default_cols)

    {:reply, cols, state}
  end

  def handle_call({:window_cols, win, fid}, _from, state) do
    f = frame(state, fid)
    cols = Map.get(f, :win_cols, %{})
    {:reply, Map.get(cols, win || f.active, @default_cols), state}
  end

  def handle_call({:frame_cols, fid}, _from, state) do
    f = frame(state, fid)
    measured = Map.get(f, :win_cols, %{})

    estimates =
      for [id, _buffer, _x, _y, width, _height] <- leaf_rects(f.tree),
          cols when is_number(cols) <- [Map.get(measured, id)],
          width > 0,
          do: cols / width

    frame_cols =
      case estimates do
        [] -> @default_cols
        values -> values |> Enum.max() |> round()
      end

    {:reply, frame_cols, state}
  end

  def handle_call({:scroll_active, delta, fid}, _from, state) do
    f = frame(state, fid)
    leaf = find_leaf(f.tree, f.active)
    top = max(leaf.top + delta, 0)
    tree = replace_leaf(f.tree, f.active, %{leaf | top: top, manual: true})
    changed(:ok, put_frame(state, %{f | tree: tree}), f.id)
  end

  def handle_call({:scroll_window, id, delta}, _from, state) do
    case find_window_frame(state, id) do
      nil ->
        {:reply, {:error, :no_window}, state}

      f ->
        leaf = find_leaf(f.tree, id)

        # A preview window has no lines to move over: the client draws it
        # as one rendered document. Move its pixel offset instead, and the
        # browser scrolls the frame. The caller still speaks in lines, so
        # `C-v` and `M-<down>` mean the same thing in every window.
        # A client-scrolled text window (every buffer under the ship-all
        # threshold) ignores `top`: the browser owns its offset. So the
        # leaf also carries a scroll request, a generation and the lines,
        # and the client scrolls by that many of its own line heights.
        leaf =
          if preview?(leaf.buffer) do
            top = max(Map.get(leaf, :ctop, 0) + delta * @preview_line_px, 0)
            leaf |> Map.put(:ctop, top) |> Map.put(:manual, true)
          else
            Map.merge(leaf, %{
              top: max(leaf.top + delta, 0),
              manual: true,
              scroll_gen: System.unique_integer([:positive, :monotonic]),
              scroll_lines: delta
            })
          end

        changed(:ok, put_frame(state, %{f | tree: replace_leaf(f.tree, id, leaf)}), f.id)
    end
  end

  def handle_call({:mouse_goto, id, line, col}, _from, state) do
    case find_window_frame(state, id) do
      nil ->
        {:reply, {:error, :no_window}, state}

      # a window can briefly show a killed buffer (kill_buffer heals the
      # tree, but a click can race it — and the registry entry outlives
      # the process for a moment, so exists? isn't enough). A dead buffer
      # must never crash the Editor: its crash wipes the keymap with it.
      f ->
        leaf = find_leaf(f.tree, id)

        try do
          Buffer.goto(leaf.buffer, mouse_pos(leaf.buffer, line, col))
          changed(:ok, state)
        catch
          :exit, _ -> {:reply, {:error, :no_buffer}, state}
        end
    end
  end

  def handle_call(:visible_buffers, _from, state) do
    visible =
      state.frames
      |> Enum.flat_map(fn {_id, f} -> visible_buffers(f.tree) end)
      |> Enum.uniq()

    current =
      state.frames
      |> Enum.map(fn {_id, f} ->
        case find_leaf(f.tree, f.active) do
          %{buffer: b} -> b
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    {:reply, %{visible: visible, current: current}, state}
  end

  # Killing a buffer never deletes a work window: the window stays and
  # shows another buffer, as kill-buffer does in Emacs. Scheme gives each
  # window that showed the victim its own history first (buffer-kill!);
  # a window left on it here shows the most recent buffer no window
  # shows, then any live buffer. Only a
  # float that showed the victim closes: nobody split for a float, and
  # one with nothing to show is not a window. Scheme policy refines the
  # choice after the kill (buffer-kill-repair): a group window fills
  # from its group.
  def handle_call({:release_buffer, buffer}, _from, state) do
    visible = Enum.flat_map(state.frames, fn {_id, f} -> visible_buffers(f.tree) end)

    fallback =
      Recent.find_buffer(fn b ->
        b != buffer and b not in visible and Buffer.exists?(b)
      end) ||
        Recent.find_buffer(fn b ->
          b != buffer and Buffer.exists?(b)
        end) ||
        # the recent list can lack every live buffer; a refill must never
        # name the buffer that dies, or the window keeps a dead name
        Enum.find(Compos.Core.list_buffers(), fn b ->
          b != buffer and not String.starts_with?(b, " ")
        end) || @scratch

    float? = float_buffer?(buffer)

    frames =
      Map.new(state.frames, fn {id, f} ->
        victim_ids = wins_showing(f.tree, buffer)
        others = f.tree |> leaf_ids_buffers() |> Enum.reject(fn {win, _} -> win in victim_ids end)

        cond do
          victim_ids == [] ->
            {id, f}

          float? and others != [] ->
            Enum.each(victim_ids, fn win ->
              wp_safely(fn -> Buffer.drop_win_point(buffer, win) end)
            end)

            tree = Enum.reduce(victim_ids, f.tree, &remove_leaf(&2, &1))
            active = if f.active in victim_ids, do: first_leaf(tree).id, else: f.active
            {id, %{f | tree: tree, active: active}}

          true ->
            Enum.each(victim_ids, fn win ->
              wp_safely(fn -> Buffer.drop_win_point(buffer, win) end)
            end)

            {id, %{f | tree: release_buffer_from_tree(f.tree, buffer, fallback)}}
        end
      end)

    Recent.forget(buffer)
    changed(:ok, %{state | frames: frames})
  end

  def handle_call({:rename_buffer, old, new}, _from, state) do
    frames =
      Map.new(state.frames, fn {id, f} ->
        {id, %{f | tree: swap_buffer(f.tree, old, new)}}
      end)

    Recent.rename(old, new)
    changed(:ok, %{state | frames: frames})
  end

  def handle_call({:mouse_region, id, al, ac, fl, fc}, _from, state) do
    case find_window_frame(state, id) do
      nil ->
        {:reply, {:error, :no_window}, state}

      f ->
        leaf = find_leaf(f.tree, id)

        try do
          Buffer.set_mark(leaf.buffer, mouse_pos(leaf.buffer, al, ac))
          Buffer.goto(leaf.buffer, mouse_pos(leaf.buffer, fl, fc))
          changed(:ok, state)
        catch
          :exit, _ -> {:reply, {:error, :no_buffer}, state}
        end
    end
  end

  def handle_call({:windows_follow_point, buffer}, _from, state) do
    frames =
      Map.new(state.frames, fn {fid, f} ->
        {fid, %{f | tree: unpin_buffer_leaves(f.tree, buffer)}}
      end)

    changed(:ok, %{state | frames: frames})
  end

  def handle_call({:user_acted, fid}, _from, state) do
    # a key ends the manual-scroll override in the window that received
    # it — a reading position in another window is not the typist's to
    # lose (S9)
    f = frame(state, fid)

    tree =
      case find_leaf(f.tree, f.active) do
        %{} = leaf -> replace_leaf(f.tree, f.active, %{leaf | manual: false})
        _ -> f.tree
      end

    {:reply, :ok, put_frame(state, %{f | tree: tree})}
  end

  def handle_call({:set_client_top, id, px, fid}, _from, state) do
    # a client-scrolled window's position, mirrored (S1). Passive: no
    # re-render broadcast — the browser already shows what it reports.
    f = frame(state, fid)

    case find_leaf(f.tree, id) do
      %{} = leaf ->
        leaf = leaf |> Map.put(:ctop, px) |> Map.put(:manual, true)
        {:reply, :ok, put_frame(state, %{f | tree: replace_leaf(f.tree, id, leaf)})}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:window_rows, win, fid}, _from, state) do
    # a window named explicitly may live in another frame: a page of it is
    # its own rows, never the caller's
    f = (win && find_window_frame(state, win)) || frame(state, fid)
    id = win || f.active

    rows =
      Map.get(f.win_rows, id) ||
        rows_for(f.tree, id, f.total_rows) || f.total_rows

    {:reply, rows, state}
  end

  def handle_call({:recenter, fid}, _from, state) do
    f = frame(state, fid)
    leaf = find_leaf(f.tree, f.active)

    rows =
      Map.get(f.win_rows, f.active) ||
        rows_for(f.tree, f.active, f.total_rows) || f.total_rows

    top = max(safe_snapshot(leaf.buffer, f.active).cursor_line - div(rows, 2), 0)

    tree = replace_leaf(f.tree, f.active, %{leaf | top: top, manual: false})
    changed(:ok, put_frame(state, %{f | tree: tree}), f.id)
  end

  def handle_call({:frame_get, field, fid}, _from, state),
    do: {:reply, Map.get(frame(state, fid), field), state}

  # false is unset. No render reads the key loop's facts but the echo and
  # the pending prefix, so only those two mark the frame changed: an armed
  # key capture must not cost every client a repaint.
  def handle_call({:frame_put, field, value, fid}, _from, state) do
    f = frame(state, fid)
    value = if value == false, do: nil, else: value

    cond do
      Map.get(f, field) == value -> {:reply, :ok, state}
      field in [:echo, :pending] -> changed(:ok, put_frame(state, Map.put(f, field, value)), f.id)
      true -> {:reply, :ok, put_frame(state, Map.put(f, field, value))}
    end
  end

  def handle_call({:finish_command, name, keep_prefix, fid}, _from, state) do
    f = frame(state, fid)
    f = if keep_prefix, do: f, else: Map.put(f, :prefix_arg, nil)

    # the prefix argument's map goes with the prefix argument
    f =
      case Map.get(f, :overriding) do
        %{until_command: true} when not keep_prefix -> Map.put(f, :overriding, nil)
        _ -> f
      end

    # what the command said it was, when it said so (set-this-command!)
    this = Map.get(f, :this_command) || ""
    last = if this in ["", nil], do: name, else: this
    f = f |> Map.put(:last_command, last) |> Map.put(:this_command, "")
    {:reply, :ok, put_frame(state, f)}
  end

  def handle_call({:set_transient, menu, fid}, _from, state) do
    f = frame(state, fid)
    menu = if menu in [nil, false], do: nil, else: menu

    if Map.get(f, :transient) == menu,
      do: {:reply, :ok, state},
      else: changed(:ok, put_frame(state, Map.merge(f, %{transient: menu, pending: []})), f.id)
  end

  # the client renders on the frame-change broadcast and takes the text there
  def handle_call({:put_clipboard, text, fid}, _from, state) do
    f = frame(state, fid)
    changed(:ok, %{state | clips: Map.put(state.clips, f.id, text)}, f.id)
  end

  def handle_call({:take_clipboard, fid}, _from, state) do
    case Map.pop(state.clips, fid) do
      {nil, _} -> {:reply, nil, state}
      {text, clips} -> {:reply, text, %{state | clips: clips}}
    end
  end

  def handle_call({:navigate, url, fid}, _from, state) do
    f = frame(state, fid)
    changed(:ok, %{state | navigations: Map.put(state.navigations, f.id, url)}, f.id)
  end

  def handle_call({:take_navigation, fid}, _from, state) do
    case Map.pop(state.navigations, fid) do
      {nil, _} -> {:reply, nil, state}
      {url, navigations} -> {:reply, url, %{state | navigations: navigations}}
    end
  end

  # Map.get and Map.put: a hot swap keeps a state built before this key
  def handle_call({:slide, dir, fid}, _from, state) do
    f = frame(state, fid)
    slides = Map.put(Map.get(state, :slides, %{}), f.id, dir)
    changed(:ok, Map.put(state, :slides, slides), f.id)
  end

  def handle_call({:take_slide, fid}, _from, state) do
    case Map.pop(Map.get(state, :slides, %{}), fid) do
      {nil, _} -> {:reply, nil, state}
      {dir, slides} -> {:reply, dir, Map.put(state, :slides, slides)}
    end
  end

  # Map.get, not state.selects: a hot swap keeps the state a running
  # daemon built before this key existed, and a missing key here restarts
  # the Editor with every keymap and style gone.
  def handle_call({:select_request, req, fid}, _from, state) do
    f = frame(state, fid)
    selects = Map.get(state, :selects, %{})
    changed(:ok, Map.put(state, :selects, Map.put(selects, f.id, req)), f.id)
  end

  def handle_call({:take_select, fid}, _from, state) do
    case Map.pop(Map.get(state, :selects, %{}), fid) do
      {nil, _} -> {:reply, nil, state}
      {req, selects} -> {:reply, req, Map.put(state, :selects, selects)}
    end
  end

  def handle_call({:set_echo_all, msg}, _from, state) do
    frames = Map.new(state.frames, fn {id, f} -> {id, %{f | echo: msg}} end)
    changed(:ok, %{state | frames: frames})
  end

  def handle_call({:set_modeline_extra, s}, _from, %{modeline_extra: s} = state),
    do: {:reply, :ok, state}

  def handle_call({:set_modeline_extra, s}, _from, state),
    do: changed(:ok, %{state | modeline_extra: s})

  # Map.get: a hot swap keeps a state map that has no :chrome key
  def handle_call({:set_chrome, key, value}, _from, state) do
    chrome = Map.get(state, :chrome, %{})

    if Map.get(chrome, key) == value,
      do: {:reply, :ok, state},
      else: changed(:ok, Map.put(state, :chrome, Map.put(chrome, key, value)))
  end

  # Scheme owns the prompt: its handlers, its policy and its history. The
  # frame keeps what the render walk draws, and VIEW is that: input, style,
  # note, legend, whether the prompt completes a path, what the list
  # matches on (QUERY :input, :segment after the last "/", or :none), and
  # how it matches (match_hint, completion_style, preselect, selected).
  def handle_call({:mb_show, prompt, candidates, view, fid}, _from, state) do
    f = frame(state, fid)

    mb =
      %{
        input: "",
        completing: false,
        query: :input,
        match_hint: false,
        style: nil,
        completion_style: :flex,
        preselect: :first
      }
      |> Map.merge(view)
      |> Map.put(:prompt, prompt)

    open_minibuffer(state, f, mb, candidates)
  end

  def handle_call({:prompt_op, op, args, fid}, _from, state) do
    f = frame(state, fid)

    case on_prompt(op, args, f) do
      {:put, reply, f2} -> changed(reply, put_frame(state, f2), f.id)
      reply -> {:reply, reply, state}
    end
  end

  # returns the snapshot (+ :selected/:total/:sel_touched/:prompt_sel) or nil
  def handle_call({:mb_close, fid}, _from, state) do
    f = frame(state, fid)

    reply =
      f.minibuffer &&
        f.minibuffer
        |> Map.put(:selected, Candidates.selected(f.minibuffer.list))
        |> Map.put(:total, Candidates.total(f.minibuffer.list))
        |> Map.put(:sel_touched, f.minibuffer.list.touched)
        |> Map.put(:prompt_sel, prompt_preselected?(f.minibuffer))

    changed(reply, put_frame(state, %{f | minibuffer: nil}), f.id)
  end

      # a window's stack count, for its header line: Scheme keeps the
  # history (window.scm) and hands the number over, keyed by window id
  # so a layout restore keeps it
  def handle_call({:set_window_stack, win, n}, _from, state) do
    case find_window_frame(state, win) do
      nil ->
        {:reply, false, state}

      f ->
        stacks = Map.get(f, :win_stacks, %{})

        if Map.get(stacks, win) == n,
          do: {:reply, true, state},
          else: changed(true, put_frame(state, Map.put(f, :win_stacks, Map.put(stacks, win, n))), f.id)
    end
  end

  def handle_call({:add_undo_exempt, name}, _from, state),
    do: {:reply, :ok, %{state | undo_exempt: MapSet.put(state.undo_exempt, name)}}

  def handle_call({:undo_exempt?, name}, _from, state),
    do: {:reply, MapSet.member?(state.undo_exempt, name), state}

  # TAIL is how far END lies past point: a capf that completes over a
  # suffix (an LSP textEdit) names the whole word, and accept replaces
  # it. Narrowing inserts at point, so the tail keeps its length.
  def handle_call({:completion_show, start, tail, candidates, fid}, _from, state) do
    f = frame(state, fid)

    case Candidates.normalize(candidates) do
      [] ->
        changed(:ok, put_frame(state, %{f | completion: nil}), f.id)

      _ ->
        completion = %{start: start, tail: max(tail, 0), list: Candidates.new(candidates)}
        changed(:ok, put_frame(state, %{f | completion: completion}), f.id)
    end
  end

  def handle_call(:faces, _from, state), do: {:reply, state.faces, state}
  def handle_call({:face, name}, _from, state), do: {:reply, Map.get(state.faces, name), state}

  def handle_call({:put_faces, changes, nil}, _from, state) do
    case put_face_changes(state.faces, changes) do
      :same -> {:reply, :ok, state}
      faces -> changed(:ok, %{state | faces: faces})
    end
  end

  def handle_call({:put_faces, changes, fid}, _from, state) do
    case state.frames[fid] do
      %{own_faces: own} = f when is_map(own) ->
        case put_face_changes(own, changes) do
          :same -> {:reply, :ok, state}
          faces -> changed(:ok, put_frame(state, %{f | own_faces: faces}), f.id)
        end

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:put_style, name, css}, _from, state) do
    if Map.get(state.styles, name) == css,
      do: {:reply, :ok, state},
      else: changed(:ok, %{state | styles: Map.put(state.styles, name, css)})
  end

  def handle_call(:styles, _from, state), do: {:reply, state.styles, state}
  def handle_call({:style, name}, _from, state), do: {:reply, Map.get(state.styles, name), state}

  # the selected window keeps its share, so a float split off it (a card,
  # a shaped prompt), which takes no width on screen, narrows nothing
  def handle_call({:split, ratio, fid}, _from, state) do
    f = frame(state, fid)
    old = find_leaf(f.tree, f.active)
    share = share(old) * (1 - ratio)
    new_leaf = %{type: :leaf, id: state.next_win, buffer: old.buffer, top: old.top, manual: false, share: share}
    tree = Enum.flat_map(row(f.tree), &if(&1.id == f.active, do: [&1, new_leaf], else: [&1]))

    # the new window starts at the old one's point and diverges from here
    # (Emacs split-window)
    if Buffer.exists?(old.buffer),
      do:
        wp_safely(fn ->
          Buffer.set_win_point(old.buffer, new_leaf.id, Buffer.win_point(old.buffer, old.id))
        end)

    changed(:ok, put_frame(%{state | next_win: state.next_win + 1}, %{f | tree: tree}), f.id)
  end

  def handle_call({:dock, ratio, fid}, _from, state) do
    f = frame(state, fid)
    seed = find_leaf(f.tree, f.active) || first_leaf(f.tree)
    dock = %{type: :leaf, id: state.next_win, buffer: seed.buffer, top: 0, manual: false, share: 1 - ratio, dock: true}
    f = %{f | tree: row(f.tree) ++ [dock]}
    changed(dock.id, put_frame(%{state | next_win: state.next_win + 1}, f), f.id)
  end

  def handle_call({:delete_window_by_id, id}, _from, state) do
    case find_window_frame(state, id) do
      nil ->
        {:reply, {:error, :no_window}, state}

      f ->
        case remove_leaf(f.tree, id) do
          nil ->
            {:reply, {:error, :sole_window}, state}

          tree ->
            leaf = find_leaf(f.tree, id)

            if Buffer.exists?(leaf.buffer),
              do: wp_safely(fn -> Buffer.drop_win_point(leaf.buffer, id) end)

            active = if f.active == id, do: first_leaf(tree).id, else: f.active

            changed(
              :ok,
              state |> put_frame(%{f | tree: tree, active: active}) |> resync_swap(),
              f.id
            )
        end
    end
  end

  def handle_call({:list_windows, fid}, _from, state),
    do: {:reply, leaf_ids_buffers(frame(state, fid).tree), state}

  def handle_call({:window_rects, fid}, _from, state),
    do: {:reply, leaf_rects(frame(state, fid).tree), state}

  # --- the line of windows ----------------------------------------------------

  def handle_call(:new_window_id, _from, state),
    do: {:reply, state.next_win, %{state | next_win: state.next_win + 1}}

  def handle_call({:arrange, spec, fid, ask_wake?}, _from, state) do
    f = frame(state, fid)
    visible = row(f.tree)
    held = Enum.flat_map(Map.values(state.frames), &frame_window_ids/1)
    items = arrange_items(spec)
    chosen = Enum.map(items, &line_leaf(&1, visible, held))
    ids = Enum.map(items, &line_item_id/1)
    asleep = Enum.flat_map(items, &List.wrap(asleep_buffer(&1, visible, held)))

    if ask_wake? and asleep != [] do
      {:reply, {:wake, Enum.uniq(asleep)}, state}
    else
      arrange_line(state, f, spec, visible, chosen, ids)
    end
  end

  # selecting a window selects its frame: bare window ids arrive from Scheme
  # (ibuffer buffer-locals, agent closures) with no frame attached
  def handle_call({:set_active, id}, _from, state) do
    case find_window_frame(state, id) do
      nil ->
        {:reply, {:error, :no_window}, state}

      f ->
        # selecting a window makes its buffer the most recent (Emacs
        # buffer-list order) — without this, a focus change is invisible
        # to C-x b history
        state = bump_mru(state, find_leaf(f.tree, id).buffer)

        changed(
          :ok,
          state |> put_frame(%{f | active: id}) |> bump_frame(f.id) |> resync_swap(),
          f.id
        )
    end
  end

  def handle_call({:active_window, fid}, _from, state),
    do: {:reply, frame(state, fid).active, state}

  def handle_call({:other_window, fid}, _from, state) do
    f = frame(state, fid)
    ids = leaf_ids(f.tree)
    idx = Enum.find_index(ids, &(&1 == f.active)) || 0
    next = Enum.at(ids, rem(idx + 1, length(ids)))
    state = bump_mru(state, find_leaf(f.tree, next).buffer)

    changed(
      :ok,
      state |> put_frame(%{f | active: next}) |> resync_swap(),
      f.id
    )
  end

  def handle_call({:set_window_buffer, buffer, fid}, _from, state) do
    case live(buffer) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      _started ->
        f = frame(state, fid)
        leaf = find_leaf(f.tree, f.active)
        tree = replace_leaf(f.tree, f.active, visit_buffer(leaf, buffer))
        changed(:ok, resync_swap(put_frame(bump_mru(state, buffer), %{f | tree: tree})), f.id)
    end
  end

  def handle_call({:restore_tree, spec, active_buffer, fid, bump_mru?}, _from, state) do
    f = frame(state, fid)
    taken = other_frames_window_ids(state, f.id)
    {state, f} = restore_frame_tree(state, f, spec, active_buffer, bump_mru?, taken)
    changed(:ok, state, f.id)
  end

  # the render modes the client draws in an iframe
  defp preview?(buffer) do
    try do
      Buffer.get_local(buffer, "render-mode") in ["html", "markdown", "app", "file", "web"]
    catch
      :exit, _ -> false
    end
  end

  # --- frame clients ----------------------------------------------------------

  # the client of a frame is gone: the tab closed, reloaded, or lost its
  # socket. Start the grace; a reattach within it cancels the clock.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    clients = frame_clients(state)

    case Enum.find(clients, fn {_fid, {_pid, r}} -> r == ref end) do
      {fid, _} ->
        state = Map.put(state, :frame_clients, Map.delete(clients, fid))
        {:noreply, arm_frame_timer(state, fid)}

      nil ->
        {:noreply, state}
    end
  end

  # the grace ran out with no client: hand the frame to Scheme, which
  # decides (frame-client-lost! in editor.scm deletes it). This server
  # never calls into Session itself — deadlock — so a Task carries it.
  def handle_info({:frame_expired, fid}, state) do
    state = Map.put(state, :frame_timers, Map.delete(frame_timers(state), fid))

    if state.frames[fid] && not Map.has_key?(frame_clients(state), fid) do
      Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
        Session.call_named("frame-client-lost!", [fid], fid)
      end)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @frame_grace_default 30 * 60_000

  defp frame_grace_ms,
    do: Application.get_env(:compos_core, :frame_grace_ms, @frame_grace_default)

  # Map.get, not a key: a hot reload swaps this module in over a state that
  # init built before these two keys existed
  defp frame_clients(state), do: Map.get(state, :frame_clients, %{})
  defp frame_timers(state), do: Map.get(state, :frame_timers, %{})

  # Record who shows the frame. A pid replaces the previous client and
  # stops the grace. nil says "no client here" (a desktop restore) and
  # starts the grace only when no client holds the frame already: a tab
  # that connected before the restore ran keeps its frame.
  defp frame_client(state, fid, nil) do
    if Map.has_key?(frame_clients(state), fid), do: state, else: arm_frame_timer(state, fid)
  end

  defp frame_client(state, fid, pid) when is_pid(pid) do
    state =
      case frame_clients(state)[fid] do
        {^pid, _ref} ->
          state

        _other ->
          state = drop_frame_client(state, fid)
          ref = Process.monitor(pid)
          Map.put(state, :frame_clients, Map.put(frame_clients(state), fid, {pid, ref}))
      end

    cancel_frame_timer(state, fid)
  end

  defp drop_frame_client(state, fid) do
    case frame_clients(state)[fid] do
      {_pid, ref} ->
        Process.demonitor(ref, [:flush])
        Map.put(state, :frame_clients, Map.delete(frame_clients(state), fid))

      nil ->
        state
    end
  end

  defp arm_frame_timer(state, fid) do
    state = cancel_frame_timer(state, fid)
    ref = Process.send_after(self(), {:frame_expired, fid}, frame_grace_ms())
    Map.put(state, :frame_timers, Map.put(frame_timers(state), fid, ref))
  end

  defp cancel_frame_timer(state, fid) do
    case frame_timers(state)[fid] do
      nil ->
        state

      ref ->
        Process.cancel_timer(ref)
        Map.put(state, :frame_timers, Map.delete(frame_timers(state), fid))
    end
  end

  # scope: a frame id (only that frame's clients re-render) or :all (global
  # mutations — faces, kill ring — reach every frame). :editor is the
  # firehose non-view subscribers (Desktop, Reactor, Agent) listen on.
  defp changed(reply, state, scope \\ :all) do
    Events.broadcast_editor(:changed)

    fids =
      case scope do
        :all -> Map.keys(state.frames)
        fid -> [fid]
      end

    Enum.each(fids, &Events.broadcast_frame/1)
    note_windows(state)
    {:reply, reply, notify_configuration(state, fids)}
  end

  # Publish which windows show each buffer beside its row, for the lists.
  # Only the buffers whose windows changed are written.
  defp note_windows(state) do
    now =
      for {_fid, f} <- state.frames, {id, buf} <- leaf_ids_buffers(f.tree), is_binary(buf), reduce: %{} do
        acc -> Map.update(acc, buf, [id], &(&1 ++ [id]))
      end

    was = Process.get(:compos_buffer_windows, %{})

    if now != was do
      Compos.Core.BufferView.note_windows(now, was)
      Process.put(:compos_buffer_windows, now)
    end
  end

  # Every mutation commits through changed/3, so this is the one place
  # that knows a frame's windows or their buffers changed, whoever changed
  # them: a command, a kill that dropped a window onto its next buffer, an
  # agent. Scheme hears it once per change, by the name Emacs gives the
  # hook, on that frame, and never on this process's time: a call from
  # here into the Session would wait on the Session's call back into
  # this server.
  defp notify_configuration(state, fids) do
    keys = Map.get(state, :config_keys, %{})

    {keys, changed} =
      Enum.reduce(fids, {keys, []}, fn fid, {keys, acc} ->
        case state.frames[fid] do
          nil ->
            {keys, acc}

          f ->
            key = {leaf_ids_buffers(f.tree), f.active}

            if Map.get(keys, fid) == key,
              do: {keys, acc},
              else: {Map.put(keys, fid, key), [fid | acc]}
        end
      end)

    if changed != [] and Session.ready?() do
      for fid <- changed do
        Task.start(fn ->
          try do
            Session.call_named(@config_hook, [], fid, 5_000)
          catch
            _, _ -> :ok
          end
        end)
      end
    end

    Map.put(state, :config_keys, keys)
  end

  # --- frame helpers ---------------------------------------------------------

  # nil frame = the last-active one: the fallback for callers with no
  # frame context (timers, agent events, RPC eval)
  defp frame(state, nil), do: state.frames[hd(state.frame_mru)]
  defp frame(state, fid), do: state.frames[fid] || state.frames[hd(state.frame_mru)]

  defp put_frame(state, f), do: %{state | frames: Map.put(state.frames, f.id, f)}

  defp frame_faces(state, f), do: Map.get(f, :own_faces) || state.faces

  defp frame_styles(state, f) do
    if is_map(Map.get(f, :own_faces)),
      do: Map.put(state.styles, "theme-skin", Map.get(f, :skin) || ""),
      else: state.styles
  end

  # FACES with CHANGES put in order, or :same when no face moved; each
  # change is compared alone, never the whole map
  defp put_face_changes(faces, changes) do
    {out, moved?} =
      Enum.reduce(changes, {faces, false}, fn
        {name, nil}, {faces, moved?} ->
          if Map.has_key?(faces, name), do: {Map.delete(faces, name), true}, else: {faces, moved?}

        {name, attrs}, {faces, moved?} ->
          if Map.get(faces, name) == attrs, do: {faces, moved?}, else: {Map.put(faces, name, attrs), true}
      end)

    if moved?, do: out, else: :same
  end

  # A frame's windows: its row of leaves. A map is the tree a frame held
  # before the row, in a daemon that hot-loaded it: it reads as its
  # leaves, left to right and top to bottom, at equal shares.
  defp row(leaves) when is_list(leaves), do: leaves
  defp row(%{type: :leaf} = leaf), do: [leaf]
  defp row(%{children: c}), do: Enum.flat_map(c, &row/1)

  defp share(leaf), do: Map.get(leaf, :share, 1)

  # one window is its leaf, more are a row
  defp payload([leaf]), do: leaf
  defp payload(leaves), do: %{type: :row, children: leaves}

  defp drop_point(%{buffer: b, id: id}) do
    if Buffer.exists?(b), do: wp_safely(fn -> Buffer.drop_win_point(b, id) end)
  end

  # A line item is a window id, or [ID, BUFFER]: the window ID, made on
  # BUFFER when this frame has no window ID and no frame holds the id.
  defp line_item_id([id, _buffer]), do: id
  defp line_item_id(id), do: id

  defp line_leaf([id, buffer], pool, held) when is_integer(id) and id > 0 and is_binary(buffer) do
    cond do
      leaf = Enum.find(pool, &(&1.id == id)) -> leaf
      id in held -> nil
      match?({:error, _}, live(buffer)) -> nil
      true -> %{type: :leaf, id: id, buffer: buffer, top: 0, manual: false}
    end
  end

  defp line_leaf(id, pool, _held), do: Enum.find(pool, &(&1.id == id))

  defp arrange_line(state, f, spec, visible, chosen, ids) do
    if chosen == [] or Enum.any?(chosen, &is_nil/1) or Enum.uniq(ids) != ids do
      {:reply, {:error, :no_window}, state}
    else
      used = MapSet.new(chosen, & &1.id)
      # a window that leaves the line goes, its point with it
      visible |> Enum.reject(&MapSet.member?(used, &1.id)) |> Enum.each(&drop_point/1)
      active = if MapSet.member?(used, f.active), do: f.active, else: hd(chosen).id
      next_win = Enum.reduce(chosen, state.next_win, &max(&2, &1.id + 1))

      f =
        %{f | tree: arrange_row(spec, chosen), active: active}

      changed(:ok, %{state | next_win: next_win} |> put_frame(f) |> resync_swap(), f.id)
    end
  end

  # the buffer an item needs started: a new window on a buffer not live
  defp asleep_buffer([id, buffer], pool, held) when is_integer(id) and id > 0 and is_binary(buffer) do
    if Enum.any?(pool, &(&1.id == id)) or id in held or Buffer.exists?(buffer), do: nil, else: buffer
  end

  defp asleep_buffer(_item, _pool, _held), do: nil

  # a spec is a line item, or {dir, shares, children}: the row's items, left
  # to right, each with its share of the width; other shares are equal
  defp arrange_items({_dir, _shares, children}), do: Enum.flat_map(children, &arrange_items/1)
  defp arrange_items(item), do: [item]

  defp arrange_row({_dir, shares, _children}, leaves) when length(shares) == length(leaves) do
    total = Enum.sum(shares)
    Enum.zip_with(leaves, shares, &Map.put(&1, :share, &2 / total))
  end

  defp arrange_row(_spec, leaves), do: Enum.map(leaves, &Map.put(&1, :share, 1 / length(leaves)))

  # A window with no buffer offers `false` here; it names no place, so it
  # never enters the recent order (Compos.Core.Recent).
  defp bump_mru(state, buffer) when is_binary(buffer) do
    Compos.Core.BufferStore.touch(buffer)
    Compos.Core.BufferView.note_used(buffer, System.system_time(:millisecond))
    if Buffer.exists?(buffer), do: Buffer.touch(buffer)
    # an insert into the order's own table, in this process: no call
    Recent.bump(buffer)
    state
  end

  defp bump_mru(state, _other), do: state

  defp bump_frame(state, fid),
    do: %{state | frame_mru: [fid | List.delete(state.frame_mru, fid)]}

  # Emacs point-swapping, one window at a time: the invariant is that the
  # buffer point of the swapped-in window's buffer IS that window's point.
  # Any change to (last-active frame, its selected window, that window's
  # buffer) saves the old window's point back into its buffer's win_points
  # and installs the new one's. Call after every mutation that can move any
  # of the three.
  # a buffer can die between exists? and the call (its registry entry
  # outlives the process for a moment) — win-point bookkeeping must never
  # take the Editor down with it
  defp wp_safely(fun) do
    fun.()
  catch
    :exit, _ -> :ok
  end

  defp resync_swap(state) do
    f = state.frames[hd(state.frame_mru)]
    leaf = find_leaf(f.tree, f.active)
    target = {f.id, f.active, leaf.buffer}

    if state.swapped == target do
      state
    else
      case state.swapped do
        {_ofid, owin, obuf} ->
          # skip windows that no longer exist — their entries were dropped
          if find_window_frame(state, owin) && Buffer.exists?(obuf),
            do: wp_safely(fn -> Buffer.win_point_save(obuf, owin) end)

        nil ->
          :ok
      end

      if Buffer.exists?(leaf.buffer),
        do: wp_safely(fn -> Buffer.win_point_swap_in(leaf.buffer, f.active) end)

      %{state | swapped: target}
    end
  end

  defp find_window_frame(state, win_id) do
    Enum.find_value(state.frames, fn {_fid, f} ->
      if find_leaf(f.tree, win_id), do: f
    end)
  end

  # the frame and the leaf of one window, when its buffer is alive
  defp window_leaf(state, win_id) do
    with %{} = f <- find_window_frame(state, win_id),
         %{} = leaf <- find_leaf(f.tree, win_id),
         true <- Buffer.exists?(leaf.buffer) do
      {f, leaf}
    else
      _ -> nil
    end
  end

  defp valid_frame_id?(id),
    do: is_binary(id) and String.starts_with?(id, "f-") and byte_size(id) <= 24

  defp gen_frame_id,
    do: "f-" <> Base.encode32(:crypto.strong_rand_bytes(4), case: :lower, padding: false)

  # --- minibuffer helpers (vertico-style: fuzzy filter + selection) ----------

  # what the minibuffer matches on: the whole input, except path prompts
  # (query :segment), which match the segment after the last "/"
  # A dynamic provider can return an already-ranked result set whose labels
  # need not contain the query (the command palette finds commands by docs and
  # recipes). Ordinary prompts keep the shared candidate matcher.
  defp mb_query(%{query: :none}), do: ""

  defp mb_query(%{query: :segment, input: input}),
    do: input |> String.split("/") |> List.last()

  defp mb_query(%{input: input}), do: input

  defp open_minibuffer(state, f, mb, candidates) do
    reset_minibuf_buffer(minibuf_of(f), mb.input)

    mb =
      Map.put(
        mb,
        :list,
        Candidates.new(candidates,
          query: mb_query(mb),
          match_hint: mb.match_hint,
          style: mb.completion_style
        )
      )

    mb =
      case mb[:selected] do
        label when is_binary(label) -> %{mb | list: Candidates.select_label(mb.list, label)}
        _ -> mb
      end

    changed(:ok, put_frame(state, %{f | minibuffer: mb}), f.id)
  end

  # True when the prompt line itself is the selection, not a candidate row
  # (vertico-preselect 'directory and 'prompt).
  #

  # A file prompt whose input ends with "/" names a directory. RET must open
  # that directory, not the first file in it — TAB descends into a directory
  # and leaves its contents listed. A prompt that asks for `preselect:
  # :prompt` (write-file) takes the typed input whatever the list shows: the
  # input names a NEW file, and a fuzzy match on another file must not take
  # the write. C-n/C-p touch the list and take the selection back to the
  # candidates in both cases. minibuffer.scm decides what RET and C-n do
  # with it; the render marks no row while it holds.
  defp prompt_preselected?(mb) do
    touched = Map.get(mb, :sel_touched) || (mb[:list] && mb.list.touched) || false

    mb[:completing] == true and not touched and
      (mb[:preselect] == :prompt or String.ends_with?(mb.input, "/"))
  end

  defp put_mb_input(mb, input) do
    mb = %{mb | input: input}
    %{mb | list: Candidates.put_query(mb.list, mb_query(mb))}
  end

  defp minibuf_of(%{id: fid}), do: " *minibuf-" <> fid <> "*"

  # one operation on the frame's prompt or popup (prompt_op/3). An op that
  # changes the frame answers {:put, REPLY, FRAME}; one that only reads
  # answers its reply. nil when nothing of that kind is open.
  defp on_prompt(:facts, [], %{minibuffer: %{} = mb}),
    do: %{input: mb.input, selected: Candidates.selected(mb.list), touched: mb.list.touched, prompt_sel: prompt_preselected?(mb)}

  defp on_prompt(:filtered, [], %{minibuffer: %{} = mb}),
    do: Enum.map(Candidates.filtered(mb.list), fn c -> [c.label, c.hint || ""] end)

  defp on_prompt(:selected, [], %{minibuffer: %{} = mb}), do: Candidates.selected(mb.list)

  # the selection moves by DELTA rows and nothing else: what a move means
  # in a prompt that holds the selection itself is the prompt's policy
  defp on_prompt(:move, [delta], %{minibuffer: %{} = mb} = f),
    do: {:put, :ok, %{f | minibuffer: %{mb | list: Candidates.move(mb.list, trunc(delta))}}}

  # the input back out of the prompt buffer after keys edited it; nil when unchanged
  defp on_prompt(:sync, [], %{minibuffer: %{} = mb} = f) do
    input = Buffer.text(minibuf_of(f))
    if input != mb.input, do: {:put, input, %{f | minibuffer: put_mb_input(mb, input)}}
  end

  defp on_prompt(:input, [input], %{minibuffer: %{} = mb} = f) do
    reset_minibuf_buffer(minibuf_of(f), input)
    {:put, :ok, %{f | minibuffer: put_mb_input(mb, input)}}
  end

  defp on_prompt(:candidates, [items], %{minibuffer: %{} = mb} = f) do
    list = mb.list |> Candidates.put_items(items) |> Candidates.put_query(mb_query(mb))
    {:put, :ok, %{f | minibuffer: %{mb | list: list}}}
  end

  # the prompt owns its style (its shape), its rail and its tabs; the same
  # input, rows and selection carry over, and nothing is inferred here
  defp on_prompt(:set, [key, value], %{minibuffer: %{} = mb} = f) when key in [:style, :rail, :tabs],
    do: {:put, :ok, %{f | minibuffer: Map.put(mb, key, value)}}

  defp on_prompt(:start, [], %{completion: %{start: start}}), do: start

  defp on_prompt(:cmove, [delta], %{completion: %{} = c} = f),
    do: {:put, :ok, %{f | completion: %{c | list: Candidates.move(c.list, delta)}}}

  # narrow the popup in place as the user types; no row left closes it
  defp on_prompt(:query, [q], %{completion: %{} = c} = f) do
    list = Candidates.put_query(c.list, q)
    {:put, :ok, %{f | completion: if(Candidates.total(list) == 0, do: nil, else: %{c | list: list})}}
  end

  # close the popup; [START, TAIL, LABEL] of the selection, or nil
  defp on_prompt(:accept, [], %{completion: %{} = c} = f) do
    label = Candidates.selected(c.list)
    {:put, label && [c.start, Map.get(c, :tail, 0), label], %{f | completion: nil}}
  end

  defp on_prompt(:dismiss, [], f), do: {:put, :ok, %{f | completion: nil}}
  defp on_prompt(_op, _args, _f), do: nil

  # --- keymaps -----------------------------------------------------------------
  # A keymap is a name, its own bindings, and a parent. A buffer's own map
  # is the keymap named after the buffer; use-local-map! gives it the mode's
  # map as its parent. A key resolves down this ladder:
  #
  #   the frame's overriding map (Transient, the prefix argument's map);
  #     locked, an unbound key is undefined
  #   the keymap of the thing at point (a block)
  #   the buffer's minor-mode maps, first wins
  #   the global minor-mode maps (cua-mode)
  #   the buffer's own map, then its parents
  #   the read-only map, when the buffer is read-only
  #   the global map
  #
  # An exact hit anywhere wins over a prefix anywhere. Emacs's
  # minor-mode-map-alist, local map and global map, in that order.

  defp dtree(tree) do
    payload(
      for %{id: id, buffer: b} = leaf <- row(tree) do
        %{
          type: :leaf,
          id: id,
          buffer: b,
          top: Map.get(leaf, :top, 0),
          point: safe_win_point(b, id),
          manual: Map.get(leaf, :manual, false),
          ctop: Map.get(leaf, :ctop, 0),
          share: share(leaf),
          dock: Map.get(leaf, :dock, false)
        }
      end
    )
  end

  defp safe_win_point(buffer, win_id) do
    if Buffer.exists?(buffer), do: Buffer.win_point(buffer, win_id), else: 0
  catch
    :exit, _ -> 0
  end

  # (re)fill the backing buffer and park point at the end
  defp reset_minibuf_buffer(name, input) do
    unless Buffer.exists?(name), do: Compos.Core.create_buffer(name)
    size = Buffer.byte_size(name)
    if size > 0, do: Buffer.delete_range(name, 0, size, source: :editor)
    if input != "", do: Buffer.append(name, input, source: :editor)
    Buffer.goto(name, Kernel.byte_size(input))
  end

  defp render_minibuffer(mb, name) do
    prompt_sel = prompt_preselected?(mb)
    geometry = mb_geometry(mb)
    # each shape shows what it has room for: the modal is three times the
    # bottom bar's slice, the popup sits between the two
    window =
      case geometry do
        "modal" -> 24
        "popup" -> 14
        _ -> 8
      end

    %{
      prompt: mb.prompt,
      input: mb.input,
      point: (Buffer.exists?(name) && Buffer.point(name)) || Kernel.byte_size(mb.input),
      # the prompt holds the selection: mark no row, so the highlight always
      # shows what RET takes
      prompt_sel: prompt_sel,
      candidates:
        if(prompt_sel,
          do: Enum.map(Candidates.rows(mb.list, window), &%{&1 | selected: false}),
          else: Candidates.rows(mb.list, window)
        ),
      # widest label of the WHOLE set, not the visible window — the names
      # column keeps one width for the session instead of reflowing per key
      label_width: Candidates.label_width(mb.list),
      sel: mb.list.sel,
      total: Candidates.total(mb.list),
      completing: mb[:completing] == true,
      # the prompt's own flavour word, which picks the label row: nil,
      # "palette", "modal", "popup", "question", "filter"
      style: Map.get(mb, :style),
      # the shape it takes on screen, derived from the flavour
      geometry: geometry,
      # the prompt's own words for the palette: the rail's footer note and
      # the head row's key legend. Scheme writes both; nothing is inferred.
      note: (is_binary(Map.get(mb, :note)) && mb.note) || "",
      # the palette's right pane when the prompt gave it one: rows the
      # arrows can step into. The prompt already shaped them; they travel
      # to the view as they are.
      rail:
        case Map.get(mb, :rail) do
          %{rows: [_ | _]} = rail -> rail
          _ -> nil
        end,
      # the tabs over the list, as the prompt wrote them
      tabs:
        case Map.get(mb, :tabs) do
          tabs when is_list(tabs) -> tabs
          _ -> []
        end,
      legend:
        case Map.get(mb, :legend) do
          rows when is_list(rows) ->
            for [key, label] <- rows, do: %{key: to_string(key), label: to_string(label)}

          _ ->
            []
        end
    }
  end

  # The three shapes a completion can take. A prompt names one with its
  # 'style handler; nothing else about the prompt changes.
  #   "minibuffer" — the bottom rows, in the flow; the window tree shrinks
  #   "popup"      — an overlay on the bottom edge; nothing reflows
  #   "modal"      — a centered panel over a scrim
  # Every surface that covers the windows uses one of the three, which-key
  # and the transient menus included. "palette" is the old spelling of
  # "modal" and still answers to it.
  defp mb_geometry(mb) do
    case Map.get(mb, :style) do
      "modal" -> "modal"
      "palette" -> "modal"
      "popup" -> "popup"
      _ -> "minibuffer"
    end
  end

  defp render_completion(c) do
    %{
      start: c.start,
      candidates: Candidates.rows(c.list),
      sel: c.list.sel,
      total: Candidates.total(c.list)
    }
  end

  # --- tree helpers ----------------------------------------------------------

  # (1-based logical line, char col) -> byte offset; line lookup is the
  # rope NIF, only the clicked line's text is materialized for the col
  defp mouse_pos(buf, line, col) do
    {start, line_text} = Buffer.line_at(buf, line)
    start + byte_size(String.slice(line_text, 0, max(col, 0)))
  end

  defp frame_buffer_cols(f, buf) do
    cols = Map.get(f, :win_cols, %{})
    wins = wins_showing(f.tree, buf)
    Enum.find_value(wins, &Map.get(cols, &1)) || estimated_cols(f, wins)
  end

  # The client measures a window and reports its columns; a window made a
  # moment ago has no measurement yet. Estimating from the tree keeps the
  # first draw at the width the window will have: without it, a new window
  # draws once at the default width and reflows when the report arrives,
  # which a table shows as a flash of narrow, wrongly trimmed rows.
  defp estimated_cols(_f, []), do: nil

  defp estimated_cols(f, [win | _]) do
    measured = Map.get(f, :win_cols, %{})
    rects = leaf_rects(f.tree)

    per_frame =
      for [id, _buffer, _x, _y, width, _height] <- rects,
          cols when is_number(cols) <- [Map.get(measured, id)],
          width > 0,
          do: cols / width

    with [_ | _] <- per_frame,
         [_, _, _, _, width, _] <- Enum.find(rects, fn [id | _] -> id == win end),
         true <- width > 0 do
      round(Enum.max(per_frame) * width)
    else
      _ -> nil
    end
  end

  defp wins_showing(tree, buf), do: for(%{id: id, buffer: ^buf} <- row(tree), do: id)

  defp find_leaf(tree, id), do: Enum.find(row(tree), &(&1.id == id))

  defp visible_buffers(tree), do: Enum.map(row(tree), & &1.buffer)

  defp swap_buffer(tree, from, to),
    do: map_leaves(tree, from, &%{&1 | buffer: to, top: 0, manual: false})

  # a leaf on BUFFER follows point again: no pin, top and pixel offset at 0
  defp unpin_buffer_leaves(tree, buffer),
    do: map_leaves(tree, buffer, &(%{&1 | top: 0, manual: false} |> Map.put(:ctop, 0)))

  # a leaf that still shows the victim shows FALLBACK. Scheme gave each
  # window its own past before the kill (window-records-release!); what is
  # left here is the window with none.
  defp release_buffer_from_tree(tree, buffer, fallback),
    do: map_leaves(tree, buffer, &(%{&1 | buffer: fallback, top: 0, manual: false} |> Map.put(:ctop, 0)))

  # FUN on each leaf that shows BUFFER
  defp map_leaves(tree, buffer, fun), do: Enum.map(row(tree), &if(&1.buffer == buffer, do: fun.(&1), else: &1))

  defp replace_leaf(tree, id, new), do: Enum.map(row(tree), &if(&1.id == id, do: new, else: &1))

  # the window's history and quit record are Scheme's (window.scm)
  defp visit_buffer(leaf, buffer) do
    # the client's scroll offset was the old buffer's: kept, it scrolls the
    # new one to an arbitrary place
    ctop = if buffer == leaf.buffer, do: Map.get(leaf, :ctop, 0), else: 0
    Map.merge(leaf, %{buffer: buffer, top: 0, manual: false, ctop: ctop})
  end

  # a floating buffer (a card, a shaped prompt) wears the class Scheme
  # gave it; the class string keeps the stylesheet's name, popup-SIDE
  defp float_buffer?(b) when is_binary(b) do
    case Buffer.get_local(b, "window-class") do
      class when is_binary(class) -> String.starts_with?(class, "popup")
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  defp float_buffer?(_), do: false

  # the row without the leaf, or nil when it was the last
  defp remove_leaf(tree, id) do
    case Enum.reject(row(tree), &(&1.id == id)) do
      [] -> nil
      rest -> rest
    end
  end

  defp first_leaf(tree), do: hd(row(tree))

  # A spec (Compos.Core.WindowSpec) becomes a live row. A leaf's id is a
  # wish, not a claim: reuse_window_ids keeps it when no other window holds
  # it, else the leaf takes an id the way a leaf without one does. Carrying
  # the id is what keeps every record keyed by window id true across a
  # layout restore.
  defp build_row(spec) do
    for s <- Compos.Core.WindowSpec.leaves(spec) do
      leaf = Map.take(s, [:buffer, :top, :manual, :ctop, :share, :dock])
      put_want(Map.merge(leaf, %{type: :leaf, id: nil}), s.id)
    end
  end

  defp put_want(leaf, want) when is_integer(want), do: Map.put(leaf, :want, want)

  defp put_want(leaf, _), do: leaf

  # Lay the frame's existing window ids back over a freshly built tree, in
  # leaf order, minting only for panes the old tree did not have. Pane
  # identity survives a retile, so the client patches geometry instead of
  # re-sending every buffer.

  defp restore_frame_tree(state, f, spec, active_buffer, bump_mru?, taken) do
    # the old windows are gone — their stored points go with them
    Enum.each(leaf_ids_buffers(f.tree), fn {id, buffer} ->
      if Buffer.exists?(buffer), do: wp_safely(fn -> Buffer.drop_win_point(buffer, id) end)
    end)

    # A retile rearranges panes; it does not make new ones. Minting a fresh
    # id for every leaf told the client that every pane was new, so it re-sent
    # each pane's whole buffer -- one arrow key in window-layout cost a patch
    # the size of every visible buffer. Keep the ids the frame already had,
    # and the ids the leaves name when they are free.
    old_panes = leaf_ids_buffers(f.tree)
    tree = build_row(spec)
    {tree, next_win} = reuse_window_ids(tree, old_panes, taken, state.next_win)

    # A buffer that cannot start leaves its pane to *scratch*, and the
    # dormant one keeps its files. Scheme makes *scratch* again if it is
    # gone (scratch--heal!, editor.scm).
    tree =
      Enum.reduce(leaf_ids_buffers(tree), tree, fn {id, buffer}, tree ->
        case live(buffer) do
          {:error, _reason} ->
            replace_leaf(tree, id, %{find_leaf(tree, id) | buffer: @scratch})

          _started ->
            Buffer.touch(buffer)
            tree
        end
      end)

    # No saved point is laid down. A layout arranges windows; it does not
    # move point (S9). The old windows' points went above, so each window
    # falls back to the buffer's own point — where the reader left it.

    active =
      Enum.find_value(leaf_ids_buffers(tree), fn {id, buffer} ->
        if buffer == active_buffer, do: id
      end) || first_leaf(tree).id

    # what the restored tree shows IS the recent history now: the active
    # buffer leads, the other windows follow. Without this a group
    # switch left no trace in C-x b. A preview is not a switch, so a look
    # at a layout leaves the history exactly as it was.
    shown = tree |> leaf_ids_buffers() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    active_buf = find_leaf(tree, active).buffer

    state =
      if bump_mru? do
        Enum.reduce(Enum.reverse(shown -- [active_buf]) ++ [active_buf], state, &bump_mru(&2, &1))
      else
        state
      end

    f = %{f | tree: tree, active: active}
    state = resync_swap(put_frame(%{state | next_win: next_win}, f))
    {state, state.frames[f.id]}
  end

  defp reuse_window_ids(tree, old_panes, taken, next_win) do
    {ids, next_win} = window_ids_for(leaf_wants(tree), old_panes, taken, next_win)
    {Enum.zip_with(tree, ids, &take_id/2), next_win}
  end

  # the leaves in order, each as {buffer, the id it asks for or nil}
  defp leaf_wants(tree), do: Enum.map(row(tree), &{&1.buffer, Map.get(&1, :want)})

  # every window id a frame holds
  defp frame_window_ids(f), do: leaf_ids(f.tree)

  # the ids every other frame holds: a restore may not take one of them
  defp other_frames_window_ids(state, fid),
    do: state.frames |> Map.delete(fid) |> Map.values() |> Enum.flat_map(&frame_window_ids/1)

  # A pane takes the id that already showed its buffer, so a retile moves and
  # resizes the pane the reader is looking at rather than replacing it. Going
  # by position alone re-sent a pane's whole buffer whenever a layout put a
  # different buffer in that slot -- megabytes per arrow key in window-layout.
  #
  # A leaf that names its id comes first: it keeps that id when no window
  # outside the panes being replaced holds it (TAKEN), so a layout a group
  # or the switcher saved comes back with the very windows it was saved
  # with. Only then do the nameless leaves match old panes by buffer, and
  # what is left takes a spare old id, then a fresh one.
  defp window_ids_for(leaves, old_panes, taken, next_win) do
    {wanted, _claimed} =
      Enum.map_reduce(leaves, taken, fn {_buf, want}, claimed ->
        if is_integer(want) and want not in claimed,
          do: {want, [want | claimed]},
          else: {nil, claimed}
      end)

    kept = Enum.reject(wanted, &is_nil/1)
    avail = Enum.reject(old_panes, fn {id, _} -> id in kept end)

    {matched, spare} =
      Enum.map_reduce(Enum.zip(leaves, wanted), avail, fn
        {_leaf, id}, avail when is_integer(id) ->
          {id, avail}

        {{buf, _want}, nil}, avail ->
          case Enum.find(avail, fn {_id, b} -> b == buf end) do
            nil -> {nil, avail}
            pair -> {elem(pair, 0), List.delete(avail, pair)}
          end
      end)

    # a kept id from a saved layout may sit past the counter (a desktop
    # restored into a fresh daemon): fresh ids start above every kept one
    next_win = Enum.max([next_win | Enum.map(kept, &(&1 + 1))])

    {ids, _spare, next_win} =
      Enum.reduce(matched, {[], spare, next_win}, fn
        nil, {acc, [{id, _} | rest], n} -> {[id | acc], rest, n}
        nil, {acc, [], n} -> {[n | acc], [], n + 1}
        id, {acc, avail, n} -> {[id | acc], avail, n}
      end)

    {Enum.reverse(ids), next_win}
  end

  defp take_id(leaf, id), do: leaf |> Map.put(:id, id) |> Map.delete(:want)

  defp leaf_ids_buffers(tree), do: Enum.map(row(tree), &{&1.id, &1.buffer})

  # normalized frame geometry per leaf: the arrow commands' map of the
  # screen. The row parts the width by share; a dock spans the width under
  # it, with its share of the height.
  defp leaf_rects(tree) do
    {docks, cols} = Enum.split_with(row(tree), &Map.get(&1, :dock))
    low = docks |> Enum.map(&share/1) |> Enum.sum()
    total = cols |> Enum.map(&share/1) |> Enum.sum()
    {top, _} = Enum.map_reduce(cols, 0.0, &{[&1.id, &1.buffer, &2, 0.0, share(&1) / total, 1.0 - low], &2 + share(&1) / total})
    {under, _} = Enum.map_reduce(docks, 1.0 - low, &{[&1.id, &1.buffer, 0.0, &2, 1.0, share(&1)], &2 + share(&1)})
    top ++ under
  end

  defp leaf_ids(tree), do: Enum.map(row(tree), & &1.id)

  @empty_snapshot %{
    text: "",
    point: 0,
    mark: nil,
    version: 0,
    modified: false,
    locals: %{},
    overlays: [],
    overlay_gen: 0,
    hidden: [],
    narrow_range: nil,
    path: nil,
    read_only: false,
    total_lines: 1,
    cursor_line: 0,
    line: 1,
    col: 0
  }

  # the modeline's derived state: one plist local, KEY VALUE ... (editor.scm
  # modeline-cache). A missing key reads nil, as a missing local did, and the
  # first of two equal keys wins, as plist-get reads it.
  defp modeline_cache(locals) do
    case Map.get(locals, "modeline-cache") do
      plist when is_list(plist) ->
        plist
        |> Enum.chunk_every(2, 2, :discard)
        |> Enum.reverse()
        |> Map.new(fn [k, v] -> {modeline_cache_key(k), v} end)

      _ ->
        %{}
    end
  end

  defp modeline_cache_key({:sym, k}), do: k
  defp modeline_cache_key(k) when is_atom(k), do: Atom.to_string(k)
  defp modeline_cache_key(k), do: k

  # The frame names its current group once, in the header line. A window
  # whose buffer is in that group wears no pin; a window from another group
  # wears that group's name. CURRENT is the frame's label, which may carry
  # a decoration after the name.
  defp modeline_pin(group, current) when is_binary(group) do
    here? =
      current == group or
        (is_binary(current) and String.starts_with?(current, group <> " "))

    if here?, do: nil, else: group
  end

  defp modeline_pin(_group, _current), do: nil

  # exists? then call still races a dying buffer (registry entries linger);
  # a dead buffer renders empty instead of crashing the Editor
  # The read model answers this without a message, which is why the walk
  # may run here at all: this process holds the whole editor while it
  # renders, and it used to wait on each visible buffer in turn. One buffer
  # busy with a reparse, a checkpoint or a save then stalled every frame of
  # every client. Now only a buffer with no row costs a call, and a dormant
  # one still draws empty rather than waking.
  defp safe_snapshot(buffer, win_id) do
    # a block tree stays in the read model: the leaf carries its stand-in,
    # and the view copies the tree only when the stand-in changes
    case Compos.Core.BufferView.snapshot(buffer, win_id, ["render-blocks"]) do
      nil ->
        if Buffer.exists?(buffer),
          do: Buffer.render_snapshot(buffer, win_id),
          else: @empty_snapshot

      snapshot ->
        snapshot
    end
  catch
    :exit, _ -> @empty_snapshot
  end

  # render walk: gives each window its rows (a dock its share of them),
  # clamps and auto-follows the viewport top (unless manually scrolled), and
  # returns both the updated row (tops persist) and the render payload
  defp render_row(tree, rows, win_rows, frame_group, win_stacks) do
    leaves = row(tree)
    walked = Enum.map(leaves, &render_walk(&1, rows_for(leaves, &1.id, rows), win_rows, frame_group, win_stacks))
    {Enum.map(walked, &elem(&1, 0)), payload(Enum.map(walked, &elem(&1, 1)))}
  end

  defp render_walk(
         %{type: :leaf, id: id, buffer: buffer} = leaf,
         rows,
         win_rows,
         frame_group,
         win_stacks
       ) do
    # the client's measured row count for this window wins over split math:
    # line height varies per buffer, so only the client knows what fits
    rows = Map.get(win_rows, id, rows)
    previous_leaf = leaf

    # one round trip per leaf — this runs on every render of every window;
    # point/mark/cursor geometry are the WINDOW's (per-window points)
    display_updating = Events.display_updating?(buffer)
    snap = safe_snapshot(buffer, id)
    %{text: text, point: point, locals: locals} = snap
    ml = modeline_cache(locals)

    # folds put top/cursor/total in VISIBLE-line space; the scroll and
    # auto-follow math below then works unchanged. Line *numbers* stay
    # logical (folds show numbering gaps, like Emacs). The no-fold case is
    # O(log n) rope lookups from the snapshot. Fold geometry is cached per
    # window: a filter key in another pane must not rescan this buffer.
    {geometry, leaf} =
      cond do
        # a block tree renders blocks, not lines — fold geometry is the
        # line view's cost, not this one's (S16)
        Map.get(locals, "render-mode") == "blocks" ->
          {{snap.total_lines, snap.cursor_line, MapSet.new(), nil},
           Map.delete(leaf, :fold_geometry)}

        snap.hidden == [] and is_nil(snap.narrow_range) ->
          {{snap.total_lines, snap.cursor_line, MapSet.new(), nil},
           Map.delete(leaf, :fold_geometry)}

        true ->
          # The immutable rope distinguishes replacement buffers with the
          # same name/version; locals and overlays do not invalidate geometry.
          key = {buffer, Map.get(snap, :rope, text), point, snap.hidden, snap.narrow_range}

          case Map.get(leaf, :fold_geometry) do
            {^key, geometry} ->
              {geometry, leaf}

            _ ->
              geometry = visible_geometry(text, point, snap.hidden, snap.narrow_range)
              {geometry, Map.put(leaf, :fold_geometry, {key, geometry})}
          end
      end

    {total_lines, cl, hidden_lines, narrow_lines} = geometry

    # Clamped to the last SCREENFUL, not the last line. Scrolling had no upper
    # bound of its own, and clamping to total-1 still let a short buffer end up
    # with one line stranded at the top of an otherwise empty window — which
    # then persisted, because tops are written back. A window can no longer be
    # scrolled past its own content, and a reload always lands somewhere real.
    top = leaf.top |> min(max(total_lines - rows, 0)) |> max(0)

    top =
      cond do
        leaf.manual ->
          top

        cl < top or cl >= top + rows ->
          # Crossing the viewport edge recenters point, leaving room to
          # keep moving instead of pushing the window one line per key.
          max(0, min(cl - div(rows, 2), max(total_lines - rows, 0)))

        true ->
          top
      end

    rendered = %{
      type: :leaf,
      id: id,
      buffer: buffer,
      # its part of the row's width; a dock's, of the frame's height
      share: share(leaf),
      dock: Map.get(leaf, :dock, false),
      # the file this buffer visits, nil for the rest. /raw URLs and the
      # modeline read these two; the client renders no UI for them yet.
      path: snap.path,
      read_only: snap.read_only,
      # the editing state: the caret map is armed and the caret shows. In
      # the movement state the client hides the caret and the window floats.
      editing: Map.get(locals, "editing-state") == true,
      # the buffer takes the plain left and right arrows as keys in the
      # movement state (a Morg page's raw and preview tabs)
      arrow_keys: Map.get(locals, "arrow-keys") == true,
      dismissible: Map.get(locals, "dismissible") == true,
      cursor_visible:
        Map.get(locals, "dismissible") != true or
          "caret-browsing-mode" in (Map.get(locals, "minor-modes") || []),
      text: text,
      rope: Map.get(snap, :rope),
      fontification: Map.get(snap, :fontification, []),
      point: point,
      mark: snap.mark,
      version: snap.version,
      modified: snap.modified,
      mode: Map.get(locals, "mode-name") || "Fundamental",
      # what the modeline calls this buffer: project coordinates inside a
      # project, "~" for the home directory outside one. Scheme decides.
      modeline_name: Map.get(ml, "name"),
      # the same name as the spans that draw it: the buffer-name grammar
      # (editor.scm) names the classes, the client draws one span each
      modeline_name_segments: Map.get(ml, "name-segments"),
      modeline_file: Map.get(ml, "file"),
      modeline_project: Map.get(ml, "project"),
      # the state the mode line draws as key/value facts: mode, llm, lane.
      # Scheme builds them (dash--modeline-facts); each is (KEY VALUE TONE RANK).
      modeline_facts: Map.get(ml, "facts"),
      # free-form per-buffer modeline segment (agent connector, etc.)
      modeline_info: Map.get(locals, "modeline-info"),
      # the LLM tool preset alone, for a modeline too narrow for the line
      modeline_preset: Map.get(locals, "modeline-preset"),
      # the version-control change this buffer's save would amend (jj.scm)
      modeline_vcs: Map.get(locals, "modeline-vcs"),
      # the buffer's own mode-line format; nil draws the frame default,
      # which Scheme publishes as the chrome's "mode-line-format"
      mode_line_format: Map.get(locals, "mode-line-format"),
      selected: Map.get(locals, "buffer-selected", false),
      dashboard_line: Map.get(locals, "dashboard-line"),
      # the same line as keyed segments: Scheme names the classes,
      # the client draws the blocks it already knows how to draw
      dashboard_line_blocks: Map.get(locals, "dashboard-line-blocks"),
      # persistent buffer-owned context above the content. Scheme supplies
      # the text; the client only renders this generic header mechanism.
      header_line: Map.get(locals, "header-line"),
      # the same mechanism under the content — a list's key bar pins here
      footer_line: Map.get(locals, "footer-line"),
      footer_line_blocks: Map.get(locals, "footer-line-blocks"),
      # the pin: the buffer's group only when it is not the frame's. The
      # frame names its group once; a window in that group does not repeat it.
      pin: modeline_pin(Map.get(ml, "group"), frame_group),
      # Scheme selects the buffer-owned group that supplies its color.
      # The frame group remains separate context for the bottom bar.
      group_color: Map.get(ml, "group-color"),
      ts_lang: Map.get(locals, "ts-lang"),
      plain_source: Map.get(locals, "plain-source") == true,
      display_updating: display_updating or Events.display_updating?(buffer),
      overlays: snap.overlays,
      overlay_gen: snap.overlay_gen,
      hidden_lines: hidden_lines,
      narrow_lines: narrow_lines,
      line: snap.line,
      col: snap.col,
      style: Map.get(locals, "style"),
      render_mode: render_mode(locals),
      visual_line_mode: Map.get(locals, "visual-line-mode") == true,
      # hl-line-mode: the page highlights the current line unless the
      # buffer turned it off, or you are editing in it: the caret is
      # the place there, and the band is only noise
      hl_line: Map.get(locals, "hl-line-mode") != "off" and Map.get(locals, "editing-state") != true,
      blocks: blocks_leaf(locals),
      # a block tree's caret input and its reader place, both nil for a
      # tree that declares neither
      blocks_input: blocks_input(locals),
      blocks_follow: blocks_follow(locals),
      blocks_root: Map.get(locals, "render-root"),
      text_root: Map.get(locals, "render-text-root"),
      semantic_records: Map.get(locals, "render-records"),
      minor_modes: Map.get(locals, "minor-modes") || [],
      # the expanded modeline: a block tree pinned above the text,
      # rendered only while the buffer-local says so
      dash:
        if(Map.get(ml, "expanded") == true,
          do: Map.get(ml, "dash-blocks") || [],
          else: nil
        ),
      preview_authored: Map.get(locals, "preview-authored") == true,
      # an app reloads when this number changes, and only then: a keystroke
      # must not restart the app you are typing at
      app_gen: Map.get(locals, "app-generation") || 0,
      # the last message the package posted into its running app
      # (app-post!, preview.scm); a new one reaches the page with no reload
      app_message: Map.get(locals, "app-message"),
      # a live web page drawn in the window (render-mode "web", web.scm)
      web_url: Map.get(locals, "web-url"),
      top: top,
      # the payload says what the daemon knows about scroll (S1): manual
      # pins the windowed top; ctop is a client-scrolled window's pixel
      # offset, applied by the client on mount
      manual: leaf.manual,
      ctop: Map.get(leaf, :ctop, 0),
      # the last server-driven scroll of a client-scrolled window, in
      # lines: the client applies a generation it has not seen
      scroll_gen: Map.get(leaf, :scroll_gen),
      scroll_lines: Map.get(leaf, :scroll_lines, 0),
      rows: rows,
      total_lines: total_lines,
      line_numbers: Map.get(locals, "line-numbers") != "off",
      # extra CSS class on the window div (writing-mode centering etc.)
      highlighted: id in (Map.get(locals, "window-highlight-ids") || []),
      window_class: Map.get(locals, "window-class") || nil,
      # the label the window flashes as it comes to the front of its pane
      # (window-flash.scm): a chat's (WIN NONCE TITLE SUMMARY STATE), drawn
      # only in WIN
      flash:
        (case Map.get(locals, "window-flash") do
          [^id, nonce, title, summary, state] ->
            %{nonce: nonce, title: title, summary: summary, state: state}

          _ -> nil
        end),
      # how many buffers the window holds: the one it shows and the ones
      # under it. The header line shows it beside the title.
      stack: Map.get(win_stacks, id, 1),
      # inline style on the window itself. A float hands its share of the
      # frame over this way: the stylesheet cannot read a number out of a
      # display rule, but it can read a custom property.
      window_style: Map.get(locals, "window-style") || nil
    }

    # Measuring incomplete text must not recenter the saved window either.
    # The completed presentation will compute geometry once from final point.
    {if(rendered.display_updating, do: previous_leaf, else: %{leaf | top: top}), rendered}
  end

  # {visible line count, cursor's visible-line index, MapSet of hidden
  # logical line indexes}. A line is hidden when its start byte falls
  # strictly inside a hidden range (the range's own start line stays
  # visible — that's the folded headline). Ranges are clamped: they can
  # be momentarily stale after an undo swaps the rope out from under them.

  # the diff card model. The cards are a projection of the buffer text —
  # the unified diff — so the card view and the plain view read the same
  # bytes. Only the open set, git's status letters, and the watch flag come
  # from locals: the text cannot say those.
  # a rich view the mode composed as a generic block tree. The client draws
  # it and decides nothing; the core carries it and reads nothing. diff-mode
  # writes it today; any mode can.
  defp blocks_leaf(%{"render-mode" => "blocks"} = locals),
    do: Map.get(locals, "render-blocks") || []

  defp blocks_leaf(_), do: nil

  # The byte where a block tree's caret input starts. 'render-input names
  # the local that holds it, so a marker local that the buffer moves on
  # each edit stays the one authority. The view clamps the value.
  defp blocks_input(%{"render-mode" => "blocks", "render-input" => name} = locals)
       when is_binary(name) do
    case Map.get(locals, name) do
      n when is_integer(n) -> n
      _ -> nil
    end
  end

  defp blocks_input(_), do: nil

  # The reader's place in a followed block list: the client reports it
  # ('follow-place), a command asks to follow again ('follow-seq). The
  # place is stored inverted, so a cleared local means "follow".
  defp blocks_follow(%{"render-mode" => "blocks"} = locals) do
    {unstick, top, anchor, offset} =
      case Map.get(locals, "follow-place") do
        [u, t, a, o] -> {u == true, t, a, o}
        _ -> {false, 0, nil, 0}
      end

    %{
      stick: not unstick,
      top: if(is_integer(top), do: top, else: 0),
      anchor: if(is_integer(anchor), do: anchor, else: nil),
      offset: if(is_integer(offset), do: offset, else: 0),
      seq: Map.get(locals, "follow-seq") || 0
    }
  end

  defp blocks_follow(_), do: nil

  # A mode that takes a buffer over inherits the locals of the mode before
  # it, and `render-mode` says which view draws the window. "blocks" with
  # no blocks drew an empty card list over a buffer full of text: dired on
  # a directory that once held a diff went blank, with no error anywhere.
  # No blocks means nothing to draw, so the window shows its text.
  defp render_mode(%{"render-mode" => "blocks"} = locals) do
    case Map.get(locals, "render-blocks") do
      [_ | _] -> "blocks"
      other -> if Compos.Core.BufferView.big_ref?(other), do: "blocks", else: nil
    end
  end

  defp render_mode(locals), do: Map.get(locals, "render-mode")

  defp visible_geometry(text, point, hidden, narrow_range) do
    len = byte_size(text)
    starts = [0 | Enum.map(:binary.matches(text, "\n"), fn {p, _} -> p + 1 end)]
    ranges = for {s, e} <- hidden, s < len, do: {s, min(e, len)}

    hidden_lines =
      for {start, idx} <- Enum.with_index(starts),
          Enum.any?(ranges, fn {s, e} -> start > s and start <= e end),
          into: MapSet.new(),
          do: idx

    narrow_lines =
      case narrow_range do
        {s, e} when s < e ->
          {Compos.Core.Text.line_index(text, s), Compos.Core.Text.line_index(text, e - 1)}

        _ ->
          nil
      end

    {first, last} = narrow_lines || {0, length(starts) - 1}

    visible =
      first..last
      |> Enum.reject(&MapSet.member?(hidden_lines, &1))

    logical_cl = Compos.Core.Text.line_index(text, point)
    visible_cl = Enum.count(visible, &(&1 < logical_cl)) |> min(max(length(visible) - 1, 0))

    {max(length(visible), 1), visible_cl, hidden_lines, narrow_lines}
  end

  defp workspace_context do
    case Application.get_env(:compos_core, :workspace_root) do
      root when is_binary(root) ->
        %{
          root: root,
          daemon: Application.get_env(:compos_core, :name, "compos"),
          project: Application.get_env(:compos_core, :workspace_project),
          name: Application.get_env(:compos_core, :workspace_name),
          url: :persistent_term.get(:compos_editor_url, "http://localhost:4004")
        }

      _ ->
        nil
    end
  end

  # a dock has its share of the frame's rows; the row has what is left
  defp rows_for(tree, id, rows) do
    leaves = row(tree)
    docks = for %{dock: true} = d <- leaves, into: %{}, do: {d.id, max(round(rows * share(d)), 3)}

    cond do
      Map.has_key?(docks, id) -> docks[id]
      not Enum.any?(leaves, &(&1.id == id)) -> nil
      docks == %{} -> rows
      true -> max(rows - Enum.sum(Map.values(docks)), 3)
    end
  end
end
