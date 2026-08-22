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

  Authorship: every mutation carries an author — an explicit `author:` opt,
  the caller-process `:aimax_edit_author` value, or a name derived from the
  source (`"user"`, `"editor"`, `"process"`, `"agent:SLUG"`). `authors` holds
  the live attribution spans `{start, end, author}` for the current text;
  spans split, shift, and merge through edits, and undo restores them with
  the rope. `edit_log` is a capped, newest-first journal of the mutations
  (`{version, author, pos, inserted, deleted}`) — it also records what
  deletions removed, which the spans cannot. `author: :none` adjusts the
  spans but stamps nothing (desktop restore is not an edit). Both live in
  memory only: a daemon restart clears attribution.

  Provenance is default-on for every buffer. A supervised SQLite store keeps
  immutable roots, exact edit operations, structured actors, content hashes,
  and recording gaps. Modes can stop recording without deleting history.
  Starting resumes the accepted head and snapshots an unrecorded interval.

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

  alias Aimax.Core.{BufferStore, Events, ProvenanceStore, Rope, Text, TS}

  @registry Aimax.Core.BufferRegistry
  @undo_limit 500
  @edit_log_limit 500
  @checkpoint_debounce 1_500

  defmodule Ref do
    @moduledoc "Immutable buffer identity. Names are mutable lookup aliases."
    @enforce_keys [:id]
    defstruct [:id]
  end

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
            win_points: %{},
            authors: [],
            edit_log: [],
            edit_log_len: 0,
            provenance: nil,
            id: nil,
            checkpoint_timer: nil,
            idle_timer: nil,
            discard: false,
            persistent: true,
            dirty: true,
            idle_gen: 0,
            encoding: :utf8

  # --- client ----------------------------------------------------------------

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: registry_name(name))
  end

  defp registry_name(%Ref{id: id}), do: {:via, Registry, {@registry, {:id, id}}}
  defp registry_name(name), do: {:via, Registry, {@registry, name}}

  @doc "Return the immutable identity handle for a live or dormant buffer."
  def ref(%Ref{} = ref), do: ref

  def ref(name) when is_binary(name) do
    case id(name) do
      nil -> nil
      id -> %Ref{id: id}
    end
  end

  @doc "Return a buffer's immutable persisted id."
  def id(%Ref{id: id}), do: id
  def id(name), do: dormant_read(name, :id, :id)

  @doc "Resolve a buffer handle to its current mutable name."
  def name(%Ref{id: id} = ref) do
    if exists?(ref) do
      GenServer.call(registry_name(ref), :name)
    else
      case BufferStore.lookup_id(id) do
        %{name: name} -> name
        nil -> nil
      end
    end
  end

  def name(name) when is_binary(name), do: name

  def via(%Ref{id: id} = ref) do
    if not exists?(ref) do
      case BufferStore.lookup_id(id) do
        %{name: name} -> Aimax.Core.ensure_buffer(name)
        nil -> :ok
      end
    end

    registry_name(ref)
  end

  def via(name) do
    if not exists?(name) and BufferStore.known?(name), do: Aimax.Core.ensure_buffer(name)
    registry_name(name)
  end

  def exists?(%Ref{id: id}), do: Registry.lookup(@registry, {:id, id}) != []
  def exists?(name), do: Registry.lookup(@registry, name) != []

  # A name with neither a process nor a checkpoint reads as empty, not as
  # nil: a list renders a row for every name the catalog holds, and one
  # buffer that died mid-render used to raise out of the whole render.
  def text(name), do: dormant_read(name, :text, :text) || ""
  def byte_size(name), do: Kernel.byte_size(text(name))
  def version(name), do: dormant_read(name, :buffer_version, :version)
  def path(name), do: dormant_read(name, :path, :path)
  def modified?(name), do: dormant_read(name, :modified, :modified?)
  def point(name), do: dormant_read(name, :point, :point)
  def touch(name), do: GenServer.cast(via(name), :touch)
  def checkpoint_now(name), do: GenServer.call(via(name), :checkpoint_now, 30_000)
  def eviction_info(name), do: GenServer.call(via(name), :eviction_info)

  def prepare_evict(name, generation),
    do: GenServer.call(via(name), {:prepare_evict, generation}, 30_000)

  def discard(name), do: GenServer.call(via(name), :discard)

  def rename(name, new_name, new_path),
    do: GenServer.call(via(name), {:rename, new_name, new_path})

  def goto(name, pos), do: GenServer.call(via(name), {:goto, pos})

  def mark(name), do: dormant_read(name, :mark, :mark)
  def set_mark(name, pos), do: GenServer.call(via(name), {:set_mark, pos})

  def read_only?(name), do: dormant_read(name, :read_only, :read_only?)
  def set_read_only(name, bool), do: GenServer.call(via(name), {:set_read_only, bool})

  # buffer-local variables (mode name, mode state, anything Scheme wants)
  def set_local(name, key, val), do: GenServer.call(via(name), {:set_local, key, val})

  def get_local(name, key) do
    if exists?(name),
      do: GenServer.call(registry_name(name), {:get_local, key}),
      else: name |> dormant() |> Map.get(:locals, %{}) |> Map.get(key)
  end

  def locals(name) do
    if exists?(name),
      do: GenServer.call(registry_name(name), :locals),
      else: name |> dormant() |> Map.get(:locals, %{})
  end

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
  def insert(name, text, opts \\ []),
    do: GenServer.call(via(name), {:insert, text, source(opts), author(opts)})

  def append(name, text, opts \\ []),
    do: GenServer.call(via(name), {:append, text, source(opts), author(opts)})

  # `:locals` writes buffer-locals in the SAME message as the insert. A
  # local that names a byte position (the agent's saved mark) must move
  # with the text it points at. Written in a second call, the broadcast
  # from this one already painted a frame in which the position is stale.
  def insert_at(name, pos, text, opts \\ []),
    do:
      GenServer.call(
        via(name),
        {:insert_at, pos, text, source(opts), author(opts), Keyword.get(opts, :locals, %{})}
      )

  def delete_range(name, pos, len, opts \\ []),
    do: GenServer.call(via(name), {:delete_range, pos, len, source(opts), author(opts)})

  @doc "Replace LEN bytes at POS with TEXT as one undo step."
  def replace_range(name, pos, len, text, opts \\ []),
    do: GenServer.call(via(name), {:replace_range, pos, len, text, source(opts), author(opts)})

  @doc "Delete n chars forward from point (negative = backward). Returns deleted text."
  def delete_char(name, n \\ 1, opts \\ []),
    do: GenServer.call(via(name), {:delete_char, n, source(opts), author(opts)})

  @doc "Delete point..end-of-line (or the newline if at eol). Returns killed text."
  def kill_line(name, opts \\ []),
    do: GenServer.call(via(name), {:kill_line, source(opts), author(opts)})

  @doc "Attribution spans for the current text: [{start, end, author}], sorted."
  def authors(name), do: GenServer.call(via(name), :authors)

  @doc "The mutation journal, newest first: [{version, author, pos, ins, del}]."
  def edit_log(name), do: GenServer.call(via(name), :edit_log)

  @doc "Return the durable Provenance status for the buffer."
  def provenance(name), do: GenServer.call(via(name), :provenance)

  @doc "Start or resume Provenance without deleting prior history."
  def provenance_start(name, opts \\ []) do
    GenServer.call(via(name), {:provenance_start, source(opts), author(opts), opts})
  end

  @doc "Stop recording after all accepted changes are durable."
  def provenance_stop(name, opts \\ []) do
    GenServer.call(via(name), {:provenance_stop, source(opts), author(opts), opts})
  end

  @doc "Close the current Provenance changeset without deleting history."
  def provenance_checkpoint(name, opts \\ []) do
    GenServer.call(via(name), {:provenance_checkpoint, source(opts), author(opts), opts})
  end

  @doc "Return durable revisions oldest first."
  def provenance_history(name), do: GenServer.call(via(name), :provenance_history)

  @doc "1-based logical line -> {start_byte, line_text sans newline}, clamped."
  def line_at(name, line), do: GenServer.call(via(name), {:line_at, line})

  @doc "The 1-based line byte offset POS is on (Emacs line-number-at-pos)."
  def line_of(name, pos), do: GenServer.call(via(name), {:line_of, pos})

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
  A node and its neighbours, from the same incremental tree the highlighter
  uses. nil when the buffer has no ts-lang. Structural motion asks this
  once per keypress, so it must never reparse from scratch.
  """
  def ts_node(name, kind, start, stop, op),
    do: GenServer.call(via(name), {:ts_node, kind, start, stop, op}, 30_000)

  @doc "Every named child of one node, from the same tree ([] without ts-lang)."
  def ts_children(name, kind, start, stop),
    do: GenServer.call(via(name), {:ts_children, kind, start, stop}, 30_000)

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

  # read in the CALLER's process: `with-edit-author` scopes the Session's
  # dictionary value, and every mutation the evaluated code makes picks it
  # up here without threading an argument through the whole call chain
  defp author(opts), do: Keyword.get(opts, :author, Process.get(:aimax_edit_author))

  defp dormant_read(name, key, message) do
    try do
      if exists?(name),
        do: GenServer.call(registry_name(name), message),
        else: Map.get(dormant(name), key)
    catch
      # A buffer can die after exists?/1 and before the call. Fall back to
      # its checkpoint; a truly stale name/ref reads as absent, never :noproc.
      :exit, _ -> Map.get(dormant(name), key)
    end
  end

  defp dormant(%Ref{id: id}) do
    case BufferStore.load_id(id) do
      %{} = checkpoint -> checkpoint
      nil -> %{}
    end
  end

  defp dormant(name) do
    case BufferStore.load(name) do
      %{} = checkpoint -> checkpoint
      nil -> %{}
    end
  end

  # --- server ----------------------------------------------------------------

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    checkpoint = read_checkpoint(Keyword.get(opts, :checkpoint))

    state =
      if checkpoint do
        restored_state(checkpoint)
      else
        path = Keyword.get(opts, :path)

        {text, encoding} =
          if path do
            path
            |> then(fn path -> if File.exists?(path), do: File.read!(path), else: "" end)
            |> decode_file_bytes()
          else
            {Keyword.get(opts, :text, ""), :utf8}
          end

        binary_file? = encoding != :utf8

        %__MODULE__{
          name: name,
          id: new_id(),
          rope: Rope.new(text),
          path: path,
          encoding: encoding,
          read_only: binary_file?,
          locals: if(binary_file?, do: %{"binary-file" => true}, else: %{})
        }
      end

    state = %{state | persistent: not String.starts_with?(name, " ")}
    state = attach_provenance(state)
    {:ok, _} = Registry.register(@registry, {:id, state.id}, state.name)
    {:ok, state |> schedule_checkpoint() |> reset_idle_timer()}
  end

  @impl true
  def handle_cast(:touch, state), do: {:noreply, touch_state(state)}

  @impl true
  def handle_info(:checkpoint, state),
    do: {:noreply, %{write_checkpoint(state) | checkpoint_timer: nil}}

  def handle_info({:idle_timeout, generation}, state) do
    BufferStore.idle_expired(state.name, state.id, generation)
    {:noreply, %{state | idle_timer: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{discard: true}), do: :ok
  def terminate(_reason, state), do: write_checkpoint(state)

  @impl true
  def handle_call(:text, _from, state) do
    {text, state} = fetch_text(state)
    {:reply, text, state}
  end

  def handle_call(:id, _from, state), do: {:reply, state.id, state}
  def handle_call(:name, _from, state), do: {:reply, state.name, state}

  def handle_call(:byte_size, _from, state), do: {:reply, Rope.byte_size(state.rope), state}
  def handle_call(:version, _from, state), do: {:reply, state.version, state}
  def handle_call(:path, _from, state), do: {:reply, state.path, state}
  def handle_call(:point, _from, state), do: {:reply, state.point, state}
  def handle_call(:checkpoint_now, _from, state), do: {:reply, :ok, write_checkpoint(state)}

  def handle_call(:eviction_info, _from, state),
    do: {:reply, %{id: state.id, idle_gen: state.idle_gen, locals: state.locals}, state}

  def handle_call({:prepare_evict, generation}, _from, state) do
    if state.idle_gen == generation,
      do: {:reply, true, write_checkpoint(state)},
      else: {:reply, false, state}
  end

  def handle_call(:discard, _from, state), do: {:reply, :ok, %{state | discard: true}}

  def handle_call({:rename, new_name, new_path}, _from, state) do
    case Registry.register(@registry, new_name, state.id) do
      {:ok, _} ->
        Registry.unregister(@registry, state.name)
        old = state.name
        state = %{state | name: new_name, path: new_path} |> checkpoint_later() |> touch_state()
        state = write_checkpoint(state)
        BufferStore.renamed(old, metadata(state))
        {:reply, :ok, state}

      {:error, {:already_registered, _}} ->
        {:reply, {:error, :already_exists}, state}
    end
  end

  def handle_call(:modified?, _from, state),
    do: {:reply, state.version != state.saved_version, state}

  def handle_call({:goto, pos}, _from, state),
    do: {:reply, :ok, state |> Map.put(:point, clamp(pos, state)) |> checkpoint_later()}

  def handle_call(:mark, _from, state), do: {:reply, state.mark, state}

  def handle_call(:read_only?, _from, state), do: {:reply, state.read_only, state}

  def handle_call({:set_read_only, bool}, _from, state),
    do: {:reply, :ok, state |> Map.put(:read_only, bool) |> checkpoint_later()}

  def handle_call({:set_local, key, val}, _from, state) do
    state = %{state | locals: Map.put(state.locals, key, val)}
    state = if key == "ts-lang", do: init_ts(state, val), else: state
    # Locals feed rendering ('style, mode-name, 'render-blocks) and
    # persistence. The editor firehose reaches the Desktop; the buffer's own
    # channel reaches every frame that shows the buffer, so views repaint
    # when a local is the ONLY thing that changed — an async render chain
    # ends exactly that way. The :locals source is unknown to every reactor
    # whitelist, so the phantom change triggers no rules.
    Events.broadcast_editor(:locals)
    broadcast(state, state.point, "", 0, :locals)
    {:reply, :ok, checkpoint_later(state)}
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
    do:
      {:reply, :ok,
       state |> Map.put(:hidden, Map.delete(state.hidden, tag)) |> checkpoint_later()}

  def handle_call({:set_hidden, tag, ranges}, _from, state),
    do:
      {:reply, :ok,
       state
       |> Map.put(:hidden, Map.put(state.hidden, tag, Enum.sort(ranges)))
       |> checkpoint_later()}

  def handle_call({:hidden, :all}, _from, state), do: {:reply, hidden_union(state), state}

  def handle_call({:hidden, tag}, _from, state),
    do: {:reply, Map.get(state.hidden, tag, []), state}

  def handle_call({:clear_hidden, :all}, _from, state),
    do: {:reply, :ok, state |> Map.put(:hidden, %{}) |> checkpoint_later()}

  def handle_call({:clear_hidden, tag}, _from, state),
    do:
      {:reply, :ok,
       state |> Map.put(:hidden, Map.delete(state.hidden, tag)) |> checkpoint_later()}

  # read-only blocks :user mutations only — programmatic sources (:editor,
  # :process, agents) are the inhibit-read-only path (dired regenerates its
  # own read-only buffer this way)
  def handle_call({:insert, _, :user, _}, _f, %{read_only: true} = s), do: ro(s)
  def handle_call({:append, _, :user, _}, _f, %{read_only: true} = s), do: ro(s)
  def handle_call({:insert_at, _, _, :user, _, _locals}, _f, %{read_only: true} = s), do: ro(s)
  def handle_call({:delete_range, _, _, :user, _}, _f, %{read_only: true} = s), do: ro(s)
  def handle_call({:replace_range, _, _, _, :user, _}, _f, %{read_only: true} = s), do: ro(s)
  def handle_call({:delete_char, _, :user, _}, _f, %{read_only: true} = s), do: ro(s)
  def handle_call({:kill_line, :user, _}, _f, %{read_only: true} = s), do: ro(s)

  def handle_call({:line_of, pos}, _from, state) do
    {:reply, Rope.byte_to_line(state.rope, clamp(pos, state)) + 1, state}
  end

  def handle_call({:line_at, line}, _from, state) do
    rope = state.rope
    count = Rope.line_count(rope)
    line = line |> max(1) |> min(count)
    s = Rope.line_to_byte(rope, line - 1)
    e = if line == count, do: Rope.byte_size(rope), else: Rope.line_to_byte(rope, line)
    {:reply, {s, rope |> Rope.slice(s, e - s) |> String.trim_trailing("\n")}, state}
  end

  def handle_call({:set_mark, nil}, _from, state),
    do: {:reply, :ok, state |> Map.put(:mark, nil) |> checkpoint_later()}

  def handle_call({:set_mark, pos}, _from, state),
    do: {:reply, :ok, state |> Map.put(:mark, clamp(pos, state)) |> checkpoint_later()}

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

  def handle_call({:insert, text, src, author}, _from, state) do
    # do_insert's point adjustment already advances point past the insertion
    {:reply, :ok,
     state |> do_insert(state.point, text, src, author) |> touch_state() |> checkpoint_later()}
  end

  def handle_call({:append, text, src, author}, _from, state) do
    {:reply, :ok,
     state
     |> do_insert(Rope.byte_size(state.rope), text, src, author)
     |> touch_state()
     |> checkpoint_later()}
  end

  def handle_call({:insert_at, pos, text, src, author, locals}, _from, state) do
    # locals first: do_insert broadcasts, and the frame it paints must
    # already see them
    state = %{state | locals: Map.merge(state.locals, locals)}

    {:reply, :ok,
     state |> do_insert(pos, text, src, author) |> touch_state() |> checkpoint_later()}
  end

  def handle_call({:delete_range, pos, len, src, author}, _from, state) do
    size = Rope.byte_size(state.rope)

    if pos < 0 or len < 0 or pos + len > size do
      # Invalid editor metadata must fail the operation, not the buffer
      # process. A crashed buffer disappears from desktop persistence and a
      # stale window can otherwise resurrect its name as an empty shell.
      {:reply, {:error, :out_of_bounds}, state}
    else
      {:reply, :ok,
       state |> do_delete(pos, len, src, author) |> touch_state() |> checkpoint_later()}
    end
  end

  def handle_call({:replace_range, pos, len, text, src, author}, _from, state) do
    size = Rope.byte_size(state.rope)

    if pos < 0 or len < 0 or pos + len > size do
      {:reply, {:error, :out_of_bounds}, state}
    else
      # one snapshot for the pair: the whole replacement is one undo step
      state = snapshot(state)
      state = if len > 0, do: do_delete(state, pos, len, src, author, false), else: state
      state = if text != "", do: do_insert(state, pos, text, src, author, false), else: state
      # never a self-insert run: the next typed char starts its own undo step
      state = %{state | insert_run: 0}
      {:reply, :ok, state |> touch_state() |> checkpoint_later()}
    end
  end

  def handle_call({:delete_char, n, src, author}, _from, state) do
    {text, state} = fetch_text(state)

    {pos, len} =
      if n >= 0 do
        {state.point, chars_len(text, state.point, n)}
      else
        start = back_up(text, state.point, -n)
        {start, state.point - start}
      end

    deleted = binary_part(text, pos, len)
    state = do_delete(state, pos, len, src, author)
    {:reply, {:ok, deleted}, state |> Map.put(:point, pos) |> touch_state() |> checkpoint_later()}
  end

  def handle_call({:kill_line, src, author}, _from, state) do
    {text, state} = fetch_text(state)
    {_bol, eol} = Text.line_bounds(text, state.point)
    len = if state.point == eol and eol < Kernel.byte_size(text), do: 1, else: eol - state.point

    if len == 0 do
      {:reply, {:ok, ""}, state}
    else
      killed = binary_part(text, state.point, len)

      {:reply, {:ok, killed},
       state |> do_delete(state.point, len, src, author) |> touch_state() |> checkpoint_later()}
    end
  end

  def handle_call(:authors, _from, state), do: {:reply, state.authors, state}
  def handle_call(:edit_log, _from, state), do: {:reply, state.edit_log, state}

  def handle_call(:provenance, _from, state),
    do: {:reply, state.provenance, state}

  def handle_call({:provenance_start, src, author, opts}, _from, state) do
    actor = resolve_actor(author, src)
    {text, state} = fetch_text(state)
    reason = Keyword.get(opts, :reason, "explicit")
    policy_source = Keyword.get(opts, :policy_source, "user")

    {:ok, status} =
      ProvenanceStore.start_recording(state.id, text, actor, reason, policy_source)

    {:reply, :ok, %{state | provenance: provenance_state(status)} |> checkpoint_later()}
  end

  def handle_call({:provenance_stop, src, author, opts}, _from, state) do
    actor = resolve_actor(author, src)
    reason = Keyword.get(opts, :reason, "explicit")
    policy_source = Keyword.get(opts, :policy_source, "user")

    if policy_source == "mode" and state.provenance.policy_source == "user" do
      {:reply, :ok, state}
    else
      {:ok, status} =
        ProvenanceStore.stop_recording(state.id, actor, reason, policy_source)

      {:reply, :ok, %{state | provenance: provenance_state(status)} |> checkpoint_later()}
    end
  end

  def handle_call({:provenance_checkpoint, src, author, opts}, _from, state) do
    actor = resolve_actor(author, src)
    reason = Keyword.get(opts, :reason, "explicit")

    case ProvenanceStore.checkpoint(state.id, actor, reason) do
      {:ok, status} ->
        {:reply, :ok, %{state | provenance: provenance_state(status)} |> checkpoint_later()}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:provenance_history, _from, state),
    do: {:reply, ProvenanceStore.history(state.id), state}

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

    # An embedded image replaces its backing URL in the display. Treat that
    # range as one cursor position too, so line/character motion cannot spend
    # keypresses walking through invisible URL bytes.
    point = snap_atomic_overlay(point, motion, state)

    {:reply, point, state |> Map.put(:point, point) |> checkpoint_later()}
  end

  # Emacs undo: the pre-undo state is pushed onto the same history, so undos
  # are themselves undoable and no state is ever lost. `undo_next` walks the
  # chain during a run of consecutive undos; any other command breaks the
  # chain, after which undo reverses the undos (redo).
  def handle_call(:undo, _from, state) do
    case Enum.at(state.history, state.undo_next) do
      nil ->
        {:reply, {:error, :no_undo}, state}

      {rope, point, mark, authors} ->
        old_text = Rope.to_binary(state.rope)
        new_text = Rope.to_binary(rope)
        state = push_history(state, {state.rope, state.point, state.mark, state.authors})

        state = %{
          state
          | rope: rope,
            bin: nil,
            point: point,
            mark: mark,
            authors: authors,
            version: state.version + 1,
            # +1 for the push above, +1 to step past the restored state
            undo_next: state.undo_next + 2,
            goal_col: nil,
            last_insert_end: nil,
            insert_run: 0
        }

        # The compatibility journal marks an undo as a discontinuity.
        state = log_edit(state, "undo", 0, 0, 0)
        actor = local_actor("system:undo", "system", "undo", :undo)
        # Provenance keeps the complete replacement so replay stays exact.
        state = log_provenance(state, actor, 0, new_text, old_text)
        state = ts_invalidate(state)
        broadcast(state, 0, "", 0, :undo)
        {:reply, :ok, checkpoint_later(state)}
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

  def handle_call({:ts_node, _kind, _s, _e, _op}, _from, %{ts: nil} = state),
    do: {:reply, nil, state}

  def handle_call({:ts_node, kind, s, e, op}, _from, %{ts: ts} = state) do
    {text, state} = fetch_text(state)
    {:reply, TS.ts_state_node(ts.res, text, kind, s, e, op), state}
  end

  def handle_call({:ts_children, _kind, _s, _e}, _from, %{ts: nil} = state),
    do: {:reply, [], state}

  def handle_call({:ts_children, kind, s, e}, _from, %{ts: ts} = state) do
    {text, state} = fetch_text(state)
    {:reply, TS.ts_state_children(ts.res, text, kind, s, e), state}
  end

  def handle_call(:break_undo_chain, _from, state),
    do: {:reply, :ok, %{state | undo_next: 0}}

  # a save is not an edit, but the modified flag every view shows just
  # changed — repaint through the same phantom-change channel set_local
  # uses (:locals triggers no reactor rules)
  def handle_call(:mark_saved, _from, state) do
    state = %{state | saved_version: state.version}
    Events.broadcast_editor(:locals)
    broadcast(state, state.point, "", 0, :locals)
    {:reply, :ok, checkpoint_later(state)}
  end

  def handle_call({:save, override}, _from, state) do
    case override || state.path do
      nil ->
        {:reply, {:error, :no_path}, state}

      path ->
        {text, state} = fetch_text(state)
        BufferStore.atomic_write(path, encode_file_text(text, state.encoding))
        state = %{state | path: path, saved_version: state.version}
        Events.broadcast_editor(:locals)
        broadcast(state, state.point, "", 0, :locals)
        {:reply, {:ok, path}, state |> touch_state() |> checkpoint_later()}
    end
  end

  defp attach_provenance(state) do
    text = Rope.to_binary(state.rope)

    actor =
      local_actor(
        "system:buffer",
        "system",
        "buffer",
        if(state.path, do: :file_load, else: :buffer_create)
      )

    {:ok, status} =
      ProvenanceStore.ensure_cell(
        state.id,
        text,
        actor,
        policy_source: "default",
        retention: if(state.persistent, do: "durable", else: "session")
      )

    status =
      cond do
        status.head_hash == text_hash(text) ->
          status

        not status.recording ->
          %{status | gap: true}

        true ->
          {:ok, recovered} =
            ProvenanceStore.start_recording(
              state.id,
              text,
              actor,
              "restore-mismatch",
              status.policy_source
            )

          recovered
      end

    %{state | provenance: provenance_state(status)}
  end

  defp provenance_state(status) do
    %{
      enabled: status.recording,
      cell_id: status.cell_id,
      head_id: status.head_id,
      head_hash: status.head_hash,
      policy_source: status.policy_source,
      retention: status.retention,
      gap: status.gap
    }
  end

  defp text_hash(text) do
    :crypto.hash(:sha256, text)
    |> Base.encode16(case: :lower)
  end

  defp new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp read_checkpoint(nil), do: nil

  defp read_checkpoint(path) do
    with {:ok, bin} <- File.read(path),
         %{version: 1} = cp <- :erlang.binary_to_term(bin),
         do: cp,
         else: (_ -> nil)
  rescue
    _ -> nil
  end

  defp restored_state(cp) do
    version = cp[:buffer_version] || 0
    saved_version = if cp[:modified], do: max(version - 1, 0), else: version

    %__MODULE__{
      name: cp.name,
      id: cp.id,
      rope: Rope.new(cp[:text] || ""),
      path: cp[:path],
      point: min(cp[:point] || 0, Kernel.byte_size(cp[:text] || "")),
      mark: cp[:mark],
      read_only: cp[:read_only] || false,
      encoding: cp[:encoding] || :utf8,
      locals: cp[:locals] || %{},
      hidden: cp[:hidden] || %{},
      version: version,
      saved_version: saved_version
    }
  end

  defp checkpoint(state) do
    {text, _} = fetch_text(state)

    %{
      version: 1,
      id: state.id,
      name: state.name,
      path: state.path,
      text: text,
      point: state.point,
      mark: state.mark,
      read_only: state.read_only,
      encoding: state.encoding,
      locals: serializable_locals(state.locals),
      hidden: state.hidden,
      buffer_version: state.version,
      modified: state.version != state.saved_version,
      provenance: state.provenance
    }
  end

  defp metadata(state),
    do: %{
      id: state.id,
      name: state.name,
      path: state.path,
      checkpoint: BufferStore.checkpoint_path(state.id)
    }

  defp write_checkpoint(%{discard: true} = state), do: state
  defp write_checkpoint(%{persistent: false} = state), do: state

  # Nothing changed since the last write, so the file on disk is current.
  # A forced checkpoint of a clean buffer costs one comparison, not one
  # serialization of the whole text.
  defp write_checkpoint(%{dirty: false} = state), do: state

  defp write_checkpoint(state) do
    BufferStore.atomic_write(
      BufferStore.checkpoint_path(state.id),
      :erlang.term_to_binary(checkpoint(state))
    )

    BufferStore.note(metadata(state))
    %{state | dirty: false}
  rescue
    _ -> state
  end

  # Every state mutation marks the buffer dirty here, so the flag is the
  # answer to "did anything change since the last write?".
  defp checkpoint_later(%{persistent: false} = state), do: state

  defp checkpoint_later(%{checkpoint_timer: nil} = state),
    do: %{
      state
      | dirty: true,
        checkpoint_timer: Process.send_after(self(), :checkpoint, @checkpoint_debounce)
    }

  defp checkpoint_later(state), do: %{state | dirty: true}

  defp schedule_checkpoint(state), do: checkpoint_later(state)

  # The rope stores UTF-8. Map arbitrary file bytes through Latin-1 so every
  # byte has a reversible representation, and keep such buffers read-only to
  # prevent ordinary text edits from silently changing a binary file.
  defp decode_file_bytes(bytes) do
    if String.valid?(bytes),
      do: {bytes, :utf8},
      else: {:unicode.characters_to_binary(bytes, :latin1, :utf8), :latin1}
  end

  defp encode_file_text(text, :utf8), do: text

  defp encode_file_text(text, :latin1) do
    case :unicode.characters_to_binary(text, :utf8, :latin1) do
      bytes when is_binary(bytes) -> bytes
      {:error, _, _} -> raise ArgumentError, "binary buffer contains characters outside Latin-1"
      {:incomplete, _, _} -> raise ArgumentError, "binary buffer contains incomplete UTF-8"
    end
  end

  defp touch_state(state) do
    if state.persistent, do: BufferStore.touch(state.name)
    reset_idle_timer(state)
  end

  defp reset_idle_timer(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    timeout = Application.get_env(:aimax_core, :buffer_idle_timeout_ms, 24 * 60 * 60 * 1_000)
    generation = state.idle_gen + 1

    %{
      state
      | idle_gen: generation,
        idle_timer:
          if(timeout > 0,
            do: Process.send_after(self(), {:idle_timeout, generation}, timeout),
            else: nil
          )
    }
  end

  defp serializable_locals(locals) do
    skip =
      case locals["desktop-skip-locals"] do
        list when is_list(list) -> Enum.map(list, &local_key/1)
        _ -> []
      end

    locals |> Map.drop(skip) |> Map.filter(fn {_k, v} -> serializable?(v) end)
  end

  defp local_key({:sym, key}), do: key
  defp local_key(key), do: to_string(key)

  defp serializable?(v) when is_function(v) or is_pid(v) or is_reference(v) or is_port(v),
    do: false

  defp serializable?(v) when is_list(v), do: Enum.all?(v, &serializable?/1)
  defp serializable?(v) when is_tuple(v), do: v |> Tuple.to_list() |> Enum.all?(&serializable?/1)

  defp serializable?(v) when is_map(v),
    do: Enum.all?(v, fn {k, val} -> serializable?(k) and serializable?(val) end)

  defp serializable?(_), do: true

  # --- mutation helpers ------------------------------------------------------

  # snap?: false only inside :replace_range, which snapshots once for the pair
  defp do_insert(state, pos, text, src, author, snap? \\ true) do
    len = Kernel.byte_size(text)
    actor = resolve_actor(author, src)
    author = actor_label(actor)
    state = if snap?, do: maybe_snapshot_insert(state, pos, text, src), else: state
    old_rope = state.rope

    state = %{
      state
      | rope: Rope.insert(state.rope, pos, text),
        bin: nil,
        version: state.version + 1
    }

    state = ts_track(state, old_rope, pos, pos, pos + len)
    state = adjust_point_insert(state, pos, len)

    state =
      adjust_ranges(state, &adjust_insert(&1, pos, len), &adjust_insert_stay(&1, pos, len))

    state = %{state | authors: stamp_insert(state.authors, pos, len, author)}
    state = log_edit(state, author, pos, len, 0)
    state = log_provenance(state, actor, pos, text, "")

    state = %{
      state
      | goal_col: nil,
        last_insert_end: pos + len,
        undo_next: 0
    }

    broadcast(state, pos, text, 0, src)
    state
  end

  # amalgamate consecutive single-char self-inserts into one undo step
  # (Emacs groups ~20) — undoing a typed word char-by-char is misery
  defp maybe_snapshot_insert(state, pos, text, :user)
       when Kernel.byte_size(text) == 1 and text != "\n" do
    # amalgamate only onto a previous self-insert (insert_run > 0) â never
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

  defp do_delete(state, pos, len, src, author, snap? \\ true) do
    actor = resolve_actor(author, src)
    author = actor_label(actor)
    state = if snap?, do: snapshot(state), else: state
    old_rope = state.rope
    deleted = Rope.slice(old_rope, pos, len)

    state = %{
      state
      | rope: Rope.delete(state.rope, pos, len),
        bin: nil,
        version: state.version + 1
    }

    state = ts_track(state, old_rope, pos, pos + len, pos)
    state = adjust_point_delete(state, pos, len)
    state = adjust_ranges(state, &adjust_delete(&1, pos, len), &adjust_delete(&1, pos, len))
    state = %{state | authors: stamp_delete(state.authors, pos, len)}
    state = log_edit(state, author, pos, 0, len)
    state = log_provenance(state, actor, pos, "", deleted)
    state = %{state | goal_col: nil, last_insert_end: nil, insert_run: 0, undo_next: 0}
    broadcast(state, pos, "", len, src)
    state
  end

  

  # trim lazily at 2x the cap: amortizes the O(limit) Enum.take so a burst of
  # keystrokes doesn't rebuild a 500-cons list on every edit
  defp snapshot(state),
    do: push_history(state, {state.rope, state.point, state.mark, state.authors})

  defp push_history(state, entry) do
    history = [entry | state.history]
    len = state.history_len + 1

    if len > @undo_limit * 2,
      do: %{state | history: Enum.take(history, @undo_limit), history_len: @undo_limit},
      else: %{state | history: history, history_len: len}
  end

  # --- authorship ------------------------------------------------------------

  # The durable actor is structured. actor_label/1 preserves the old author
  # spans and edit-log API until callers migrate.
  defp resolve_actor(%{} = actor, src) do
    actor
    |> Map.put_new(:source, inspect(src))
    |> Map.put_new(:assurance, "explicit")
  end

  defp resolve_actor(:none, src) do
    %{
      id: "system:materialization",
      kind: "system",
      display_name: "materialization",
      assurance: "system",
      source: inspect(src),
      stamp: false
    }
  end

  defp resolve_actor(nil, :user), do: local_actor("user:local", "user", "user", :user)
  defp resolve_actor(nil, :editor), do: local_actor("system:editor", "system", "editor", :editor)
  defp resolve_actor(nil, :process), do: local_actor("process:local", "process", "process", :process)

  defp resolve_actor(nil, {:agent, slug}) do
    local_actor("agent:" <> slug, "agent", "agent:" <> slug, {:agent, slug})
    |> Map.put(:run_id, slug)
  end

  defp resolve_actor(nil, src) do
    local_actor("unknown:" <> inspect(src), "unknown", inspect(src), src)
    |> Map.put(:assurance, "unverified")
  end

  defp resolve_actor(author, src) do
    label = to_string(author)
    kind =
      cond do
        String.starts_with?(label, "agent:") -> "agent"
        String.starts_with?(label, "mode:") -> "mode"
        String.starts_with?(label, "process:") -> "process"
        String.starts_with?(label, "user:") -> "user"
        true -> "legacy"
      end

    id = if kind == "legacy", do: "legacy:" <> label, else: label

    local_actor(id, kind, label, src)
    |> Map.put(:assurance, "legacy")
  end

  defp local_actor(id, kind, display_name, source) do
    %{
      id: id,
      kind: kind,
      display_name: display_name,
      authority: "local",
      assurance: "local",
      session_id: nil,
      source: inspect(source)
    }
  end

  defp actor_label(%{stamp: false}), do: nil
  defp actor_label(%{display_name: display_name}), do: display_name

  # a span that contains the insertion point splits — the inserted text
  # must not inherit the surrounding span's author
  defp stamp_insert(authors, pos, len, author) do
    spans =
      Enum.flat_map(authors, fn {s, e, a} ->
        cond do
          e <= pos -> [{s, e, a}]
          s >= pos -> [{s + len, e + len, a}]
          true -> [{s, pos, a}, {pos + len, e + len, a}]
        end
      end)

    spans = if author, do: [{pos, pos + len, author} | spans], else: spans
    spans |> Enum.sort() |> merge_spans()
  end

  defp stamp_delete(authors, pos, len) do
    authors
    |> Enum.map(fn {s, e, a} -> {adjust_delete(s, pos, len), adjust_delete(e, pos, len), a} end)
    |> Enum.reject(fn {s, e, _} -> s >= e end)
    |> merge_spans()
  end

  defp merge_spans([{s1, e1, a}, {s2, e2, a} | rest]) when e1 == s2,
    do: merge_spans([{s1, e2, a} | rest])

  defp merge_spans([span | rest]), do: [span | merge_spans(rest)]
  defp merge_spans([]), do: []

  # same lazy 2x trim as the undo history
  defp log_edit(state, author, pos, ins, del) do
    log = [{state.version, author, pos, ins, del} | state.edit_log]
    len = state.edit_log_len + 1

    if len > @edit_log_limit * 2,
      do: %{state | edit_log: Enum.take(log, @edit_log_limit), edit_log_len: @edit_log_limit},
      else: %{state | edit_log: log, edit_log_len: len}
  end

  defp log_provenance(%{provenance: nil} = state, _actor, _pos, _inserted, _deleted),
    do: state

  defp log_provenance(
         %{provenance: %{enabled: false} = provenance} = state,
         _actor,
         _pos,
         _inserted,
         _deleted
       ) do
    %{state | provenance: %{provenance | gap: true}}
  end

  defp log_provenance(state, actor, pos, inserted, deleted) do
    {text, state} = fetch_text(state)

    case ProvenanceStore.record_change(
           state.id,
           state.provenance.head_id,
           state.version,
           actor,
           pos,
           inserted,
           deleted,
           text
         ) do
      {:ok, status} ->
        %{state | provenance: provenance_state(status)}

      {:error, {:stale_revision, conflict}} ->
        raise "stale local Provenance head: #{inspect(conflict)}"
    end
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
  # ranges (start >= end after a delete) are dropped. Starts and ends
  # adjust differently on insert: text inserted exactly at an end stays
  # outside the range (Emacs rear-advance nil) — a closed fold must not
  # swallow text appended at its boundary.
  defp adjust_ranges(state, fs, fe) do
    overlays =
      Map.new(state.overlays, fn {tag, ranges} ->
        {tag,
         ranges
         |> Enum.map(fn {s, e, face} -> {fs.(s), fe.(e), face} end)
         |> Enum.reject(fn {s, e, _} -> s >= e end)}
      end)

    # the same adjustment, per tag: a tag that loses every range drops out
    hidden =
      state.hidden
      |> Enum.map(fn {tag, ranges} ->
        {tag,
         ranges
         |> Enum.map(fn {s, e} -> {fs.(s), fe.(e)} end)
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
    change = %{
      version: state.version,
      pos: pos,
      inserted: inserted,
      deleted: deleted,
      source: src
    }

    # Stable-object subscribers follow the immutable ref across rename.
    # Name subscribers remain as a compatibility surface for UI code.
    Events.broadcast(%Ref{id: state.id}, change)
    Events.broadcast(state.name, change)
  end

  defp ro(state), do: {:reply, {:error, :read_only}, state}

  # flattening the rope is O(buffer) — do it once per version, not per read
  defp fetch_text(%{bin: nil} = state) do
    bin = Rope.to_binary(state.rope)
    {bin, %{state | bin: bin}}
  end

  defp fetch_text(state), do: {state.bin, state}

  # --- incremental tree-sitter ------------------------------------------------

  # a mode that leaves clears 'ts-lang, and the local carries #f (false) to
  # say so. No language, no parser: false must drop the state, not hold it.
  defp init_ts(state, lang) when lang in [nil, false], do: %{state | ts: nil}

  defp init_ts(state, lang) do
    case TS.ts_state_new(lang) do
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

  defp snap_atomic_overlay(point, motion, state) do
    range =
      state.overlays
      |> Map.values()
      |> Enum.concat()
      |> Enum.find(fn
        {s, e, face} when is_binary(face) ->
          String.contains?(face, "img-embed") and point > s and point < e

        _ ->
          false
      end)

    case {range, motion} do
      {{s, _e, _face}, motion} when motion in [:backward, :backward_word, :prev_line] -> s
      {{_s, e, _face}, motion} when motion in [:forward, :forward_word, :next_line] -> e
      _ -> point
    end
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
