defmodule Compos.Core.MetaDb do
  @moduledoc """
  Buffer metadata as SQLite rows, `meta.db` in the home: what a listing
  filters, searches and annotates, read with one query, never by asking
  each buffer.

  Core writes the facts. A buffer reports a change from the one place it
  publishes its row (`Events.broadcast_meta/2`), and a dropped row reports
  itself from `BufferView.forget/1`. This process reads each named row
  again from `BufferView`: a row there is written, a row gone is deleted.
  A burst is one transaction, and nothing waits on a timer. A start
  rebuilds every row from `BufferView`, so the file is derived: delete it
  and it comes back.

  Scheme writes what only Scheme knows: a buffer's icon, project and
  workspace (`put_labels/1`, when the buffer changes), and each group's
  label, face and note (`put_groups/1`). A rebuild keeps them.
  """

  use GenServer

  require Logger

  alias Compos.Core.{BufferView, Events}
  alias Exqlite.Sqlite3

  # what a buffer's annotation reads; `where/1` filters it
  @annotation_select "SELECT b.name, b.icon, b.mode, b.group_id, g.label, g.face, g.note, " <>
                       "b.project, b.workspace, b.path FROM buffers b " <>
                       "LEFT JOIN groups g ON g.id = b.group_id"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def path, do: Path.join(Compos.Core.home(), "meta.db")

  @doc """
  Start it under the core supervisor when it is not running: a session
  that loaded this module after its start has no MetaDb yet.
  """
  def ensure_started do
    unless Process.whereis(__MODULE__) do
      Supervisor.start_child(Compos.Core.Supervisor, __MODULE__)
    end

    :ok
  end

  @doc "Scheme's labels for some buffers: `[[name, icon, project, workspace]]`."
  def put_labels(rows), do: GenServer.cast(__MODULE__, {:labels, rows})

  @doc "Every group: `[[id, label, face, note]]`. An unchanged list writes nothing."
  def put_groups(groups), do: GenServer.cast(__MODULE__, {:groups, groups})

  @doc """
  NAME was used at MS, system milliseconds: the recent order. Uses in the
  same millisecond keep the order they came in.
  """
  def note_used(name, ms), do: GenServer.cast(__MODULE__, {:used, name, ms})

  @doc "NAME goes to the end of the recent order, below the buffers never used."
  def bury(name), do: GenServer.cast(__MODULE__, {:bury, name})

  @doc """
  The finished annotation of each of NAMES, in order, as `[name, hint,
  face]`: the columns icon, mode, group, project, workspace and path (a
  chat with no path shows its group's note), padded to the widest of each,
  the way `marginalia-join` writes them. HINT is nil for a buffer with no
  labels yet. PINNED is the group the frame pins, which PIN-ICON follows.
  """
  def annotations(names, pinned, pin_icon),
    do: GenServer.call(__MODULE__, {:annotations, names, pinned, pin_icon})

  @doc """
  `annotations/3` for the rows OPTS selects (`query/1`'s filters and
  sort), in the database's order: a buffer prompt's whole candidate list
  from one query.
  """
  def candidates(opts, pinned, pin_icon),
    do: GenServer.call(__MODULE__, {:candidates, opts, pinned, pin_icon})

  @doc """
  `{TOTAL, ROWS}` for OPTS, a map with string keys:

    * `names`, `modes`, `groups` - only these
    * `exclude-names` - leave these out
    * `match` - space-separated terms; each is a case-blind substring of
      the name, title, path, mode, group label, project or workspace
    * `hidden`, `context-only` - keep those buffers too
    * `sort` - `recent` (default: last used first) or `name`
    * `offset`, `limit` - the page

  The filter, the sort and the page are SQL, all of them.
    * `fields` - what each row carries after its name: path mode title
      group group-label modified read-only icon project workspace
  """
  def query(opts), do: GenServer.call(__MODULE__, {:query, opts})

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, path())
    File.mkdir_p!(Path.dirname(path))
    {:ok, db} = Sqlite3.open(path)

    :ok =
      Sqlite3.execute(db, """
      PRAGMA journal_mode = WAL;
      PRAGMA synchronous = NORMAL;
      CREATE TABLE IF NOT EXISTS buffers (
        name TEXT PRIMARY KEY,
        path TEXT, mode TEXT, title TEXT, group_id TEXT,
        modified INTEGER, read_only INTEGER, context_only INTEGER,
        icon TEXT, project TEXT, workspace TEXT, used INTEGER);
      CREATE INDEX IF NOT EXISTS buffers_mode ON buffers (mode);
      CREATE INDEX IF NOT EXISTS buffers_group ON buffers (group_id);
      CREATE INDEX IF NOT EXISTS buffers_path ON buffers (path);
      CREATE TABLE IF NOT EXISTS groups (
        id TEXT PRIMARY KEY, label TEXT, face TEXT, note TEXT);
      """)

    # a file from before the recent order gets the column once
    _ = Sqlite3.execute(db, "ALTER TABLE buffers ADD COLUMN used INTEGER")
    :ok = Sqlite3.execute(db, "CREATE INDEX IF NOT EXISTS buffers_used ON buffers (used)")

    Events.subscribe_meta()
    {:ok, %{db: db, groups: nil, used: 0}, {:continue, :rebuild}}
  end

  @impl true
  def handle_continue(:rebuild, state) do
    names = BufferView.table() |> :ets.select([{{:"$1", :_}, [{:is_binary, :"$1"}], [:"$1"]}])
    known = state |> all("SELECT name FROM buffers", []) |> Enum.map(&hd/1)
    transaction(state, fn -> Enum.each(Enum.uniq(names ++ known), &sync(state, &1)) end)
    seed_used(state)
    [[top]] = all(state, "SELECT coalesce(max(used), 0) FROM buffers", [])
    {:noreply, %{state | used: top}}
  rescue
    ArgumentError -> {:noreply, state}
  end

  @impl true
  def handle_cast({:labels, rows}, state) do
    transaction(state, fn ->
      for [name, icon, project, workspace] <- rows do
        if absent?(state, name), do: sync(state, name)

        run(state, "UPDATE buffers SET icon = ?2, project = ?3, workspace = ?4 WHERE name = ?1",
          [name, str(icon), str(project), str(workspace)])
      end
    end)

    {:noreply, state}
  end

  def handle_cast({:used, name, ms}, state) do
    used = max(ms, state.used + 1)
    if absent?(state, name), do: sync(state, name)
    run(state, "UPDATE buffers SET used = ?2 WHERE name = ?1", [name, used])
    {:noreply, %{state | used: used}}
  end

  def handle_cast({:bury, name}, state) do
    run(state, "UPDATE buffers SET used = (SELECT min(0, coalesce(min(used), 0)) - 1 FROM buffers) WHERE name = ?1", [name])
    {:noreply, state}
  end

  def handle_cast({:groups, groups}, %{groups: groups} = state), do: {:noreply, state}

  def handle_cast({:groups, groups}, state) do
    transaction(state, fn ->
      run(state, "DELETE FROM groups", [])

      for [id, label, face, note] <- groups, is_binary(id) do
        run(state, "INSERT OR REPLACE INTO groups (id, label, face, note) VALUES (?1, ?2, ?3, ?4)",
          [id, str(label), str(face), str(note)])
      end
    end)

    {:noreply, %{state | groups: groups}}
  end

  @impl true
  def handle_call({:annotations, names, pinned, pin_icon}, _from, state) do
    rows = annotation_rows(state)
    missing = Enum.reject(names, &Map.has_key?(rows, &1))

    rows =
      if missing == [] do
        rows
      else
        transaction(state, fn -> Enum.each(missing, &sync(state, &1)) end)
        annotation_rows(state)
      end

    {:reply, render(Enum.map(names, &{&1, rows[&1]}), pinned, pin_icon), state}
  end

  def handle_call({:candidates, opts, pinned, pin_icon}, _from, state) do
    {where, args} = where(opts)
    rows = all(state, @annotation_select <> where <> order(opts["sort"]), args)
    {:reply, render(Enum.map(rows, fn [n | r] -> {n, r} end), pinned, pin_icon), state}
  end

  def handle_call({:query, opts}, _from, state) do
    {where, args} = where(opts)
    from = " FROM buffers b LEFT JOIN groups g ON g.id = b.group_id" <> where
    [[total]] = all(state, "SELECT count(*)" <> from, args)

    sql =
      "SELECT b.name, b.path, b.mode, b.title, b.group_id, g.label, b.modified, b.read_only, " <>
        "b.icon, b.project, b.workspace" <> from <> order(opts["sort"]) <> " LIMIT ? OFFSET ?"

    rows = all(state, sql, args ++ [opts["limit"] || -1, opts["offset"] || 0])
    fields = List.wrap(opts["fields"] || [])
    {:reply, {total, Enum.map(rows, &row_out(&1, fields))}, state}
  end

  @impl true
  def handle_info({:buffer_meta, name, diff}, state) do
    events = drain([{name, diff}])

    transaction(state, fn ->
      # a rename moves the old row, so the buffer keeps its place in the
      # recent order; a row for the new name already there wins
      for {n, d} <- events, {was, now} <- renames(n, d) do
        run(state, "UPDATE OR IGNORE buffers SET name = ?2 WHERE name = ?1", [was, now])
      end

      events |> Enum.flat_map(fn {n, d} -> names_of(n, d) end) |> Enum.uniq() |> Enum.each(&sync(state, &1))
    end)

    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: Sqlite3.close(state.db)

  # everything already queued joins the burst, oldest first
  defp drain(acc) do
    receive do
      {:buffer_meta, name, diff} -> drain([{name, diff} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # a rename names both rows


  defp names_of(name, %{was: was}) when is_binary(was), do: [name, was]
  defp names_of(name, _), do: [name]

  defp renames(name, %{was: was}) when is_binary(was), do: [{was, name}]
  defp renames(_, _), do: []

  # The row BufferView holds now is the truth: written when it is there,
  # deleted when it is gone. The labels stay with a written row.
  defp sync(state, name) do
    case facts(name) do
      {:ok, facts} ->
        run(state, """
        INSERT INTO buffers (name, path, mode, title, group_id, modified, read_only, context_only)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        ON CONFLICT (name) DO UPDATE SET path = excluded.path, mode = excluded.mode,
          title = excluded.title, group_id = excluded.group_id, modified = excluded.modified,
          read_only = excluded.read_only, context_only = excluded.context_only
        """, facts)

      :error ->
        run(state, "DELETE FROM buffers WHERE name = ?1", [name])
    end
  end

  defp facts(name) do
    keys = ~w(mode-name group-id list-title chat-title context-only)

    case BufferView.project(name, [:path, :modified, :read_only], keys) do
      {:ok, [path, modified, ro, mode, gid, title, chat_title, ctx]} ->
        {:ok,
         [name, str(path), str(mode), title_of(name, title, chat_title), str(gid),
          flag(modified), flag(ro), flag(ctx)]}

      _ ->
        :error
    end
  end

  # a list names a row by its `list-title`, a chat by its `chat-title`
  defp title_of(name, title, chat_title),
    do: Enum.find([title, chat_title], name, &(is_binary(&1) and &1 != ""))

  defp absent?(state, name), do: all(state, "SELECT 1 FROM buffers WHERE name = ?1", [name]) == []

  defp annotation_rows(state) do
    state |> all(@annotation_select, []) |> Map.new(fn [n | r] -> {n, r} end)
  end

  # PAIRS is `[{name, row | nil}]` in the order to answer; a row with no
  # labels yet answers a nil hint
  defp render(pairs, pinned, pin_icon) do
    cols =
      Enum.map(pairs, fn
        {n, [icon | _] = r} when is_binary(icon) -> {n, columns(r, pinned, pin_icon), face(r)}
        {n, _} -> {n, nil, nil}
      end)

    widths = widths(for {_, c, _} <- cols, c, do: c)

    Enum.map(cols, fn
      {n, nil, _} -> [n, nil, nil]
      {n, c, face} -> [n, join(trim(c), widths), face]
    end)
  end

  # The saved history is the editor's recent list (`Editor` starts its
  # ring from it, and every use touches both), so a start takes the order
  # from it: newest just below now, so every use from here on ranks above.
  # A buffer it does not name has no use, and sorts by name below them all.
  defp seed_used(state) do
    # the editor's own list when it runs; at boot it has not started, and
    # the history is what it will start from
    history =
      if Process.whereis(Compos.Core.Editor),
        do: Compos.Core.Editor.buffer_mru(),
        else: Compos.Core.BufferStore.history()

    now = System.system_time(:millisecond)

    transaction(state, fn ->
      run(state, "UPDATE buffers SET used = NULL", [])

      history
      |> Enum.with_index()
      |> Enum.each(fn {name, i} ->
        run(state, "UPDATE buffers SET used = ?2 WHERE name = ?1", [name, now - 1 - i])
      end)
    end)
  catch
    :exit, _ -> :ok
  end

  # the buffer annotator's columns (`marginalia! 'buffer` in editor.scm)
  defp columns([icon, mode, gid, label, _face, note, project, workspace, path], pinned, pin_icon) do
    group =
      cond do
        not is_binary(gid) or not is_binary(label) -> "ungrouped"
        gid == pinned and label != "" -> label <> " " <> pin_icon
        true -> label
      end

    last =
      cond do
        is_binary(path) -> path
        mode == "chat-mode" and is_binary(gid) and is_binary(note) -> note
        true -> ""
      end

    [icon, mode || "Fundamental", group, project || "", workspace || "", last]
  end

  # a buffer in a group wears the group's colour; a group gone, none
  defp face([_icon, _mode, gid, label, face | _]) when is_binary(gid) and is_binary(label),
    do: face || "accent"

  defp face(_), do: nil

  defp widths(rows) do
    Enum.reduce(rows, [], fn r, ws ->
      lens = Enum.map(r, &cps/1)
      n = max(length(lens), length(ws))

      for i <- 0..(n - 1)//1,
          do: max(Enum.at(lens, i, 0), Enum.at(ws, i, 0))
    end)
  end

  defp trim(fields), do: fields |> Enum.reverse() |> Enum.drop_while(&(&1 == "")) |> Enum.reverse()

  defp join(fields, widths) do
    last = length(fields) - 1

    fields
    |> Enum.with_index()
    |> Enum.map(fn
      {f, ^last} -> f
      {f, i} -> f <> String.duplicate(" ", max(Enum.at(widths, i, 0) - cps(f), 0))
    end)
    |> Enum.join("  ")
  end

  # Scheme counts a string in code points
  defp cps(s), do: length(String.to_charlist(s))

  defp where(opts) do
    {clauses, args} =
      [
        in_clause("b.name", opts["names"]),
        in_clause("b.mode", opts["modes"]),
        in_clause("b.group_id", opts["groups"]),
        in_clause("b.name", opts["exclude-names"], "NOT IN"),
        if(opts["hidden"] == true, do: nil, else: {"substr(b.name, 1, 1) <> ' '", []}),
        if(opts["context-only"] == true, do: nil, else: {"coalesce(b.context_only, 0) = 0", []})
        | match_clauses(opts["match"])
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce({[], []}, fn {c, a}, {cs, as} -> {[c | cs], as ++ a} end)

    case clauses do
      [] -> {"", args}
      cs -> {" WHERE " <> Enum.join(Enum.reverse(cs), " AND "), args}
    end
  end

  defp in_clause(col, v, op \\ "IN")
  defp in_clause(_col, v, _op) when v in [nil, false, []], do: nil

  defp in_clause(col, v, op) do
    vs = List.wrap(v)
    {col <> " " <> op <> " (" <> Enum.map_join(vs, ", ", fn _ -> "?" end) <> ")", vs}
  end

  @searched ~w(b.name b.title b.path b.mode g.label b.project b.workspace)

  defp match_clauses(q) when is_binary(q) do
    for term <- String.split(q, " ", trim: true) do
      like = "%" <> String.replace(term, ["\\", "%", "_"], &("\\" <> &1)) <> "%"
      c = Enum.map_join(@searched, " OR ", &(&1 <> " LIKE ? ESCAPE '\\'"))
      {"(" <> c <> ")", List.duplicate(like, length(@searched))}
    end
  end

  defp match_clauses(_), do: []

  defp order("name"), do: " ORDER BY lower(coalesce(b.title, b.name)), b.name"
  defp order(_recent), do: " ORDER BY coalesce(b.used, 0) DESC, b.name"

  @out ~w(name path mode title group group-label modified read-only icon project workspace)

  defp row_out([n | _] = r, fields) do
    by = Map.new(Enum.zip(@out, r))

    [n | Enum.map(fields, fn
       f when f in ["modified", "read-only"] -> by[f] == 1
       f -> by[f]
     end)]
  end

  defp str(v) when is_binary(v), do: v
  defp str(_), do: nil

  defp flag(v) when v in [nil, false], do: 0
  defp flag(_), do: 1

  defp transaction(state, f) do
    :ok = Sqlite3.execute(state.db, "BEGIN")

    try do
      f.()
      :ok = Sqlite3.execute(state.db, "COMMIT")
    rescue
      e ->
        Sqlite3.execute(state.db, "ROLLBACK")
        Logger.warning("meta-db: " <> Exception.message(e))
    end
  end

  defp run(state, sql, args) do
    {:ok, stmt} = Sqlite3.prepare(state.db, sql)

    try do
      :ok = Sqlite3.bind(stmt, args)
      :done = Sqlite3.step(state.db, stmt)
      :ok
    after
      Sqlite3.release(state.db, stmt)
    end
  end

  defp all(state, sql, args) do
    {:ok, stmt} = Sqlite3.prepare(state.db, sql)

    try do
      :ok = Sqlite3.bind(stmt, args)
      {:ok, rows} = Sqlite3.fetch_all(state.db, stmt)
      rows
    after
      Sqlite3.release(state.db, stmt)
    end
  end
end
