defmodule Aimax.Core.ProvenanceStore do
  @moduledoc """
  Durable revision and actor history for buffers.

  One GenServer owns one SQLite connection. Buffer processes remain the
  mutation authority. This store validates each expected head and records the
  accepted revision before the buffer reports success.
  """

  use GenServer

  alias Exqlite.Sqlite3

  @schema_version 1

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def path do
    Application.get_env(
      :aimax_core,
      :provenance_path,
      Path.join(Aimax.Core.home(), "provenance.sqlite3")
    )
  end

  def ensure_cell(buffer_id, text, actor, opts \\ []) do
    GenServer.call(__MODULE__, {:ensure_cell, buffer_id, text, actor, opts}, 30_000)
  end

  def status(buffer_id), do: GenServer.call(__MODULE__, {:status, buffer_id})
  def history(buffer_id), do: GenServer.call(__MODULE__, {:history, buffer_id})

  def record_change(buffer_id, expected_head, version, actor, pos, inserted, deleted, text) do
    GenServer.call(
      __MODULE__,
      {:record_change, buffer_id, expected_head, version, actor, pos, inserted, deleted, text},
      30_000
    )
  end

  def start_recording(buffer_id, text, actor, reason, policy_source) do
    GenServer.call(
      __MODULE__,
      {:start_recording, buffer_id, text, actor, reason, policy_source},
      30_000
    )
  end

  def stop_recording(buffer_id, actor, reason, policy_source) do
    GenServer.call(
      __MODULE__,
      {:stop_recording, buffer_id, actor, reason, policy_source},
      30_000
    )
  end

  def checkpoint(buffer_id, actor, reason) do
    GenServer.call(__MODULE__, {:checkpoint, buffer_id, actor, reason}, 30_000)
  end

  @impl true
  def init(nil) do
    database = path()
    if database != ":memory:", do: File.mkdir_p!(Path.dirname(database))

    {:ok, conn} = Sqlite3.open(database)
    :ok = Sqlite3.execute(conn, "PRAGMA journal_mode = WAL")
    :ok = Sqlite3.execute(conn, "PRAGMA synchronous = NORMAL")
    :ok = Sqlite3.execute(conn, "PRAGMA foreign_keys = ON")
    create_schema(conn)
    {:ok, conn}
  end

  @impl true
  def terminate(_reason, conn) do
    Sqlite3.close(conn)
  end

  @impl true
  def handle_call({:ensure_cell, buffer_id, text, actor, opts}, _from, conn) do
    status =
      case cell(conn, buffer_id) do
        nil ->
          create_root(
            conn,
            buffer_id,
            text,
            actor,
            Keyword.get(opts, :policy_source, "default"),
            Keyword.get(opts, :retention, "durable")
          )

        status ->
          status
      end

    {:reply, {:ok, status}, conn}
  end

  def handle_call({:status, buffer_id}, _from, conn) do
    {:reply, cell(conn, buffer_id), conn}
  end

  def handle_call({:history, buffer_id}, _from, conn) do
    rows =
      query(
        conn,
        """
        SELECT id, parent_id, buffer_version, kind, content_hash,
               actor, operation, snapshot, metadata, created_at
        FROM revisions WHERE buffer_id = ?1 ORDER BY seq
        """,
        [buffer_id]
      )

    history =
      Enum.map(rows, fn [
                          id,
                          parent,
                          version,
                          kind,
                          hash,
                          actor,
                          operation,
                          snapshot,
                          metadata,
                          at
                        ] ->
        %{
          id: id,
          parent_id: parent,
          buffer_version: version,
          kind: kind,
          content_hash: hash,
          actor: decode_term(actor),
          operation: decode_term(operation),
          snapshot: snapshot,
          metadata: decode_term(metadata),
          created_at: at
        }
      end)

    {:reply, history, conn}
  end

  def handle_call(
        {:record_change, buffer_id, expected_head, version, actor, pos, inserted, deleted, text},
        _from,
        conn
      ) do
    current = fetch_cell!(conn, buffer_id)

    reply =
      cond do
        not current.recording ->
          exec(conn, "UPDATE cells SET gap = 1, updated_at = ?2 WHERE buffer_id = ?1", [
            buffer_id,
            now()
          ])

          {:ok, %{current | gap: true}}

        current.head_id != expected_head ->
          proposal_id = revision_id()

          exec(
            conn,
            """
            INSERT INTO proposals
              (id, buffer_id, expected_head, actual_head, actor, operation, created_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            """,
            [
              proposal_id,
              buffer_id,
              expected_head,
              current.head_id,
              blob(actor),
              blob(%{version: version, pos: pos, inserted: inserted, deleted: deleted}),
              now()
            ]
          )

          {:error,
           {:stale_revision,
            %{
              expected_head: expected_head,
              actual_head: current.head_id,
              proposal_id: proposal_id
            }}}

        true ->
          new_id = revision_id()
          hash = content_hash(text)

          transact(conn, fn ->
            insert_revision(conn, %{
              id: new_id,
              buffer_id: buffer_id,
              parent_id: current.head_id,
              buffer_version: version,
              kind: "edit",
              content_hash: hash,
              actor: actor,
              operation: %{pos: pos, inserted: inserted, deleted: deleted},
              snapshot: nil,
              metadata: %{}
            })

            exec(
              conn,
              """
              UPDATE cells
              SET head_id = ?2, head_hash = ?3, gap = 0, updated_at = ?4
              WHERE buffer_id = ?1
              """,
              [buffer_id, new_id, hash, now()]
            )
          end)

          {:ok, %{current | head_id: new_id, head_hash: hash, gap: false}}
      end

    {:reply, reply, conn}
  end

  def handle_call(
        {:start_recording, buffer_id, text, actor, reason, policy_source},
        _from,
        conn
      ) do
    current = fetch_cell!(conn, buffer_id)
    hash = content_hash(text)

    status =
      if current.recording and not current.gap and current.head_hash == hash and
           current.policy_source == policy_source do
        current
      else
        transact(conn, fn ->
          status =
            if current.gap or current.head_hash != hash do
              new_id = revision_id()

              insert_revision(conn, %{
                id: new_id,
                buffer_id: buffer_id,
                parent_id: current.head_id,
                buffer_version: nil,
                kind: "gap",
                content_hash: hash,
                actor: actor,
                operation: nil,
                snapshot: text,
                metadata: %{reason: reason, attribution: "incomplete"}
              })

              %{current | head_id: new_id, head_hash: hash, gap: false}
            else
              current
            end

          exec(
            conn,
            """
            UPDATE cells
            SET head_id = ?2, head_hash = ?3, recording = 1,
                policy_source = ?4, gap = 0, updated_at = ?5
            WHERE buffer_id = ?1
            """,
            [buffer_id, status.head_id, status.head_hash, policy_source, now()]
          )

          insert_event(conn, buffer_id, "start", actor, reason, policy_source)
          %{status | recording: true, policy_source: policy_source, gap: false}
        end)
      end

    {:reply, {:ok, status}, conn}
  end

  def handle_call(
        {:stop_recording, buffer_id, actor, reason, policy_source},
        _from,
        conn
      ) do
    current = fetch_cell!(conn, buffer_id)

    status =
      if current.recording or current.policy_source != policy_source do
        transact(conn, fn ->
          exec(
            conn,
            """
            UPDATE cells
            SET recording = 0, policy_source = ?2, updated_at = ?3
            WHERE buffer_id = ?1
            """,
            [buffer_id, policy_source, now()]
          )

          insert_event(conn, buffer_id, "stop", actor, reason, policy_source)
          %{current | recording: false, policy_source: policy_source}
        end)
      else
        current
      end

    {:reply, {:ok, status}, conn}
  end

  def handle_call({:checkpoint, buffer_id, actor, reason}, _from, conn) do
    current = fetch_cell!(conn, buffer_id)

    if current.recording do
      transact(conn, fn ->
        insert_event(
          conn,
          buffer_id,
          "checkpoint",
          actor,
          reason,
          current.policy_source
        )
      end)

      {:reply, {:ok, current}, conn}
    else
      {:reply, {:error, :not_recording}, conn}
    end
  end

  defp create_root(conn, buffer_id, text, actor, policy_source, retention) do
    revision_id = revision_id()
    hash = content_hash(text)

    transact(conn, fn ->
      insert_revision(conn, %{
        id: revision_id,
        buffer_id: buffer_id,
        parent_id: nil,
        buffer_version: 0,
        kind: "root",
        content_hash: hash,
        actor: actor,
        operation: nil,
        snapshot: text,
        metadata: %{origin: "buffer"}
      })

      exec(
        conn,
        """
        INSERT INTO cells
          (buffer_id, head_id, head_hash, recording, policy_source,
           retention, gap, updated_at)
        VALUES (?1, ?2, ?3, 1, ?4, ?5, 0, ?6)
        """,
        [buffer_id, revision_id, hash, policy_source, retention, now()]
      )
    end)

    fetch_cell!(conn, buffer_id)
  end

  defp create_schema(conn) do
    [
      """
      CREATE TABLE IF NOT EXISTS provenance_schema (
        version INTEGER NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS cells (
        buffer_id TEXT PRIMARY KEY,
        head_id TEXT NOT NULL,
        head_hash TEXT NOT NULL,
        recording INTEGER NOT NULL,
        policy_source TEXT NOT NULL,
        retention TEXT NOT NULL,
        gap INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS revisions (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        id TEXT NOT NULL UNIQUE,
        buffer_id TEXT NOT NULL,
        parent_id TEXT,
        buffer_version INTEGER,
        kind TEXT NOT NULL,
        content_hash TEXT NOT NULL,
        actor BLOB NOT NULL,
        operation BLOB,
        snapshot BLOB,
        metadata BLOB,
        created_at INTEGER NOT NULL
      )
      """,
      """
      CREATE INDEX IF NOT EXISTS revisions_buffer_seq
        ON revisions(buffer_id, seq)
      """,
      """
      CREATE TABLE IF NOT EXISTS lifecycle_events (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        buffer_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        actor BLOB NOT NULL,
        reason TEXT,
        policy_source TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS proposals (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        id TEXT NOT NULL UNIQUE,
        buffer_id TEXT NOT NULL,
        expected_head TEXT,
        actual_head TEXT NOT NULL,
        actor BLOB NOT NULL,
        operation BLOB NOT NULL,
        created_at INTEGER NOT NULL
      )
      """
    ]
    |> Enum.each(&Sqlite3.execute(conn, &1))

    case query(conn, "SELECT version FROM provenance_schema LIMIT 1", []) do
      [] -> exec(conn, "INSERT INTO provenance_schema(version) VALUES (?1)", [@schema_version])
      [[@schema_version]] -> :ok
      [[version]] -> raise "unsupported provenance schema version: #{version}"
    end
  end

  defp cell(conn, buffer_id) do
    case query(
           conn,
           """
           SELECT head_id, head_hash, recording, policy_source, retention, gap
           FROM cells WHERE buffer_id = ?1
           """,
           [buffer_id]
         ) do
      [] ->
        nil

      [[head_id, head_hash, recording, policy_source, retention, gap]] ->
        %{
          cell_id: buffer_id,
          head_id: head_id,
          head_hash: head_hash,
          recording: recording == 1,
          policy_source: policy_source,
          retention: retention,
          gap: gap == 1
        }
    end
  end

  defp fetch_cell!(conn, buffer_id) do
    cell(conn, buffer_id) || raise "unknown provenance cell: #{buffer_id}"
  end

  defp insert_revision(conn, revision) do
    exec(
      conn,
      """
      INSERT INTO revisions
        (id, buffer_id, parent_id, buffer_version, kind, content_hash,
         actor, operation, snapshot, metadata, created_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
      """,
      [
        revision.id,
        revision.buffer_id,
        revision.parent_id,
        revision.buffer_version,
        revision.kind,
        revision.content_hash,
        blob(revision.actor),
        maybe_blob(revision.operation),
        maybe_blob(revision.snapshot, :binary),
        blob(revision.metadata),
        now()
      ]
    )
  end

  defp insert_event(conn, buffer_id, kind, actor, reason, policy_source) do
    exec(
      conn,
      """
      INSERT INTO lifecycle_events
        (buffer_id, kind, actor, reason, policy_source, created_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6)
      """,
      [buffer_id, kind, blob(actor), reason, policy_source, now()]
    )
  end

  defp exec(conn, sql, params) do
    {:ok, statement} = Sqlite3.prepare(conn, sql)

    try do
      :ok = Sqlite3.bind(statement, params)
      :done = Sqlite3.step(conn, statement)
      :ok
    after
      Sqlite3.release(conn, statement)
    end
  end

  defp query(conn, sql, params) do
    {:ok, statement} = Sqlite3.prepare(conn, sql)

    try do
      :ok = Sqlite3.bind(statement, params)
      collect_rows(conn, statement, [])
    after
      Sqlite3.release(conn, statement)
    end
  end

  defp collect_rows(conn, statement, rows) do
    case Sqlite3.step(conn, statement) do
      {:row, row} -> collect_rows(conn, statement, [row | rows])
      :done -> Enum.reverse(rows)
    end
  end

  defp transact(conn, fun) do
    :ok = Sqlite3.execute(conn, "BEGIN IMMEDIATE")

    try do
      result = fun.()
      :ok = Sqlite3.execute(conn, "COMMIT")
      result
    rescue
      error ->
        Sqlite3.execute(conn, "ROLLBACK")
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        Sqlite3.execute(conn, "ROLLBACK")
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp blob(value), do: {:blob, :erlang.term_to_binary(value)}
  defp maybe_blob(nil), do: nil
  defp maybe_blob(value), do: blob(value)
  defp maybe_blob(nil, :binary), do: nil
  defp maybe_blob(value, :binary), do: {:blob, value}

  defp decode_term(nil), do: nil
  defp decode_term(value), do: :erlang.binary_to_term(value, [:safe])

  defp content_hash(text) do
    :crypto.hash(:sha256, text)
    |> Base.encode16(case: :lower)
  end

  defp revision_id do
    Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  end

  defp now, do: System.system_time(:millisecond)
end
