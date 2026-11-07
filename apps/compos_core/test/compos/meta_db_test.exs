defmodule Compos.Core.MetaDbTest do
  use ExUnit.Case, async: false

  alias Compos.Core.{Buffer, MetaDb}
  alias Exqlite.Sqlite3

  # Another connection on meta.db (a second VM, a test run beside the
  # daemon) holds the write lock. A batch that finds the file busy used to
  # roll back and lose its rows; now it stays pending and the next read
  # writes it before it answers.
  test "a busy write is kept and its rows land when the file is free" do
    MetaDb.ensure_started()
    was = Application.get_env(:compos_core, :meta_db_busy_timeout_ms)
    # fail at once on the lock: no wait, so the refusal is certain
    Application.put_env(:compos_core, :meta_db_busy_timeout_ms, 0)
    {:ok, other} = Sqlite3.open(MetaDb.path())

    try do
      :ok = Sqlite3.execute(other, "BEGIN IMMEDIATE")
      name = "zz-mdb-busy-#{System.unique_integer([:positive])}"
      Compos.Core.create_buffer(name)
      id = Buffer.id(name)

      # the buffer reported before create answered: this waits for the write
      state = :sys.get_state(MetaDb)
      assert Map.get(state, :busy, 0) >= 1, "the write found the file busy"
      assert Map.get(state, :pending, []) != [], "and kept the batch"

      :ok = Sqlite3.execute(other, "ROLLBACK")

      assert {1, [[^name]]} =
               MetaDb.query(%{"ids" => [id], "hidden" => true, "context-only" => true})

      assert Map.get(:sys.get_state(MetaDb), :pending, []) == []
    after
      Sqlite3.close(other)

      if was,
        do: Application.put_env(:compos_core, :meta_db_busy_timeout_ms, was),
        else: Application.delete_env(:compos_core, :meta_db_busy_timeout_ms)
    end
  end

  # A layout names its buffers by id; a buffer just made, never changed,
  # must already have its row.
  test "a new buffer has its row before its first change" do
    MetaDb.ensure_started()
    name = "zz-mdb-new-#{System.unique_integer([:positive])}"
    Compos.Core.create_buffer(name)
    id = Buffer.id(name)

    assert {1, [[^name]]} =
             MetaDb.query(%{"ids" => [id], "hidden" => true, "context-only" => true})
  end

  # The recent order has one owner, Compos.Core.Recent. A move there, with
  # no word to meta.db, is the order the recent sort answers.
  test "the recent sort is Recent's order" do
    MetaDb.ensure_started()
    n = System.unique_integer([:positive])
    [a, b] = names = ["zz-mdb-ra-#{n}", "zz-mdb-rb-#{n}"]
    Enum.each(names, &Compos.Core.create_buffer/1)
    q = %{"names" => names, "sort" => "recent"}

    Compos.Core.Recent.bump(a)
    Compos.Core.Recent.bump(b)
    assert {2, [[^b], [^a]]} = MetaDb.query(q)
    assert [^b, ^a] = Enum.map(MetaDb.candidates(q, nil, ""), &hd/1)

    Compos.Core.Recent.bump(a)
    assert {2, [[^a], [^b]]} = MetaDb.query(q)

    Compos.Core.Recent.bury(a)
    assert {2, [[^b], [^a]]} = MetaDb.query(q)
  end
end
