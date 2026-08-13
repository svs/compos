defmodule Aimax.Core.Buffer do
  @moduledoc """
  A buffer is a process: rope + point + undo history + metadata. All content
  mutations broadcast change events (with provenance) via `Aimax.Core.Events`.

  This is deliberately a *primitive* layer: motion and editing operations only.
  Commands (kill-line-the-command, find-file, ...) are Scheme, built on these.

  Undo: persistent ropes make snapshots free — history is a list of
  `{rope, point}` (capped). TODO: undo grouping (amalgamate consecutive
  self-inserts), redo via Emacs-style undo-the-undos.

  Point is a byte offset; motion ops are grapheme-aware. TODO: goal column
  for line motion, marks, text properties.

  Per-window points (Emacs window-point): `win_points` holds a point/mark/goal
  per window id for every window displaying this buffer EXCEPT the one
  swapped in (the selected window of the last-active frame — the Editor
  deletes its entry and the plain buffer point is authoritative for it).
  Entries adjust through edits like markers, atomically with the edit;
  insertion exactly at a stored window point leaves it before the inserted
  text (Emacs window-point-insertion-type nil).
  """

  # :temporary — a crashed buffer must not restart-storm the supervisor
  # (a restart would resurrect it empty anyway; better to stay dead loudly)
  use GenServer, restart: :temporary

  alias Aimax.Core.{Events, Rope, Text, TS}

  @registry Aimax.Core.BufferRegistry
  @undo_limit 500

  defstruct name: nil,
            rope: nil,
            bin: nil,
            version: 0,
            saved_version: 0,
            path: nil,
            point: 0,
            mark: nil,
            read_only: false,
            history: [],
            history_len: 0,
            locals: %{},
            goal_col: nil,
            last_insert_end: nil,
            insert_run: 0,
            undo_next: 0,
            overlays: %{},
            overlay_gen: 0,
            hidden: %{},
            ts: nil,
            win_points: %{}

  # --- client ----------------------------------------------------------------

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  def via(name), do: {:via, Registry, {@registry, name}}

  def exists?(name), do: Registry.lookup(@registry, name) != []

  def text(name), do: GenServer.call(via(name), :text)
  def byte_size(name), do: GenServer.call(via(name), :byte_size)
  def version(name), do: GenServer.call(via(name), :version)
  def path(name), do: GenServer.call(via(name), :path)
  def modified?(name), do: GenServer.call(via(name), :modified?)
  def point(name), do: GenServer.call(via(name), :point)

  def goto(name, pos), do: GenServer.call(via(name), {:goto, pos})

  def mark(name), do: GenServer.call(via(name), :mark)
  def set_mark(name, pos), do: GenServer.call(via(name), {:set_mark, pos})

  def read_only?(name), do: GenServer.call(via(name), :read_only?)
  def set_read_only(name, bool), do: GenServer.call(via(name), {:set_read_only, bool})

  # buffer-local variables (mode name, mode state, anything Scheme wants)
  def set_local(name, key, val), do: GenServer.call(via(name), {:set_local, key, val})
  def get_local(name, key), do: GenServer.call(via(name), {:get_local, key})
  def locals(name), do: GenServer.call(via(name), :locals)

  # overlays: per-tag face ranges (fontification). Byte positions auto-adjust
  # on edits (like mark); modes replace their whole tag set on recompute.
  def set_overlays(name, tag, ranges), do: GenServer.call(via(name), {:set_overlays, tag, ranges})
  def clear_overlays(name, tag \\ :all), do: GenServer.call(via(name), {:clear_overlays, tag})
  def overlays(name), do: GenServer.call(via(name), :overlays)
  def overlay_gen(name), do: GenServer.call(via(name), :overlay_gen)

  # hidden: folded byte ranges — filtered out of the display, skipped by
  # line motion. Auto-adjusted like overlays.
  #
  # Ranges are TAGGED, like overlays, because a buffer has more than one
  # fold owner: org folds headlines, the agent transcript folds tool
  # output, diff-mode folds hunks, code-browse folds bodies. Each owner
  # replaces its own tag's ranges. The display hides the union.
  @default_tag "default"

  def set_hidden(name, ranges), do: set_hidden(name, @default_tag, ranges)

  def set_hidden(name, tag, ranges), do: GenServer.call(via(name), {:set_hidden, tag, ranges})

  @doc "One tag's ranges, or the union of every tag with `:all`."
  def hidden(name, tag \\ :all), do: GenServer.call(via(name), {:hidden, tag})

  def clear_hidden(name, tag \\ :all), do: GenServer.call(via(name), {:clear_hidden, tag})

  def forward_word(name), do: GenServer.call(via(name), {:motion, :forward_word})
  def backward_word(name), do: GenServer.call(via(name), {:motion, :backward_word})

  @doc "Search for `q` from byte offset. Returns {start, stop} byte range or nil."
  def search(name, q, from, dir \\ :forward),
    do: GenServer.call(via(name), {:search, q, from, dir})

  @doc "Insert at point, advancing point."
  def insert(name, text, opts \\ []), do: GenServer.call(via(name), {:insert, text, source(opts)})

  def append(name, text, opts \\ []), do: GenServer.call(via(name), {:append, text, source(opts)})

  # `:locals` writes buffer-locals in the SAME message as the insert. A
  # local that names a byte position (the agent's saved mark) must move
  # with the text it points at. Written in a second call, the broadcast
  # from this one already painted a frame in which the position is stale.
  def insert_at(name, pos, text, opts \\ []),
    do:
      GenServer.call(
        via(name),
        {:insert_at, pos, text, source(opts), Keyword.get(opts, :locals, %{})}
      )

  def delete_range(name, pos, len, opts \\ []),
    do: GenServer.call(via(name), {:delete_range, pos, len, source(opts)})

  @doc "Delete n chars forward from point (negative = backward). Returns deleted text."
  def delete_char(name, n \\ 1, opts \\ []),
    do: GenServer.call(via(name), {:delete_char, n, source(opts)})

  @doc "Delete point..end-of-line (or the newline if at eol). Returns killed text."
  def kill_line(name, opts \\ []), do: GenServer.call(via(name), {:kill_line, source(opts)})

  @doc "1-based logical line -> {start_byte, line_text sans newline}, clamped."
  def line_at(name, line), do: GenServer.call(via(name), {:line_at, line})

  def forward_char(name), do: GenServer.call(via(name), {:motion, :forward})
  def backward_char(name), do: GenServer.call(via(name), {:motion, :backward})
  def next_line(name), do: GenServer.call(via(name), {:motion, :next_line})
  def previous_line(name), do: GenServer.call(via(name), {:motion, :prev_line})
  def beginning_of_line(name), do: GenServer.call(via(name), {:motion, :bol})
  def end_of_line(name), do: GenServer.call(via(name), {:motion, :eol})
  def beginning_of_buffer(name), do: GenServer.call(via(name), {:motion, :bob})
  def end_of_buffer(name), do: GenServer.call(via(name), {:motion, :eob})

  def undo(name), do: GenServer.call(via(name), :undo)

  @doc """
  All render inputs (text, point, mark, version, locals, overlays, hidden)
  in one call. With a win_id, point/mark/cursor geometry come from that
  window's stored point when it has one (the swapped-in window doesn't —
  it falls through to the buffer point, which is its live point).
  """
  def render_snapshot(name, win_id \\ nil),
    do: GenServer.call(via(name), {:render_snapshot, win_id})

  # per-window points: the Editor drives these on selection changes
  @doc "Install win_id's stored point/mark/goal as the buffer's and drop the entry."
  def win_point_swap_in(name, win_id), do: GenServer.call(via(name), {:wp_swap_in, win_id})

  @doc "Store the buffer's point/mark/goal under win_id (window deselected)."
  def win_point_save(name, win_id), do: GenServer.call(via(name), {:wp_save, win_id})

  def set_win_point(name, win_id, pos), do: GenServer.call(via(name), {:wp_set, win_id, pos})
  def drop_win_point(name, win_id), do: GenServer.call(via(name), {:wp_drop, win_id})

  @doc "win_id's effective point: its stored one, or the buffer point (swapped in / no entry)."
  def win_point(name, win_id), do: GenServer.call(via(name), {:wp_get, win_id})

  @doc """
  Highlight spans from the buffer's incremental tree-sitter state ([] if the
  buffer has no ts-lang). Cached per version, shared by every client.
  """
  def ts_highlight(name), do: GenServer.call(via(name), :ts_highlight, 30_000)

  @doc """
  Break the undo chain (Emacs: any command other than undo does this).
  After a break, undo reverses the previous undos — that IS redo.
  """
  def break_undo_chain(name), do: GenServer.call(via(name), :break_undo_chain)

  @doc "Write buffer to its path (or the given path). {:ok, path} | {:error, :no_path}."
  def save(name, path \\ nil), do: GenServer.call(via(name), {:save, path})

  # for buffers whose contents were written by other means (remote files):
  # the buffer counts as saved without touching the local filesystem
  def mark_saved(name), do: GenServer.call(via(name), :mark_saved)

  defp source(opts), do: Keyword.get(opts, :source, :user)

  # --- server ----------------------------------------------------------------

  @impl true
  def init(opts) do
    text =
      case Keyword.get(opts, :path) do
        nil -> Keyword.get(opts, :text, "")
        path -> if File.exists?(path), do: File.read!(path), else: ""
      end

    {:ok,
     %__MODULE__{
       name: Keyword.fetch!(opts, :name),
       rope: Rope.new(text),
       path: Keyword.get(opts, :path)
     }}
  end

  @impl true
  def handle_call(:text, _from, state) do
    {text, state} = fetch_text(state)
    {:reply, text, state}
  end
  def handle_call(:byte_size, _from, state), do: {:reply, Rope.byte_size(state.rope), state}
  def handle_call(:version, _from, state), do: {:reply, state.version, state}
  def handle_call(:path, _from, state), do: {:reply, state.path, state}
  def handle_call(:point, _from, state), do: {:reply, state.point, state}

  def handle_call(:modified?, _from, state),
    do: {:reply, state.version != state.saved_version, state}

  def handle_call({:goto, pos}, _from, state),
    do: {:reply, :ok, %{state | point: clamp(pos, state)}}

  def handle_call(:mark, _from, state), do: {:reply, state.mark, state}

  def handle_call(:read_only?, _from, state), do: {:reply, state.read_only, state}

  def handle_call({:set_read_only, bool}, _from, state),
    do: {:reply, :ok, %{state | read_only: bool}}

  def handle_call({:set_local, key, val}, _from, state) do
    state = %{state | locals: Map.put(state.locals, key, val)}
    state = if key == "ts-lang", do: init_ts(state, val), else: state
    # locals feed rendering ('style, mode-name, line-numbers) and persistence —
    # clients must repaint and the desktop must persist without a buffer edit
    Events.broadcast_editor(:locals)
    {:reply, :ok, state}
  end

  def handle_call({:get_local, key}, _from, state),
    do: {:reply, Map.get(state.locals, key), state}

  def handle_call(:locals, _from, state), do: {:reply, state.locals, state}

  def handle_call({:set_overlays, tag, ranges}, _from, state) do
    {:reply, :ok,
     %{
       state
       | overlays: Map.put(state.overlays, tag, ranges),
         overlay_gen: state.overlay_gen + 1
     }}
  end

  def handle_call({:clear_overlays, :all}, _from, state),
    do: {:reply, :ok, %{state | overlays: %{}, overlay_gen: state.overlay_gen + 1}}

  def handle_call({:clear_overlays, tag}, _from, state) do
    {:reply, :ok,
     %{
       state
       | overlays: Map.delete(state.overlays, tag),
         overlay_gen: state.overlay_gen + 1
     }}
  end

  def handle_call(:overlays, _from, state),
    do: {:reply, state.overlays |> Map.values() |> Enum.concat(), state}

  def handle_call(:overlay_gen, _from, state), do: {:reply, state.overlay_gen, state}

  # an empty range list drops the tag: an owner with nothing folded costs
  # nothing to union
  def handle_call({:set_hidden, tag, []}, _from, state),
    do: {:reply, :ok, %{state | hidden: Map.delete(state.hidden, tag)}}

  def handle_call({:set_hidden, tag, ranges}, _from, state),
    do: {:reply, :ok, %{state | hidden: Map.put(state.hidden, tag, Enum.sort(ranges))}}

  def handle_call({:hidden, :all}, _from, state), do: {:reply, hidden_union(state), state}

  def handle_call({:hidden, tag}, _from, state),
    do: {:reply, Map.get(state.hidden, tag, []), state}

  def handle_call({:clear_hidden, :all}, _from, state),
    do: {:reply, :ok, %{state | hidden: %{}}}

  def handle_call({:clear_hidden, tag}, _from, state),
    do: {:reply, :ok, %{state | hidden: Map.delete(state.hidden, tag)}}

  # read-only blocks :user mutations only — programmatic sources (:editor,
  # :process, agents) are the inhibit-read-only path (dired regenerates its
  # own read-only buffer this way)
  def handle_call({:insert, _, :user}, _f, %{read_only: true} = s), do: ro(s)
  def handle_call({:append, _, :user}, _f, %{read_only: true} = s), do: ro(s)
  def handle_call({:insert_at, _, _, :user, _locals}, _f, %{read_only: true} = s), do: ro(s)
  def handle_call({:delete_range, _, _, :user}, _f, %{read_only: true} = s), do: ro(s)
  def handle_call({:delete_char, _, :user}, _f, %{read_only: true} = s), do: ro(s)
  def handle_call({:kill_line, :user}, _f, %{read_only: true} = s), do: ro(s)

  def handle_call({:line_at, line}, _from, state) do
    rope = state.rope
    count = Rope.line_count(rope)
    line = line |> max(1) |> min(count)
    s = Rope.line_to_byte(rope, line - 1)
    e = if line == count, do: Rope.byte_size(rope), else: Rope.line_to_byte(rope, line)
    {:reply, {s, rope |> Rope.slice(s, e - s) |> String.trim_trailing("\n")}, state}
  end

  def handle_call({:set_mark, nil}, _from, state), do: {:reply, :ok, %{state | mark: nil}}

  def handle_call({:set_mark, pos}, _from, state),
    do: {:reply, :ok, %{state | mark: clamp(pos, state)}}

  def handle_call({:search, q, from, dir}, _from, state) do
    {text, state} = fetch_text(state)

    result =
      case dir do
        :forward ->
          scope_len = Kernel.byte_size(text) - from

          case scope_len > 0 && :binary.match(text, q, scope: {from, scope_len}) do
            {s, l} -> {s, s + l}
            _ -> nil
          end

        :backward ->
          # scope so the scan stops at `from` (matches must start before it)
          scope_len =
            (from - 1 + Kernel.byte_size(q))
            |> min(Kernel.byte_size(text))
            |> max(0)

          case scope_len > 0 && :binary.matches(text, q, scope: {0, scope_len}) do
            [_ | _] = matches ->
              {s, l} = List.last(matches)
              {s, s + l}

            _ ->
              nil
          end
      end

    {:reply, result, state}
  end

  def handle_call({:insert, text, src}, _from, state) do
    # do_insert's point adjustment already advances point past the insertion
    {:reply, :ok, do_insert(state, state.point, text, src)}
  end

  def handle_call({:append, text, src}, _from, state) do
    {:reply, :ok, do_insert(state, Rope.byte_size(state.rope), text, src)}
  end

  def handle_call({:insert_at, pos, text, src, locals}, _from, state) do
    # locals first: do_insert broadcasts, and the frame it paints must
    # already see them
    state = %{state | locals: Map.merge(state.locals, locals)}
    {:reply, :ok, do_insert(state, pos, text, src)}
  end

  def handle_call({:delete_range, pos, len, src}, _from, state) do
    {:reply, :ok, do_delete(state, pos, len, src)}
  end

  def handle_call({:delete_char, n, src}, _from, state) do
    {text, state} = fetch_text(state)

    {pos, len} =
      if n >= 0 do
        {state.point, chars_len(text, state.point, n)}
      else
        start = back_up(text, state.point, -n)
        {start, state.point - start}
      end

    deleted = binary_part(text, pos, len)
    state = do_delete(state, pos, len, src)
    {:reply, {:ok, deleted}, %{state | point: pos}}
  end

  def handle_call({:kill_line, src}, _from, state) do
    {text, state} = fetch_text(state)
    {_bol, eol} = Text.line_bounds(text, state.point)
    len = if state.point == eol and eol < Kernel.byte_size(text), do: 1, else: eol - state.point

    if len == 0 do
      {:reply, {:ok, ""}, state}
    else
      killed = binary_part(text, state.point, len)
      {:reply, {:ok, killed}, do_delete(state, state.point, len, src)}
    end
  end

  def handle_call({:motion, motion}, _from, state) do
    {text, state} = fetch_text(state)

    state =
      if motion in [:next_line, :prev_line] do
        # goal column: crossing a short line must not lose the column
        {bol, _} = Text.line_bounds(text, state.point)
        %{state | goal_col: state.goal_col || state.point - bol}
      else
        %{state | goal_col: nil}
      end

    point = apply_motion(motion, text, state.point, state.goal_col)

    # line motion may not land inside a fold — keep going in the same
    # direction; if the fold runs to a buffer edge, stay where we were.
    # Every tag's ranges hide, so motion reads the union.
    hidden = hidden_union(state)

    point =
      if motion in [:next_line, :prev_line] and in_hidden?(point, hidden),
        do: skip_hidden(motion, text, point, state.goal_col, hidden, state.point),
        else: point

    {:reply, point, %{state | point: point}}
  end

  # Emacs undo: the pre-undo state is pushed onto the same history, so undos
  # are themselves undoable and no state is ever lost. `undo_next` walks the
  # chain during a run of consecutive undos; any other command breaks the
  # chain, after which undo reverses the undos (redo).
  def handle_call(:undo, _from, state) do
    case Enum.at(state.history, state.undo_next) do
      nil ->
        {:reply, {:error, :no_undo}, state}

      {rope, point, mark} ->
        state = push_history(state, {state.rope, state.point, state.mark})

        state = %{
          state
          | rope: rope,
            bin: nil,
            point: point,
            mark: mark,
            version: state.version + 1,
            # +1 for the push above, +1 to step past the restored state
            undo_next: state.undo_next + 2,
            goal_col: nil,
            last_insert_end: nil,
            insert_run: 0
        }

        state = ts_invalidate(state)
        broadcast(state, 0, "", 0, :undo)
        {:reply, :ok, state}
    end
  end

  # everything the renderer needs, in one round trip; line geometry is
  # O(log n) rope lookups, not text scans
  def handle_call({:render_snapshot, win_id}, _from, state) do
    {text, state} = fetch_text(state)

    {point, mark} =
      case win_id && state.win_points[win_id] do
        # undo swaps the rope wholesale under stored points — clamp on read
        %{point: p, mark: m} -> {clamp(p, state), m && clamp(m, state)}
        nil -> {state.point, state.mark}
      end

    cursor_line = Rope.byte_to_line(state.rope, point)

    {:reply,
     %{
       text: text,
       point: point,
       mark: mark,
       version: state.version,
       modified: state.version != state.saved_version,
       locals: state.locals,
       overlays: state.overlays |> Map.values() |> Enum.concat(),
       overlay_gen: state.overlay_gen,
       hidden: hidden_union(state),
       path: state.path,
       read_only: state.read_only,
       total_lines: Rope.line_count(state.rope),
       cursor_line: cursor_line,
       line: cursor_line + 1,
       col: point - Rope.line_to_byte(state.rope, cursor_line)
     }, state}
  end

  def handle_call({:wp_swap_in, win_id}, _from, state) do
    case state.win_points[win_id] do
      nil ->
        # first display in this window: it inherits the buffer point
        {:reply, :ok, state}

      %{point: p, mark: m, goal: g} ->
        {:reply, :ok,
         %{
           state
           | point: clamp(p, state),
             mark: m && clamp(m, state),
             goal_col: g,
             win_points: Map.delete(state.win_points, win_id)
         }}
    end
  end

  def handle_call({:wp_save, win_id}, _from, state) do
    entry = %{point: state.point, mark: state.mark, goal: state.goal_col}
    {:reply, :ok, %{state | win_points: Map.put(state.win_points, win_id, entry)}}
  end

  def handle_call({:wp_set, win_id, pos}, _from, state) do
    entry = %{point: clamp(pos, state), mark: nil, goal: nil}
    {:reply, :ok, %{state | win_points: Map.put(state.win_points, win_id, entry)}}
  end

  def handle_call({:wp_drop, win_id}, _from, state),
    do: {:reply, :ok, %{state | win_points: Map.delete(state.win_points, win_id)}}

  def handle_call({:wp_get, win_id}, _from, state) do
    case state.win_points[win_id] do
      %{point: p} -> {:reply, clamp(p, state), state}
      nil -> {:reply, state.point, state}
    end
  end

  def handle_call(:ts_highlight, _from, %{ts: nil} = state), do: {:reply, [], state}

  def handle_call(:ts_highlight, _from, %{ts: %{spans: spans}} = state) when spans != nil,
    do: {:reply, spans, state}

  def handle_call(:ts_highlight, _from, %{ts: ts} = state) do
    {text, state} = fetch_text(state)
    spans = TS.ts_state_highlight(ts.res, text)
    {:reply, spans, %{state | ts: %{ts | spans: spans}}}
  end

  def handle_call(:break_undo_chain, _from, state),
    do: {:reply, :ok, %{state | undo_next: 0}}

  def handle_call(:mark_saved, _from, state),
    do: {:reply, :ok, %{state | saved_version: state.version}}

  def handle_call({:save, override}, _from, state) do
    case override || state.path do
      nil ->
        {:reply, {:error, :no_path}, state}

      path ->
        {text, state} = fetch_text(state)
        File.write!(path, text)
        {:reply, {:ok, path}, %{state | path: path, saved_version: state.version}}
    end
  end

  # --- mutation helpers ------------------------------------------------------

  defp do_insert(state, pos, text, src) do
    state = maybe_snapshot_insert(state, pos, text, src)
    old_rope = state.rope
    state = %{state | rope: Rope.insert(state.rope, pos, text), bin: nil, version: state.version + 1}
    state = ts_track(state, old_rope, pos, pos, pos + Kernel.byte_size(text))
    state = adjust_point_insert(state, pos, Kernel.byte_size(text))
    state = adjust_ranges(state, &adjust_insert(&1, pos, Kernel.byte_size(text)))
    state = %{
      state
      | goal_col: nil,
        last_insert_end: pos + Kernel.byte_size(text),
        undo_next: 0
    }

    broadcast(state, pos, text, 0, src)
    state
  end

  # amalgamate consecutive single-char self-inserts into one undo step
  # (Emacs groups ~20) — undoing a typed word char-by-char is misery
  defp maybe_snapshot_insert(state, pos, text, :user)
       when Kernel.byte_size(text) == 1 and text != "\n" do
    # amalgamate only onto a previous self-insert (insert_run > 0) — never
    # chain onto a newline/paste/programmatic insert's undo step
    if state.last_insert_end == pos and state.insert_run > 0 and state.insert_run < 20 do
      %{state | insert_run: state.insert_run + 1}
    else
      %{snapshot(state) | insert_run: 1}
    end
  end

  defp maybe_snapshot_insert(state, _pos, _text, _src),
    do: %{snapshot(state) | insert_run: 0}

  defp do_delete(state, pos, len, src) do
    state = snapshot(state)
    old_rope = state.rope
    state = %{state | rope: Rope.delete(state.rope, pos, len), bin: nil, version: state.version + 1}
    state = ts_track(state, old_rope, pos, pos + len, pos)
    state = adjust_point_delete(state, pos, len)
    state = adjust_ranges(state, &adjust_delete(&1, pos, len))
    state = %{state | goal_col: nil, last_insert_end: nil, insert_run: 0, undo_next: 0}
    broadcast(state, pos, "", len, src)
    state
  end

  # trim lazily at 2x the cap: amortizes the O(limit) Enum.take so a burst of
  # keystrokes doesn't rebuild a 500-cons list on every edit
  defp snapshot(state),
    do: push_history(state, {state.rope, state.point, state.mark})

  defp push_history(state, entry) do
    history = [entry | state.history]
    len = state.history_len + 1

    if len > @undo_limit * 2,
      do: %{state | history: Enum.take(history, @undo_limit), history_len: @undo_limit},
      else: %{state | history: history, history_len: len}
  end

  defp adjust_point_insert(state, pos, len) do
    %{
      state
      | point: adjust_insert(state.point, pos, len),
        mark: state.mark && adjust_insert(state.mark, pos, len),
        win_points: adjust_win_points(state.win_points, &adjust_insert_stay(&1, pos, len))
    }
  end

  defp adjust_point_delete(state, pos, len) do
    %{
      state
      | point: adjust_delete(state.point, pos, len),
        mark: state.mark && adjust_delete(state.mark, pos, len),
        win_points: adjust_win_points(state.win_points, &adjust_delete(&1, pos, len))
    }
  end

  defp adjust_win_points(win_points, f) do
    Map.new(win_points, fn {w, wp} ->
      {w, %{wp | point: f.(wp.point), mark: wp.mark && f.(wp.mark)}}
    end)
  end

  # shift overlay + hidden range endpoints through an edit; collapsed
  # ranges (start >= end after a delete) are dropped
  defp adjust_ranges(state, f) do
    overlays =
      Map.new(state.overlays, fn {tag, ranges} ->
        {tag,
         ranges
         |> Enum.map(fn {s, e, face} -> {f.(s), f.(e), face} end)
         |> Enum.reject(fn {s, e, _} -> s >= e end)}
      end)

    # the same adjustment, per tag: a tag that loses every range drops out
    hidden =
      state.hidden
      |> Enum.map(fn {tag, ranges} ->
        {tag,
         ranges
         |> Enum.map(fn {s, e} -> {f.(s), f.(e)} end)
         |> Enum.reject(fn {s, e} -> s >= e end)}
      end)
      |> Enum.reject(fn {_tag, ranges} -> ranges == [] end)
      |> Map.new()

    %{state | overlays: overlays, hidden: hidden}
  end

  defp hidden_union(state),
    do: state.hidden |> Map.values() |> Enum.concat() |> Enum.sort()

  defp adjust_insert(p, pos, len) when p >= pos, do: p + len
  defp adjust_insert(p, _pos, _len), do: p

  # window points don't advance over text inserted exactly at them
  # (Emacs window-point-insertion-type nil) — the buffer point does
  defp adjust_insert_stay(p, pos, len) when p > pos, do: p + len
  defp adjust_insert_stay(p, _pos, _len), do: p

  defp adjust_delete(p, pos, len) do
    cond do
      p <= pos -> p
      p >= pos + len -> p - len
      true -> pos
    end
  end

  defp broadcast(state, pos, inserted, deleted, src) do
    Events.broadcast(state.name, %{
      version: state.version,
      pos: pos,
      inserted: inserted,
      deleted: deleted,
      source: src
    })
  end

  defp ro(state), do: {:reply, {:error, :read_only}, state}

  # flattening the rope is O(buffer) — do it once per version, not per read
  defp fetch_text(%{bin: nil} = state) do
    bin = Rope.to_binary(state.rope)
    {bin, %{state | bin: bin}}
  end

  defp fetch_text(state), do: {state.bin, state}

  # --- incremental tree-sitter ------------------------------------------------

  defp init_ts(state, lang) do
    case lang && TS.ts_state_new(lang) do
      nil -> %{state | ts: nil}
      res -> %{state | ts: %{res: res, spans: nil}}
    end
  end

  # feed the edit into the held tree; points are O(log n) rope lookups.
  # start is identical in old and new text; old_end reads the pre-edit rope,
  # new_end the post-edit one.
  defp ts_track(%{ts: nil} = state, _old_rope, _start, _old_end, _new_end), do: state

  defp ts_track(%{ts: ts} = state, old_rope, start, old_end, new_end) do
    {sr, sc} = ts_point(old_rope, start)
    {oer, oec} = ts_point(old_rope, old_end)
    {ner, nec} = ts_point(state.rope, new_end)
    TS.ts_state_edit(ts.res, start, old_end, new_end, sr, sc, oer, oec, ner, nec)
    %{state | ts: %{ts | spans: nil}}
  end

  # undo (or any wholesale content swap): no edit to feed — drop the tree
  defp ts_invalidate(%{ts: nil} = state), do: state

  defp ts_invalidate(%{ts: ts} = state) do
    TS.ts_state_reset(ts.res)
    %{state | ts: %{ts | spans: nil}}
  end

  defp ts_point(rope, pos) do
    line = Rope.byte_to_line(rope, pos)
    {line, pos - Rope.line_to_byte(rope, line)}
  end

  defp clamp(pos, state), do: pos |> max(0) |> min(Rope.byte_size(state.rope))

  # --- text geometry (grapheme-aware, byte offsets) --------------------------

  # byte length of the next n graphemes — iterates instead of materializing
  # the whole rest of the buffer as a grapheme list
  defp chars_len(text, pos, n) do
    rest = binary_part(text, pos, Kernel.byte_size(text) - pos)
    take_graphemes(rest, n, 0)
  end

  defp take_graphemes(_bin, 0, acc), do: acc

  defp take_graphemes(bin, n, acc) do
    case String.next_grapheme(bin) do
      nil -> acc
      {g, rest} -> take_graphemes(rest, n - 1, acc + Kernel.byte_size(g))
    end
  end

  defp back_up(text, pos, n), do: Text.back_graphemes(text, pos, n)

  defp apply_motion(motion, text, pos, goal_col \\ nil)

  defp apply_motion(:forward, text, pos, _), do: pos + chars_len(text, pos, 1)
  defp apply_motion(:backward, text, pos, _), do: back_up(text, pos, 1)
  defp apply_motion(:bob, _text, _pos, _), do: 0
  defp apply_motion(:eob, text, _pos, _), do: Kernel.byte_size(text)
  defp apply_motion(:bol, text, pos, _), do: text |> Text.line_bounds(pos) |> elem(0)
  defp apply_motion(:eol, text, pos, _), do: text |> Text.line_bounds(pos) |> elem(1)

  defp apply_motion(:next_line, text, pos, goal) do
    {bol, eol} = Text.line_bounds(text, pos)
    col = goal || pos - bol

    if eol >= Kernel.byte_size(text) do
      pos
    else
      {nbol, neol} = Text.line_bounds(text, eol + 1)
      min(nbol + col, neol)
    end
  end

  defp apply_motion(:prev_line, text, pos, goal) do
    {bol, _eol} = Text.line_bounds(text, pos)
    col = goal || pos - bol

    if bol == 0 do
      pos
    else
      {pbol, peol} = Text.line_bounds(text, bol - 1)
      min(pbol + col, peol)
    end
  end

  # words: [A-Za-z0-9_] runs, Emacs-style — skip separators, then the word
  defp apply_motion(:forward_word, text, pos, _) do
    len = Kernel.byte_size(text)
    pos = skip_while(text, pos, len, &(!word_byte?(&1)))
    skip_while(text, pos, len, &word_byte?/1)
  end

  defp apply_motion(:backward_word, text, pos, _) do
    pos = skip_back_while(text, pos, &(!word_byte?(&1)))
    skip_back_while(text, pos, &word_byte?/1)
  end

  defp in_hidden?(p, hidden), do: Enum.any?(hidden, fn {s, e} -> p > s and p <= e end)

  defp skip_hidden(motion, text, point, goal, hidden, orig) do
    next = apply_motion(motion, text, point, goal)

    cond do
      next == point -> orig
      in_hidden?(next, hidden) -> skip_hidden(motion, text, next, goal, hidden, orig)
      true -> next
    end
  end

  defp word_byte?(b),
    do: b in ?a..?z or b in ?A..?Z or b in ?0..?9 or b == ?_ or b > 127

  defp skip_while(_text, pos, len, _f) when pos >= len, do: pos

  defp skip_while(text, pos, len, f) do
    if f.(:binary.at(text, pos)), do: skip_while(text, pos + 1, len, f), else: pos
  end

  defp skip_back_while(_text, 0, _f), do: 0

  defp skip_back_while(text, pos, f) do
    if f.(:binary.at(text, pos - 1)), do: skip_back_while(text, pos - 1, f), else: pos
  end
end
