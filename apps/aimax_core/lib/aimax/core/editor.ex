defmodule Aimax.Core.Editor do
  @moduledoc """
  Editor state holder: tiling window tree, keymap table, minibuffer state,
  kill ring, echo area. **Policy-free by design** — every command and default
  keybinding is Scheme (`priv/editor.scm`); this process only stores state and
  applies small mutations. Key routing lives in `Aimax.Core.KeyDispatch`,
  which runs in the caller's process so Scheme primitives can call back into
  this server without deadlock.

  Window tree: `%{type: :leaf, id, buffer}` | `%{type: :split, dir: :h | :v,
  children: [tree, tree]}`. Each leaf shows a buffer; `:h` = side-by-side.
  TODO: per-window points, ratios, window resizing.
  """

  use GenServer

  alias Aimax.Core.{Buffer, Candidates, Events}

  # the minibuffer's backing buffer (Emacs-style: prompt input IS a buffer,
  # so point motion, kill/yank, undo and local keymaps all just work).
  # Space-prefixed = hidden from buffer lists, like Emacs.
  @minibuf " *minibuf*"
  def minibuf_name, do: @minibuf

  @scratch "*scratch*"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # readers
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)
  def current_buffer, do: GenServer.call(__MODULE__, :current_buffer)
  def lookup_key(seq), do: GenServer.call(__MODULE__, {:lookup_key, seq})
  def render_state, do: GenServer.call(__MODULE__, :render_state)

  # keymap
  def bind_key(seq, command), do: GenServer.call(__MODULE__, {:bind_key, seq, command})

  def local_bind_key(buffer, seq, command),
    do: GenServer.call(__MODULE__, {:local_bind_key, buffer, seq, command})

  @doc "Emacs [remap]: in BUFFER, any key that resolves to FROM runs TO instead."
  def local_remap(buffer, from, to),
    do: GenServer.call(__MODULE__, {:local_remap, buffer, from, to})

  # pending prefix + echo
  def set_pending(seq), do: GenServer.call(__MODULE__, {:set_pending, seq})
  def set_echo(msg), do: GenServer.call(__MODULE__, {:set_echo, msg})
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
  def minibuffer_activate_full(prompt, candidates, handlers),
    do: GenServer.call(__MODULE__, {:mb_activate, prompt, candidates, handlers})

  def minibuffer_set_input(input), do: GenServer.call(__MODULE__, {:mb_input, input})

  def minibuffer_set_candidates(candidates),
    do: GenServer.call(__MODULE__, {:mb_candidates, candidates})

  def minibuffer_move_sel(delta), do: GenServer.call(__MODULE__, {:mb_move_sel, delta})

  @doc "Currently selected candidate label (after fuzzy filter), or nil."
  def minibuffer_selected, do: GenServer.call(__MODULE__, :mb_selected)

  def minibuffer_close, do: GenServer.call(__MODULE__, :mb_close)

  @doc "Re-read input from the minibuf buffer. :unchanged | {:changed, input}."
  def minibuffer_sync_input, do: GenServer.call(__MODULE__, :mb_sync_input)

  @doc "While false, current_buffer ignores an active minibuffer (handler escape hatch)."
  def set_mb_redirect(bool), do: GenServer.call(__MODULE__, {:mb_redirect, bool})

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
  def completion_show(start, candidates),
    do: GenServer.call(__MODULE__, {:completion_show, start, candidates})

  def completion_move(delta), do: GenServer.call(__MODULE__, {:completion_move, delta})

  @doc "Narrow the open popup by prefix typed since it opened."
  def completion_query(q), do: GenServer.call(__MODULE__, {:completion_query, q})

  @doc "Accept the selection: returns {start, label} and clears, or nil."
  def completion_accept, do: GenServer.call(__MODULE__, :completion_accept)

  def completion_dismiss, do: GenServer.call(__MODULE__, :completion_dismiss)

  # kill ring
  def kill_push(text), do: GenServer.call(__MODULE__, {:kill_push, text})
  def kill_top, do: GenServer.call(__MODULE__, :kill_top)
  def kill_nth(i), do: GenServer.call(__MODULE__, {:kill_nth, i})
  def kill_size, do: GenServer.call(__MODULE__, :kill_size)

  # faces: name -> attrs map, merged; frontends map them to CSS vars
  def set_face(name, attrs), do: GenServer.call(__MODULE__, {:set_face, name, attrs})

  # windows
  def split(dir, ratio \\ 0.5) when dir in [:h, :v],
    do: GenServer.call(__MODULE__, {:split, dir, ratio})

  def delete_window, do: GenServer.call(__MODULE__, :delete_window)
  def delete_window_by_id(id), do: GenServer.call(__MODULE__, {:delete_window_by_id, id})
  def list_windows, do: GenServer.call(__MODULE__, :list_windows)
  def window_rects, do: GenServer.call(__MODULE__, :window_rects)
  def set_active(id), do: GenServer.call(__MODULE__, {:set_active, id})
  def active_window, do: GenServer.call(__MODULE__, :active_window)
  def delete_other_windows, do: GenServer.call(__MODULE__, :delete_other_windows)
  def other_window, do: GenServer.call(__MODULE__, :other_window)
  def set_window_buffer(buffer), do: GenServer.call(__MODULE__, {:set_window_buffer, buffer})

  @doc "Show BUFFER in the active window WITHOUT touching the MRU ring — candidate preview must not reorder the buffer history."
  def preview_buffer(buffer), do: GenServer.call(__MODULE__, {:preview_buffer, buffer})

  @doc "A buffer is dying: swap every window showing it onto a live one."
  def release_buffer(buffer), do: GenServer.call(__MODULE__, {:release_buffer, buffer})

  @doc "Replace the whole window tree from a {:leaf, name} | {:split, dir, a, b} spec."
  def restore_tree(spec, active_buffer),
    do: GenServer.call(__MODULE__, {:restore_tree, spec, active_buffer})

  # viewport: client reports how many text rows fit; wheel scrolls the
  # active window server-side; any key re-enables point auto-follow
  def set_total_rows(rows), do: GenServer.call(__MODULE__, {:set_total_rows, rows})

  @doc "Per-window measured rows (%{win_id => rows}) — line height varies per buffer."
  def set_window_rows(map), do: GenServer.call(__MODULE__, {:set_window_rows, map})
  def scroll_active(delta_lines), do: GenServer.call(__MODULE__, {:scroll_active, delta_lines})
  def scroll_window(id, delta_lines), do: GenServer.call(__MODULE__, {:scroll_window, id, delta_lines})

  # mouse: place point at (logical line, char col) in a window's buffer;
  # or set a region from a drag's anchor/focus positions
  def mouse_goto(id, line, col), do: GenServer.call(__MODULE__, {:mouse_goto, id, line, col})

  def mouse_region(id, al, ac, fl, fc),
    do: GenServer.call(__MODULE__, {:mouse_region, id, al, ac, fl, fc})

  # Cmd-C with no native selection: the active region (pushed onto the kill
  # ring, Emacs kill-ring-save) or, without one, the kill-ring top
  def copy_text, do: GenServer.call(__MODULE__, :copy_text)
  def user_acted, do: GenServer.call(__MODULE__, :user_acted)
  def window_rows, do: GenServer.call(__MODULE__, :window_rows)
  def recenter, do: GenServer.call(__MODULE__, :recenter)

  # --- server ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    Aimax.Core.create_buffer(@scratch)

    {:ok,
     %{
       tree: %{type: :leaf, id: 1, buffer: @scratch, top: 0, manual: false},
       active: 1,
       next_win: 2,
       pending: [],
       minibuffer: nil,
       kill_ring: [],
       keymap: %{},
       echo: "",
       modeline_extra: "",
       faces: %{},
       local_keymaps: %{},
       remaps: %{},
       last_command: "",
       undo_exempt: MapSet.new(["undo"]),
       completion: nil,
       total_rows: 40,
       win_rows: %{},
       mru: [@scratch],
       mb_redirect: true
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    snap = Map.take(state, [:pending, :minibuffer, :echo, :active, :completion])
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
  def handle_call(:current_buffer, _from, %{minibuffer: %{}, mb_redirect: true} = state) do
    {:reply, @minibuf, state}
  end

  def handle_call(:current_buffer, _from, state) do
    {:reply, find_leaf(state.tree, state.active).buffer, state}
  end

  def handle_call({:mb_redirect, bool}, _from, state),
    do: {:reply, :ok, %{state | mb_redirect: bool}}

  def handle_call({:lookup_key, seq}, _from, state) do
    buffer =
      if state.minibuffer, do: @minibuf, else: find_leaf(state.tree, state.active).buffer

    local = Map.get(state.local_keymaps, buffer, %{})

    reply =
      cond do
        Map.has_key?(local, seq) -> {:command, local[seq]}
        Map.has_key?(state.keymap, seq) -> {:command, state.keymap[seq]}
        Enum.any?(Map.keys(local), &List.starts_with?(&1, seq)) -> :prefix
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

  def handle_call({:local_remap, buffer, from, to}, _from, state) do
    remaps = Map.update(state.remaps, buffer, %{from => to}, &Map.put(&1, from, to))
    {:reply, :ok, %{state | remaps: remaps}}
  end

  def handle_call({:local_bind_key, buffer, seq, command}, _from, state) do
    local_keymaps =
      Map.update(state.local_keymaps, buffer, %{seq => command}, &Map.put(&1, seq, command))

    {:reply, :ok, %{state | local_keymaps: local_keymaps}}
  end

  def handle_call(:render_state, _from, state) do
    {tree, rendered} = render_walk(state.tree, state.total_rows, state.win_rows)
    state = %{state | tree: tree}

    {:reply,
     %{
       tree: rendered,
       active: state.active,
       pending: state.pending,
       minibuffer: state.minibuffer && render_minibuffer(state.minibuffer),
       which_key: which_key(state),
       completion: state.completion && render_completion(state.completion),
       echo: state.echo,
       modeline_extra: state.modeline_extra,
       faces: state.faces
     }, state}
  end

  def handle_call({:set_total_rows, rows}, _from, state),
    do: {:reply, :ok, %{state | total_rows: rows |> max(5) |> min(500)}}

  # no-op guard: the client re-reports after every patch; only real changes
  # may broadcast or this loops forever
  def handle_call({:set_window_rows, map}, _from, %{win_rows: map} = state),
    do: {:reply, :ok, state}

  def handle_call({:set_window_rows, map}, _from, state) when is_map(map),
    do: changed(:ok, %{state | win_rows: map})

  def handle_call({:scroll_active, delta}, _from, state) do
    leaf = find_leaf(state.tree, state.active)
    top = max(leaf.top + delta, 0)
    tree = replace_leaf(state.tree, state.active, %{leaf | top: top, manual: true})
    changed(:ok, %{state | tree: tree})
  end

  def handle_call({:scroll_window, id, delta}, _from, state) do
    case find_leaf(state.tree, id) do
      nil ->
        {:reply, {:error, :no_window}, state}

      leaf ->
        top = max(leaf.top + delta, 0)
        tree = replace_leaf(state.tree, id, %{leaf | top: top, manual: true})
        changed(:ok, %{state | tree: tree})
    end
  end

  def handle_call({:mouse_goto, id, line, col}, _from, state) do
    case find_leaf(state.tree, id) do
      nil ->
        {:reply, {:error, :no_window}, state}

      # a window can briefly show a killed buffer (kill_buffer heals the
      # tree, but a click can race it — and the registry entry outlives
      # the process for a moment, so exists? isn't enough). A dead buffer
      # must never crash the Editor: its crash wipes the keymap with it.
      leaf ->
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
    visible = visible_buffers(state.tree)

    fallback =
      Enum.find(state.mru, fn b ->
        b != buffer and b not in visible and Buffer.exists?(b)
      end) ||
        Enum.find(state.mru, @scratch, fn b ->
          b != buffer and Buffer.exists?(b)
        end)

    tree = swap_buffer(state.tree, buffer, fallback)
    changed(:ok, %{state | tree: tree, mru: List.delete(state.mru, buffer)})
  end

  def handle_call({:mouse_region, id, al, ac, fl, fc}, _from, state) do
    case find_leaf(state.tree, id) do
      nil ->
        {:reply, {:error, :no_window}, state}

      leaf ->
        try do
          Buffer.set_mark(leaf.buffer, mouse_pos(leaf.buffer, al, ac))
          Buffer.goto(leaf.buffer, mouse_pos(leaf.buffer, fl, fc))
          changed(:ok, state)
        catch
          :exit, _ -> {:reply, {:error, :no_buffer}, state}
        end
    end
  end

  def handle_call(:copy_text, _from, state) do
    buf = active_buffer_of(state)
    snap = Buffer.render_snapshot(buf)

    case snap.mark do
      mark when is_integer(mark) and mark != snap.point ->
        {s, e} = {min(mark, snap.point), max(mark, snap.point)}
        region = binary_part(snap.text, s, e - s)
        {:reply, region, %{state | kill_ring: Enum.take([region | state.kill_ring], 60)}}

      _ ->
        {:reply, List.first(state.kill_ring, ""), state}
    end
  end

  def handle_call(:user_acted, _from, state),
    do: {:reply, :ok, %{state | tree: clear_manual(state.tree)}}

  def handle_call(:window_rows, _from, state) do
    rows =
      Map.get(state.win_rows, state.active) ||
        rows_for(state.tree, state.active, state.total_rows) || state.total_rows

    {:reply, rows, state}
  end

  def handle_call(:recenter, _from, state) do
    leaf = find_leaf(state.tree, state.active)

    rows =
      Map.get(state.win_rows, state.active) ||
        rows_for(state.tree, state.active, state.total_rows) || state.total_rows

    top =
      if Buffer.exists?(leaf.buffer) do
        max(Buffer.render_snapshot(leaf.buffer).cursor_line - div(rows, 2), 0)
      else
        0
      end

    tree = replace_leaf(state.tree, state.active, %{leaf | top: top, manual: false})
    changed(:ok, %{state | tree: tree})
  end

  def handle_call({:bind_key, seq, command}, _from, state),
    do: {:reply, :ok, %{state | keymap: Map.put(state.keymap, seq, command)}}

  # no-op writes must not broadcast — echo("")/pending([]) fire on every key
  def handle_call({:set_pending, seq}, _from, %{pending: seq} = state),
    do: {:reply, :ok, state}

  def handle_call({:set_pending, seq}, _from, state), do: changed(:ok, %{state | pending: seq})

  def handle_call({:set_echo, msg}, _from, %{echo: msg} = state), do: {:reply, :ok, state}
  def handle_call({:set_echo, msg}, _from, state), do: changed(:ok, %{state | echo: msg})

  def handle_call({:set_modeline_extra, s}, _from, %{modeline_extra: s} = state),
    do: {:reply, :ok, state}

  def handle_call({:set_modeline_extra, s}, _from, state),
    do: changed(:ok, %{state | modeline_extra: s})

  def handle_call({:mb_activate, prompt, candidates, handlers}, _from, state) do
    mb =
      %{on_confirm: nil, on_complete: nil, on_change: nil, on_cancel: nil, input: ""}
      |> Map.merge(handlers)
      |> Map.put(:prompt, prompt)

    reset_minibuf_buffer(mb.input)
    mb = Map.put(mb, :list, Candidates.new(candidates, query: mb_query(mb)))
    changed(:ok, %{state | minibuffer: mb})
  end

  def handle_call({:mb_input, input}, _from, %{minibuffer: %{} = mb} = state) do
    reset_minibuf_buffer(input)
    changed(:ok, %{state | minibuffer: put_mb_input(mb, input)})
  end

  def handle_call({:mb_input, _}, _from, state), do: {:reply, {:error, :inactive}, state}

  # pull the input back out of the minibuffer buffer after keys edited it
  # (self-insert, DEL, yank, undo — anything); requery candidates on change
  def handle_call(:mb_sync_input, _from, %{minibuffer: %{} = mb} = state) do
    input = Buffer.text(@minibuf)

    if input == mb.input,
      do: {:reply, :unchanged, state},
      else: changed({:changed, input}, %{state | minibuffer: put_mb_input(mb, input)})
  end

  def handle_call(:mb_sync_input, _from, state), do: {:reply, :unchanged, state}

  def handle_call({:mb_candidates, candidates}, _from, %{minibuffer: %{} = mb} = state) do
    list = mb.list |> Candidates.put_items(candidates) |> Candidates.put_query(mb_query(mb))
    changed(:ok, %{state | minibuffer: %{mb | list: list}})
  end

  def handle_call({:mb_candidates, _}, _from, state), do: {:reply, {:error, :inactive}, state}

  def handle_call({:mb_move_sel, delta}, _from, %{minibuffer: %{} = mb} = state),
    do: changed(:ok, %{state | minibuffer: %{mb | list: Candidates.move(mb.list, delta)}})

  def handle_call({:mb_move_sel, _}, _from, state), do: {:reply, {:error, :inactive}, state}

  def handle_call(:mb_selected, _from, %{minibuffer: %{} = mb} = state),
    do: {:reply, Candidates.selected(mb.list), state}

  def handle_call(:mb_selected, _from, state), do: {:reply, nil, state}

  # returns the minibuffer map (handlers + :selected/:total/:sel_touched) or nil
  def handle_call(:mb_close, _from, state) do
    reply =
      state.minibuffer &&
        state.minibuffer
        |> Map.put(:selected, Candidates.selected(state.minibuffer.list))
        |> Map.put(:total, Candidates.total(state.minibuffer.list))
        |> Map.put(:sel_touched, state.minibuffer.list.touched)

    changed(reply, %{state | minibuffer: nil})
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

  def handle_call({:completion_show, start, candidates}, _from, state) do
    case Candidates.normalize(candidates) do
      [] ->
        changed(:ok, %{state | completion: nil})

      _ ->
        changed(:ok, %{state | completion: %{start: start, list: Candidates.new(candidates)}})
    end
  end

  def handle_call({:completion_move, delta}, _from, %{completion: %{} = c} = state),
    do: changed(:ok, %{state | completion: %{c | list: Candidates.move(c.list, delta)}})

  def handle_call({:completion_move, _}, _from, state), do: {:reply, :ok, state}

  # narrow the popup in place as the user types — no source re-query
  def handle_call({:completion_query, q}, _from, %{completion: %{} = c} = state) do
    list = Candidates.put_query(c.list, q)

    if Candidates.total(list) == 0,
      do: changed(:ok, %{state | completion: nil}),
      else: changed(:ok, %{state | completion: %{c | list: list}})
  end

  def handle_call({:completion_query, _}, _from, state), do: {:reply, :ok, state}

  def handle_call(:completion_accept, _from, %{completion: %{} = c} = state) do
    reply =
      case Candidates.selected(c.list) do
        nil -> nil
        label -> {c.start, label}
      end

    changed(reply, %{state | completion: nil})
  end

  def handle_call(:completion_accept, _from, state), do: {:reply, nil, state}


  def handle_call(:completion_dismiss, _from, state),
    do: changed(:ok, %{state | completion: nil})

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

  def handle_call(:kill_top, _from, state),
    do: {:reply, List.first(state.kill_ring, ""), state}

  def handle_call({:kill_nth, i}, _from, state),
    do: {:reply, Enum.at(state.kill_ring, i, ""), state}

  def handle_call(:kill_size, _from, state), do: {:reply, length(state.kill_ring), state}

  def handle_call({:split, dir, ratio}, _from, state) do
    old = find_leaf(state.tree, state.active)
    new_leaf = %{type: :leaf, id: state.next_win, buffer: old.buffer, top: old.top, manual: false}
    split = %{type: :split, dir: dir, ratio: ratio, children: [old, new_leaf]}
    tree = replace_leaf(state.tree, state.active, split)
    changed(:ok, %{state | tree: tree, next_win: state.next_win + 1})
  end

  def handle_call({:delete_window_by_id, id}, _from, state) do
    case remove_leaf(state.tree, id) do
      nil ->
        {:reply, {:error, :sole_window}, state}

      tree ->
        active = if state.active == id, do: first_leaf(tree).id, else: state.active
        changed(:ok, %{state | tree: tree, active: active})
    end
  end

  def handle_call(:list_windows, _from, state),
    do: {:reply, leaf_ids_buffers(state.tree), state}

  def handle_call(:window_rects, _from, state),
    do: {:reply, leaf_rects(state.tree, {0.0, 0.0, 1.0, 1.0}), state}

  def handle_call({:set_active, id}, _from, state) do
    if find_leaf(state.tree, id),
      do: changed(:ok, %{state | active: id}),
      else: {:reply, {:error, :no_window}, state}
  end

  def handle_call(:active_window, _from, state), do: {:reply, state.active, state}

  def handle_call(:delete_window, _from, state) do
    case remove_leaf(state.tree, state.active) do
      nil ->
        {:reply, {:error, :sole_window}, state}

      tree ->
        changed(:ok, %{state | tree: tree, active: first_leaf(tree).id})
    end
  end

  def handle_call(:delete_other_windows, _from, state) do
    leaf = find_leaf(state.tree, state.active)
    changed(:ok, %{state | tree: leaf})
  end

  def handle_call(:other_window, _from, state) do
    ids = leaf_ids(state.tree)
    idx = Enum.find_index(ids, &(&1 == state.active)) || 0
    changed(:ok, %{state | active: Enum.at(ids, rem(idx + 1, length(ids)))})
  end

  def handle_call({:set_window_buffer, buffer}, _from, state) do
    unless Aimax.Core.Buffer.exists?(buffer), do: Aimax.Core.create_buffer(buffer)
    leaf = find_leaf(state.tree, state.active)
    tree = replace_leaf(state.tree, state.active, %{leaf | buffer: buffer, top: 0, manual: false})
    mru = Enum.take([buffer | List.delete(state.mru, buffer)], 50)
    changed(:ok, %{state | tree: tree, mru: mru})
  end

  def handle_call({:preview_buffer, buffer}, _from, state) do
    if Aimax.Core.Buffer.exists?(buffer) do
      leaf = find_leaf(state.tree, state.active)
      tree = replace_leaf(state.tree, state.active, %{leaf | buffer: buffer, top: 0, manual: false})
      changed(:ok, %{state | tree: tree})
    else
      {:reply, {:error, :no_buffer}, state}
    end
  end

  def handle_call({:restore_tree, spec, active_buffer}, _from, state) do
    {tree, next_win} = build_tree(spec, state.next_win)

    Enum.each(leaf_ids_buffers(tree), fn {_id, buffer} ->
      unless Aimax.Core.Buffer.exists?(buffer), do: Aimax.Core.create_buffer(buffer)
    end)

    active =
      Enum.find_value(leaf_ids_buffers(tree), fn {id, buffer} ->
        if buffer == active_buffer, do: id
      end) || first_leaf(tree).id

    changed(:ok, %{state | tree: tree, next_win: next_win, active: active})
  end

  defp changed(reply, state) do
    Events.broadcast_editor(:changed)
    {:reply, reply, state}
  end

  # --- minibuffer helpers (vertico-style: fuzzy filter + selection) ----------

  # what the minibuffer matches on: the whole input, except hierarchical
  # (on_complete) prompts, which match the segment after the last "/"
  defp mb_query(%{on_complete: oc, input: input}) when oc not in [nil, false],
    do: input |> String.split("/") |> List.last()

  defp mb_query(%{input: input}), do: input

  defp put_mb_input(mb, input) do
    mb = %{mb | input: input}
    %{mb | list: Candidates.put_query(mb.list, mb_query(mb))}
  end

  # (re)fill the backing buffer and park point at the end
  defp reset_minibuf_buffer(input) do
    unless Buffer.exists?(@minibuf), do: Aimax.Core.create_buffer(@minibuf)
    size = Buffer.byte_size(@minibuf)
    if size > 0, do: Buffer.delete_range(@minibuf, 0, size, source: :editor)
    if input != "", do: Buffer.append(@minibuf, input, source: :editor)
    Buffer.goto(@minibuf, Kernel.byte_size(input))
  end

  defp render_minibuffer(mb) do
    %{
      prompt: mb.prompt,
      input: mb.input,
      point: (Buffer.exists?(@minibuf) && Buffer.point(@minibuf)) || Kernel.byte_size(mb.input),
      candidates: Candidates.rows(mb.list),
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


  defp which_key(%{pending: []}), do: nil

  defp which_key(state) do
    buffer = find_leaf(state.tree, state.active).buffer
    local = Map.get(state.local_keymaps, buffer, %{})

    [local, state.keymap]
    |> Enum.flat_map(&Map.to_list/1)
    |> Enum.filter(fn {seq, _} -> List.starts_with?(seq, state.pending) and seq != state.pending end)
    |> Enum.map(fn {seq, cmd} -> %{key: Enum.join(Enum.drop(seq, length(state.pending)), " "), command: cmd} end)
    |> Enum.uniq_by(& &1.key)
    |> Enum.sort_by(& &1.key)
  end

  # --- tree helpers ----------------------------------------------------------

  defp active_buffer_of(state), do: find_leaf(state.tree, state.active).buffer

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
    total_lines: 1,
    cursor_line: 0,
    line: 1,
    col: 0
  }

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

  defp split_rows(:h, rows, _ratio), do: {rows, rows}

  defp split_rows(:v, rows, ratio) do
    a = max(round(rows * ratio), 3)
    {a, max(rows - a, 3)}
  end

  defp render_walk(%{type: :leaf, id: id, buffer: buffer} = leaf, rows, win_rows) do
    # the client's measured row count for this window wins over split math:
    # line height varies per buffer, so only the client knows what fits
    rows = Map.get(win_rows, id, rows)

    # one round trip per leaf — this runs on every render of every window
    snap = if Buffer.exists?(buffer), do: Buffer.render_snapshot(buffer), else: @empty_snapshot
    %{text: text, point: point, locals: locals} = snap

    # folds put top/cursor/total in VISIBLE-line space; the scroll and
    # auto-follow math below then works unchanged. Line *numbers* stay
    # logical (folds show numbering gaps, like Emacs). The no-fold case is
    # O(log n) rope lookups from the snapshot; folds still scan.
    {total_lines, cl, hidden_lines} =
      case snap.hidden do
        [] -> {snap.total_lines, snap.cursor_line, MapSet.new()}
        hidden -> visible_geometry(text, point, hidden)
      end

    top = leaf.top |> min(max(total_lines - 1, 0)) |> max(0)

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
      text: text,
      point: point,
      mark: snap.mark,
      version: snap.version,
      modified: snap.modified,
      mode: Map.get(locals, "mode-name") || "Fundamental",
      # free-form per-buffer modeline segment (agent connector, etc.)
      modeline_info: Map.get(locals, "modeline-info"),
      # buffer-group tag ("companion-of" is the pre-group legacy pointer)
      group: Map.get(locals, "group") || Map.get(locals, "companion-of"),
      ts_lang: Map.get(locals, "ts-lang"),
      overlays: snap.overlays,
      overlay_gen: snap.overlay_gen,
      hidden_lines: hidden_lines,
      line: snap.line,
      col: snap.col,
      style: Map.get(locals, "style"),
      render_mode: Map.get(locals, "render-mode"),
      # web buffers: the page the frame points at (render-mode "web")
      url: Map.get(locals, "url"),
      agent: agent_leaf(locals, text),
      preview_authored: Map.get(locals, "preview-authored") == true,
      top: top,
      rows: rows,
      total_lines: total_lines,
      line_numbers: Map.get(locals, "line-numbers") != "off",
      # extra CSS class on the window div (writing-mode centering etc.)
      window_class: Map.get(locals, "window-class") || nil
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

    %{
      blocks: Map.get(locals, "agent-blocks") || [],
      # the mark is a plain local, so text edits it doesn't know about
      # (undo, edits before it) can strand it past the end of the buffer —
      # clamp so the input region and cursor never vanish
      mark: mark |> min(byte_size(text) - marker_bytes) |> max(0),
      marker_bytes: marker_bytes,
      queued: Map.get(locals, "agent-queued") || [],
      slug: Map.get(locals, "agent-slug")
    }
  end

  defp agent_leaf(_, _), do: nil

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

  defp clear_manual(%{type: :leaf} = leaf), do: %{leaf | manual: false}

  defp clear_manual(%{type: :split} = split),
    do: %{split | children: Enum.map(split.children, &clear_manual/1)}

  defp rows_for(%{type: :leaf, id: id}, id, rows), do: rows
  defp rows_for(%{type: :leaf}, _id, _rows), do: nil

  defp rows_for(%{type: :split, dir: dir, children: [a, b]} = split, id, rows) do
    ratio = Map.get(split, :ratio, 0.5)
    {rows_a, rows_b} = split_rows(dir, rows, ratio)
    rows_for(a, id, rows_a) || rows_for(b, id, rows_b)
  end
end
