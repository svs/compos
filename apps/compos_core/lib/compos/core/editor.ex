defmodule Compos.Core.Editor do
  @moduledoc """
  Editor state holder: frames (each a tiling window tree + minibuffer + echo
  + viewport geometry), keymap table, kill ring. **Policy-free by design** —
  every command and default keybinding is Scheme (`priv/editor.scm`); this
  process only stores state and applies small mutations. Key routing lives in
  `Compos.Core.KeyDispatch`, which runs outside this server so Scheme
  primitives can call back in without deadlock.

  A frame is one client's view: its own window tree and selection, sharing
  buffers, keymaps, faces and the kill ring with every other frame. Frame
  ids are short stable strings; window ids are integers, globally unique
  across all frames, so a bare window id always names one window.

  Window tree: `%{type: :leaf, id, buffer, top, manual}` | `%{type: :split,
  dir: :h | :v, ratio, children: [tree, tree]}`. `:h` = side-by-side.
  TODO: per-window points, window resizing.

  Calls that take a frame accept nil, resolved server-side to the
  last-active frame (the fallback for async callers with no frame context).
  """

  use GenServer

  alias Compos.Core.{Buffer, BufferStore, Candidates, Events, Frame, Session}

  # Emacs window-configuration-change-hook, by its Scheme name
  @config_hook "window-configuration-changed!"

  # every frame has its own minibuffer backing buffer, " *minibuf-<fid>*"
  # (Emacs-style: prompt input IS a buffer, so point motion, kill/yank, undo
  # and local keymaps all just work; per-frame so two prompts can be open at
  # once). Space-prefixed = hidden from buffer lists, like Emacs. The bare
  # " *minibuf*" is the shared local-KEYMAP namespace: binds and lookups on
  # any frame's minibuf buffer normalize to it, so editor.scm binds the
  # prompt keys once for all frames.
  @minibuf " *minibuf*"

  @doc "The calling frame's minibuffer buffer name."
  def minibuf_name(fid \\ nil), do: GenServer.call(__MODULE__, {:minibuf_name, fid(fid)})

  @scratch "*scratch*"
  @main_frame "f-main"
  # what a window is worth in columns before the client has measured one
  @default_cols 100

  # the keymap every read-only buffer inherits. No buffer holds this name:
  # a space prefix keeps it out of the buffer lists, as " *minibuf*" is.
  @readonly_map " *read-only*"

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

  def lookup_key(seq, fid \\ nil), do: GenServer.call(__MODULE__, {:lookup_key, seq, fid(fid)})

  @doc """
  Look SEQ up in one named keymap only — no buffer resolution, no global
  fallback, no remaps. The completion popup's map lives under the
  pseudo-buffer name `" *completion*"`.
  """
  def lookup_keymap(name, seq), do: GenServer.call(__MODULE__, {:lookup_keymap, name, seq})

  @doc "Every global binding as {key-sequence, command-name}."
  def global_keys, do: GenServer.call(__MODULE__, :global_keys)

  @doc "One buffer's local bindings as {key-sequence, command-name}."
  def local_keys(buffer), do: GenServer.call(__MODULE__, {:local_keys, buffer})
  def render_state(fid \\ nil), do: GenServer.call(__MODULE__, {:render_state, fid(fid)})

  @doc """
  Read-only view for desktop save (S15): the frame's tree with each
  leaf's top and effective per-window point, plus faces — none of
  render_state's write-back.
  """
  def desktop_view(fid \\ nil), do: GenServer.call(__MODULE__, {:desktop_view, fid(fid)})

  # frames
  @doc "Attach a client: nil -> fresh frame; known id -> reattach; unknown id -> create with it."
  def attach_frame(id), do: GenServer.call(__MODULE__, {:attach_frame, id})

  @doc "Returns {:ok, closed_minibuffer | nil} so the caller can fire on_cancel."
  def delete_frame(id), do: GenServer.call(__MODULE__, {:delete_frame, id})

  def frame_list, do: GenServer.call(__MODULE__, :frame_list)
  def last_active_frame, do: GenServer.call(__MODULE__, :last_active_frame)
  def select_frame(id), do: GenServer.call(__MODULE__, {:select_frame, id})
  def frame_of_window(win_id), do: GenServer.call(__MODULE__, {:frame_of_window, win_id})

  @doc "Bump a frame in the MRU without broadcasting — the top of every input dispatch."
  def touch_frame(id), do: GenServer.call(__MODULE__, {:touch_frame, id})

  @doc "Active minibuffer maps of every frame (Session GC roots live closures)."
  def all_minibuffers, do: GenServer.call(__MODULE__, :all_minibuffers)

  @doc "All windows across all frames, frame-MRU order: [{win_id, buffer, frame_id}]."
  def list_windows_all, do: GenServer.call(__MODULE__, :list_windows_all)

  @doc "Set any window's buffer, any frame, without selecting it."
  def window_set_buffer(win_id, buffer) do
    restoring = dormant?(buffer)
    result = GenServer.call(__MODULE__, {:window_set_buffer, win_id, buffer})
    restore_if_woken(buffer, restoring)
    result
  end

  # keymap
  def bind_key(seq, command), do: GenServer.call(__MODULE__, {:bind_key, seq, command})

  @doc "Drop the global binding for SEQ."
  def unbind_key(seq), do: GenServer.call(__MODULE__, {:unbind_key, seq})

  def local_bind_key(buffer, seq, command),
    do: GenServer.call(__MODULE__, {:local_bind_key, buffer, seq, command})

  @doc "Drop BUFFER's own binding for SEQ; the global one applies again."
  def local_unbind_key(buffer, seq),
    do: GenServer.call(__MODULE__, {:local_unbind_key, buffer, seq})

  @doc "Emacs [remap]: in BUFFER, any key that resolves to FROM runs TO instead."
  def local_remap(buffer, from, to),
    do: GenServer.call(__MODULE__, {:local_remap, buffer, from, to})

  # pending prefix + echo
  def set_pending(seq, fid \\ nil), do: GenServer.call(__MODULE__, {:set_pending, seq, fid(fid)})
  def set_echo(msg, fid \\ nil), do: GenServer.call(__MODULE__, {:set_echo, msg, fid(fid)})

  @doc "The calling frame's raw Emacs prefix argument, or nil."
  def prefix_arg(fid \\ nil), do: GenServer.call(__MODULE__, {:prefix_arg, fid(fid)})

  def set_prefix_arg(arg, fid \\ nil),
    do: GenServer.call(__MODULE__, {:set_prefix_arg, arg, fid(fid)})

  @doc "Record the command and clear its one-shot prefix unless KEEP_PREFIX is true."
  def finish_command(name, keep_prefix, fid \\ nil),
    do: GenServer.call(__MODULE__, {:finish_command, name, keep_prefix, fid(fid)})

  @doc """
  Arm a one-shot key capture: the next complete key sequence runs COMMAND
  instead of its own binding, and `last_keys/0` reports the sequence. nil
  disarms. Scheme owns what the capture means (describe-key reads it).
  """
  def set_key_capture(command, fid \\ nil),
    do: GenServer.call(__MODULE__, {:set_key_capture, command, fid(fid)})

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

  # minibuffer
  def minibuffer_activate(prompt, candidates, on_confirm, on_complete \\ nil) do
    minibuffer_activate_full(prompt, candidates, %{
      on_confirm: on_confirm,
      on_complete: on_complete
    })
  end

  @doc "Handlers: %{on_confirm:, on_complete:, on_change:, on_cancel:} (all optional closures)."
  def minibuffer_activate_full(prompt, candidates, handlers, fid \\ nil),
    do: GenServer.call(__MODULE__, {:mb_activate, prompt, candidates, handlers, fid(fid)})

  def minibuffer_set_input(input, fid \\ nil),
    do: GenServer.call(__MODULE__, {:mb_input, input, fid(fid)})

  def minibuffer_set_candidates(candidates, fid \\ nil),
    do: GenServer.call(__MODULE__, {:mb_candidates, candidates, fid(fid)})

  def minibuffer_move_sel(delta, fid \\ nil),
    do: GenServer.call(__MODULE__, {:mb_move_sel, delta, fid(fid)})

  @doc "Currently selected candidate label (after fuzzy filter), or nil."
  def minibuffer_selected(fid \\ nil), do: GenServer.call(__MODULE__, {:mb_selected, fid(fid)})

  def minibuffer_close(fid \\ nil), do: GenServer.call(__MODULE__, {:mb_close, fid(fid)})

  @doc "Re-read input from the minibuf buffer. :unchanged | {:changed, input}."
  def minibuffer_sync_input(fid \\ nil),
    do: GenServer.call(__MODULE__, {:mb_sync_input, fid(fid)})

  @doc "While false, current_buffer ignores an active minibuffer (handler escape hatch)."
  def set_mb_redirect(bool, fid \\ nil),
    do: GenServer.call(__MODULE__, {:mb_redirect, bool, fid(fid)})

  @doc "Record the group context this frame stands in; nil clears it."
  def set_frame_group_label(label, fid \\ nil),
    do: GenServer.call(__MODULE__, {:set_group_label, label, fid(fid)})

  @doc "Record the group label and accent color for this frame."
  def set_frame_group_style(label, color, fid \\ nil),
    do: GenServer.call(__MODULE__, {:set_group_style, label, color, fid(fid)})

  @doc "The tersest key bound to COMMAND: BUFFER's keymap first, then the global one."
  def key_for_command(command, buffer \\ nil),
    do: GenServer.call(__MODULE__, {:key_for_command, command, buffer})

  @doc "Buffers in most-recently-displayed order (Emacs buffer list)."
  def buffer_mru, do: GenServer.call(__MODULE__, :buffer_mru)

  @doc "Previous buffers for one window, most recently displayed first."
  def window_buffer_history(win \\ nil, fid \\ nil),
    do: GenServer.call(__MODULE__, {:window_buffer_history, win, fid(fid)})

  def mru_all, do: GenServer.call(__MODULE__, :mru_all)
  def mru_note_group(g), do: GenServer.call(__MODULE__, {:mru_note_group, g})

  # Emacs last-command (yank-pop and friends dispatch on it)
  def set_last_command(name), do: GenServer.call(__MODULE__, {:set_last_command, name})
  def last_command, do: GenServer.call(__MODULE__, :last_command)

  # the key sequence whose keymap lookup ran the current command — one
  # command bound to many keys (the switcher's type-to-narrow) reads it
  def set_last_keys(seq), do: GenServer.call(__MODULE__, {:set_last_keys, seq})
  def last_keys, do: GenServer.call(__MODULE__, :last_keys)

  # commands that manage their own undo boundaries (Scheme registers them;
  # KeyDispatch skips its automatic break for these — "undo" is one from birth)
  def add_undo_exempt(name), do: GenServer.call(__MODULE__, {:add_undo_exempt, name})
  def undo_exempt?(name), do: GenServer.call(__MODULE__, {:undo_exempt?, name})

  # completion-at-point popup (anchored at a buffer position)
  def completion_show(start, candidates, fid \\ nil),
    do: GenServer.call(__MODULE__, {:completion_show, start, candidates, fid(fid)})

  def completion_move(delta, fid \\ nil),
    do: GenServer.call(__MODULE__, {:completion_move, delta, fid(fid)})

  @doc "Narrow the open popup by prefix typed since it opened."
  def completion_query(q, fid \\ nil),
    do: GenServer.call(__MODULE__, {:completion_query, q, fid(fid)})

  @doc "Accept the selection: returns {start, label} and clears, or nil."
  def completion_accept(fid \\ nil),
    do: GenServer.call(__MODULE__, {:completion_accept, fid(fid)})

  def completion_dismiss(fid \\ nil),
    do: GenServer.call(__MODULE__, {:completion_dismiss, fid(fid)})

  # kill ring
  def kill_push(text), do: GenServer.call(__MODULE__, {:kill_push, text})
  def kill_top, do: GenServer.call(__MODULE__, :kill_top)
  def kill_nth(i), do: GenServer.call(__MODULE__, {:kill_nth, i})
  def kill_size, do: GenServer.call(__MODULE__, :kill_size)

  # faces: name -> attrs map, merged; frontends map them to CSS vars
  def set_face(name, attrs), do: GenServer.call(__MODULE__, {:set_face, name, attrs})
  @doc "Forget every attribute of a face. load-theme clears before it applies."
  def clear_face(name), do: GenServer.call(__MODULE__, {:clear_face, name})
  @doc "The face table: name -> attrs."
  def faces, do: GenServer.call(__MODULE__, :faces)

  # styles: name -> a stylesheet the mode wrote; the page renders them all.
  # Faces carry colors; styles carry structure (grids, cards, spacing).
  def set_style(name, css), do: GenServer.call(__MODULE__, {:set_style, name, css})

  # windows
  def split(dir, ratio \\ 0.5, fid \\ nil) when dir in [:h, :v],
    do: GenServer.call(__MODULE__, {:split, dir, ratio, fid(fid)})

  def delete_window(fid \\ nil), do: GenServer.call(__MODULE__, {:delete_window, fid(fid)})
  def delete_window_by_id(id), do: GenServer.call(__MODULE__, {:delete_window_by_id, id})
  def list_windows(fid \\ nil), do: GenServer.call(__MODULE__, {:list_windows, fid(fid)})
  def window_rects(fid \\ nil), do: GenServer.call(__MODULE__, {:window_rects, fid(fid)})

  @doc "Selecting a window selects its frame (Emacs: windows live on frames)."
  def set_active(id), do: GenServer.call(__MODULE__, {:set_active, id})
  def active_window(fid \\ nil), do: GenServer.call(__MODULE__, {:active_window, fid(fid)})

  def delete_other_windows(fid \\ nil),
    do: GenServer.call(__MODULE__, {:delete_other_windows, fid(fid)})

  def other_window(fid \\ nil), do: GenServer.call(__MODULE__, {:other_window, fid(fid)})

  @doc """
  Show BUFFER in the active window WITHOUT touching the MRU ring — candidate
  preview must not reorder the buffer history. WIN previews into that window
  instead (the modal switcher previews into its home window, not its own).
  """
  def preview_buffer(buffer, fid \\ nil, win \\ nil) do
    restoring = dormant?(buffer)
    result = GenServer.call(__MODULE__, {:preview_buffer, buffer, fid(fid), win})
    restore_if_woken(buffer, restoring)
    result
  end

  @doc "A buffer is dying: swap every window showing it (any frame) onto a live one."
  def release_buffer(buffer), do: GenServer.call(__MODULE__, {:release_buffer, buffer})

  @doc """
  What is on screen: `%{visible: buffers-in-any-window, current: each
  frame's active-window buffer}`. The Reactor gates background work on it.
  """
  def visible_buffers, do: GenServer.call(__MODULE__, :visible_buffers)

  @doc "Carry windows, keymaps, and MRU state across a buffer rename."
  def rename_buffer(old, new), do: GenServer.call(__MODULE__, {:rename_buffer, old, new})

  def set_window_buffer(buffer, fid \\ nil) do
    restoring = dormant?(buffer)
    result = GenServer.call(__MODULE__, {:set_window_buffer, buffer, fid(fid)})
    restore_if_woken(buffer, restoring)
    result
  end

  defp dormant?(buffer), do: not Buffer.exists?(buffer) and BufferStore.known?(buffer)

  defp restore_if_woken(buffer, true) do
    # Scheme completes this in its switch-to-buffer! wrapper, and says so by
    # setting :compos_inline_runtime_restore in the calling process. Testing
    # the Session pid instead stopped working when Scheme moved to lanes: an
    # eval runs in a Lane worker, never in Session itself, so the guard was
    # always true and every Scheme-driven wake restored the buffer twice.
    if Buffer.exists?(buffer) and not Process.get(:compos_inline_runtime_restore, false),
      do: Compos.Core.restore_runtime(buffer)
  end

  defp restore_if_woken(_buffer, false), do: :ok

  @doc "Replace a frame's window tree from a {:leaf, name} | {:split, dir, a, b} spec."
  def restore_tree(spec, active_buffer, fid \\ nil),
    do: GenServer.call(__MODULE__, {:restore_tree, spec, active_buffer, fid(fid)})

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
  def window_rows(fid \\ nil), do: GenServer.call(__MODULE__, {:window_rows, fid(fid)})

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
    Compos.Core.create_buffer(@scratch)

    frame = %{
      id: @main_frame,
      tree: %{type: :leaf, id: 1, buffer: @scratch, history: [], top: 0, manual: false},
      active: 1,
      pending: [],
      prefix_arg: nil,
      key_capture: nil,
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
       # the one window whose point is swapped into its buffer (the selected
       # window of the last-active frame): {frame_id, win_id, buffer}
       swapped: nil,
       next_win: 2,
       kill_ring: [],
       keymap: %{},
       modeline_extra: "",
       faces: %{},
       styles: %{},
       local_keymaps: %{},
       remaps: %{},
       last_command: "",
       last_keys: [],
       undo_exempt: MapSet.new(["undo"]),
       mru: Enum.uniq([@scratch | Compos.Core.BufferStore.history()]),
       # frame id => text a command wants on that client's OS clipboard
       clips: %{},
       # frame id => URL for same-tab navigation on the next client render
       navigations: %{},
       # frame id => a Selection.modify request for the editable surface
       selects: %{}
     }}
  end

  # --- frame lifecycle --------------------------------------------------------

  @impl true
  def handle_call({:attach_frame, id}, _from, state) do
    case state.frames[id] do
      %{} ->
        {:reply, {:ok, id}, state |> bump_frame(id) |> resync_swap()}

      nil ->
        id = if valid_frame_id?(id), do: id, else: gen_frame_id()
        buffer = List.first(Enum.filter(state.mru, &Buffer.exists?/1)) || live_scratch()

        frame = %{
          id: id,
          tree: %{
            type: :leaf,
            id: state.next_win,
            buffer: buffer,
            history: [],
            top: 0,
            manual: false
          },
          active: state.next_win,
          pending: [],
          prefix_arg: nil,
          key_capture: nil,
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
        changed({:ok, id}, state |> bump_frame(id) |> resync_swap(), id)
    end
  end

  def handle_call({:delete_frame, id}, _from, state) do
    cond do
      state.frames[id] == nil ->
        {:reply, {:error, :no_frame}, state}

      map_size(state.frames) == 1 ->
        {:reply, {:error, :last_frame}, state}

      true ->
        # hand the closed prompt back so the caller can fire on_cancel
        # (this server must never call into Session — deadlock)
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

  def handle_call({:window_set_buffer, win_id, buffer}, _from, state) do
    case find_window_frame(state, win_id) do
      nil ->
        {:reply, {:error, :no_window}, state}

      f ->
        Compos.Core.ensure_buffer(buffer)
        Buffer.touch(buffer)
        leaf = find_leaf(f.tree, win_id)
        tree = replace_leaf(f.tree, win_id, visit_buffer(leaf, buffer))
        mru = Enum.take([buffer | List.delete(state.mru, buffer)], 50)
        changed(:ok, resync_swap(put_frame(%{state | mru: mru}, %{f | tree: tree})), f.id)
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

  def handle_call({:lookup_key, seq, fid}, _from, state) do
    f = frame(state, fid)
    buffer = if f.minibuffer, do: minibuf_of(f), else: find_leaf(f.tree, f.active).buffer
    local = Map.get(state.local_keymaps, keymap_key(buffer), %{})

    # a read-only buffer takes a third map between the local one and the
    # global one. What it holds is Scheme's business (dup #22): editor.scm
    # binds q there, so every buffer you cannot type in quits the same way.
    # The mode's own map still wins — code-mode keeps q for its exit. The
    # buffer only answers read_only? for a key that map claims, so the
    # other 200 keys per minute cost one map lookup.
    ro = if readonly_hit?(state, seq, buffer), do: readonly_map(state), else: %{}

    reply =
      cond do
        Map.has_key?(local, seq) -> {:command, local[seq]}
        Map.has_key?(ro, seq) -> {:command, ro[seq]}
        Map.has_key?(state.keymap, seq) -> {:command, state.keymap[seq]}
        Enum.any?(Map.keys(local), &List.starts_with?(&1, seq)) -> :prefix
        Enum.any?(Map.keys(ro), &List.starts_with?(&1, seq)) -> :prefix
        Enum.any?(Map.keys(state.keymap), &List.starts_with?(&1, seq)) -> :prefix
        true -> :none
      end

    # Emacs command remapping: the buffer substitutes its own command for
    # a resolved one — every key bound to the original follows, arrows and
    # C-n alike, including user rebindings
    reply =
      case reply do
        {:command, name} ->
          {:command, state.remaps |> Map.get(buffer, %{}) |> Map.get(name, name)}

        other ->
          other
      end

    {:reply, reply, state}
  end

  def handle_call({:lookup_keymap, name, seq}, _from, state) do
    local = Map.get(state.local_keymaps, name, %{})

    reply =
      cond do
        Map.has_key?(local, seq) -> {:command, local[seq]}
        Enum.any?(Map.keys(local), &List.starts_with?(&1, seq)) -> :prefix
        true -> :none
      end

    {:reply, reply, state}
  end

  def handle_call({:desktop_view, fid}, _from, state) do
    f = frame(state, fid)

    active =
      case find_leaf(f.tree, f.active) do
        %{buffer: b} -> b
        _ -> nil
      end

    {:reply, %{tree: dtree(f.tree), active_buffer: active, faces: state.faces}, state}
  end

  def handle_call({:local_remap, buffer, from, to}, _from, state) do
    remaps = Map.update(state.remaps, buffer, %{from => to}, &Map.put(&1, from, to))
    {:reply, :ok, %{state | remaps: remaps}}
  end

  def handle_call({:local_bind_key, buffer, seq, command}, _from, state) do
    buffer = keymap_key(buffer)

    local_keymaps =
      Map.update(state.local_keymaps, buffer, %{seq => command}, &Map.put(&1, seq, command))

    {:reply, :ok, %{state | local_keymaps: local_keymaps}}
  end

  def handle_call({:local_unbind_key, buffer, seq}, _from, state) do
    buffer = keymap_key(buffer)
    local_keymaps = Map.update(state.local_keymaps, buffer, %{}, &Map.delete(&1, seq))
    {:reply, :ok, %{state | local_keymaps: local_keymaps}}
  end

  def handle_call({:render_state, fid}, _from, state) do
    f = frame(state, fid)
    {tree, rendered} = render_walk(f.tree, f.total_rows, f.win_rows, Map.get(f, :group_label))
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
       which_key: which_key(state, f),
       completion: f.completion && render_completion(f.completion),
       echo: f.echo,
       workspace: workspace_context(),
       modeline_extra: state.modeline_extra,
       faces: state.faces,
       styles: state.styles
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
  def handle_call({:set_window_cols, map, fid}, _from, state) when is_map(map) do
    f = frame(state, fid)

    if Map.get(f, :win_cols, %{}) == map,
      do: {:reply, false, state},
      else: {:reply, true, put_frame(state, Map.put(f, :win_cols, map))}
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
      for [id, _buffer, _x, _y, width, _height] <- leaf_rects(f.tree, {0.0, 0.0, 1.0, 1.0}),
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
        leaf =
          if preview?(leaf.buffer) do
            top = max(Map.get(leaf, :ctop, 0) + delta * @preview_line_px, 0)
            leaf |> Map.put(:ctop, top) |> Map.put(:manual, true)
          else
            %{leaf | top: max(leaf.top + delta, 0), manual: true}
          end

        changed(:ok, put_frame(state, %{f | tree: replace_leaf(f.tree, id, leaf)}), f.id)
    end
  end

  # the render modes the client draws in an iframe
  defp preview?(buffer) do
    try do
      Buffer.locals(buffer)["render-mode"] in ["html", "markdown", "app", "file"]
    catch
      :exit, _ -> false
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

  # Release every window from BUFFER before it dies. Remove its windows when
  # another WORK window can preserve the frame: a popup floats over the
  # frame and cannot, so a listing under a peek falls to its next buffer
  # instead of leaving the peek as the only window. A sole window needs a
  # live buffer.
  def handle_call({:release_buffer, buffer}, _from, state) do
    visible = Enum.flat_map(state.frames, fn {_id, f} -> visible_buffers(f.tree) end)

    fallback =
      Enum.find(state.mru, fn b ->
        b != buffer and b not in visible and Buffer.exists?(b)
      end) ||
        Enum.find(state.mru, fn b ->
          b != buffer and Buffer.exists?(b)
        end) || live_scratch()

    frames =
      Map.new(state.frames, fn {id, f} ->
        victim_ids = wins_showing(f.tree, buffer)

        survivors =
          f.tree
          |> leaf_ids_buffers()
          |> Enum.reject(fn {_id, b} -> b == buffer or popup_buffer?(b) end)

        cond do
          victim_ids == [] ->
            {id, f}

          survivors != [] ->
            Enum.each(victim_ids, fn win ->
              wp_safely(fn -> Buffer.drop_win_point(buffer, win) end)
            end)

            tree = Enum.reduce(victim_ids, f.tree, &remove_leaf(&2, &1))
            active = if f.active in victim_ids, do: first_leaf(tree).id, else: f.active
            {id, %{f | tree: tree, active: active}}

          true ->
            keep = if f.active in victim_ids, do: f.active, else: hd(victim_ids)
            remove = List.delete(victim_ids, keep)

            Enum.each(remove, fn win ->
              wp_safely(fn -> Buffer.drop_win_point(buffer, win) end)
            end)

            tree = Enum.reduce(remove, f.tree, &remove_leaf(&2, &1))
            {id, %{f | tree: release_buffer_from_tree(tree, buffer, fallback), active: keep}}
        end
      end)

    changed(:ok, %{state | frames: frames, mru: List.delete(state.mru, buffer)})
  end

  def handle_call({:rename_buffer, old, new}, _from, state) do
    frames =
      Map.new(state.frames, fn {id, f} -> {id, %{f | tree: swap_buffer(f.tree, old, new)}} end)

    keymaps =
      state.local_keymaps
      |> Map.put(new, Map.get(state.local_keymaps, old, %{}))
      |> Map.delete(old)

    remaps = state.remaps |> Map.put(new, Map.get(state.remaps, old, %{})) |> Map.delete(old)
    mru = state.mru |> Enum.map(&if(&1 == old, do: new, else: &1)) |> Enum.uniq()
    changed(:ok, %{state | frames: frames, local_keymaps: keymaps, remaps: remaps, mru: mru})
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

  def handle_call({:window_rows, fid}, _from, state) do
    f = frame(state, fid)

    rows =
      Map.get(f.win_rows, f.active) ||
        rows_for(f.tree, f.active, f.total_rows) || f.total_rows

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

  def handle_call({:bind_key, seq, command}, _from, state),
    do: {:reply, :ok, %{state | keymap: Map.put(state.keymap, seq, command)}}

  def handle_call({:unbind_key, seq}, _from, state),
    do: {:reply, :ok, %{state | keymap: Map.delete(state.keymap, seq)}}

  # no-op writes must not broadcast — echo("")/pending([]) fire on every key
  def handle_call({:set_pending, seq, fid}, _from, state) do
    f = frame(state, fid)

    if f.pending == seq,
      do: {:reply, :ok, state},
      else: changed(:ok, put_frame(state, %{f | pending: seq}), f.id)
  end

  def handle_call({:prefix_arg, fid}, _from, state),
    do: {:reply, Map.get(frame(state, fid), :prefix_arg), state}

  def handle_call({:set_prefix_arg, arg, fid}, _from, state) do
    f = frame(state, fid)
    arg = if arg in [nil, false], do: nil, else: arg
    {:reply, :ok, put_frame(state, Map.put(f, :prefix_arg, arg))}
  end

  def handle_call({:finish_command, name, keep_prefix, fid}, _from, state) do
    f = frame(state, fid)
    f = if keep_prefix, do: f, else: Map.put(f, :prefix_arg, nil)
    {:reply, :ok, %{put_frame(state, f) | last_command: name}}
  end

  # No render depends on the capture flag, so it never marks the frame
  # changed — an armed capture must not cost every client a repaint.
  def handle_call({:set_key_capture, command, fid}, _from, state) do
    f = frame(state, fid)
    command = if command in [nil, false], do: nil, else: command
    {:reply, :ok, put_frame(state, Map.put(f, :key_capture, command))}
  end

  def handle_call({:set_transient, menu, fid}, _from, state) do
    f = frame(state, fid)
    menu = if menu in [nil, false], do: nil, else: menu

    if Map.get(f, :transient) == menu,
      do: {:reply, :ok, state},
      else: changed(:ok, put_frame(state, Map.merge(f, %{transient: menu, pending: []})), f.id)
  end

  def handle_call({:set_echo, msg, fid}, _from, state) do
    f = frame(state, fid)

    if f.echo == msg,
      do: {:reply, :ok, state},
      else: changed(:ok, put_frame(state, %{f | echo: msg}), f.id)
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

  def handle_call({:mb_activate, prompt, candidates, handlers, fid}, _from, state) do
    f = frame(state, fid)

    mb =
      %{
        on_confirm: nil,
        on_complete: nil,
        on_change: nil,
        on_cancel: nil,
        on_collect: nil,
        input: "",
        filter: true,
        match_hint: false,
        style: nil
      }
      |> Map.merge(handlers)
      |> Map.put(:prompt, prompt)

    reset_minibuf_buffer(minibuf_of(f), mb.input)

    mb =
      Map.put(
        mb,
        :list,
        Candidates.new(candidates, query: mb_query(mb), match_hint: mb.match_hint)
      )

    changed(:ok, put_frame(state, %{f | minibuffer: mb}), f.id)
  end

  def handle_call({:mb_input, input, fid}, _from, state) do
    case frame(state, fid) do
      %{minibuffer: %{} = mb} = f ->
        reset_minibuf_buffer(minibuf_of(f), input)
        changed(:ok, put_frame(state, %{f | minibuffer: put_mb_input(mb, input)}), f.id)

      _ ->
        {:reply, {:error, :inactive}, state}
    end
  end

  # pull the input back out of the minibuffer buffer after keys edited it
  # (self-insert, DEL, yank, undo — anything); requery candidates on change
  def handle_call({:mb_sync_input, fid}, _from, state) do
    case frame(state, fid) do
      %{minibuffer: %{} = mb} = f ->
        input = Buffer.text(minibuf_of(f))

        if input == mb.input,
          do: {:reply, :unchanged, state},
          else:
            changed(
              {:changed, input},
              put_frame(state, %{f | minibuffer: put_mb_input(mb, input)}),
              f.id
            )

      _ ->
        {:reply, :unchanged, state}
    end
  end

  def handle_call({:mb_candidates, candidates, fid}, _from, state) do
    case frame(state, fid) do
      %{minibuffer: %{} = mb} = f ->
        list = mb.list |> Candidates.put_items(candidates) |> Candidates.put_query(mb_query(mb))
        changed(:ok, put_frame(state, %{f | minibuffer: %{mb | list: list}}), f.id)

      _ ->
        {:reply, {:error, :inactive}, state}
    end
  end

  def handle_call({:mb_move_sel, delta, fid}, _from, state) do
    case frame(state, fid) do
      %{minibuffer: %{} = mb} = f ->
        # the prompt holds the selection (a directory input): the first move
        # down takes it to the first candidate, it does not skip one
        delta = if prompt_preselected?(mb) and delta > 0, do: delta - 1, else: delta

        changed(
          :ok,
          put_frame(state, %{f | minibuffer: %{mb | list: Candidates.move(mb.list, delta)}}),
          f.id
        )

      _ ->
        {:reply, {:error, :inactive}, state}
    end
  end

  def handle_call({:mb_selected, fid}, _from, state) do
    case frame(state, fid) do
      %{minibuffer: %{} = mb} -> {:reply, Candidates.selected(mb.list), state}
      _ -> {:reply, nil, state}
    end
  end

  # returns the minibuffer map (handlers + :selected/:total/:sel_touched) or nil
  def handle_call({:mb_close, fid}, _from, state) do
    f = frame(state, fid)

    reply =
      f.minibuffer &&
        f.minibuffer
        |> Map.put(:selected, Candidates.selected(f.minibuffer.list))
        |> Map.put(:total, Candidates.total(f.minibuffer.list))
        |> Map.put(:sel_touched, f.minibuffer.list.touched)

    changed(reply, put_frame(state, %{f | minibuffer: nil}), f.id)
  end

  def handle_call(:buffer_mru, _from, state) do
    known = MapSet.new(Compos.Core.buffer_names())
    live = Enum.filter(state.mru, fn b -> is_binary(b) and MapSet.member?(known, b) end)
    rest = Compos.Core.buffer_names() -- live

    # space-prefixed buffers are internal (the minibuf), hidden like Emacs
    {:reply, Enum.reject(live ++ Enum.sort(rest), &String.starts_with?(&1, " ")), state}
  end

  def handle_call({:window_buffer_history, win, fid}, _from, state) do
    f = frame(state, fid)
    leaf = find_leaf(f.tree, win || f.active)
    known = MapSet.new(Compos.Core.buffer_names())

    history =
      if leaf do
        leaf
        |> Map.get(:history, [])
        |> Enum.filter(&(is_binary(&1) and MapSet.member?(known, &1)))
        |> Enum.reject(&String.starts_with?(&1, " "))
      else
        []
      end

    {:reply, history, state}
  end

  # the WHOLE history, group marks included: a group switch is an entry
  # like any buffer visit, so one stream ranks every place you went
  def handle_call(:mru_all, _from, state) do
    rows =
      Enum.flat_map(state.mru, fn
        {:group, g} -> [["group", g]]
        b when is_binary(b) -> if b in Compos.Core.buffer_names(), do: [["buffer", b]], else: []
        # anything else is not a place the user went. Drop it, never raise
        # on it: this runs inside Editor.handle_call, and a raise here kills
        # the Editor and takes every buffer's local keymap with it. A chat
        # that loses its keymap stops sending on RET.
        _ -> []
      end)

    {:reply, rows, state}
  end

  def handle_call({:mru_note_group, g}, _from, state),
    do: changed(:ok, bump_mru(state, {:group, g}))

  def handle_call({:set_last_command, name}, _from, state),
    do: {:reply, :ok, %{state | last_command: name}}

  def handle_call(:last_command, _from, state), do: {:reply, state.last_command, state}

  def handle_call({:set_last_keys, seq}, _from, state),
    do: {:reply, :ok, %{state | last_keys: seq}}

  def handle_call(:last_keys, _from, state), do: {:reply, state.last_keys, state}

  def handle_call({:add_undo_exempt, name}, _from, state),
    do: {:reply, :ok, %{state | undo_exempt: MapSet.put(state.undo_exempt, name)}}

  def handle_call({:undo_exempt?, name}, _from, state),
    do: {:reply, MapSet.member?(state.undo_exempt, name), state}

  def handle_call({:completion_show, start, candidates, fid}, _from, state) do
    f = frame(state, fid)

    case Candidates.normalize(candidates) do
      [] ->
        changed(:ok, put_frame(state, %{f | completion: nil}), f.id)

      _ ->
        changed(
          :ok,
          put_frame(state, %{f | completion: %{start: start, list: Candidates.new(candidates)}}),
          f.id
        )
    end
  end

  def handle_call({:completion_move, delta, fid}, _from, state) do
    case frame(state, fid) do
      %{completion: %{} = c} = f ->
        changed(
          :ok,
          put_frame(state, %{f | completion: %{c | list: Candidates.move(c.list, delta)}}),
          f.id
        )

      _ ->
        {:reply, :ok, state}
    end
  end

  # narrow the popup in place as the user types — no source re-query
  def handle_call({:completion_query, q, fid}, _from, state) do
    case frame(state, fid) do
      %{completion: %{} = c} = f ->
        list = Candidates.put_query(c.list, q)

        if Candidates.total(list) == 0,
          do: changed(:ok, put_frame(state, %{f | completion: nil}), f.id),
          else: changed(:ok, put_frame(state, %{f | completion: %{c | list: list}}), f.id)

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:completion_accept, fid}, _from, state) do
    case frame(state, fid) do
      %{completion: %{} = c} = f ->
        reply =
          case Candidates.selected(c.list) do
            nil -> nil
            label -> {c.start, label}
          end

        changed(reply, put_frame(state, %{f | completion: nil}), f.id)

      _ ->
        {:reply, nil, state}
    end
  end

  def handle_call({:completion_dismiss, fid}, _from, state) do
    f = frame(state, fid)
    changed(:ok, put_frame(state, %{f | completion: nil}), f.id)
  end

  # every global binding, as {"C-x C-f", "find-file"} — apropos searches
  # keys, and 249 bindings existed with nothing that could look one up
  def handle_call(:global_keys, _from, state) do
    {:reply, Enum.map(state.keymap, fn {seq, cmd} -> {Enum.join(seq, " "), cmd} end), state}
  end

  # one buffer's own bindings, as {"RET", "ibuffer-visit"} — describe-mode
  # reads the keymap the buffer really has, not a copy in the mode's source
  def handle_call({:local_keys, buffer}, _from, state) do
    # a read-only buffer really does answer to the read-only map as well,
    # and its own map wins — describe-mode must show the same ladder
    ro = if read_only_buffer?(buffer), do: readonly_map(state), else: %{}

    keys =
      ro
      |> Map.merge(Map.get(state.local_keymaps, keymap_key(buffer), %{}))
      |> Enum.map(fn {seq, cmd} -> {Enum.join(seq, " "), cmd} end)

    {:reply, keys, state}
  end

  def handle_call({:key_for_command, command, buffer}, _from, state) do
    # several keys may run one command (C-n and <down>) — show the tersest.
    # A buffer's own keymap counts beside the global one, so a mode's
    # binding answers for the buffers that wear the mode.
    local =
      if is_binary(buffer),
        do: Map.get(state.local_keymaps, keymap_key(buffer), %{}),
        else: %{}

    reply =
      (Enum.to_list(local) ++ Enum.to_list(state.keymap))
      |> Enum.filter(fn {_seq, cmd} -> cmd == command end)
      |> Enum.map(fn {seq, _} -> Enum.join(seq, " ") end)
      |> Enum.min_by(&{String.length(&1), &1}, fn -> "" end)

    {:reply, reply, state}
  end

  def handle_call({:kill_push, text}, _from, state),
    do: changed(:ok, %{state | kill_ring: Enum.take([text | state.kill_ring], 60)})

  def handle_call({:set_face, name, attrs}, _from, state) do
    faces = Map.update(state.faces, name, attrs, &Map.merge(&1, attrs))
    changed(:ok, %{state | faces: faces})
  end

  def handle_call(:faces, _from, state), do: {:reply, state.faces, state}

  def handle_call({:clear_face, name}, _from, state) do
    if Map.has_key?(state.faces, name),
      do: changed(:ok, %{state | faces: Map.delete(state.faces, name)}),
      else: {:reply, :ok, state}
  end

  def handle_call({:set_style, name, css}, _from, state),
    do: changed(:ok, %{state | styles: Map.put(state.styles, name, css)})

  def handle_call(:kill_top, _from, state),
    do: {:reply, List.first(state.kill_ring, ""), state}

  def handle_call({:kill_nth, i}, _from, state),
    do: {:reply, Enum.at(state.kill_ring, i, ""), state}

  def handle_call(:kill_size, _from, state), do: {:reply, length(state.kill_ring), state}

  def handle_call({:split, dir, ratio, fid}, _from, state) do
    f = frame(state, fid)
    old = find_leaf(f.tree, f.active)

    new_leaf = %{
      type: :leaf,
      id: state.next_win,
      buffer: old.buffer,
      history: Map.get(old, :history, []),
      top: old.top,
      manual: false
    }

    split = %{type: :split, dir: dir, ratio: ratio, children: [old, new_leaf]}
    tree = replace_leaf(f.tree, f.active, split)

    # the new window starts at the old one's point and diverges from here
    # (Emacs split-window)
    if Buffer.exists?(old.buffer),
      do:
        wp_safely(fn ->
          Buffer.set_win_point(old.buffer, new_leaf.id, Buffer.win_point(old.buffer, old.id))
        end)

    changed(:ok, put_frame(%{state | next_win: state.next_win + 1}, %{f | tree: tree}), f.id)
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
    do: {:reply, leaf_rects(frame(state, fid).tree, {0.0, 0.0, 1.0, 1.0}), state}

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

  def handle_call({:delete_window, fid}, _from, state) do
    f = frame(state, fid)
    leaf = find_leaf(f.tree, f.active)

    case remove_leaf(f.tree, f.active) do
      nil ->
        {:reply, {:error, :sole_window}, state}

      tree ->
        if Buffer.exists?(leaf.buffer),
          do: wp_safely(fn -> Buffer.drop_win_point(leaf.buffer, leaf.id) end)

        changed(
          :ok,
          state |> put_frame(%{f | tree: tree, active: first_leaf(tree).id}) |> resync_swap(),
          f.id
        )
    end
  end

  def handle_call({:delete_other_windows, fid}, _from, state) do
    f = frame(state, fid)
    leaf = find_leaf(f.tree, f.active)

    for {win, buf} <- leaf_ids_buffers(f.tree), win != leaf.id, Buffer.exists?(buf) do
      wp_safely(fn -> Buffer.drop_win_point(buf, win) end)
    end

    changed(:ok, state |> put_frame(%{f | tree: leaf}) |> resync_swap(), f.id)
  end

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
    Compos.Core.ensure_buffer(buffer)
    Buffer.touch(buffer)
    f = frame(state, fid)
    leaf = find_leaf(f.tree, f.active)
    tree = replace_leaf(f.tree, f.active, visit_buffer(leaf, buffer))
    mru = Enum.take([buffer | List.delete(state.mru, buffer)], 50)
    changed(:ok, resync_swap(put_frame(%{state | mru: mru}, %{f | tree: tree})), f.id)
  end

  def handle_call({:preview_buffer, buffer, fid, win}, _from, state) do
    if Compos.Core.Buffer.exists?(buffer) or Compos.Core.BufferStore.known?(buffer) do
      f = frame(state, fid)
      target = win || f.active

      case find_leaf(f.tree, target) do
        nil ->
          {:reply, {:error, :no_window}, state}

        leaf ->
          Compos.Core.ensure_buffer(buffer)
          Buffer.touch(buffer)
          origin = Map.get(leaf, :preview_origin, leaf.buffer)

          previewed =
            %{leaf | buffer: buffer, top: 0, manual: false}
            |> then(fn next ->
              if buffer == origin,
                do: Map.delete(next, :preview_origin),
                else: Map.put(next, :preview_origin, origin)
            end)

          tree = replace_leaf(f.tree, target, previewed)
          changed(:ok, put_frame(state, %{f | tree: tree}))
      end
    else
      {:reply, {:error, :no_buffer}, state}
    end
  end

  def handle_call({:restore_tree, spec, active_buffer, fid}, _from, state) do
    f = frame(state, fid)

    # the old windows are gone — their stored points go with them
    Enum.each(leaf_ids_buffers(f.tree), fn {id, buffer} ->
      if Buffer.exists?(buffer), do: wp_safely(fn -> Buffer.drop_win_point(buffer, id) end)
    end)

    {tree, next_win} = build_tree(spec, state.next_win)

    Enum.each(leaf_ids_buffers(tree), fn {_id, buffer} ->
      Compos.Core.ensure_buffer(buffer)
      Buffer.touch(buffer)
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
    # switch left no trace in C-x b.
    shown = tree |> leaf_ids_buffers() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    active_buf = find_leaf(tree, active).buffer

    state =
      Enum.reduce(Enum.reverse(shown -- [active_buf]) ++ [active_buf], state, &bump_mru(&2, &1))

    changed(
      :ok,
      resync_swap(put_frame(%{state | next_win: next_win}, %{f | tree: tree, active: active})),
      f.id
    )
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
    {:reply, reply, notify_configuration(state, fids)}
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

  # the history holds buffer names and group marks. A window with no buffer
  # offers `false` here; it names no place, so it never enters the history.
  defp bump_mru(state, buffer) when is_binary(buffer) do
    Compos.Core.BufferStore.touch(buffer)
    if Buffer.exists?(buffer), do: Buffer.touch(buffer)
    push_mru(state, buffer)
  end

  defp bump_mru(state, {:group, _} = mark), do: push_mru(state, mark)

  defp bump_mru(state, _other), do: state

  defp push_mru(state, entry),
    do: %{state | mru: Enum.take([entry | List.delete(state.mru, entry)], 500)}

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

  defp valid_frame_id?(id),
    do: is_binary(id) and String.starts_with?(id, "f-") and byte_size(id) <= 24

  defp gen_frame_id,
    do: "f-" <> Base.encode32(:crypto.strong_rand_bytes(4), case: :lower, padding: false)

  # --- minibuffer helpers (vertico-style: fuzzy filter + selection) ----------

  # what the minibuffer matches on: the whole input, except hierarchical
  # (on_complete) prompts, which match the segment after the last "/"
  # A dynamic provider can return an already-ranked result set whose labels
  # need not contain the query (the command palette finds commands by docs and
  # recipes). Ordinary prompts keep the shared candidate matcher.
  defp mb_query(%{filter: false}), do: ""

  defp mb_query(%{on_complete: oc, input: input}) when oc not in [nil, false],
    do: input |> String.split("/") |> List.last()

  defp mb_query(%{input: input}), do: input

  @doc """
  True when the prompt line itself is the selection, not a candidate row
  (vertico-preselect 'directory).

  A file prompt whose input ends with "/" names a directory. RET must open
  that directory, not the first file in it — TAB descends into a directory
  and leaves its contents listed. C-n/C-p touch the list and take the
  selection back to the candidates.
  """
  def prompt_preselected?(mb) do
    touched = Map.get(mb, :sel_touched) || (mb[:list] && mb.list.touched) || false

    mb[:on_complete] not in [nil, false] and not touched and
      String.ends_with?(mb.input, "/")
  end

  defp put_mb_input(mb, input) do
    mb = %{mb | input: input}
    %{mb | list: Candidates.put_query(mb.list, mb_query(mb))}
  end

  defp minibuf_of(%{id: fid}), do: " *minibuf-" <> fid <> "*"

  # any frame's minibuf buffer shares one local-keymap namespace
  defp keymap_key(" *minibuf" <> _), do: @minibuf
  defp keymap_key(name), do: name

  defp readonly_map(state), do: Map.get(state.local_keymaps, @readonly_map, %{})

  defp read_only_buffer?(buffer), do: Buffer.exists?(buffer) and Buffer.read_only?(buffer)

  # does the read-only map claim this sequence, and is the buffer read-only?
  # The keys are lists, so a caller that hands over anything else must not
  # reach List.starts_with?: it raises, and a raise here takes the Editor
  # and every local keymap with it.
  defp readonly_hit?(state, seq, buffer) when is_list(seq) do
    map = readonly_map(state)

    (Map.has_key?(map, seq) or Enum.any?(Map.keys(map), &List.starts_with?(&1, seq))) and
      read_only_buffer?(buffer)
  end

  defp readonly_hit?(_state, _seq, _buffer), do: false

  # the desktop's read-only tree: structure, tops, points, scroll state
  defp dtree(%{type: :leaf, id: id, buffer: b} = leaf) do
    %{
      type: :leaf,
      buffer: b,
      history: Map.get(leaf, :history, []),
      top: Map.get(leaf, :top, 0),
      point: safe_win_point(b, id),
      manual: Map.get(leaf, :manual, false),
      ctop: Map.get(leaf, :ctop, 0)
    }
  end

  defp dtree(%{type: :split, dir: dir, children: [a, b]} = s),
    do: %{type: :split, dir: dir, ratio: Map.get(s, :ratio, 0.5), children: [dtree(a), dtree(b)]}

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
    # the palette is tall: show three times the bottom bar's slice
    window = if Map.get(mb, :style) == "palette", do: 24, else: 8

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
      completing: mb.on_complete not in [nil, false],
      # presentation, chosen by the prompt: nil = bottom panel,
      # "palette" = centered panel
      style: Map.get(mb, :style)
    }
  end

  defp render_completion(c) do
    %{
      start: c.start,
      candidates: Candidates.rows(c.list),
      sel: c.list.sel,
      total: Candidates.total(c.list)
    }
  end

  defp which_key(_state, %{pending: []}), do: nil

  defp which_key(state, f) do
    # while a prompt is active the minibuffer's map is the one in force,
    # and it is stored under the normalized key (S16)
    buffer = if f.minibuffer, do: minibuf_of(f), else: find_leaf(f.tree, f.active).buffer
    local = Map.get(state.local_keymaps, keymap_key(buffer), %{})

    [local, state.keymap]
    |> Enum.flat_map(&Map.to_list/1)
    |> Enum.filter(fn {seq, _} -> List.starts_with?(seq, f.pending) and seq != f.pending end)
    |> Enum.map(fn {seq, cmd} ->
      keys = Enum.drop(seq, length(f.pending))
      {modifiers, base} = which_key_modifiers(hd(keys))

      %{
        key: Enum.join(keys, " "),
        command: cmd,
        modifiers: modifiers,
        modifier_label: which_key_modifier_label(modifiers),
        sort_key: [String.downcase(base) | tl(keys)]
      }
    end)
    |> Enum.uniq_by(& &1.key)
    |> Enum.sort_by(fn item ->
      unmodified = if item.modifiers == [], do: 0, else: 1
      {unmodified, item.modifier_label, item.sort_key, item.key}
    end)
    |> Enum.map(&Map.delete(&1, :sort_key))
  end

  @which_key_modifier_order ~w(C M S s)
  @which_key_shifted_printable ~w(! @ # $ % ^ & * \( \) _ + { } | : " < > ? ~)

  defp which_key_modifiers(key) do
    {explicit, base} = take_key_modifiers(key, [])

    shifted =
      String.length(base) == 1 and
        (base in @which_key_shifted_printable or String.downcase(base) != base)

    modifiers = if shifted, do: ["S" | explicit], else: explicit
    {Enum.filter(@which_key_modifier_order, &(&1 in modifiers)), base}
  end

  defp take_key_modifiers(<<modifier::binary-size(1), "-", rest::binary>>, found)
       when modifier in @which_key_modifier_order,
       do: take_key_modifiers(rest, [modifier | found])

  defp take_key_modifiers(key, found), do: {found, key}

  defp which_key_modifier_label([]), do: "Unmodified"

  defp which_key_modifier_label(modifiers) do
    modifiers
    |> Enum.map(fn
      "C" -> "Control"
      "M" -> "Meta"
      "S" -> "Shift"
      "s" -> "Super"
    end)
    |> Enum.join(" + ")
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
    Enum.find_value(wins_showing(f.tree, buf), &Map.get(cols, &1))
  end

  defp wins_showing(%{type: :leaf, id: id, buffer: b}, buf), do: if(b == buf, do: [id], else: [])

  defp wins_showing(%{type: :split, children: cs}, buf),
    do: Enum.flat_map(cs, &wins_showing(&1, buf))

  defp find_leaf(%{type: :leaf} = leaf, id), do: if(leaf.id == id, do: leaf, else: nil)

  defp find_leaf(%{type: :split, children: children}, id),
    do: Enum.find_value(children, &find_leaf(&1, id))

  # A window must land on a live buffer. When every candidate is dead,
  # recreate *scratch* — a window that shows a dead name turns the next
  # keypress into a :noproc crash.
  defp live_scratch do
    unless Buffer.exists?(@scratch), do: Compos.Core.create_buffer(@scratch)
    @scratch
  end

  defp visible_buffers(%{type: :leaf, buffer: b}), do: [b]

  defp visible_buffers(%{type: :split, children: children}),
    do: Enum.flat_map(children, &visible_buffers/1)

  defp swap_buffer(%{type: :leaf} = leaf, from, to),
    do:
      leaf
      |> Map.update(:history, [], &Enum.map(&1, fn b -> if b == from, do: to, else: b end))
      |> then(fn renamed ->
        if renamed.buffer == from,
          do: %{renamed | buffer: to, top: 0, manual: false},
          else: renamed
      end)

  defp swap_buffer(%{type: :split} = split, from, to),
    do: %{split | children: Enum.map(split.children, &swap_buffer(&1, from, to))}

  # a leaf on BUFFER follows point again: no pin, top and pixel offset at 0
  defp unpin_buffer_leaves(%{type: :leaf} = leaf, buffer) do
    if leaf.buffer == buffer,
      do: %{leaf | top: 0, manual: false} |> Map.put(:ctop, 0),
      else: leaf
  end

  defp unpin_buffer_leaves(%{type: :split} = split, buffer),
    do: %{split | children: Enum.map(split.children, &unpin_buffer_leaves(&1, buffer))}

  defp release_buffer_from_tree(%{type: :leaf} = leaf, buffer, fallback) do
    leaf = Map.update(leaf, :history, [], &List.delete(&1, buffer))

    if leaf.buffer == buffer,
      do: %{leaf | buffer: fallback, top: 0, manual: false},
      else: leaf
  end

  defp release_buffer_from_tree(%{type: :split} = split, buffer, fallback),
    do: %{
      split
      | children: Enum.map(split.children, &release_buffer_from_tree(&1, buffer, fallback))
    }

  defp replace_leaf(%{type: :leaf} = leaf, id, new),
    do: if(leaf.id == id, do: new, else: leaf)

  defp replace_leaf(%{type: :split} = split, id, new),
    do: %{split | children: Enum.map(split.children, &replace_leaf(&1, id, new))}

  defp visit_buffer(leaf, buffer) do
    previous = Map.get(leaf, :preview_origin, leaf.buffer)
    history = Map.get(leaf, :history, [])

    history =
      if previous == buffer do
        List.delete(history, buffer)
      else
        Enum.take([previous | List.delete(List.delete(history, previous), buffer)], 500)
      end

    leaf
    |> Map.delete(:preview_origin)
    |> Map.merge(%{buffer: buffer, history: history, top: 0, manual: false})
  end

  # returns the tree with the leaf removed, or nil if the tree IS that leaf
  # a buffer floating as the popup wears the class Scheme gave it
  defp popup_buffer?(b) when is_binary(b) do
    case Buffer.get_local(b, "window-class") do
      class when is_binary(class) -> String.starts_with?(class, "popup")
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  defp popup_buffer?(_), do: false

  defp remove_leaf(%{type: :leaf, id: id}, id), do: nil
  defp remove_leaf(%{type: :leaf} = leaf, _id), do: leaf

  defp remove_leaf(%{type: :split, children: [a, b]} = split, id) do
    case {remove_leaf(a, id), remove_leaf(b, id)} do
      {nil, b2} -> b2
      {a2, nil} -> a2
      {a2, b2} -> %{split | children: [a2, b2]}
    end
  end

  defp first_leaf(%{type: :leaf} = leaf), do: leaf
  defp first_leaf(%{type: :split, children: [a | _]}), do: first_leaf(a)

  defp build_tree({:leaf, buffer}, n), do: build_tree({:leaf, buffer, 0}, n)

  defp build_tree({:leaf, buffer, top}, n),
    do: {%{type: :leaf, id: n, buffer: buffer, history: [], top: top, manual: false}, n + 1}

  # 4-tuple carries a saved window point (desktop v2). Older layouts and
  # desktop files still hold one; it is read and discarded, because a
  # restore never writes point into a buffer.
  defp build_tree({:leaf, buffer, top, _point}, n), do: build_tree({:leaf, buffer, top}, n)

  # 6-tuple adds the scroll override and the client-scroll offset (S1):
  # a manually scrolled window restores pinned where the reader left it.
  # A saved offset is itself the pin. `manual` is cleared by the key that
  # reaches the active window (S9), and the key that starts a group
  # switch is such a key — so the flag alone loses the reader's place.
  defp build_tree({:leaf, buffer, top, point, manual, ctop}, n) do
    {leaf, n} = build_tree({:leaf, buffer, top, point}, n)
    ctop = ctop || 0
    {%{leaf | manual: manual == true or ctop > 0} |> Map.put(:ctop, ctop), n}
  end

  # 7-tuple keeps the window-local buffer history across layout and desktop
  # restore. Older layouts start with an empty history.
  defp build_tree({:leaf, buffer, top, point, manual, ctop, history}, n) do
    {leaf, n} = build_tree({:leaf, buffer, top, point, manual, ctop}, n)
    {%{leaf | history: Enum.filter(history, &is_binary/1)}, n}
  end

  defp build_tree({:split, dir, a, b}, n), do: build_tree({:split, dir, 0.5, a, b}, n)

  defp build_tree({:split, dir, ratio, a, b}, n) do
    {ta, n} = build_tree(a, n)
    {tb, n} = build_tree(b, n)
    {%{type: :split, dir: dir, ratio: ratio, children: [ta, tb]}, n}
  end

  defp leaf_ids_buffers(%{type: :leaf, id: id, buffer: b}), do: [{id, b}]

  defp leaf_ids_buffers(%{type: :split, children: c}),
    do: Enum.flat_map(c, &leaf_ids_buffers/1)

  # normalized frame geometry per leaf — windmove's map of the screen
  defp leaf_rects(%{type: :leaf, id: id, buffer: b}, {x, y, w, h}),
    do: [[id, b, x, y, w, h]]

  defp leaf_rects(%{type: :split, dir: :h, ratio: r, children: [a, b]}, {x, y, w, h}),
    do: leaf_rects(a, {x, y, w * r, h}) ++ leaf_rects(b, {x + w * r, y, w * (1 - r), h})

  defp leaf_rects(%{type: :split, dir: :v, ratio: r, children: [a, b]}, {x, y, w, h}),
    do: leaf_rects(a, {x, y, w, h * r}) ++ leaf_rects(b, {x, y + h * r, w, h * (1 - r)})

  defp leaf_ids(%{type: :leaf, id: id}), do: [id]
  defp leaf_ids(%{type: :split, children: children}), do: Enum.flat_map(children, &leaf_ids/1)

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

  defp split_rows(:h, rows, _ratio), do: {rows, rows}

  defp split_rows(:v, rows, ratio) do
    a = max(round(rows * ratio), 3)
    {a, max(rows - a, 3)}
  end

  defp modeline_group(groups, current) when is_list(groups) do
    names = Enum.filter(groups, &is_binary/1)

    current_name =
      cond do
        current in names -> current
        is_binary(current) -> Enum.find(names, &String.starts_with?(current, &1 <> " "))
        true -> nil
      end

    decorated? = is_binary(current_name) and current != current_name

    cond do
      names == [] ->
        nil

      length(names) == 1 and decorated? and hd(names) == current_name ->
        current

      length(names) == 1 ->
        hd(names)

      is_binary(current_name) and current_name in names ->
        "#{current} (#{length(names) - 1} more)"

      true ->
        "#{length(names)} groups"
    end
  end

  defp modeline_group(_groups, _current), do: nil

  # exists? then call still races a dying buffer (registry entries linger);
  # a dead buffer renders empty instead of crashing the Editor
  # The read model answers this without a message, which is why the walk
  # may run here at all: this process holds the whole editor while it
  # renders, and it used to wait on each visible buffer in turn. One buffer
  # busy with a reparse, a checkpoint or a save then stalled every frame of
  # every client. Now only a buffer with no row costs a call, and a dormant
  # one still draws empty rather than waking.
  defp safe_snapshot(buffer, win_id) do
    case Compos.Core.BufferView.snapshot(buffer, win_id) do
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

  # render walk: computes per-window rows (v-splits divide), clamps and
  # auto-follows the viewport top (unless manually scrolled), and returns
  # both the updated tree (tops persist) and the render payload
  defp render_walk(
         %{type: :split, dir: dir, children: [a, b]} = split,
         rows,
         win_rows,
         frame_group
       ) do
    ratio = Map.get(split, :ratio, 0.5)
    {rows_a, rows_b} = split_rows(dir, rows, ratio)
    {a2, ra} = render_walk(a, rows_a, win_rows, frame_group)
    {b2, rb} = render_walk(b, rows_b, win_rows, frame_group)

    {%{split | children: [a2, b2]}, %{type: :split, dir: dir, ratio: ratio, children: [ra, rb]}}
  end

  defp render_walk(
         %{type: :leaf, id: id, buffer: buffer} = leaf,
         rows,
         win_rows,
         frame_group
       ) do
    # the client's measured row count for this window wins over split math:
    # line height varies per buffer, so only the client knows what fits
    rows = Map.get(win_rows, id, rows)

    # one round trip per leaf — this runs on every render of every window;
    # point/mark/cursor geometry are the WINDOW's (per-window points)
    snap = safe_snapshot(buffer, id)
    %{text: text, point: point, locals: locals} = snap

    # folds put top/cursor/total in VISIBLE-line space; the scroll and
    # auto-follow math below then works unchanged. Line *numbers* stay
    # logical (folds show numbering gaps, like Emacs). The no-fold case is
    # O(log n) rope lookups from the snapshot; folds still scan.
    {total_lines, cl, hidden_lines, narrow_lines} =
      cond do
        # the rich transcript renders blocks, not lines — fold geometry
        # is the plain view's cost, not this one's (S16)
        Map.get(locals, "render-mode") == "agent" ->
          {snap.total_lines, snap.cursor_line, MapSet.new(), nil}

        snap.hidden == [] and is_nil(snap.narrow_range) ->
          {snap.total_lines, snap.cursor_line, MapSet.new(), nil}

        true ->
          visible_geometry(text, point, snap.hidden, snap.narrow_range)
      end

    # Clamped to the last SCREENFUL, not the last line. Scrolling had no upper
    # bound of its own, and clamping to total-1 still let a short buffer end up
    # with one line stranded at the top of an otherwise empty window — which
    # then persisted, because tops are written back. A window can no longer be
    # scrolled past its own content, and a reload always lands somewhere real.
    top = leaf.top |> min(max(total_lines - rows, 0)) |> max(0)

    top =
      cond do
        leaf.manual -> top
        cl < top -> cl
        cl >= top + rows -> cl - rows + 1
        true -> top
      end

    rendered = %{
      type: :leaf,
      id: id,
      buffer: buffer,
      # the file this buffer visits, nil for the rest. /raw URLs and the
      # modeline read these two; the client renders no UI for them yet.
      path: snap.path,
      read_only: snap.read_only,
      text: text,
      point: point,
      mark: snap.mark,
      version: snap.version,
      modified: snap.modified,
      mode: Map.get(locals, "mode-name") || "Fundamental",
      # what the modeline calls this buffer: project coordinates inside a
      # project, "~" for the home directory outside one. Scheme decides.
      modeline_name: Map.get(locals, "modeline-name"),
      modeline_file: Map.get(locals, "modeline-file"),
      modeline_project: Map.get(locals, "modeline-project"),
      # free-form per-buffer modeline segment (agent connector, etc.)
      modeline_info: Map.get(locals, "modeline-info"),
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
      # Scheme resolves durable ids into membership names. This last, purely
      # presentational compaction must happen per frame: one buffer can be
      # visible on two monitors whose current groups differ.
      group: modeline_group(Map.get(locals, "modeline-groups"), frame_group),
      # Scheme selects the buffer-owned group that supplies its color.
      # The frame group remains separate context for the bottom bar.
      group_color: Map.get(locals, "modeline-group-color"),
      ts_lang: Map.get(locals, "ts-lang"),
      overlays: snap.overlays,
      overlay_gen: snap.overlay_gen,
      hidden_lines: hidden_lines,
      narrow_lines: narrow_lines,
      line: snap.line,
      col: snap.col,
      style: Map.get(locals, "style"),
      render_mode: render_mode(locals),
      visual_line_mode: Map.get(locals, "visual-line-mode") == true,
      # the page carries this so the wrap map it measures can name the
      # text it measured
      version: Buffer.version(buffer) || 0,
      agent: agent_leaf(locals, text),
      blocks: blocks_leaf(locals),
      minor_modes: Map.get(locals, "minor-modes") || [],
      # the expanded modeline: a block tree pinned above the text,
      # rendered only while the buffer-local says so
      dash:
        if(Map.get(locals, "modeline-expanded") == true,
          do: Map.get(locals, "modeline-dash-blocks") || [],
          else: nil
        ),
      preview_authored: Map.get(locals, "preview-authored") == true,
      # an app reloads when this number changes, and only then: a keystroke
      # must not restart the app you are typing at
      app_gen: Map.get(locals, "app-generation") || 0,
      top: top,
      # the payload says what the daemon knows about scroll (S1): manual
      # pins the windowed top; ctop is a client-scrolled window's pixel
      # offset, applied by the client on mount
      manual: leaf.manual,
      ctop: Map.get(leaf, :ctop, 0),
      rows: rows,
      total_lines: total_lines,
      line_numbers: Map.get(locals, "line-numbers") != "off",
      # extra CSS class on the window div (writing-mode centering etc.)
      window_class: Map.get(locals, "window-class") || nil,
      # inline style on the window itself. A popup hands its share of the
      # frame over this way: the stylesheet cannot read a number out of a
      # display rule, but it can read a custom property.
      window_style: Map.get(locals, "window-style") || nil
    }

    {%{leaf | top: top}, rendered}
  end

  # {visible line count, cursor's visible-line index, MapSet of hidden
  # logical line indexes}. A line is hidden when its start byte falls
  # strictly inside a hidden range (the range's own start line stays
  # visible — that's the folded headline). Ranges are clamped: they can
  # be momentarily stale after an undo swaps the rope out from under them.
  # everything the rich agent transcript renderer needs, straight from the
  # buffer-locals agent.scm maintains — nil unless the buffer opted in
  defp agent_leaf(%{"render-mode" => "agent"} = locals, text) do
    marker_bytes = Map.get(locals, "agent-marker-bytes") || 0
    mark = Map.get(locals, "agent-saved-mark") || 0

    # the mark is a plain local, so text edits it doesn't know about (undo,
    # edits before it) can strand it past the end of the buffer — clamp so
    # the input region and cursor never vanish
    mark = mark |> min(byte_size(text) - marker_bytes) |> max(0)

    %{
      blocks: Map.get(locals, "agent-blocks") || [],
      mark: mark,
      marker_bytes: marker_bytes,
      # where the input region begins, computed once. The client used to
      # add these two together itself, which made it a fourth place that
      # had to agree with Scheme about what a chat's layout is.
      input_start: mark + marker_bytes,
      slug: Map.get(locals, "agent-slug"),
      # controlled card state (S6): the ids whose tool cards show open
      open_cards: Map.get(locals, "agent-open-cards") || [],
      # transcript follow flag + reader position (S7) — runtime locals,
      # so a page refresh keeps the reader's place and a restart resets
      # to following. Stored INVERTED (agent-unstick): a cleared local is
      # #f, and cleared must mean "follow".
      stick: Map.get(locals, "agent-unstick") != true,
      scroll_top: Map.get(locals, "agent-scroll-top") || 0,
      # the activity word agent.scm sets on every event ("waiting…",
      # "thinking…", "streaming", "tool · X"); nil when no turn runs
      activity: Map.get(locals, "chat-activity"),
      # messages typed mid-turn that the model did not read yet — muted
      # rows between the transcript and the input, not transcript text
      queued: Map.get(locals, "chat-queued") || []
    }
  end

  defp agent_leaf(_, _), do: nil

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

  # A mode that takes a buffer over inherits the locals of the mode before
  # it, and `render-mode` says which view draws the window. "blocks" with
  # no blocks drew an empty card list over a buffer full of text: dired on
  # a directory that once held a diff went blank, with no error anywhere.
  # No blocks means nothing to draw, so the window shows its text.
  defp render_mode(%{"render-mode" => "blocks"} = locals) do
    case Map.get(locals, "render-blocks") do
      [_ | _] -> "blocks"
      _ -> nil
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

  defp rows_for(%{type: :leaf, id: id}, id, rows), do: rows
  defp rows_for(%{type: :leaf}, _id, _rows), do: nil

  defp rows_for(%{type: :split, dir: dir, children: [a, b]} = split, id, rows) do
    ratio = Map.get(split, :ratio, 0.5)
    {rows_a, rows_b} = split_rows(dir, rows, ratio)
    rows_for(a, id, rows_a) || rows_for(b, id, rows_b)
  end
end
