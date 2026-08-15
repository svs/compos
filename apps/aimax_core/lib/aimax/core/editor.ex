defmodule Aimax.Core.Editor do
  @moduledoc """
  Editor state holder: frames (each a tiling window tree + minibuffer + echo
  + viewport geometry), keymap table, kill ring. **Policy-free by design** —
  every command and default keybinding is Scheme (`priv/editor.scm`); this
  process only stores state and applies small mutations. Key routing lives in
  `Aimax.Core.KeyDispatch`, which runs outside this server so Scheme
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

  alias Aimax.Core.{Buffer, Candidates, Events, Frame}

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
  def current_buffer(fid \\ nil), do: GenServer.call(__MODULE__, {:current_buffer, fid(fid)})
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
  def window_set_buffer(win_id, buffer),
    do: GenServer.call(__MODULE__, {:window_set_buffer, win_id, buffer})

  # keymap
  def bind_key(seq, command), do: GenServer.call(__MODULE__, {:bind_key, seq, command})

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

  @doc "Echo a message in every frame (async sources: agents, timers)."
  def set_echo_all(msg), do: GenServer.call(__MODULE__, {:set_echo_all, msg})

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
  def minibuffer_sync_input(fid \\ nil), do: GenServer.call(__MODULE__, {:mb_sync_input, fid(fid)})

  @doc "While false, current_buffer ignores an active minibuffer (handler escape hatch)."
  def set_mb_redirect(bool, fid \\ nil),
    do: GenServer.call(__MODULE__, {:mb_redirect, bool, fid(fid)})

  def key_for_command(command), do: GenServer.call(__MODULE__, {:key_for_command, command})

  @doc "Buffers in most-recently-displayed order (Emacs buffer list)."
  def buffer_mru, do: GenServer.call(__MODULE__, :buffer_mru)

  # Emacs last-command (yank-pop and friends dispatch on it)
  def set_last_command(name), do: GenServer.call(__MODULE__, {:set_last_command, name})
  def last_command, do: GenServer.call(__MODULE__, :last_command)

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
  def completion_query(q, fid \\ nil), do: GenServer.call(__MODULE__, {:completion_query, q, fid(fid)})

  @doc "Accept the selection: returns {start, label} and clears, or nil."
  def completion_accept(fid \\ nil), do: GenServer.call(__MODULE__, {:completion_accept, fid(fid)})

  def completion_dismiss(fid \\ nil), do: GenServer.call(__MODULE__, {:completion_dismiss, fid(fid)})

  # kill ring
  def kill_push(text), do: GenServer.call(__MODULE__, {:kill_push, text})
  def kill_top, do: GenServer.call(__MODULE__, :kill_top)
  def kill_nth(i), do: GenServer.call(__MODULE__, {:kill_nth, i})
  def kill_size, do: GenServer.call(__MODULE__, :kill_size)

  # faces: name -> attrs map, merged; frontends map them to CSS vars
  def set_face(name, attrs), do: GenServer.call(__MODULE__, {:set_face, name, attrs})

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
  def delete_other_windows(fid \\ nil), do: GenServer.call(__MODULE__, {:delete_other_windows, fid(fid)})
  def other_window(fid \\ nil), do: GenServer.call(__MODULE__, {:other_window, fid(fid)})

  @doc "Show BUFFER in the active window WITHOUT touching the MRU ring — candidate preview must not reorder the buffer history."
  def preview_buffer(buffer, fid \\ nil),
    do: GenServer.call(__MODULE__, {:preview_buffer, buffer, fid(fid)})

  @doc "A buffer is dying: swap every window showing it (any frame) onto a live one."
  def release_buffer(buffer), do: GenServer.call(__MODULE__, {:release_buffer, buffer})

  def set_window_buffer(buffer, fid \\ nil),
    do: GenServer.call(__MODULE__, {:set_window_buffer, buffer, fid(fid)})

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

  def scroll_active(delta_lines, fid \\ nil),
    do: GenServer.call(__MODULE__, {:scroll_active, delta_lines, fid(fid)})

  def scroll_window(id, delta_lines), do: GenServer.call(__MODULE__, {:scroll_window, id, delta_lines})

  @doc "Mirror a client-scrolled window's pixel offset into its leaf (S1)."
  def set_client_top(id, px, fid \\ nil),
    do: GenServer.call(__MODULE__, {:set_client_top, id, px, fid(fid)})

  # mouse: place point at (logical line, char col) in a window's buffer;
  # or set a region from a drag's anchor/focus positions
  def mouse_goto(id, line, col), do: GenServer.call(__MODULE__, {:mouse_goto, id, line, col})

  def mouse_region(id, al, ac, fl, fc),
    do: GenServer.call(__MODULE__, {:mouse_region, id, al, ac, fl, fc})

  # Cmd-C with no native selection: the active region (pushed onto the kill
  # ring, Emacs kill-ring-save) or, without one, the kill-ring top
  def user_acted(fid \\ nil), do: GenServer.call(__MODULE__, {:user_acted, fid(fid)})
  def window_rows(fid \\ nil), do: GenServer.call(__MODULE__, {:window_rows, fid(fid)})
  def recenter(fid \\ nil), do: GenServer.call(__MODULE__, {:recenter, fid(fid)})

  # explicit nil beats an unset pdict; the server resolves nil -> last active
  defp fid(nil), do: Frame.current()
  defp fid(fid), do: fid

  # --- server ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    Aimax.Core.create_buffer(@scratch)

    frame = %{
      id: @main_frame,
      tree: %{type: :leaf, id: 1, buffer: @scratch, top: 0, manual: false},
      active: 1,
      pending: [],
      minibuffer: nil,
      mb_redirect: true,
      echo: "",
      completion: nil,
      total_rows: 40,
      win_rows: %{}
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
       undo_exempt: MapSet.new(["undo"]),
       mru: [@scratch]
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
        buffer = List.first(Enum.filter(state.mru, &Buffer.exists?/1)) || @scratch

        frame = %{
          id: id,
          tree: %{type: :leaf, id: state.next_win, buffer: buffer, top: 0, manual: false},
          active: state.next_win,
          pending: [],
          minibuffer: nil,
          mb_redirect: true,
          echo: "",
          completion: nil,
          total_rows: 40,
          win_rows: %{}
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
        Task.Supervisor.start_child(Aimax.Core.TaskSupervisor, fn -> Aimax.Core.kill_buffer(mb_buf) end)

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
        unless Aimax.Core.Buffer.exists?(buffer), do: Aimax.Core.create_buffer(buffer)
        leaf = find_leaf(f.tree, win_id)
        tree = replace_leaf(f.tree, win_id, %{leaf | buffer: buffer, top: 0, manual: false})
        mru = Enum.take([buffer | List.delete(state.mru, buffer)], 50)
        changed(:ok, resync_swap(put_frame(%{state | mru: mru}, %{f | tree: tree})), f.id)
    end
  end

  # --- frame-scoped state -----------------------------------------------------

  def handle_call({:snapshot, fid}, _from, state) do
    f = frame(state, fid)
    snap = Map.take(f, [:pending, :minibuffer, :echo, :active, :completion])
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
    {tree, rendered} = render_walk(f.tree, f.total_rows, f.win_rows)
    state = put_frame(state, %{f | tree: tree})

    {:reply,
     %{
       frame: f.id,
       tree: rendered,
       active: f.active,
       pending: f.pending,
       minibuffer: f.minibuffer && render_minibuffer(f.minibuffer, minibuf_of(f)),
       which_key: which_key(state, f),
       completion: f.completion && render_completion(f.completion),
       echo: f.echo,
       modeline_extra: state.modeline_extra,
       faces: state.faces,
       styles: state.styles
     }, state}
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

  # the three render modes the client draws in an iframe
  defp preview?(buffer) do
    try do
      Buffer.locals(buffer)["render-mode"] in ["html", "markdown", "app"]
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

  # swap every window off BUFFER (it is being killed) onto the most
  # recent live buffer — windows must never point at the dead
  def handle_call({:release_buffer, buffer}, _from, state) do
    # prefer a buffer not already on screen — swapping to one that is
    # (e.g. *ibuffer* while killing from inside it) duplicates windows
    visible = Enum.flat_map(state.frames, fn {_id, f} -> visible_buffers(f.tree) end)

    fallback =
      Enum.find(state.mru, fn b ->
        b != buffer and b not in visible and Buffer.exists?(b)
      end) ||
        Enum.find(state.mru, @scratch, fn b ->
          b != buffer and Buffer.exists?(b)
        end)

    frames =
      Map.new(state.frames, fn {id, f} ->
        {id, %{f | tree: swap_buffer(f.tree, buffer, fallback)}}
      end)

    changed(:ok, %{state | frames: frames, mru: List.delete(state.mru, buffer)})
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

  # no-op writes must not broadcast — echo("")/pending([]) fire on every key
  def handle_call({:set_pending, seq, fid}, _from, state) do
    f = frame(state, fid)

    if f.pending == seq,
      do: {:reply, :ok, state},
      else: changed(:ok, put_frame(state, %{f | pending: seq}), f.id)
  end

  def handle_call({:set_echo, msg, fid}, _from, state) do
    f = frame(state, fid)

    if f.echo == msg,
      do: {:reply, :ok, state},
      else: changed(:ok, put_frame(state, %{f | echo: msg}), f.id)
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
      %{on_confirm: nil, on_complete: nil, on_change: nil, on_cancel: nil, input: ""}
      |> Map.merge(handlers)
      |> Map.put(:prompt, prompt)

    reset_minibuf_buffer(minibuf_of(f), mb.input)
    mb = Map.put(mb, :list, Candidates.new(candidates, query: mb_query(mb)))
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
            changed({:changed, input}, put_frame(state, %{f | minibuffer: put_mb_input(mb, input)}), f.id)

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
        changed(:ok, put_frame(state, %{f | minibuffer: %{mb | list: Candidates.move(mb.list, delta)}}), f.id)

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
    live = Enum.filter(state.mru, &Buffer.exists?/1)
    rest = Aimax.Core.list_buffers() -- live

    # space-prefixed buffers are internal (the minibuf), hidden like Emacs
    {:reply, Enum.reject(live ++ Enum.sort(rest), &String.starts_with?(&1, " ")), state}
  end

  def handle_call({:set_last_command, name}, _from, state),
    do: {:reply, :ok, %{state | last_command: name}}

  def handle_call(:last_command, _from, state), do: {:reply, state.last_command, state}

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
        changed(:ok, put_frame(state, %{f | completion: %{c | list: Candidates.move(c.list, delta)}}), f.id)

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

  def handle_call({:key_for_command, command}, _from, state) do
    # several keys may run one command (C-n and <down>) — show the tersest
    reply =
      state.keymap
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
    new_leaf = %{type: :leaf, id: state.next_win, buffer: old.buffer, top: old.top, manual: false}
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
      nil -> {:reply, {:error, :no_window}, state}
      f -> changed(:ok, state |> put_frame(%{f | active: id}) |> bump_frame(f.id) |> resync_swap(), f.id)
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
    changed(
      :ok,
      state |> put_frame(%{f | active: Enum.at(ids, rem(idx + 1, length(ids)))}) |> resync_swap(),
      f.id
    )
  end

  def handle_call({:set_window_buffer, buffer, fid}, _from, state) do
    unless Aimax.Core.Buffer.exists?(buffer), do: Aimax.Core.create_buffer(buffer)
    f = frame(state, fid)
    leaf = find_leaf(f.tree, f.active)
    tree = replace_leaf(f.tree, f.active, %{leaf | buffer: buffer, top: 0, manual: false})
    mru = Enum.take([buffer | List.delete(state.mru, buffer)], 50)
    changed(:ok, resync_swap(put_frame(%{state | mru: mru}, %{f | tree: tree})), f.id)
  end

  def handle_call({:preview_buffer, buffer, fid}, _from, state) do
    if Aimax.Core.Buffer.exists?(buffer) do
      f = frame(state, fid)
      leaf = find_leaf(f.tree, f.active)
      tree = replace_leaf(f.tree, f.active, %{leaf | buffer: buffer, top: 0, manual: false})
      changed(:ok, put_frame(state, %{f | tree: tree}))
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
      unless Aimax.Core.Buffer.exists?(buffer), do: Aimax.Core.create_buffer(buffer)
    end)

    # lay saved per-window points down; the active window's swaps into the
    # buffer point via resync below
    tree = apply_init_points(tree)

    active =
      Enum.find_value(leaf_ids_buffers(tree), fn {id, buffer} ->
        if buffer == active_buffer, do: id
      end) || first_leaf(tree).id

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

    case scope do
      :all -> Enum.each(Map.keys(state.frames), &Events.broadcast_frame/1)
      fid -> Events.broadcast_frame(fid)
    end

    {:reply, reply, state}
  end

  # --- frame helpers ---------------------------------------------------------

  # nil frame = the last-active one: the fallback for callers with no
  # frame context (timers, agent events, RPC eval)
  defp frame(state, nil), do: state.frames[hd(state.frame_mru)]
  defp frame(state, fid), do: state.frames[fid] || state.frames[hd(state.frame_mru)]

  defp put_frame(state, f), do: %{state | frames: Map.put(state.frames, f.id, f)}

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

  defp valid_frame_id?(id), do: is_binary(id) and String.starts_with?(id, "f-") and byte_size(id) <= 24

  defp gen_frame_id,
    do: "f-" <> Base.encode32(:crypto.strong_rand_bytes(4), case: :lower, padding: false)

  # --- minibuffer helpers (vertico-style: fuzzy filter + selection) ----------

  # what the minibuffer matches on: the whole input, except hierarchical
  # (on_complete) prompts, which match the segment after the last "/"
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
  defp readonly_hit?(state, seq, buffer) do
    map = readonly_map(state)

    (Map.has_key?(map, seq) or Enum.any?(Map.keys(map), &List.starts_with?(&1, seq))) and
      read_only_buffer?(buffer)
  end

  # the desktop's read-only tree: structure, tops, points, scroll state
  defp dtree(%{type: :leaf, id: id, buffer: b} = leaf) do
    %{
      type: :leaf,
      buffer: b,
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
    unless Buffer.exists?(name), do: Aimax.Core.create_buffer(name)
    size = Buffer.byte_size(name)
    if size > 0, do: Buffer.delete_range(name, 0, size, source: :editor)
    if input != "", do: Buffer.append(name, input, source: :editor)
    Buffer.goto(name, Kernel.byte_size(input))
  end

  defp render_minibuffer(mb, name) do
    prompt_sel = prompt_preselected?(mb)

    %{
      prompt: mb.prompt,
      input: mb.input,
      point: (Buffer.exists?(name) && Buffer.point(name)) || Kernel.byte_size(mb.input),
      # the prompt holds the selection: mark no row, so the highlight always
      # shows what RET takes
      prompt_sel: prompt_sel,
      candidates:
        if(prompt_sel,
          do: Enum.map(Candidates.rows(mb.list), &%{&1 | selected: false}),
          else: Candidates.rows(mb.list)
        ),
      # widest label of the WHOLE set, not the visible window — the names
      # column keeps one width for the session instead of reflowing per key
      label_width: Candidates.label_width(mb.list),
      sel: mb.list.sel,
      total: Candidates.total(mb.list),
      completing: mb.on_complete not in [nil, false]
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
    |> Enum.map(fn {seq, cmd} -> %{key: Enum.join(Enum.drop(seq, length(f.pending)), " "), command: cmd} end)
    |> Enum.uniq_by(& &1.key)
    |> Enum.sort_by(& &1.key)
  end

  # --- tree helpers ----------------------------------------------------------

  # (1-based logical line, char col) -> byte offset; line lookup is the
  # rope NIF, only the clicked line's text is materialized for the col
  defp mouse_pos(buf, line, col) do
    {start, line_text} = Buffer.line_at(buf, line)
    start + byte_size(String.slice(line_text, 0, max(col, 0)))
  end

  defp find_leaf(%{type: :leaf} = leaf, id), do: if(leaf.id == id, do: leaf, else: nil)

  defp find_leaf(%{type: :split, children: children}, id),
    do: Enum.find_value(children, &find_leaf(&1, id))

  defp visible_buffers(%{type: :leaf, buffer: b}), do: [b]

  defp visible_buffers(%{type: :split, children: children}),
    do: Enum.flat_map(children, &visible_buffers/1)

  defp swap_buffer(%{type: :leaf} = leaf, from, to),
    do: if(leaf.buffer == from, do: %{leaf | buffer: to, top: 0, manual: false}, else: leaf)

  defp swap_buffer(%{type: :split} = split, from, to),
    do: %{split | children: Enum.map(split.children, &swap_buffer(&1, from, to))}

  defp replace_leaf(%{type: :leaf} = leaf, id, new),
    do: if(leaf.id == id, do: new, else: leaf)

  defp replace_leaf(%{type: :split} = split, id, new),
    do: %{split | children: Enum.map(split.children, &replace_leaf(&1, id, new))}

  # returns the tree with the leaf removed, or nil if the tree IS that leaf
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
    do: {%{type: :leaf, id: n, buffer: buffer, top: top, manual: false}, n + 1}

  # 4-tuple carries a saved window point (desktop v2); it rides on the leaf
  # as :init_point until restore_tree writes it into the buffer
  defp build_tree({:leaf, buffer, top, point}, n) do
    {leaf, n} = build_tree({:leaf, buffer, top}, n)
    {Map.put(leaf, :init_point, point), n}
  end

  # 6-tuple adds the scroll override and the client-scroll offset (S1):
  # a manually scrolled window restores pinned where the reader left it
  defp build_tree({:leaf, buffer, top, point, manual, ctop}, n) do
    {leaf, n} = build_tree({:leaf, buffer, top, point}, n)
    {%{leaf | manual: manual == true} |> Map.put(:ctop, ctop || 0), n}
  end

  defp build_tree({:split, dir, a, b}, n), do: build_tree({:split, dir, 0.5, a, b}, n)

  defp build_tree({:split, dir, ratio, a, b}, n) do
    {ta, n} = build_tree(a, n)
    {tb, n} = build_tree(b, n)
    {%{type: :split, dir: dir, ratio: ratio, children: [ta, tb]}, n}
  end

  defp apply_init_points(%{type: :leaf} = leaf) do
    case Map.pop(leaf, :init_point) do
      {nil, leaf} ->
        leaf

      {point, leaf} ->
        if Buffer.exists?(leaf.buffer),
          do: wp_safely(fn -> Buffer.set_win_point(leaf.buffer, leaf.id, point) end)

        leaf
    end
  end

  defp apply_init_points(%{type: :split} = split),
    do: %{split | children: Enum.map(split.children, &apply_init_points/1)}

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

  # exists? then call still races a dying buffer (registry entries linger);
  # a dead buffer renders empty instead of crashing the Editor
  defp safe_snapshot(buffer, win_id) do
    if Buffer.exists?(buffer), do: Buffer.render_snapshot(buffer, win_id), else: @empty_snapshot
  catch
    :exit, _ -> @empty_snapshot
  end

  # render walk: computes per-window rows (v-splits divide), clamps and
  # auto-follows the viewport top (unless manually scrolled), and returns
  # both the updated tree (tops persist) and the render payload
  defp render_walk(%{type: :split, dir: dir, children: [a, b]} = split, rows, win_rows) do
    ratio = Map.get(split, :ratio, 0.5)
    {rows_a, rows_b} = split_rows(dir, rows, ratio)
    {a2, ra} = render_walk(a, rows_a, win_rows)
    {b2, rb} = render_walk(b, rows_b, win_rows)

    {%{split | children: [a2, b2]},
     %{type: :split, dir: dir, ratio: ratio, children: [ra, rb]}}
  end

  defp render_walk(%{type: :leaf, id: id, buffer: buffer} = leaf, rows, win_rows) do
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
    {total_lines, cl, hidden_lines} =
      cond do
        # the rich transcript renders blocks, not lines — fold geometry
        # is the plain view's cost, not this one's (S16)
        Map.get(locals, "render-mode") == "agent" ->
          {snap.total_lines, snap.cursor_line, MapSet.new()}

        snap.hidden == [] ->
          {snap.total_lines, snap.cursor_line, MapSet.new()}

        true ->
          visible_geometry(text, point, snap.hidden)
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
      # free-form per-buffer modeline segment (agent connector, etc.)
      modeline_info: Map.get(locals, "modeline-info"),
      # buffer-group tag — chat setup migrates the legacy companion-of
      # pointer to this local, so the payload reads only the raw local
      group: Map.get(locals, "group"),
      ts_lang: Map.get(locals, "ts-lang"),
      overlays: snap.overlays,
      overlay_gen: snap.overlay_gen,
      hidden_lines: hidden_lines,
      line: snap.line,
      col: snap.col,
      style: Map.get(locals, "style"),
      render_mode: render_mode(locals),
      agent: agent_leaf(locals, text),
      blocks: blocks_leaf(locals),
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
      queued: Map.get(locals, "agent-queued") || [],
      slug: Map.get(locals, "agent-slug"),
      # controlled card state (S6): the ids whose tool cards show open
      open_cards: Map.get(locals, "agent-open-cards") || [],
      # transcript follow flag + reader position (S7) — runtime locals,
      # so a page refresh keeps the reader's place and a restart resets
      # to following. Stored INVERTED (agent-unstick): a cleared local is
      # #f, and cleared must mean "follow".
      stick: Map.get(locals, "agent-unstick") != true,
      scroll_top: Map.get(locals, "agent-scroll-top") || 0
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

  defp visible_geometry(text, point, hidden) do
    len = byte_size(text)
    starts = [0 | Enum.map(:binary.matches(text, "\n"), fn {p, _} -> p + 1 end)]
    ranges = for {s, e} <- hidden, s < len, do: {s, min(e, len)}

    hidden_lines =
      for {start, idx} <- Enum.with_index(starts),
          Enum.any?(ranges, fn {s, e} -> start > s and start <= e end),
          into: MapSet.new(),
          do: idx

    logical_cl = Aimax.Core.Text.line_index(text, point)

    visible_cl =
      Enum.count(0..(logical_cl - 1)//1, &(not MapSet.member?(hidden_lines, &1)))

    {length(starts) - MapSet.size(hidden_lines), visible_cl, hidden_lines}
  end


  defp rows_for(%{type: :leaf, id: id}, id, rows), do: rows
  defp rows_for(%{type: :leaf}, _id, _rows), do: nil

  defp rows_for(%{type: :split, dir: dir, children: [a, b]} = split, id, rows) do
    ratio = Map.get(split, :ratio, 0.5)
    {rows_a, rows_b} = split_rows(dir, rows, ratio)
    rows_for(a, id, rows_a) || rows_for(b, id, rows_b)
  end
end
