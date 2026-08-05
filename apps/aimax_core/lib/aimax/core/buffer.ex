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
  for line motion, marks, per-window points, text properties.
  """

  # :temporary — a crashed buffer must not restart-storm the supervisor
  # (a restart would resurrect it empty anyway; better to stay dead loudly)
  use GenServer, restart: :temporary

  alias Aimax.Core.{Events, Rope}

  @registry Aimax.Core.BufferRegistry
  @undo_limit 500

  defstruct name: nil,
            rope: nil,
            version: 0,
            saved_version: 0,
            path: nil,
            point: 0,
            mark: nil,
            read_only: false,
            history: [],
            locals: %{},
            goal_col: nil,
            last_insert_end: nil,
            insert_run: 0,
            undo_next: 0,
            overlays: %{},
            overlay_gen: 0,
            hidden: []

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
  def set_hidden(name, ranges), do: GenServer.call(via(name), {:set_hidden, ranges})
  def hidden(name), do: GenServer.call(via(name), :hidden)

  def forward_word(name), do: GenServer.call(via(name), {:motion, :forward_word})
  def backward_word(name), do: GenServer.call(via(name), {:motion, :backward_word})

  @doc "Search for `q` from byte offset. Returns {start, stop} byte range or nil."
  def search(name, q, from, dir \\ :forward),
    do: GenServer.call(via(name), {:search, q, from, dir})

  @doc "Insert at point, advancing point."
  def insert(name, text, opts \\ []), do: GenServer.call(via(name), {:insert, text, source(opts)})

  def append(name, text, opts \\ []), do: GenServer.call(via(name), {:append, text, source(opts)})

  def insert_at(name, pos, text, opts \\ []),
    do: GenServer.call(via(name), {:insert_at, pos, text, source(opts)})

  def delete_range(name, pos, len, opts \\ []),
    do: GenServer.call(via(name), {:delete_range, pos, len, source(opts)})

  @doc "Delete n chars forward from point (negative = backward). Returns deleted text."
  def delete_char(name, n \\ 1, opts \\ []),
    do: GenServer.call(via(name), {:delete_char, n, source(opts)})

  @doc "Delete point..end-of-line (or the newline if at eol). Returns killed text."
  def kill_line(name, opts \\ []), do: GenServer.call(via(name), {:kill_line, source(opts)})

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
  Break the undo chain (Emacs: any command other than undo does this).
  After a break, undo reverses the previous undos — that IS redo.
  """
  def break_undo_chain(name), do: GenServer.call(via(name), :break_undo_chain)

  @doc "Write buffer to its path (or the given path). {:ok, path} | {:error, :no_path}."
  def save(name, path \\ nil), do: GenServer.call(via(name), {:save, path})

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
  def handle_call(:text, _from, state), do: {:reply, Rope.to_binary(state.rope), state}
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

  def handle_call({:set_local, key, val}, _from, state),
    do: {:reply, :ok, %{state | locals: Map.put(state.locals, key, val)}}

  def handle_call({:get_local, key}, _from, state),
    do: {:reply, Map.get(state.locals, key), state}

  def handle_call(:locals, _from, state), do: {:reply, state.locals, state}

  # read-only blocks :user mutations only — programmatic sources (:editor,
  # :process, agents) are the inhibit-read-only path (dired regenerates its
  # own read-only buffer this way)
  def handle_call({:insert, _, :user}, _f, %{read_only: true} = s), do: ro(s)
  def handle_call({:append, _, :user}, _f, %{read_only: true} = s), do: ro(s)
  def handle_call({:insert_at, _, _, :user}, _f, %{read_only: true} = s), do: ro(s)
  def handle_call({:delete_range, _, _, :user}, _f, %{read_only: true} = s), do: ro(s)
  def handle_call({:delete_char, _, :user}, _f, %{read_only: true} = s), do: ro(s)
  def handle_call({:kill_line, :user}, _f, %{read_only: true} = s), do: ro(s)

  def handle_call({:set_mark, nil}, _from, state), do: {:reply, :ok, %{state | mark: nil}}

  def handle_call({:set_mark, pos}, _from, state),
    do: {:reply, :ok, %{state | mark: clamp(pos, state)}}

  def handle_call({:search, q, from, dir}, _from, state) do
    text = Rope.to_binary(state.rope)

    result =
      case dir do
        :forward ->
          scope_len = Kernel.byte_size(text) - from

          case scope_len > 0 && :binary.match(text, q, scope: {from, scope_len}) do
            {s, l} -> {s, s + l}
            _ -> nil
          end

        :backward ->
          text
          |> :binary.matches(q)
          |> Enum.filter(fn {s, _} -> s < from end)
          |> List.last()
          |> case do
            {s, l} -> {s, s + l}
            nil -> nil
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

  def handle_call({:insert_at, pos, text, src}, _from, state) do
    {:reply, :ok, do_insert(state, pos, text, src)}
  end

  def handle_call({:delete_range, pos, len, src}, _from, state) do
    {:reply, :ok, do_delete(state, pos, len, src)}
  end

  def handle_call({:delete_char, n, src}, _from, state) do
    text = Rope.to_binary(state.rope)

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
    text = Rope.to_binary(state.rope)
    {_bol, eol} = line_bounds(text, state.point)
    len = if state.point == eol and eol < Kernel.byte_size(text), do: 1, else: eol - state.point

    if len == 0 do
      {:reply, {:ok, ""}, state}
    else
      killed = binary_part(text, state.point, len)
      {:reply, {:ok, killed}, do_delete(state, state.point, len, src)}
    end
  end

  def handle_call({:motion, motion}, _from, state) do
    text = Rope.to_binary(state.rope)

    state =
      if motion in [:next_line, :prev_line] do
        # goal column: crossing a short line must not lose the column
        {bol, _} = line_bounds(text, state.point)
        %{state | goal_col: state.goal_col || state.point - bol}
      else
        %{state | goal_col: nil}
      end

    point = apply_motion(motion, text, state.point, state.goal_col)
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
        current = {state.rope, state.point, state.mark}

        state = %{
          state
          | rope: rope,
            point: point,
            mark: mark,
            history: Enum.take([current | state.history], @undo_limit),
            version: state.version + 1,
            # +1 for the push above, +1 to step past the restored state
            undo_next: state.undo_next + 2,
            goal_col: nil,
            last_insert_end: nil,
            insert_run: 0
        }

        broadcast(state, 0, "", 0, :undo)
        {:reply, :ok, state}
    end
  end

  def handle_call(:break_undo_chain, _from, state),
    do: {:reply, :ok, %{state | undo_next: 0}}

  def handle_call({:save, override}, _from, state) do
    case override || state.path do
      nil ->
        {:reply, {:error, :no_path}, state}

      path ->
        File.write!(path, Rope.to_binary(state.rope))
        {:reply, {:ok, path}, %{state | path: path, saved_version: state.version}}
    end
  end

  # --- mutation helpers ------------------------------------------------------

  defp do_insert(state, pos, text, src) do
    state = maybe_snapshot_insert(state, pos, text, src)
    state = %{state | rope: Rope.insert(state.rope, pos, text), version: state.version + 1}
    state = adjust_point_insert(state, pos, Kernel.byte_size(text))
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
    state = %{state | rope: Rope.delete(state.rope, pos, len), version: state.version + 1}
    state = adjust_point_delete(state, pos, len)
    state = %{state | goal_col: nil, last_insert_end: nil, insert_run: 0, undo_next: 0}
    broadcast(state, pos, "", len, src)
    state
  end

  defp snapshot(state) do
    history = Enum.take([{state.rope, state.point, state.mark} | state.history], @undo_limit)
    %{state | history: history}
  end

  defp adjust_point_insert(state, pos, len) do
    %{
      state
      | point: adjust_insert(state.point, pos, len),
        mark: state.mark && adjust_insert(state.mark, pos, len)
    }
  end

  defp adjust_point_delete(state, pos, len) do
    %{
      state
      | point: adjust_delete(state.point, pos, len),
        mark: state.mark && adjust_delete(state.mark, pos, len)
    }
  end

  defp adjust_insert(p, pos, len) when p >= pos, do: p + len
  defp adjust_insert(p, _pos, _len), do: p

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

  defp clamp(pos, state), do: pos |> max(0) |> min(Rope.byte_size(state.rope))

  # --- text geometry (grapheme-aware, byte offsets) --------------------------

  defp chars_len(text, pos, n) do
    rest = binary_part(text, pos, Kernel.byte_size(text) - pos)

    rest
    |> String.graphemes()
    |> Enum.take(n)
    |> Enum.map(&Kernel.byte_size/1)
    |> Enum.sum()
  end

  defp back_up(text, pos, n) do
    binary_part(text, 0, pos)
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.take(n)
    |> Enum.map(&Kernel.byte_size/1)
    |> Enum.sum()
    |> then(&(pos - &1))
  end

  defp line_bounds(text, pos) do
    before = binary_part(text, 0, pos)

    bol =
      case :binary.matches(before, "\n") do
        [] -> 0
        matches -> matches |> List.last() |> elem(0) |> Kernel.+(1)
      end

    total = Kernel.byte_size(text)
    rest = binary_part(text, pos, total - pos)

    eol =
      case :binary.match(rest, "\n") do
        :nomatch -> total
        {off, _} -> pos + off
      end

    {bol, eol}
  end

  defp apply_motion(motion, text, pos, goal_col \\ nil)

  defp apply_motion(:forward, text, pos, _), do: pos + chars_len(text, pos, 1)
  defp apply_motion(:backward, text, pos, _), do: back_up(text, pos, 1)
  defp apply_motion(:bob, _text, _pos, _), do: 0
  defp apply_motion(:eob, text, _pos, _), do: Kernel.byte_size(text)
  defp apply_motion(:bol, text, pos, _), do: text |> line_bounds(pos) |> elem(0)
  defp apply_motion(:eol, text, pos, _), do: text |> line_bounds(pos) |> elem(1)

  defp apply_motion(:next_line, text, pos, goal) do
    {bol, eol} = line_bounds(text, pos)
    col = goal || pos - bol

    if eol >= Kernel.byte_size(text) do
      pos
    else
      {nbol, neol} = line_bounds(text, eol + 1)
      min(nbol + col, neol)
    end
  end

  defp apply_motion(:prev_line, text, pos, goal) do
    {bol, _eol} = line_bounds(text, pos)
    col = goal || pos - bol

    if bol == 0 do
      pos
    else
      {pbol, peol} = line_bounds(text, bol - 1)
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
