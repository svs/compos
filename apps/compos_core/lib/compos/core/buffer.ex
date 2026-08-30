defmodule Compos.Core.Buffer do
  @moduledoc """
  A buffer is a process: rope + point + undo history + metadata. All content
  mutations broadcast change events (with provenance) via `Compos.Core.Events`.

  This is deliberately a *primitive* layer: motion and editing operations only.
  Commands (kill-line-the-command, find-file, ...) are Scheme, built on these.

  Undo: persistent ropes make snapshots free — history is a list of
  `{rope, point}` (capped). TODO: undo grouping (amalgamate consecutive
  self-inserts), redo via Emacs-style undo-the-undos.

  Point is a byte offset; motion ops are grapheme-aware. TODO: goal column
  for line motion, marks, text properties.

  Authorship: every mutation carries an author — an explicit `author:` opt,
  the caller-process `:compos_edit_author` value, or a name derived from the
  source (`"user"`, `"editor"`, `"process"`, `"agent:SLUG"`). `authors` holds
  the live attribution spans `{start, end, changeset_id}` for the current
  text; spans split, shift, and merge through edits, and undo restores them
  with the rope. The span names the CHANGESET that wrote those bytes, which
  is the revision the provenance store records, so the span inherits the
  actor, the time, and the group instead of copying a display name. `origins`
  resolves those ids in memory, and `authors/1` still answers labels.

  `edit_log` is a capped, newest-first journal of the mutations
  (`{version, author, pos, inserted, deleted}`) — it also records what
  deletions removed, which the spans cannot. `author: :none` adjusts the
  spans but stamps nothing (desktop restore is not an edit). The spans and
  their origins ride in the checkpoint, so attribution survives a restart;
  the edit log does not.

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

  require Logger

  alias Compos.Core.{BufferHistoryStore, BufferStore, BufferView, Events, Rope, Text, TS}
  alias Compos.Core.BufferHistory, as: History

  @registry Compos.Core.BufferRegistry
  @undo_limit 500
  @edit_log_limit 500
  @checkpoint_debounce 1_500

  # Typing does not reach SQLite. Each keystroke appends one operation to a
  # pending changeset; the checkpoint boundary above writes the batch. The cap
  # bounds the journal when a burst outruns the timer.
  @provenance_batch_limit 200

  defmodule Ref do
    @moduledoc "Immutable buffer identity. Names are mutable lookup aliases."
    @enforce_keys [:id]
    defstruct [:id]
  end

  defstruct name: nil,
            rope: nil,
            history: nil,
            bin: nil,
            version: 0,
            saved_version: 0,
            path: nil,
            point: 0,
            mark: nil,
            read_only: false,
            undo_run: false,
            locals: %{},
            goal_col: nil,
            last_insert_end: nil,
            insert_run: 0,
            overlays: %{},
            overlay_gen: 0,
            hidden: %{},
            narrow_range: nil,
            ts: nil,
            win_points: %{},
            authors: [],
            origins: %{},
            edit_log: [],
            edit_log_len: 0,
            provenance: nil,
            history_actor: nil,
            history_group: nil,
            history_persisted: nil,
            changeset_id: nil,
            pending_ops: [],
            pending_actor: nil,
            pending_group: nil,
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
  def id(name), do: viewed(name, :id, fn -> dormant_read(name, :id, :id) end)

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
        %{name: name} -> Compos.Core.ensure_buffer(name)
        nil -> :ok
      end
    end

    registry_name(ref)
  end

  def via(name) do
    if not exists?(name) and BufferStore.known?(name), do: Compos.Core.ensure_buffer(name)
    registry_name(name)
  end

  def exists?(%Ref{id: id}), do: Registry.lookup(@registry, {:id, id}) != []
  def exists?(name), do: Registry.lookup(@registry, name) != []

  # Reads take the published row when the buffer has one. A row is written
  # by the owning process before it answers the write that made it, so a
  # reader never sees a state older than its own last write. Without a row
  # the read falls back to the process, and then to the checkpoint.
  #
  # A name with neither a process nor a checkpoint reads as empty, not as
  # nil: a list renders a row for every name the catalog holds, and one
  # buffer that died mid-render used to raise out of the whole render.
  defp viewed(name, key, fallback) do
    case BufferView.fetch(name) do
      {:ok, view} -> Map.fetch!(view, key)
      :error -> fallback.()
    end
  end

  def text(name) do
    case BufferView.fetch(name) do
      {:ok, view} -> BufferView.text(view)
      :error -> dormant_read(name, :text, :text) || ""
    end
  end

  def byte_size(name), do: viewed(name, :size, fn -> Kernel.byte_size(text(name)) end)

  def version(name),
    do: viewed(name, :version, fn -> dormant_read(name, :buffer_version, :version) end)

  def path(name), do: viewed(name, :path, fn -> dormant_read(name, :path, :path) end)

  def modified?(name),
    do: viewed(name, :modified, fn -> dormant_read(name, :modified, :modified?) end)

  def point(name), do: viewed(name, :point, fn -> dormant_read(name, :point, :point) end)

  @doc """
  Where the caret stands, as the buffer's own fact: the byte offset, and
  the 1-based line and byte column it falls on. Answers nil when the buffer
  shows no caret.

  A display asks the buffer where the caret is. It does not work the answer
  out from the text, and it does not get to decide whether there is one: a
  rendered page and a source view read the same answer and draw it their
  own way. A mode that shows no caret says so with the `caret` local, which
  is how a terminal, a rendered help page, or a list keeps a clean page.

  The point is clamped here, so no caller has to.
  """
  def caret(name) do
    if get_local(name, "caret") == false do
      nil
    else
      case point(name) do
        nil ->
          nil

        p ->
          text = text(name)
          pos = p |> max(0) |> min(Kernel.byte_size(text))
          {line, column} = Text.line_col(text, pos)
          %{point: pos, line: line, column: column}
      end
    end
  end

  def touch(name), do: GenServer.cast(via(name), :touch)
  def checkpoint_now(name), do: GenServer.call(via(name), :checkpoint_now, 30_000)
  def eviction_info(name), do: GenServer.call(via(name), :eviction_info)

  def prepare_evict(name, generation),
    do: GenServer.call(via(name), {:prepare_evict, generation}, 30_000)

  def discard(name), do: GenServer.call(via(name), :discard)

  def rename(name, new_name, new_path),
    do: GenServer.call(via(name), {:rename, new_name, new_path})

  def goto(name, pos), do: GenServer.call(via(name), {:goto, pos})

  def mark(name), do: viewed(name, :mark, fn -> dormant_read(name, :mark, :mark) end)
  def set_mark(name, pos), do: GenServer.call(via(name), {:set_mark, pos})

  def read_only?(name),
    do: viewed(name, :read_only, fn -> dormant_read(name, :read_only, :read_only?) end)

  def set_read_only(name, bool), do: GenServer.call(via(name), {:set_read_only, bool})

  # buffer-local variables (mode name, mode state, anything Scheme wants)
  def set_local(name, key, val), do: GenServer.call(via(name), {:set_local, key, val})

  @doc """
  Set several locals in one message. One broadcast follows, not one per
  key: a list draw that wrote nine locals one by one made the frame
  refresh and render nine times.
  """
  def set_locals(name, %{} = locals), do: GenServer.call(via(name), {:set_locals, locals})

  def get_local(name, key), do: Map.get(locals(name), key)

  def locals(name) do
    viewed(name, :locals, fn ->
      if exists?(name),
        do: GenServer.call(registry_name(name), :locals),
        else: name |> dormant() |> Map.get(:locals, %{})
    end)
  end

  # overlays: per-tag face ranges (fontification). Byte positions auto-adjust
  # on edits (like mark); modes replace their whole tag set on recompute.
  def set_overlays(name, tag, ranges), do: GenServer.call(via(name), {:set_overlays, tag, ranges})
  def clear_overlays(name, tag \\ :all), do: GenServer.call(via(name), {:clear_overlays, tag})

  def overlays(name) do
    case BufferView.fetch(name) do
      {:ok, view} -> BufferView.overlays(view)
      :error -> GenServer.call(via(name), :overlays)
    end
  end

  def overlay_gen(name),
    do: viewed(name, :overlay_gen, fn -> GenServer.call(via(name), :overlay_gen) end)

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
  def hidden(name, tag \\ :all)

  # the row carries the union the display asks for; one tag still asks the
  # buffer, because only it knows which owner wrote which range
  def hidden(name, :all) do
    case BufferView.fetch(name) do
      {:ok, view} -> BufferView.hidden(view)
      :error -> GenServer.call(via(name), {:hidden, :all})
    end
  end

  def hidden(name, tag), do: GenServer.call(via(name), {:hidden, tag})

  def clear_hidden(name, tag \\ :all), do: GenServer.call(via(name), {:clear_hidden, tag})

  @doc "Narrow the buffer's visible text to an exclusive byte range."
  def narrow(name, start, stop), do: GenServer.call(via(name), {:narrow, start, stop})

  @doc "Widen the buffer so all of its text is visible."
  def widen(name), do: GenServer.call(via(name), :widen)

  def narrow_range(name) do
    case BufferView.fetch(name) do
      {:ok, view} -> Map.get(view, :narrow_range, Map.get(view, :display_range))
      :error -> if exists?(name), do: GenServer.call(via(name), :narrow_range), else: nil
    end
  end

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

  @doc """
  Attribution spans for the current text, as `{start, end, author}`, sorted.

  A dormant buffer answers from its checkpoint, so attribution reads the
  same whether the buffer holds a process or not.
  """
  def authors(name) do
    %{spans: spans, origins: origins} = author_fold(name)
    resolve_spans(spans, origins)
  end

  @doc """
  The fold: `%{spans: [{start, end, changeset_id}], origins: %{id => origin}}`.

  A span names the changeset that wrote its bytes, and an origin holds that
  changeset's actor. This is the form that turns into hunks; `authors/1` is
  the display view of the same data.
  """
  def author_fold(name) do
    try do
      if exists?(name),
        do: GenServer.call(registry_name(name), :author_fold),
        else: dormant_fold(name)
    catch
      :exit, _ -> dormant_fold(name)
    end
  end

  defp dormant_fold(name) do
    cp = dormant(name)
    %{spans: Map.get(cp, :authors) || [], origins: Map.get(cp, :origins) || %{}}
  end

  defp resolve_spans(spans, origins) do
    spans
    |> Enum.map(fn {s, e, id} ->
      case origins[id] do
        %{actor: actor} -> {s, e, actor_label(actor) || "unknown"}
        _ -> {s, e, "unknown"}
      end
    end)
    |> merge_spans()
  end

  @doc """
  Attribution by line: `[{line, author, bytes}]`, 1-based, line order.

  A line two actors touched appears once per actor, largest share first.
  This is the view that meets a diff: git speaks lines, the buffer speaks
  bytes, and the bytes are what the edits actually moved.
  """
  def author_lines(name) do
    try do
      if exists?(name),
        do: GenServer.call(registry_name(name), :author_lines),
        else: dormant_author_lines(name)
    catch
      :exit, _ -> dormant_author_lines(name)
    end
  end

  defp dormant_author_lines(name) do
    cp = dormant(name)

    line_rows(
      Map.get(cp, :text) || "",
      Map.get(cp, :authors) || [],
      Map.get(cp, :origins) || %{}
    )
  end

  @doc "The mutation journal, newest first: [{version, author, pos, ins, del}]."
  def edit_log(name), do: GenServer.call(via(name), :edit_log)

  @doc "Return the durable Provenance status for the buffer."
  def provenance(name), do: GenServer.call(via(name), :provenance)

  @doc """
  The buffer's Loro document, or nil when its mode opted out of recording.

  The document is a mutable handle shared with the buffer process, so a caller
  reads it and does not edit it. Flushes first, so the caller never sees a
  change the buffer has already made but not committed.
  """
  def history(name), do: GenServer.call(via(name), :history)

  @doc """
  Every change to this buffer, oldest first, as the buffer log reads them.

  Each is `%{id:, parent_id:, kind:, actor:, operation:, created_at:, ...}`.
  The actor and the group come out of the change message, which is where they
  are durable.
  """
  def change_log(name) do
    case history(name) do
      nil ->
        []

      weave ->
        changes = History.changes(weave)
        Enum.map(changes, &change_row(&1, changes))
    end
  end

  # A dependency names the last operation of the change it followed, never that
  # change's own id, so it has to be resolved back to the change holding it.
  defp parent_of(deps, changes) do
    Enum.find_value(deps, fn {peer, counter} ->
      changes
      |> Enum.filter(&(&1.peer == peer and &1.counter <= counter))
      |> Enum.max_by(& &1.counter, fn -> nil end)
      |> case do
        nil -> nil
        change -> change_id(change.peer, change.counter)
      end
    end)
  end

  defp change_row(change, changes) do
    {actor, group} = decode_message(change.message)

    %{
      id: change_id(change.peer, change.counter),
      parent_id: parent_of(change.deps, changes),
      kind: change_kind(actor),
      actor: actor,
      operation: %{ops: Enum.map(change.ops, &Map.from_struct/1)},
      metadata: %{group: group},
      created_at: change.timestamp * 1000,
      buffer_version: change.counter,
      lamport: change.lamport
    }
  end

  defp change_id(peer, counter), do: "#{peer}@#{counter}"

  # The kind a reader cares about: where the text came from, not which Loro
  # container it landed in.
  defp change_kind(%{"id" => "system:buffer"}), do: "root"
  defp change_kind(%{"id" => "system:reload"}), do: "gap"
  defp change_kind(%{"id" => "system:resync"}), do: "gap"
  defp change_kind(_), do: "edit"

  defp decode_message(message) do
    case Jason.decode(message || "") do
      {:ok, %{"actor" => actor} = m} -> {actor, m["group"]}
      _ -> {%{"id" => "unknown", "kind" => "unknown"}, nil}
    end
  end

  @doc """
  An anchor on a byte position: an opaque token that keeps naming the same
  place while the text around it changes.

  A byte offset read now and used later is wrong if anyone edited above it in
  between, which is what happens when an agent reads a buffer, thinks, and then
  edits. An anchor survives that, and survives a restart, because it names an
  operation rather than a distance from the start.

  Returns nil for a buffer whose mode records no history.
  """
  def anchor(name, pos) when pos >= 0, do: GenServer.call(via(name), {:anchor, pos})

  @doc "Where an anchor points now, or nil if it cannot be resolved."
  def anchor_pos(name, anchor) when is_binary(anchor),
    do: GenServer.call(via(name), {:anchor_pos, anchor})

  @doc """
  This buffer's version, as the token a replica hands over to ask for what it
  is missing. Opaque, and only meaningful to `updates_since/2`.
  """
  def version_token(name), do: GenServer.call(via(name), :version_token)

  @doc """
  Everything this buffer knows that a replica at `token` does not.

  Pass `nil` for a replica that knows nothing. The bytes are what `merge/2`
  takes, and they are the same bytes the log holds, so a wire and a file carry
  the history in one form.
  """
  def updates_since(name, token \\ nil),
    do: GenServer.call(via(name), {:updates_since, token})

  @doc """
  Take changes another replica made and let this buffer catch up.

  The history merges them, the rope follows, and the point stays where the
  person left it. Concurrent edits do not conflict: two replicas that exchange
  updates both ways end up with the same text.

  Returns `{:ok, changed?}`, or `{:error, reason}` when the bytes are not
  something this buffer can read.
  """
  def merge(name, bytes) when is_binary(bytes),
    do: GenServer.call(via(name), {:merge, bytes}, 30_000)

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

  @doc "1-based logical line -> {start_byte, line_text sans newline}, clamped."
  def line_at(name, line), do: GenServer.call(via(name), {:line_at, line})

  @doc "The 1-based line and text at point, without the newline."
  def line_at_point(name), do: GenServer.call(via(name), :line_at_point)

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

  def undo(name, opts \\ []),
    do: GenServer.call(via(name), {:undo, source(opts), author(opts)})

  @doc """
  All render inputs (text, point, mark, version, locals, overlays, hidden)
  in one read. With a win_id, point/mark/cursor geometry come from that
  window's stored point when it has one (the swapped-in window doesn't —
  it falls through to the buffer point, which is its live point).

  This reads the published row, so a render never queues behind the buffer
  it draws. It falls back to the process only in the moment between
  `start_link` and the first publish.
  """
  def render_snapshot(name, win_id \\ nil) do
    case BufferView.snapshot(name, win_id) do
      nil -> call_render_snapshot(name, win_id)
      snapshot -> snapshot
    end
  end

  defp call_render_snapshot(name, win_id),
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

  @doc """
  Open (true) or close (false) an undo group: the edits between the two
  calls are one undo step, as one command is one step in Emacs. Opening
  closes the step before it; closing commits the group.
  """
  def undo_group(name, on?) when is_boolean(on?),
    do: GenServer.call(via(name), {:undo_group, on?})

  @doc "Write buffer to its path (or the given path). {:ok, path} | {:error, :no_path}."
  def save(name, path \\ nil), do: GenServer.call(via(name), {:save, path})

  # for buffers whose contents were written by other means (remote files):
  # the buffer counts as saved without touching the local filesystem
  def mark_saved(name), do: GenServer.call(via(name), :mark_saved)

  defp source(opts), do: Keyword.get(opts, :source, :user)

  # read in the CALLER's process: `with-edit-author` scopes the Session's
  # dictionary value, and every mutation the evaluated code makes picks it
  # up here without threading an argument through the whole call chain
  defp author(opts), do: Keyword.get(opts, :author, Process.get(:compos_edit_author))

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

    # A leading space is the Emacs convention for an internal buffer, and it
    # is the default answer. A caller that owns a visible but throwaway
    # buffer, like *Messages*, says so with :persistent.
    persistent? = Keyword.get(opts, :persistent, not String.starts_with?(name, " "))
    state = %{state | persistent: persistent?}
    state = state |> attach_provenance() |> attach_history()
    {:ok, _} = Registry.register(@registry, {:id, state.id}, state.name)
    state = state |> schedule_checkpoint() |> reset_idle_timer()

    # publish before the first caller can look: this process is registered
    # from `start_link`, so a reader can already resolve the name here
    BufferView.track(self(), state.name)
    BufferView.put(view(state))
    {:ok, state}
  end

  # Every callback returns through these three, and they are the only place
  # the read model is written. A new callback therefore cannot forget to
  # publish, which is the whole reason the reads may trust the row.
  #
  # The ETS write lands BEFORE the GenServer sends the reply, so a caller
  # that writes and then reads always sees its own write.

  @impl true
  def handle_call(msg, from, state) do
    state = upgrade(state)
    msg |> on_call(from, state) |> published(state)
  end

  @impl true
  def handle_cast(msg, state) do
    state = upgrade(state)
    msg |> on_cast(state) |> published(state)
  end

  @impl true
  def handle_info(msg, state) do
    state = upgrade(state)
    msg |> on_info(state) |> published(state)
  end

  # A hot reload can add a field to the state map. A buffer process that
  # started before the reload still holds the old map, and the first
  # message that reads the field would stop the process. Every entry
  # point fills the field in first. Add a line here with the field.
  defp upgrade(state) do
    Map.put_new(state, :narrow_range, Map.get(state, :display_range))
  end

  defp published({:reply, reply, state}, before),
    do: {:reply, reply, publish_and_notify(state, before)}

  defp published({:reply, reply, state, extra}, before),
    do: {:reply, reply, publish_and_notify(state, before), extra}

  defp published({:noreply, state}, before),
    do: {:noreply, publish_and_notify(state, before)}

  defp published({:noreply, state, extra}, before),
    do: {:noreply, publish_and_notify(state, before), extra}

  defp published(other, _before), do: other

  defp publish_and_notify(state, before) do
    state = publish(state, before)

    if state.hidden != before.hidden do
      Events.broadcast_editor(:locals)
      broadcast(state, state.point, "", 0, :locals)
    end

    state
  end

  # The fields the view holds. An untouched field is the SAME term, so a
  # message that only reads costs one pointer comparison each and writes
  # nothing.
  @view_fields ~w(name id rope bin version saved_version path read_only
                  point mark locals overlays overlay_gen hidden narrow_range win_points)a

  defp publish(state, before) do
    if Enum.any?(@view_fields, &(Map.fetch!(state, &1) != Map.fetch!(before, &1))),
      do: BufferView.put(view(state))

    state
  end

  # `bin` rides along only when this process already flattened the rope for
  # its own sake. It is never flattened to publish: a buffer nobody displays
  # must not pay O(n) per edit, and a reader can flatten the published rope
  # in its own process.
  defp view(state) do
    %{
      name: state.name,
      id: state.id,
      rope: state.rope,
      bin: state.bin,
      size: Rope.byte_size(state.rope),
      version: state.version,
      modified: state.version != state.saved_version,
      path: state.path,
      read_only: state.read_only,
      # Clamped here for the same reason `on_call(:point, ...)` clamps: point
      # never stands outside the buffer, and a redraw that shortens the text
      # leaves it there. Nearly every reader takes point from this row now, so
      # publishing the raw value would route around that guarantee.
      point: clamp(state.point, state),
      mark: state.mark && clamp(state.mark, state),
      locals: state.locals,
      # the RAW tag maps: flattening them costs a concat and a sort, and a
      # write must not pay for a shape only a reader wants. An edit adjusts
      # every range, so this would otherwise run on every keystroke instead
      # of on every render. `BufferView` flattens, in the reading process.
      overlays: state.overlays,
      overlay_gen: state.overlay_gen,
      hidden: state.hidden,
      narrow_range: state.narrow_range,
      win_points: state.win_points
    }
  end

  defp on_cast(:touch, state), do: {:noreply, touch_state(state)}

  defp on_info(:checkpoint, state),
    do: {:noreply, %{write_checkpoint(state) | checkpoint_timer: nil}}

  defp on_info({:idle_timeout, generation}, state) do
    BufferStore.idle_expired(state.name, state.id, generation)
    {:noreply, %{state | idle_timer: nil}}
  end

  # BufferView restarted with an empty table and asked for our row back.
  # `publish/2` writes only what changed, so the row has to be forced.
  defp on_info(:republish_view, state) do
    BufferView.track(self(), state.name)
    BufferView.put(view(state))
    {:noreply, state}
  end

  defp on_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{discard: true} = state) do
    BufferView.forget(state.name)
    flush_provenance(state)
    :ok
  end

  def terminate(_reason, state) do
    BufferView.forget(state.name)
    write_checkpoint(state)
  end

  defp on_call(:text, _from, state) do
    {text, state} = fetch_text(state)
    {:reply, text, state}
  end

  defp on_call(:id, _from, state), do: {:reply, state.id, state}
  defp on_call(:name, _from, state), do: {:reply, state.name, state}

  defp on_call(:byte_size, _from, state), do: {:reply, Rope.byte_size(state.rope), state}
  defp on_call(:version, _from, state), do: {:reply, state.version, state}
  defp on_call(:path, _from, state), do: {:reply, state.path, state}
  # Point never stands outside the buffer. A redraw can replace a list's
  # text with a shorter one while point stays where it was, and every
  # reader that turns point into a byte range then asks for bytes that are
  # not there. wp_get and every setter clamp; so does this, and so does the
  # published row, which is where nearly every reader now takes it from.
  defp on_call(:point, _from, state), do: {:reply, clamp(state.point, state), state}
  defp on_call(:checkpoint_now, _from, state), do: {:reply, :ok, write_checkpoint(state)}

  defp on_call(:eviction_info, _from, state),
    do: {:reply, %{id: state.id, idle_gen: state.idle_gen, locals: state.locals}, state}

  defp on_call({:prepare_evict, generation}, _from, state) do
    if state.idle_gen == generation,
      do: {:reply, true, write_checkpoint(state)},
      else: {:reply, false, state}
  end

  defp on_call(:discard, _from, state), do: {:reply, :ok, %{state | discard: true}}

  defp on_call({:rename, new_name, new_path}, _from, state) do
    case Registry.register(@registry, new_name, state.id) do
      {:ok, _} ->
        Registry.unregister(@registry, state.name)
        old = state.name
        # the row moves with the name; the name it leaves keeps no row
        BufferView.forget(old)
        state = %{state | name: new_name, path: new_path} |> checkpoint_later() |> touch_state()
        state = write_checkpoint(state)
        BufferStore.renamed(old, metadata(state))
        {:reply, :ok, state}

      {:error, {:already_registered, _}} ->
        {:reply, {:error, :already_exists}, state}
    end
  end

  defp on_call(:modified?, _from, state),
    do: {:reply, state.version != state.saved_version, state}

  # a jump (a click, goto-char) ends a run of line motions: the next C-n
  # takes its column from where point now stands (Emacs: last-command)
  defp on_call({:goto, pos}, _from, state),
    do:
      {:reply, :ok,
       state |> Map.put(:point, clamp(pos, state)) |> Map.put(:goal_col, nil) |> checkpoint_later()}

  defp on_call(:mark, _from, state), do: {:reply, state.mark, state}

  defp on_call(:read_only?, _from, state), do: {:reply, state.read_only, state}

  defp on_call({:set_read_only, bool}, _from, state),
    do: {:reply, :ok, state |> Map.put(:read_only, bool) |> checkpoint_later()}

  defp on_call({:set_locals, locals}, _from, state) do
    state = %{state | locals: Map.merge(state.locals, locals)}

    state =
      case Map.fetch(locals, "ts-lang") do
        {:ok, lang} -> init_ts(state, lang)
        :error -> state
      end

    Events.broadcast_editor(:locals)
    broadcast(state, state.point, "", 0, :locals)
    {:reply, :ok, checkpoint_later(state)}
  end

  defp on_call({:set_local, key, val}, _from, state) do
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

  defp on_call({:get_local, key}, _from, state),
    do: {:reply, Map.get(state.locals, key), state}

  defp on_call(:locals, _from, state), do: {:reply, state.locals, state}

  # An overlay change repaints the views that show the buffer, the way a
  # local does. A mode that paints from the reactor (morg, markdown) sets
  # its overlays after the keystroke's own redraw; without this the last
  # typed character wears the old face until the next key. The phantom
  # :locals source triggers no reactor rule, so no paint loop starts.
  defp on_call({:set_overlays, tag, ranges}, _from, state) do
    state = %{
      state
      | overlays: Map.put(state.overlays, tag, ranges),
        overlay_gen: state.overlay_gen + 1
    }

    Events.broadcast_editor(:locals)
    broadcast(state, state.point, "", 0, :locals)
    {:reply, :ok, state}
  end

  defp on_call({:clear_overlays, :all}, _from, state),
    do: {:reply, :ok, %{state | overlays: %{}, overlay_gen: state.overlay_gen + 1}}

  defp on_call({:clear_overlays, tag}, _from, state) do
    {:reply, :ok,
     %{
       state
       | overlays: Map.delete(state.overlays, tag),
         overlay_gen: state.overlay_gen + 1
     }}
  end

  defp on_call(:overlays, _from, state),
    do: {:reply, state.overlays |> Map.values() |> Enum.concat(), state}

  defp on_call(:overlay_gen, _from, state), do: {:reply, state.overlay_gen, state}

  # an empty range list drops the tag: an owner with nothing folded costs
  # nothing to union
  defp on_call({:set_hidden, tag, []}, _from, state) do
    state =
      state
      |> Map.put(:hidden, Map.delete(state.hidden, tag))
      |> checkpoint_later()

    {:reply, :ok, state}
  end

  defp on_call({:set_hidden, tag, ranges}, _from, state) do
    state =
      state
      |> Map.put(:hidden, Map.put(state.hidden, tag, Enum.sort(ranges)))
      |> checkpoint_later()

    {:reply, :ok, state}
  end

  defp on_call({:hidden, :all}, _from, state), do: {:reply, hidden_union(state), state}

  defp on_call({:hidden, tag}, _from, state),
    do: {:reply, Map.get(state.hidden, tag, []), state}

  defp on_call({:clear_hidden, :all}, _from, state),
    do: {:reply, :ok, state |> Map.put(:hidden, %{}) |> checkpoint_later()}

  defp on_call({:clear_hidden, tag}, _from, state),
    do:
      {:reply, :ok,
       state |> Map.put(:hidden, Map.delete(state.hidden, tag)) |> checkpoint_later()}

  defp on_call({:narrow, start, stop}, _from, state) do
    size = Rope.byte_size(state.rope)
    start = start |> max(0) |> min(size)
    stop = stop |> max(start) |> min(size)
    range = if start < stop, do: {start, stop}, else: nil
    {:reply, :ok, %{state | narrow_range: range}}
  end

  defp on_call(:widen, _from, state), do: {:reply, :ok, %{state | narrow_range: nil}}

  defp on_call(:narrow_range, _from, state), do: {:reply, state.narrow_range, state}

  # read-only blocks :user mutations only — programmatic sources (:editor,
  # :process, agents) are the inhibit-read-only path (dired regenerates its
  # own read-only buffer this way)
  defp on_call({:insert, _, :user, _}, _f, %{read_only: true} = s), do: ro(s)
  defp on_call({:append, _, :user, _}, _f, %{read_only: true} = s), do: ro(s)
  defp on_call({:insert_at, _, _, :user, _, _locals}, _f, %{read_only: true} = s), do: ro(s)
  defp on_call({:delete_range, _, _, :user, _}, _f, %{read_only: true} = s), do: ro(s)
  defp on_call({:replace_range, _, _, _, :user, _}, _f, %{read_only: true} = s), do: ro(s)
  defp on_call({:delete_char, _, :user, _}, _f, %{read_only: true} = s), do: ro(s)
  defp on_call({:kill_line, :user, _}, _f, %{read_only: true} = s), do: ro(s)

  defp on_call({:line_of, pos}, _from, state) do
    {:reply, Rope.byte_to_line(state.rope, clamp(pos, state)) + 1, state}
  end

  defp on_call(:line_at_point, _from, state) do
    rope = state.rope
    line = Rope.byte_to_line(rope, clamp(state.point, state)) + 1
    count = Rope.line_count(rope)
    start = Rope.line_to_byte(rope, line - 1)
    stop = if line == count, do: Rope.byte_size(rope), else: Rope.line_to_byte(rope, line)
    text = rope |> Rope.slice(start, stop - start) |> String.trim_trailing("\n")
    {:reply, {line, text}, state}
  end

  defp on_call({:line_at, line}, _from, state) do
    rope = state.rope
    count = Rope.line_count(rope)
    line = line |> max(1) |> min(count)
    s = Rope.line_to_byte(rope, line - 1)
    e = if line == count, do: Rope.byte_size(rope), else: Rope.line_to_byte(rope, line)
    {:reply, {s, rope |> Rope.slice(s, e - s) |> String.trim_trailing("\n")}, state}
  end

  defp on_call({:set_mark, nil}, _from, state),
    do: {:reply, :ok, state |> Map.put(:mark, nil) |> checkpoint_later()}

  defp on_call({:set_mark, pos}, _from, state),
    do: {:reply, :ok, state |> Map.put(:mark, clamp(pos, state)) |> checkpoint_later()}

  defp on_call({:search, q, from, dir}, _from, state) do
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

  defp on_call({:insert, text, src, author}, _from, state) do
    # do_insert's point adjustment already advances point past the insertion
    {:reply, :ok,
     state |> do_insert(state.point, text, src, author) |> touch_state() |> checkpoint_later()}
  end

  defp on_call({:append, text, src, author}, _from, state) do
    {:reply, :ok,
     state
     |> do_insert(Rope.byte_size(state.rope), text, src, author)
     |> touch_state()
     |> checkpoint_later()}
  end

  defp on_call({:insert_at, pos, text, src, author, locals}, _from, state) do
    # locals first: do_insert broadcasts, and the frame it paints must
    # already see them
    state = %{state | locals: Map.merge(state.locals, locals)}

    {:reply, :ok,
     state |> do_insert(pos, text, src, author) |> touch_state() |> checkpoint_later()}
  end

  defp on_call({:delete_range, pos, len, src, author}, _from, state) do
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

  defp on_call({:replace_range, pos, len, text, src, author}, _from, state) do
    size = Rope.byte_size(state.rope)

    if pos < 0 or len < 0 or pos + len > size do
      {:reply, {:error, :out_of_bounds}, state}
    else
      # one snapshot for the pair: the whole replacement is one undo step
      state = close_undo_step(state)
      state = if len > 0, do: do_delete(state, pos, len, src, author, false), else: state
      state = if text != "", do: do_insert(state, pos, text, src, author, false), else: state
      # never a self-insert run: the next typed char starts its own undo step
      state = %{state | insert_run: 0}
      # The pair is one step, so it closes here rather than between its halves.
      state = if batchable?(src), do: state, else: settle(state)
      {:reply, :ok, state |> touch_state() |> checkpoint_later()}
    end
  end

  defp on_call({:delete_char, n, src, author}, _from, state) do
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

  defp on_call({:kill_line, src, author}, _from, state) do
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

  defp on_call(:authors, _from, state),
    do: {:reply, resolve_spans(state.authors, state.origins), state}

  defp on_call(:author_fold, _from, state),
    do: {:reply, %{spans: state.authors, origins: state.origins}, state}

  defp on_call(:author_lines, _from, state) do
    {text, state} = fetch_text(state)
    {:reply, line_rows(text, state.authors, state.origins), state}
  end

  defp on_call(:edit_log, _from, state), do: {:reply, state.edit_log, state}

  defp on_call(:provenance, _from, state) do
    state = flush_provenance(state)
    {:reply, state.provenance, state}
  end

  defp on_call(:history, _from, state) do
    state = state |> flush_provenance() |> close_undo_step()
    {:reply, state.history, state}
  end

  defp on_call({:anchor, pos}, _from, state) do
    {:reply, take_anchor(state, pos), state}
  end

  defp on_call({:anchor_pos, anchor}, _from, state) do
    {:reply, read_anchor(state, anchor), state}
  end

  defp on_call(:version_token, _from, state) do
    state = state |> flush_provenance() |> close_undo_step()
    {:reply, state.history && History.version(state.history), state}
  end

  defp on_call({:updates_since, _token}, _from, %{history: nil} = state),
    do: {:reply, {:error, :no_history}, state}

  defp on_call({:updates_since, token}, _from, state) do
    # Close the open change first: a replica must never be told about work
    # this buffer has not finished writing.
    state = state |> flush_provenance() |> close_undo_step()

    reply =
      case token do
        nil -> History.export_all(state.history)
        from -> History.export_updates(state.history, from)
      end

    {:reply, reply, state}
  end

  defp on_call({:merge, _bytes}, _from, %{history: nil} = state),
    do: {:reply, {:error, :no_history}, state}

  defp on_call({:merge, bytes}, _from, state) do
    # Our own work closes before theirs arrives, so the merge cannot fold a
    # half-written local change together with a remote one.
    state = state |> flush_provenance() |> close_undo_step()
    {before, state} = fetch_text(state)

    case History.import(state.history, bytes) do
      {:error, reason} ->
        Logger.error("merge refused in #{state.name}: #{inspect(reason)}")
        {:reply, {:error, reason}, state}

      _len ->
        state = apply_history_text(state, merge_actor(state), :remote)
        {text, state} = fetch_text(state)

        # Their change is already committed on the replica that made it, so
        # this only puts the bytes in our log.
        state = persist_history(state)
        {:reply, {:ok, text != before}, checkpoint_later(state)}
    end
  end

  # The authorship fold wants one actor for the bytes that arrived. The change
  # itself carries the actor who really wrote it, so the fold says "elsewhere"
  # and the history says who.
  defp merge_actor(_state),
    do: local_actor("system:remote", "system", "remote", :merge)

  defp on_call({:provenance_start, src, author, opts}, _from, state) do
    state = flush_provenance(state)
    actor = resolve_actor(author, src)
    policy_source = policy_of(opts)

    state = %{
      state
      | provenance: %{state.provenance | enabled: true, policy_source: policy_source, gap: false}
    }

    # Edits made while recording was off never reached the history, so it is
    # behind the rope. One change bridges the interval, attributed to whoever
    # started recording rather than to whoever typed: nobody recorded that.
    {text, state} = fetch_text(state)

    state =
      state
      |> mirror_update(text)
      |> claim(%{actor | id: "system:gap", kind: "system"})
      |> commit_history()

    {:reply, :ok, checkpoint_later(state)}
  end

  defp on_call({:provenance_stop, _src, _author, opts}, _from, state) do
    state = flush_provenance(state)
    policy_source = policy_of(opts)

    if policy_source == "mode" and state.provenance.policy_source == "user" do
      {:reply, :ok, state}
    else
      # Everything recorded so far is committed and on disk before recording
      # stops, so stopping never loses the work behind it.
      state = settle(state)

      state = %{
        state
        | provenance: %{state.provenance | enabled: false, policy_source: policy_source}
      }

      {:reply, :ok, checkpoint_later(state)}
    end
  end

  defp on_call({:provenance_checkpoint, _src, _author, _opts}, _from, state) do
    if state.provenance.enabled,
      do: {:reply, :ok, state |> settle() |> checkpoint_later()},
      else: {:reply, {:error, :not_recording}, state}
  end

  defp on_call({:motion, motion}, _from, state) do
    {text, state} = fetch_text(state)

    state =
      if motion in [:next_line, :prev_line] do
        # goal column: crossing a short line must not lose the column. The
        # column counts graphemes, not bytes: a byte column lands inside a
        # multibyte character on a line of CJK or emoji.
        {bol, _} = Text.line_bounds(text, state.point)

        %{
          state
          | goal_col:
              state.goal_col || String.length(binary_part(text, bol, state.point - bol))
        }
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

  # Undo belongs to the actor that asks for it. The document reverts only that
  # actor's operations and rebases them over everyone else's, so undoing your
  # own typing no longer reverts the agent's work in the same buffer.
  #
  # The Emacs model survives on top of that. A run of consecutive undos keeps
  # walking back; any other command breaks the run, after which undo replays
  # the undos, which is Emacs's redo.
  defp on_call({:undo, src, author}, _from, state) do
    actor = resolve_actor(author, src)

    if state.history == nil do
      {:reply, {:error, :no_undo}, state}
    else
      # Close the open step, so the work being undone is a complete change.
      state = state |> close_undo_step() |> ensure_undo_actor(actor)
      id = undo_scope(actor)

      case undo_or_redo(state, id) do
        {:ok, _} ->
          state = state |> apply_history_text(actor) |> Map.put(:undo_run, true)
          {:reply, :ok, checkpoint_later(state)}

        :none ->
          {:reply, {:error, :no_undo}, state}

        {:error, reason} ->
          Logger.error("undo failed for #{state.name}: #{inspect(reason)}")
          {:reply, {:error, :no_undo}, state}
      end
    end
  end

  # everything the renderer needs, in one round trip; line geometry is
  # O(log n) rope lookups, not text scans
  defp on_call({:render_snapshot, win_id}, _from, state) do
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
       narrow_range: state.narrow_range,
       path: state.path,
       read_only: state.read_only,
       total_lines: Rope.line_count(state.rope),
       cursor_line: cursor_line,
       line: cursor_line + 1,
       col: point - Rope.line_to_byte(state.rope, cursor_line)
     }, state}
  end

  defp on_call({:wp_swap_in, win_id}, _from, state) do
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

  defp on_call({:wp_save, win_id}, _from, state) do
    entry = %{point: state.point, mark: state.mark, goal: state.goal_col}
    {:reply, :ok, %{state | win_points: Map.put(state.win_points, win_id, entry)}}
  end

  defp on_call({:wp_set, win_id, pos}, _from, state) do
    entry = %{point: clamp(pos, state), mark: nil, goal: nil}
    {:reply, :ok, %{state | win_points: Map.put(state.win_points, win_id, entry)}}
  end

  defp on_call({:wp_drop, win_id}, _from, state),
    do: {:reply, :ok, %{state | win_points: Map.delete(state.win_points, win_id)}}

  defp on_call({:wp_get, win_id}, _from, state) do
    case state.win_points[win_id] do
      %{point: p} -> {:reply, clamp(p, state), state}
      nil -> {:reply, state.point, state}
    end
  end

  defp on_call(:ts_highlight, _from, %{ts: nil} = state), do: {:reply, [], state}

  defp on_call(:ts_highlight, _from, %{ts: %{spans: spans}} = state) when spans != nil,
    do: {:reply, spans, state}

  defp on_call(:ts_highlight, _from, %{ts: ts} = state) do
    {text, state} = fetch_text(state)
    spans = TS.ts_state_highlight(ts.res, text)
    {:reply, spans, %{state | ts: %{ts | spans: spans}}}
  end

  defp on_call({:ts_node, _kind, _s, _e, _op}, _from, %{ts: nil} = state),
    do: {:reply, nil, state}

  defp on_call({:ts_node, kind, s, e, op}, _from, %{ts: ts} = state) do
    {text, state} = fetch_text(state)
    {:reply, TS.ts_state_node(ts.res, text, kind, s, e, op), state}
  end

  defp on_call({:ts_children, _kind, _s, _e}, _from, %{ts: nil} = state),
    do: {:reply, [], state}

  defp on_call({:ts_children, kind, s, e}, _from, %{ts: ts} = state) do
    {text, state} = fetch_text(state)
    {:reply, TS.ts_state_children(ts.res, text, kind, s, e), state}
  end

  defp on_call({:undo_group, true}, _from, state) do
    state = close_undo_step(state)
    {:reply, :ok, Map.put(state, :undo_group, true)}
  end

  defp on_call({:undo_group, false}, _from, state) do
    state = Map.put(state, :undo_group, false)
    {:reply, :ok, close_undo_step(state)}
  end

  defp on_call(:break_undo_chain, _from, state),
    do: {:reply, :ok, %{state | undo_run: false}}

  # a save is not an edit, but the modified flag every view shows just
  # changed — repaint through the same phantom-change channel set_local
  # uses (:locals triggers no reactor rules)
  defp on_call(:mark_saved, _from, state) do
    state = %{state | saved_version: state.version}
    Events.broadcast_editor(:locals)
    broadcast(state, state.point, "", 0, :locals)
    {:reply, :ok, checkpoint_later(state)}
  end

  defp on_call({:save, override}, _from, state) do
    case override || state.path do
      nil ->
        {:reply, {:error, :no_path}, state}

      path ->
        {text, state} = fetch_text(state)
        BufferStore.atomic_write(path, encode_file_text(text, state.encoding))
        state = %{state | path: path, saved_version: state.version}
        Events.broadcast_editor(:locals)
        broadcast(state, state.point, "", 0, :locals)

        state =
          state
          |> flush_provenance()
          |> close_undo_step()
          |> persist_history()
          |> touch_state()
          |> checkpoint_later()

        {:reply, {:ok, path}, state}
    end
  end

  # The recording policy, which the checkpoint restores and this seeds. It is
  # four fields about whether to record, not a record of anything: the history
  # itself lives in the weave and its log.
  defp attach_provenance(%{provenance: %{enabled: _}} = state), do: state

  defp attach_provenance(state) do
    %{
      state
      | provenance: %{
          enabled: true,
          policy_source: "default",
          retention: if(state.persistent, do: "durable", else: "session"),
          gap: false
        }
    }
  end

  defp policy_of(opts), do: Keyword.get(opts, :policy_source, "user")

  # A changeset id is local to this buffer: the authorship fold names it and
  # the origins map resolves it. The history has its own ids for its own
  # changes, and the two never have to agree.
  defp new_changeset_id, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  # --- the Loro document -----------------------------------------------------
  #
  # See `docs/PROVENANCE-CRDT.md`. The document mirrors the rope: the rope
  # leads for a local edit, and every mutation path funnels through `do_insert`
  # and `do_delete`, so mirroring in those two places covers all of them.
  #
  # Nothing reads the document yet. It records history and merges concurrent
  # work; the rope stays the working representation and the line index.

  # A buffer whose mode opted out of recording gets no document either, so one
  # policy governs both. `attach_provenance` always answers with a map, so
  # there is no nil case here.
  defp attach_history(%{provenance: %{enabled: false}} = state), do: state

  defp attach_history(state) do
    {text, state} = fetch_text(state)

    case restore_history(state, text) do
      nil -> %{state | history: seed_history(state, text)}
      weave -> %{state | history: weave, history_persisted: History.version(weave)}
    end
  rescue
    # A history is not worth losing a buffer over. Without one the buffer
    # behaves as it did before any of this.
    e ->
      Logger.error("no history attached to #{state.name}: #{inspect(e)}")
      state
  end

  # A buffer the store has never seen. The seed change says how the text got
  # here, so even a buffer with no log on disk has an origin.
  defp seed_history(state, text) do
    weave = History.new(History.replica_peer())
    if text != "", do: History.insert(weave, 0, text)

    History.commit(
      weave,
      "system",
      history_message(
        local_actor(
          "system:buffer",
          "system",
          "buffer",
          if(state.path, do: :file_load, else: :buffer_create)
        ),
        buffer_group(state)
      )
    )

    weave
  end

  # The log holds everything this buffer ever was. Reading it back is the whole
  # point of writing it: an evicted buffer that comes back keeps its history,
  # and so does one that comes back after a restart.
  defp restore_history(state, text) do
    case BufferHistoryStore.read(state.id) do
      [] ->
        nil

      blobs ->
        weave = History.new(History.replica_peer())
        Enum.each(blobs, &History.import(weave, &1))
        reconcile_history(state, weave, text)
    end
  rescue
    e ->
      Logger.error("could not restore the history for #{state.name}: #{inspect(e)}")
      nil
  end

  # The text can move while the buffer is away: a file re-read from disk, or an
  # edit made by something else. What came before is still this buffer's, so the
  # history takes the new text as a change rather than being thrown away.
  defp reconcile_history(state, weave, text) do
    case History.text(weave) do
      ^text ->
        weave

      other when is_binary(other) ->
        History.update(weave, text)

        History.commit(
          weave,
          "system",
          history_message(
            local_actor("system:reload", "system", "reload", :external_change),
            buffer_group(state)
          )
        )

        weave

      _ ->
        nil
    end
  end

  # Recording can stop after the history is attached. A stopped buffer flushes
  # nothing, so a mirrored operation would never get a message. One test
  # answers both questions.
  defp mirroring?(%{history: nil}), do: false
  defp mirroring?(%{provenance: %{enabled: true}}), do: true
  defp mirroring?(_), do: false

  defp mirror_insert(state, pos, text, actor) do
    if mirroring?(state) do
      state
      |> commit_on_actor_change(actor)
      |> history_result(History.insert(state.history, pos, text), "insert")
      |> claim(actor)
    else
      state
    end
  end

  defp mirror_delete(state, pos, len, actor) do
    if mirroring?(state) do
      state
      |> commit_on_actor_change(actor)
      |> history_result(History.delete(state.history, pos, len), "delete")
      |> claim(actor)
    else
      state
    end
  end

  # Who owns the operations sitting uncommitted in the document. Provenance
  # clears `pending_actor` on its own schedule, so the document keeps its own
  # answer and the two no longer have to flush together.
  defp claim(state, actor),
    do: %{state | history_actor: actor, history_group: buffer_group(state)}

  # A change holds one actor's work. A different actor closes the open one.
  defp commit_on_actor_change(%{history_actor: nil} = state, _actor), do: state

  defp commit_on_actor_change(state, actor) do
    if state.history_actor.id == actor.id and state.history_group == buffer_group(state),
      do: state,
      else: commit_history(state)
  end

  # Undo swaps the whole rope, so the document takes the result and works out
  # the operations. Phase 3 moves undo into the document and retires this.
  defp mirror_update(state, text) do
    if mirroring?(state),
      do: history_result(state, History.update(state.history, text), "update"),
      else: state
  end

  # A failed mirror leaves the document behind the rope. The checkpoint
  # comparison finds that and resynchronizes, so log it and keep editing.
  # A failed Loro call leaves the document behind: the NIF reported a
  # poisoned lock once, and the next call into that document panicked
  # inside Loro and aborted the VM. The text is the rope's; the weave is a
  # mirror. Drop the mirror and keep editing; the checkpoint on disk holds
  # the last good weave.
  defp history_result(state, {:error, reason}, what) do
    Logger.error(
      "loro #{what} failed for #{state.name}: #{inspect(reason)}; provenance mirroring stops for this buffer"
    )

    %{state | history: nil}
  end

  defp history_result(state, _ok, _what), do: state

  defp commit_history(%{history_actor: nil} = state), do: state

  # inside an undo group (one command) the edits stay one step; the group's
  # end commits them. Map.get: a hot swap keeps a state built before the key.
  defp commit_history(%{undo_group: true} = state), do: state

  defp commit_history(state) do
    state =
      if mirroring?(state) do
        try do
          History.commit(
            state.history,
            history_origin(state.history_actor),
            history_message(state.history_actor, state.history_group)
          )

          state
        rescue
          e ->
            # a panic inside the NIF surfaces here; the document is not to
            # be touched again (see history_result)
            history_result(state, {:error, Exception.message(e)}, "commit")
        end
      else
        state
      end

    %{state | history_actor: nil, history_group: nil}
  end

  # The origin is the live label the undo managers filter on in Phase 3. The
  # actor id already reads `user:local`, `agent:codex`, `system:undo`, so a
  # prefix match on it separates the actors.
  defp history_origin(actor), do: Map.get(actor, :id, "unknown")

  # The durable record. A Loro change carries no origin field, so everything
  # that must survive an export goes in the message.
  defp history_message(actor, group) do
    Jason.encode!(%{actor: actor, group: group})
  rescue
    _ -> to_string(Map.get(actor, :id, "unknown"))
  end

  # The invariant: the rope and the document hold the same bytes. Checked at
  # every checkpoint boundary, which is also where the buffer already compares
  # content hashes.
  #
  # In this phase the rope is authoritative, so a mismatch resynchronizes the
  # document from the rope. That direction reverses in Phase 5, once the
  # document owns the history the rope cannot rebuild.
  defp verify_history(%{history: nil} = state), do: state

  # Recording can be off while the document stays attached. Then the rope is
  # meant to run ahead: the mirror is off, and `provenance_start` bridges the
  # interval with one change. A comparison here reports a divergence that it
  # cannot repair, once per checkpoint, for as long as the buffer lives.
  defp verify_history(%{provenance: %{enabled: false}} = state), do: state

  defp verify_history(state) do
    {text, state} = fetch_text(state)

    case History.text(state.history) do
      ^text ->
        state

      other when is_binary(other) ->
        Logger.error(
          "history diverged in #{state.name}: rope #{Kernel.byte_size(text)} B, " <>
            "history #{Kernel.byte_size(other)} B; resynchronizing from the rope"
        )

        state
        |> mirror_update(text)
        |> claim(resync_actor())
        |> commit_history()

      {:error, reason} ->
        Logger.error("history unreadable in #{state.name}: #{inspect(reason)}")
        state
    end
  end

  defp resync_actor,
    do: local_actor("system:resync", "system", "resync", :history_resync)

  # --- persisting the document -----------------------------------------------
  #
  # Appended at every checkpoint boundary, which costs about 1.2 KB per 500
  # typed characters. The log is rewritten as one snapshot when it grows past
  # a multiple of the text, so the file tracks the buffer instead of the number
  # of edits ever made to it.

  defp persist_history(%{history: nil} = state), do: state
  defp persist_history(%{discard: true} = state), do: state
  defp persist_history(%{persistent: false} = state), do: state

  defp persist_history(state) do
    # Nothing written yet means the log starts empty, so it wants everything.
    # Exporting "since the current version" would write nothing at all.
    exported =
      case state.history_persisted do
        nil -> History.export_all(state.history)
        from -> History.export_updates(state.history, from)
      end

    case exported do
      updates when is_binary(updates) and Kernel.byte_size(updates) > 0 ->
        written = BufferHistoryStore.append(state.id, updates)
        state = %{state | history_persisted: History.version(state.history)}
        if written > 0, do: maybe_compact(state), else: state

      _ ->
        state
    end
  rescue
    e ->
      # The text is safe in the checkpoint either way. Losing the log costs
      # history, which is worth a loud message and not a dead buffer.
      Logger.error("could not persist the document for #{state.name}: #{inspect(e)}")
      state
  end

  # A snapshot of an 85 KB source file is about 75 KB, so a log several times
  # that has more update frames than content and is worth collapsing.
  @history_log_slack 4

  defp maybe_compact(state) do
    if BufferHistoryStore.size(state.id) >
         max(@history_log_slack * Rope.byte_size(state.rope), 64 * 1024) do
      case History.export_snapshot(state.history) do
        snapshot when is_binary(snapshot) ->
          BufferHistoryStore.compact(state.id, snapshot)
          %{state | history_persisted: History.version(state.history)}

        _ ->
          state
      end
    else
      state
    end
  end

  # --- anchors ---------------------------------------------------------------
  #
  # A cursor names an operation, so it keeps naming the same place while text
  # is inserted and deleted around it. The bytes cross into Scheme and out to a
  # tool call as base64, because an anchor travels through JSON.

  defp take_anchor(%{history: nil}, _pos), do: nil

  defp take_anchor(state, pos) do
    case History.cursor(state.history, min(pos, Rope.byte_size(state.rope))) do
      cursor when is_binary(cursor) -> Base.url_encode64(cursor, padding: false)
      _ -> nil
    end
  end

  defp read_anchor(%{history: nil}, _anchor), do: nil

  defp read_anchor(state, anchor) do
    with {:ok, bytes} <- Base.url_decode64(anchor, padding: false),
         pos when is_integer(pos) <- History.cursor_pos(state.history, bytes) do
      min(pos, Rope.byte_size(state.rope))
    else
      _ -> nil
    end
  end

  # --- undo ------------------------------------------------------------------
  #
  # One commit is one undo step. The buffer decides where a step ends, exactly
  # where it used to push a snapshot, and the document remembers the rest.
  # A run of typed characters stays one step because nothing commits until the
  # run breaks.

  # An undo stack belongs to a scope, not to one actor id. A command that the
  # user invoked edits as `system:editor`, and Emacs undoes it as the user's
  # own work, so the user's scope owns every kind except the ones that act on
  # their own: agents and processes.
  #
  # Agents share one scope with each other. No caller needs them apart yet.
  defp undo_scope(%{kind: "agent"} = actor), do: actor.id
  defp undo_scope(%{kind: "process"}), do: "process"
  defp undo_scope(_actor), do: "user"

  defp undo_excludes("user"), do: ~w(agent process)
  defp undo_excludes("process"), do: ~w(user agent system mode legacy unknown)
  defp undo_excludes(_agent), do: ~w(user process system mode legacy unknown)

  defp close_undo_step(state), do: commit_history(state)

  defp ensure_undo_actor(%{history: nil} = state, _actor), do: state

  defp ensure_undo_actor(state, actor) do
    scope = undo_scope(actor)

    unless History.actor?(state.history, scope) do
      History.register_actor(state.history, scope, undo_excludes(scope), @undo_limit)
    end

    state
  end

  # Emacs: a run of undos keeps walking back, and the first undo after the run
  # breaks replays them instead.
  defp undo_or_redo(state, id) do
    {undos, redos} = History.undo_count(state.history, id)

    cond do
      not state.undo_run and redos > 0 -> result(History.redo(state.history, id))
      undos > 0 -> result(History.undo(state.history, id))
      redos > 0 -> result(History.redo(state.history, id))
      true -> :none
    end
  end

  defp result(true), do: {:ok, true}
  defp result(false), do: :none
  defp result({:error, reason}), do: {:error, reason}

  # The document led, so the rope follows. Comparing the two texts gives one
  # contiguous replacement that always reaches the right result. A step that
  # touched separate regions produces a wider span than it strictly changed,
  # which costs precision in the authorship fold and nothing in the text.
  defp apply_history_text(state, actor, src \\ :undo) do
    {old, state} = fetch_text(state)

    case History.text(state.history) do
      {:error, reason} ->
        Logger.error("could not read the history in #{state.name}: #{inspect(reason)}")
        state

      new ->
        case text_delta(old, new) do
          nil -> state
          {pos, removed, inserted} -> rewrite(state, actor, pos, removed, inserted, src)
        end
    end
  end

  defp rewrite(state, actor, pos, removed, inserted, src) do
    old_rope = state.rope
    rope = if removed > 0, do: Rope.delete(state.rope, pos, removed), else: state.rope
    rope = if inserted != "", do: Rope.insert(rope, pos, inserted), else: rope
    added = Kernel.byte_size(inserted)

    state = %{state | rope: rope, bin: nil, version: state.version + 1}
    state = ts_track(state, old_rope, pos, pos + removed, pos + added)

    state =
      state
      |> adjust_point_delete(pos, removed)
      |> adjust_ranges(&adjust_delete(&1, pos, removed), &adjust_delete(&1, pos, removed))
      |> adjust_point_insert(pos, added)
      |> adjust_ranges(&adjust_insert(&1, pos, added), &adjust_insert_stay(&1, pos, added))

    # An undo authors what it restores: the actor who asked for it is
    # responsible for the text coming back. A merge authors nothing new, and
    # the actor is whoever wrote the change on the replica it came from.
    {changeset, state} = open_changeset(state, actor, src)
    authors = if removed > 0, do: stamp_delete(state.authors, pos, removed), else: state.authors

    # Only stamp bytes that came back. Stamping zero of them would leave an
    # empty span behind, and an undo that only deletes leaves the surviving
    # spans exactly as their authors wrote them.
    authors =
      if added > 0,
        do: stamp_insert(authors, pos, added, stamp_id(actor, changeset)),
        else: authors

    # An undo puts the point on what it restored, because the person asked for
    # it and wants to see it. A change from elsewhere must not move the point:
    # the adjustments above already carried it past the edit.
    state = %{
      state
      | authors: authors,
        point: if(src == :undo, do: pos + added, else: state.point),
        goal_col: nil,
        last_insert_end: nil,
        insert_run: 0
    }

    state = log_edit(state, actor_label(actor), pos, added, removed)
    state = record_op(state, actor, pos, inserted, "", src, true)
    state = ts_invalidate(state)
    broadcast(state, 0, "", 0, src)
    # The change was written and closed elsewhere, by the undo manager or by
    # another replica, so this buffer holds no uncommitted work of its own.
    %{state | history_actor: nil, history_group: nil}
  end

  # The one contiguous replacement between two texts: skip the common prefix,
  # skip the common suffix, and what is left is the change. Both ends step back
  # to a character boundary, because the rope floors a byte offset that lands
  # inside a character and would otherwise cut one in half.
  defp text_delta(same, same), do: nil

  defp text_delta(old, new) do
    prefix = char_floor(old, common_prefix(old, new, 0))

    suffix =
      common_suffix(
        old,
        new,
        min(Kernel.byte_size(old) - prefix, Kernel.byte_size(new) - prefix)
      )

    suffix = suffix_floor(old, suffix)
    removed = Kernel.byte_size(old) - prefix - suffix
    inserted = binary_part(new, prefix, Kernel.byte_size(new) - prefix - suffix)
    {prefix, removed, inserted}
  end

  defp common_prefix(old, new, i) do
    limit = min(Kernel.byte_size(old), Kernel.byte_size(new))

    if i < limit and :binary.at(old, i) == :binary.at(new, i),
      do: common_prefix(old, new, i + 1),
      else: i
  end

  defp common_suffix(old, new, limit, i \\ 0)
  defp common_suffix(_old, _new, limit, i) when i >= limit, do: limit

  defp common_suffix(old, new, limit, i) do
    a = :binary.at(old, Kernel.byte_size(old) - 1 - i)
    b = :binary.at(new, Kernel.byte_size(new) - 1 - i)
    if a == b, do: common_suffix(old, new, limit, i + 1), else: i
  end

  # A UTF-8 continuation byte is 0b10xxxxxx. The prefix ends earlier and the
  # suffix starts later, so both moves widen the changed span rather than
  # cutting a character in half.
  defp continuation?(bin, i),
    do: i < Kernel.byte_size(bin) and Bitwise.band(:binary.at(bin, i), 0xC0) == 0x80

  defp char_floor(_bin, 0), do: 0
  defp char_floor(bin, i), do: if(continuation?(bin, i), do: char_floor(bin, i - 1), else: i)

  defp char_ceil(bin, i), do: if(continuation?(bin, i), do: char_ceil(bin, i + 1), else: i)

  defp suffix_floor(bin, suffix) do
    start = char_ceil(bin, Kernel.byte_size(bin) - suffix)
    Kernel.byte_size(bin) - start
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
      saved_version: saved_version,
      authors: restored_authors(cp),
      origins: cp[:origins] || %{},
      provenance: cp[:provenance]
    }
  end

  # A checkpoint written before the fold existed restores no spans, and a
  # span cannot outlive the text it describes: a file re-read from disk can
  # be shorter than the buffer that wrote the checkpoint.
  defp restored_authors(cp) do
    size = Kernel.byte_size(cp[:text] || "")

    (cp[:authors] || [])
    |> Enum.map(fn {s, e, id} -> {min(s, size), min(e, size), id} end)
    |> Enum.reject(fn {s, e, _} -> s >= e end)
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
      provenance: state.provenance,
      authors: state.authors,
      origins: Map.take(state.origins, Enum.map(state.authors, fn {_, _, id} -> id end))
    }
  end

  defp metadata(state),
    do: %{
      id: state.id,
      name: state.name,
      path: state.path,
      checkpoint: BufferStore.checkpoint_path(state.id)
    }

  # Provenance flushes on every checkpoint boundary, including the ones that
  # write no state: a dormant, unsaved, or discarded buffer still owns its
  # history.
  defp write_checkpoint(state),
    do:
      state
      |> flush_provenance()
      |> close_undo_step()
      |> verify_history()
      |> persist_history()
      |> prune_origins()
      |> write_state_checkpoint()

  defp write_state_checkpoint(%{discard: true} = state), do: state
  defp write_state_checkpoint(%{persistent: false} = state), do: state

  # Nothing changed since the last write, so the file on disk is current.
  # A forced checkpoint of a clean buffer costs one comparison, not one
  # serialization of the whole text.
  defp write_state_checkpoint(%{dirty: false} = state), do: state

  defp write_state_checkpoint(state) do
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
  defp checkpoint_later(%{persistent: false, pending_ops: []} = state), do: state

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
    timeout = Application.get_env(:compos_core, :buffer_idle_timeout_ms, 24 * 60 * 60 * 1_000)
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
    state = if snap?, do: maybe_close_undo_step(state, pos, text, src), else: state
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

    # After open_changeset, never before. Opening flushes the previous actor's
    # work, and a document operation applied before that flush would be
    # committed under the previous actor's name.
    {changeset, state} = open_changeset(state, actor, src)
    state = mirror_insert(state, pos, text, actor)
    state = %{state | authors: stamp_insert(state.authors, pos, len, stamp_id(actor, changeset))}
    state = log_edit(state, author, pos, len, 0)
    state = record_op(state, actor, pos, text, "", src, snap?)

    state = %{
      state
      | goal_col: nil,
        last_insert_end: pos + len,
        undo_run: false
    }

    broadcast(state, pos, text, 0, src)
    state
  end

  # amalgamate consecutive single-char self-inserts into one undo step
  # (Emacs groups ~20) — undoing a typed word char-by-char is misery
  defp maybe_close_undo_step(state, pos, text, :user)
       when Kernel.byte_size(text) == 1 and text != "\n" do
    # amalgamate only onto a previous self-insert (insert_run > 0) â never
    # amalgamate only onto a previous self-insert (insert_run > 0) — never
    # chain onto a newline/paste/programmatic insert's undo step
    if state.last_insert_end == pos and state.insert_run > 0 and state.insert_run < 20 do
      %{state | insert_run: state.insert_run + 1}
    else
      %{close_undo_step(state) | insert_run: 1}
    end
  end

  defp maybe_close_undo_step(state, _pos, _text, _src),
    do: %{close_undo_step(state) | insert_run: 0}

  defp do_delete(state, pos, len, src, author, snap? \\ true) do
    actor = resolve_actor(author, src)
    author = actor_label(actor)
    state = if snap?, do: close_undo_step(state), else: state
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
    # After open_changeset, for the reason given in do_insert.
    {_changeset, state} = open_changeset(state, actor, src)
    state = mirror_delete(state, pos, len, actor)
    state = %{state | authors: stamp_delete(state.authors, pos, len)}
    state = log_edit(state, author, pos, 0, len)
    state = record_op(state, actor, pos, "", deleted, src, snap?)
    state = %{state | goal_col: nil, last_insert_end: nil, insert_run: 0, undo_run: false}
    broadcast(state, pos, "", len, src)
    state
  end

  # trim lazily at 2x the cap: amortizes the O(limit) Enum.take so a burst of
  # keystrokes doesn't rebuild a 500-cons list on every edit
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

  defp resolve_actor(nil, :process),
    do: local_actor("process:local", "process", "process", :process)

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

  # Byte spans become line rows: each span is cut at the newlines it crosses,
  # and the pieces are summed per line and per actor. A line the agent only
  # renamed one word in still names the human who wrote the rest, with the
  # byte counts that say who owns most of it.
  defp line_rows(_text, [], _origins), do: []

  defp line_rows(text, spans, origins) do
    starts = line_start_index(text)
    size = Kernel.byte_size(text)

    spans
    |> Enum.flat_map(fn {s, e, id} ->
      span_line_bytes(starts, size, s, e, label_for(origins, id))
    end)
    |> Enum.reduce(%{}, fn {line, author, bytes}, acc ->
      Map.update(acc, {line, author}, bytes, &(&1 + bytes))
    end)
    |> Enum.map(fn {{line, author}, bytes} -> {line, author, bytes} end)
    |> Enum.sort_by(fn {line, author, bytes} -> {line, -bytes, author} end)
  end

  defp label_for(origins, id) do
    case origins[id] do
      %{actor: actor} -> actor_label(actor) || "unknown"
      _ -> "unknown"
    end
  end

  defp line_start_index(text),
    do: List.to_tuple([0 | Enum.map(:binary.matches(text, "\n"), fn {at, _} -> at + 1 end)])

  defp span_line_bytes(starts, size, s, e, author) do
    first = line_at_pos(starts, s)
    last = line_at_pos(starts, max(e - 1, s))

    for line <- first..last do
      from = max(s, elem(starts, line - 1))
      to = min(e, line_end(starts, size, line))
      {line, author, max(to - from, 0)}
    end
    |> Enum.reject(fn {_, _, bytes} -> bytes == 0 end)
  end

  defp line_end(starts, size, line) do
    if line < tuple_size(starts), do: elem(starts, line) - 1, else: size
  end

  # 1-based line for a byte offset, by binary search over the line starts
  defp line_at_pos(starts, pos), do: line_at_pos(starts, pos, 0, tuple_size(starts) - 1)

  defp line_at_pos(_starts, _pos, low, high) when low >= high, do: low + 1

  defp line_at_pos(starts, pos, low, high) do
    mid = div(low + high + 1, 2)

    if elem(starts, mid) <= pos,
      do: line_at_pos(starts, pos, mid, high),
      else: line_at_pos(starts, pos, low, mid - 1)
  end

  # The fold keeps one span per changeset. Two runs by one actor stay apart
  # there, because they are different work; the label view merges them,
  # because they read the same.

  # An origin outlives its bytes only until the next checkpoint. Undo used to
  # restore an old span wholesale, so the snapshot stack held a claim on its
  # origin. It no longer does: an undo stamps what it restores with the actor
  # that asked for it, so only the live spans keep their origins.
  defp prune_origins(state) do
    live =
      state.authors
      |> Enum.map(fn {_, _, id} -> id end)
      |> MapSet.new()

    %{state | origins: Map.take(state.origins, MapSet.to_list(live))}
  end

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

  # One changeset holds one actor's uninterrupted run of edits, and its id is
  # the id of the revision the store records. Opening it is the only place
  # that decides "same work or new work", so the span the fold stamps and the
  # revision the store writes can never disagree. An edit by anyone else, or
  # in another group, closes the open one first.
  defp open_changeset(state, actor, src) do
    group = buffer_group(state)

    if continues?(state, actor, group, src) do
      {state.changeset_id, state}
    else
      state = flush_provenance(state)
      # Before the actor's first operation reaches the document, because an
      # undo manager records only what happens after it exists. This runs on an
      # actor change, not per keystroke.
      state = ensure_undo_actor(state, actor)
      id = new_changeset_id()

      {id,
       %{
         state
         | changeset_id: id,
           pending_actor: actor,
           pending_group: group,
           origins: Map.put(state.origins, id, origin(actor))
       }}
    end
  end

  defp continues?(%{changeset_id: nil}, _actor, _group, _src), do: false

  defp continues?(state, actor, group, src) do
    batchable?(src) and state.pending_actor != nil and
      state.pending_actor.id == actor.id and state.pending_group == group
  end

  # What a span's id resolves to. The revision row holds the same actor, so
  # this is a cache that keeps `authors/1` out of SQLite, and the only copy
  # for a buffer whose recording is off.
  defp origin(actor), do: %{actor: actor, at: now_ms()}

  defp now_ms, do: System.system_time(:millisecond)

  # `author: :none` (desktop restore) adjusts the spans and stamps nothing.
  defp stamp_id(actor, changeset), do: if(Map.get(actor, :stamp, true), do: changeset, else: nil)

  defp record_op(%{provenance: nil} = state, _actor, _pos, _inserted, _deleted, _src, _whole?),
    do: state

  defp record_op(
         %{provenance: %{enabled: false} = provenance} = state,
         _actor,
         _pos,
         _inserted,
         _deleted,
         _src,
         _whole?
       ) do
    %{state | provenance: %{provenance | gap: true}}
  end

  defp record_op(state, actor, pos, inserted, deleted, src, whole?) do
    op = %{pos: pos, inserted: inserted, deleted: deleted}

    state = %{
      state
      | pending_ops: [op | state.pending_ops],
        pending_actor: actor,
        pending_group: buffer_group(state)
    }

    cond do
      # An atomic edit is durable before its caller hears that it worked. An
      # agent writes a whole hunk at a time, so the commit and the append are
      # rare and the round trip hides inside the tool call that asked for it.
      # An atomic edit is durable before its caller hears that it worked. Only
      # when it is a whole step: a replacement is a delete and an insert, and
      # closing between them would make them two changes and two undo steps.
      not batchable?(src) and whole? -> settle(state)
      not batchable?(src) -> flush_provenance(state)
      length(state.pending_ops) >= @provenance_batch_limit -> settle(state)
      true -> state
    end
  end

  # Close the open change and put it on disk.
  defp settle(state),
    do: state |> flush_provenance() |> close_undo_step() |> persist_history()

  # groups.scm owns the policy; the buffer-local is the mechanism, and this
  # reads it without asking Scheme, because a mutation cannot call back in.
  # groups.scm owns the policy; the buffer-local is the mechanism, and this
  # reads it without asking Scheme, because a mutation cannot call back in.
  #
  # A chat holds one `group-id`. A work buffer holds a `group-ids` list, and
  # `buffer-group` in groups.scm prefers whichever of them the frame is
  # currently showing. A record must not depend on which frame someone was
  # looking at, so the first id is the answer here.
  #
  # `group` is the local both of those replaced. `buffer-add-group!` sets it to
  # false on every join, so a buffer that still carries a string there has not
  # been touched since the migration.
  defp buffer_group(state) do
    case state.locals do
      %{"group-id" => id} when is_binary(id) -> id
      %{"group-ids" => [id | _]} when is_binary(id) -> id
      %{"group" => name} when is_binary(name) -> name
      _ -> nil
    end
  end

  # Only keyboard typing batches. Everything else arrives whole.
  defp batchable?(:user), do: true
  defp batchable?(_), do: false

  # The pending changeset becomes one revision: N operations, one hash, one
  # transaction. Called at every checkpoint boundary, on an actor change, and
  # before anything reads the durable history.
  defp flush_provenance(%{pending_ops: []} = state), do: %{state | changeset_id: nil}

  defp flush_provenance(%{provenance: nil} = state),
    do: %{state | pending_ops: [], pending_actor: nil, pending_group: nil, changeset_id: nil}

  # The history itself is a change in the weave, written by commit_history and
  # persisted by the log. Nothing is recorded twice, so this only closes the
  # pending batch and leaves the store its cell, its actors and its policy.
  defp flush_provenance(state) do
    %{state | pending_ops: [], pending_actor: nil, pending_group: nil, changeset_id: nil}
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

    narrow_range =
      case state.narrow_range do
        {s, e} ->
          s = fs.(s)
          e = fe.(e)
          if s < e, do: {s, e}, else: nil

        nil ->
          nil
      end

    %{state | overlays: overlays, hidden: hidden, narrow_range: narrow_range}
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
    # The row goes out BEFORE the event that announces it. A subscriber
    # wakes on this message and reads the row without asking us, so a row
    # written after the send would let a client paint one edit behind and
    # then sit there: no further event would arrive to correct it. The
    # callback wrapper publishes again on the way out, which is one more
    # small write and the reason a caller still reads its own last write.
    BufferView.put(view(state))

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
    col = goal || String.length(binary_part(text, bol, pos - bol))

    if eol >= Kernel.byte_size(text) do
      pos
    else
      {nbol, neol} = Text.line_bounds(text, eol + 1)
      column_pos(text, nbol, neol, col)
    end
  end

  defp apply_motion(:prev_line, text, pos, goal) do
    {bol, _eol} = Text.line_bounds(text, pos)
    col = goal || String.length(binary_part(text, bol, pos - bol))

    if bol == 0 do
      pos
    else
      {pbol, peol} = Text.line_bounds(text, bol - 1)
      column_pos(text, pbol, peol, col)
    end
  end

  # the byte where grapheme column COL of the line BOL..EOL begins, or the
  # end of the line when the line is shorter
  defp column_pos(text, bol, eol, col) do
    line = binary_part(text, bol, eol - bol)

    line
    |> String.graphemes()
    |> Enum.take(col)
    |> Enum.reduce(bol, fn g, acc -> acc + Kernel.byte_size(g) end)
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
