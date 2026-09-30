defmodule Compos.Core.Events.Log do
  @moduledoc """
  The durable half of `Compos.Core.Events`: an append-only log of events
  and the saved position of each subscriber, in one SQLite file.

  An event is a sequence number, a topic ("mail:svs", "whatsapp:JID",
  "chat:..."), a kind, data and a time in seconds. Kind and data are
  Scheme values (strings, numbers, `{:sym, name}`, lists), kept as terms,
  so what Scheme publishes reads back the same.

  A write is on disk before `append/3` returns. The log keeps
  `:events_retain_days` of events (default 365) and drops older ones at
  start and once a day. Positions are never dropped: a subscriber further
  behind than the retention simply starts at the oldest event kept.

  The log does not run subscribers. After a burst of appends it tells
  Scheme once (`events-arrived!`), and Scheme reads what it has not yet
  delivered. Scheme owns subscribers, views and policy
  (`scheme/packages/events.scm`).

  Workflows (`Compos.Core.Workflow`) consume the log in Elixir. Each append
  reaches them as a message, `{:event_appended, seq, topic}`, and a
  workflow's batch lands through `commit/5`: its events, its once keys and
  its new position in one transaction, fenced on the position it read
  from. The `once` table keeps what `once!` recorded, for as long as the
  file lives.
  """

  use GenServer

  alias Compos.Core.Session
  alias Exqlite.Sqlite3

  @notify_ms 50
  @notify_fn "events-arrived!"
  @prune_ms 24 * 60 * 60 * 1000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Append one event. Answer its seq."
  def append(topic, kind, data, at \\ nil) when is_binary(topic),
    do: GenServer.call(__MODULE__, {:append, topic, kind, data, at})

  @doc "At most LIMIT events after SEQ whose topic PATTERN matches, oldest first. A nil PATTERN matches every topic."
  def read(after_seq, pattern, limit),
    do: GenServer.call(__MODULE__, {:read, after_seq || 0, pattern, limit})

  @doc "At most LIMIT events whose topic PATTERN matches, newest first."
  def newest(pattern, limit), do: GenServer.call(__MODULE__, {:newest, pattern, limit})

  @doc "The seq of the newest event, or 0."
  def seq, do: GenServer.call(__MODULE__, :seq)

  @doc "At most LIMIT events after SEQ whose topic matches any of PATTERNS, oldest first."
  def read_any(after_seq, patterns, limit) when is_list(patterns),
    do: GenServer.call(__MODULE__, {:read_any, after_seq || 0, patterns, limit})

  @doc """
  Commit one workflow batch in a single transaction: EVENTS ({topic, kind,
  data}) appended, ONCES ({key, value}) recorded, and the position NAME
  moved from EXPECTED to UPTO. Nothing is written unless NAME still stands
  at EXPECTED: a rewind, or a second runner, between the read and the
  commit makes the batch a no-op. So a batch commits exactly once. Answer
  `{:ok, seqs}` or `{:error, :moved}`.
  """
  def commit(name, expected, upto, events, onces),
    do: GenServer.call(__MODULE__, {:commit, name, expected, upto, events, onces})

  @doc "The value once! recorded under KEY: `{:ok, value}`, or `:none`."
  def once(key), do: GenServer.call(__MODULE__, {:once, key})

  @doc "Record VALUE under KEY unless a value is there already. Answer the value that stands."
  def put_once(key, value), do: GenServer.call(__MODULE__, {:put_once, key, value})

  def position(name), do: GenServer.call(__MODULE__, {:position, name})
  def set_position(name, seq), do: GenServer.call(__MODULE__, {:set_position, name, seq})
  def forget(name), do: GenServer.call(__MODULE__, {:forget, name})

  @doc "Load EVENTS (maps with seq, topic, kind, data, at) and POSITIONS ({name, seq}) into an empty log. Answer how many events went in."
  def import(events, positions), do: GenServer.call(__MODULE__, {:import, events, positions}, 60_000)

  def path, do: Path.join(Compos.Core.home(), "events.db")

  # --- server ----------------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, path())
    File.mkdir_p!(Path.dirname(path))
    {:ok, db} = Sqlite3.open(path)

    :ok =
      Sqlite3.execute(db, """
      PRAGMA journal_mode = WAL;
      PRAGMA synchronous = NORMAL;
      CREATE TABLE IF NOT EXISTS events (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        topic TEXT NOT NULL,
        kind BLOB,
        data BLOB,
        at INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS events_topic ON events (topic, seq);
      CREATE INDEX IF NOT EXISTS events_at ON events (at);
      CREATE TABLE IF NOT EXISTS positions (
        name BLOB PRIMARY KEY,
        seq INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS once (
        key BLOB PRIMARY KEY,
        value BLOB,
        at INTEGER NOT NULL);
      """)

    state = %{db: db, notify: nil}
    prune(state)
    Process.send_after(self(), :prune, @prune_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:append, topic, kind, data, at}, _from, state) do
    seq = insert_event(state, topic, kind, data, at || System.os_time(:second))
    announce([{seq, topic}])
    {:reply, seq, arm(state)}
  end

  def handle_call({:read_any, after_seq, patterns, limit}, _from, state) do
    {where, args} = topics_where(patterns)

    rows =
      all(
        state,
        "SELECT seq, topic, kind, data, at FROM events WHERE seq > ?1" <>
          where <> " ORDER BY seq LIMIT ?2",
        [after_seq, limit] ++ args
      )

    {:reply, Enum.map(rows, &event/1), state}
  end

  def handle_call({:commit, name, expected, upto, events, onces}, _from, state) do
    ensure_once(state)

    if position_of(state, name) != expected do
      {:reply, {:error, :moved}, state}
    else
      :ok = Sqlite3.execute(state.db, "BEGIN IMMEDIATE")

      try do
        at = System.os_time(:second)
        appended = for {topic, kind, data} <- events, do: {insert_event(state, topic, kind, data, at), topic}

        for {key, value} <- onces do
          run(state, "INSERT OR IGNORE INTO once (key, value, at) VALUES (?1, ?2, ?3)", [
            key(key),
            {:blob, :erlang.term_to_binary(value)},
            at
          ])
        end

        put_position(state, name, upto)
        :ok = Sqlite3.execute(state.db, "COMMIT")
        announce(appended)
        {:reply, {:ok, Enum.map(appended, &elem(&1, 0))}, arm(state)}
      rescue
        e ->
          Sqlite3.execute(state.db, "ROLLBACK")
          {:reply, {:error, Exception.message(e)}, state}
      end
    end
  end

  def handle_call({:once, key}, _from, state) do
    ensure_once(state)

    case all(state, "SELECT value FROM once WHERE key = ?1", [key(key)]) do
      [[value]] -> {:reply, {:ok, :erlang.binary_to_term(value)}, state}
      [] -> {:reply, :none, state}
    end
  end

  def handle_call({:put_once, key, value}, _from, state) do
    ensure_once(state)

    run(state, "INSERT OR IGNORE INTO once (key, value, at) VALUES (?1, ?2, ?3)", [
      key(key),
      {:blob, :erlang.term_to_binary(value)},
      System.os_time(:second)
    ])

    [[stands]] = all(state, "SELECT value FROM once WHERE key = ?1", [key(key)])
    {:reply, :erlang.binary_to_term(stands), state}
  end

  def handle_call({:read, after_seq, pattern, limit}, _from, state) do
    {where, args} = topic_where(pattern)

    rows =
      all(
        state,
        "SELECT seq, topic, kind, data, at FROM events WHERE seq > ?1" <>
          where <> " ORDER BY seq LIMIT ?2",
        [after_seq, limit] ++ args
      )

    {:reply, Enum.map(rows, &event/1), state}
  end

  def handle_call({:newest, pattern, limit}, _from, state) do
    {where, args} = topic_where(pattern)

    rows =
      all(
        state,
        "SELECT seq, topic, kind, data, at FROM events WHERE seq > ?1" <>
          where <> " ORDER BY seq DESC LIMIT ?2",
        [0, limit] ++ args
      )

    {:reply, Enum.map(rows, &event/1), state}
  end

  def handle_call(:seq, _from, state) do
    [[seq]] = all(state, "SELECT coalesce(max(seq), 0) FROM events", [])
    {:reply, seq, state}
  end

  def handle_call({:position, name}, _from, state) do
    case all(state, "SELECT seq FROM positions WHERE name = ?1", [key(name)]) do
      [[seq]] -> {:reply, seq, state}
      [] -> {:reply, nil, state}
    end
  end

  def handle_call({:set_position, name, seq}, _from, state) do
    run(
      state,
      "INSERT INTO positions (name, seq) VALUES (?1, ?2) ON CONFLICT (name) DO UPDATE SET seq = ?2",
      [key(name), seq]
    )

    {:reply, :ok, state}
  end

  def handle_call({:forget, name}, _from, state) do
    run(state, "DELETE FROM positions WHERE name = ?1", [key(name)])
    {:reply, :ok, state}
  end

  def handle_call({:import, events, positions}, _from, state) do
    case all(state, "SELECT count(*) FROM events", []) do
      [[0]] ->
        :ok = Sqlite3.execute(state.db, "BEGIN")

        for e <- events do
          run(state, "INSERT INTO events (seq, topic, kind, data, at) VALUES (?1, ?2, ?3, ?4, ?5)", [
            e.seq,
            e.topic,
            {:blob, :erlang.term_to_binary(e.kind)},
            {:blob, :erlang.term_to_binary(e.data)},
            e.at
          ])
        end

        for {name, seq} <- positions do
          run(state, "INSERT OR REPLACE INTO positions (name, seq) VALUES (?1, ?2)", [key(name), seq])
        end

        :ok = Sqlite3.execute(state.db, "COMMIT")
        {:reply, length(events), state}

      _ ->
        {:reply, 0, state}
    end
  end

  @impl true
  def handle_info(:notify, state) do
    if Session.ready?() do
      Task.start(fn ->
        try do
          Session.call_named(@notify_fn, [], nil, 30_000)
        catch
          _, _ -> :ok
        end
      end)
    end

    {:noreply, %{state | notify: nil}}
  end

  def handle_info(:prune, state) do
    prune(state)
    Process.send_after(self(), :prune, @prune_ms)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state), do: Sqlite3.close(state.db)

  defp insert_event(state, topic, kind, data, at) do
    run(state, "INSERT INTO events (topic, kind, data, at) VALUES (?1, ?2, ?3, ?4)", [
      topic,
      {:blob, :erlang.term_to_binary(kind)},
      {:blob, :erlang.term_to_binary(data)},
      at
    ])

    {:ok, seq} = Sqlite3.last_insert_rowid(state.db)
    seq
  end

  # The processes that consume the log in Elixir (Compos.Core.Workflow)
  # hear of each event at once, by message: {:event_appended, seq, topic}.
  # Scheme still hears of a burst through events-arrived!.
  defp announce([]), do: :ok

  defp announce(appended) do
    Registry.dispatch(Compos.Core.EventRegistry, :event_log, fn entries ->
      for {pid, _} <- entries, {seq, topic} <- appended, do: send(pid, {:event_appended, seq, topic})
    end)
  end

  defp position_of(state, name) do
    case all(state, "SELECT seq FROM positions WHERE name = ?1", [key(name)]) do
      [[seq]] -> seq
      [] -> nil
    end
  end

  defp put_position(state, name, seq) do
    run(
      state,
      "INSERT INTO positions (name, seq) VALUES (?1, ?2) ON CONFLICT (name) DO UPDATE SET seq = ?2",
      [key(name), seq]
    )
  end

  # a log opened before the once table existed gets it on first use
  defp ensure_once(state) do
    unless Process.get(:events_once_table) do
      :ok =
        Sqlite3.execute(
          state.db,
          "CREATE TABLE IF NOT EXISTS once (key BLOB PRIMARY KEY, value BLOB, at INTEGER NOT NULL)"
        )

      Process.put(:events_once_table, true)
    end
  end

  # any of PATTERNS: each a prefix ("demo:*") or one topic; the arguments
  # follow ?1 and ?2, which the query keeps for the seq and the limit
  defp topics_where([]), do: {" AND 0", []}

  defp topics_where(patterns) do
    {clauses, args, _} =
      Enum.reduce(patterns, {[], [], 3}, fn pattern, {cs, as, n} ->
        if String.ends_with?(pattern, "*") do
          prefix = String.trim_trailing(pattern, "*")
          c = "substr(topic, 1, ?#{n}) = ?#{n + 1}"
          {[c | cs], as ++ [String.length(prefix), prefix], n + 2}
        else
          {["topic = ?#{n}" | cs], as ++ [pattern], n + 1}
        end
      end)

    {" AND (" <> Enum.join(Enum.reverse(clauses), " OR ") <> ")", args}
  end

  # one notice per burst: Scheme reads everything new when it runs
  defp arm(%{notify: nil} = state),
    do: %{state | notify: Process.send_after(self(), :notify, @notify_ms)}

  defp arm(state), do: state

  defp prune(state) do
    days = Application.get_env(:compos_core, :events_retain_days, 365)
    run(state, "DELETE FROM events WHERE at < ?1", [System.os_time(:second) - days * 86_400])
  end

  # "chat:*" is a prefix, anything else one topic, nil every topic
  defp topic_where(nil), do: {"", []}
  defp topic_where(false), do: {"", []}

  defp topic_where(pattern) when is_binary(pattern) do
    if String.ends_with?(pattern, "*") do
      prefix = String.trim_trailing(pattern, "*")
      {" AND substr(topic, 1, ?3) = ?4", [String.length(prefix), prefix]}
    else
      {" AND topic = ?3", [pattern]}
    end
  end

  defp event([seq, topic, kind, data, at]) do
    %{
      seq: seq,
      topic: topic,
      kind: :erlang.binary_to_term(kind),
      data: :erlang.binary_to_term(data),
      at: at
    }
  end

  defp key(name), do: {:blob, :erlang.term_to_binary(name)}

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
