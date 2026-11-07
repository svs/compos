defmodule Compos.ZzMetaDbBusyDiagTest do
  use ExUnit.Case, async: false
  alias Exqlite.Sqlite3

  test "diag: meta.db and a just-made buffer" do
    Compos.Core.MetaDb.ensure_started()
    q = fn id -> Compos.Core.MetaDb.query(%{"ids" => [id], "hidden" => true, "context-only" => true}) end

    # 1. no contention: is a just-made buffer in meta.db at once?
    a = "zz-mdb-a-#{System.unique_integer([:positive])}"
    Compos.Core.create_buffer(a)
    ida = Compos.Core.Buffer.id(a)
    IO.puts("DIAG free: #{inspect(q.(ida))}")

    # 2. another connection holds the write lock, as a second VM does
    {:ok, other} = Sqlite3.open(Compos.Core.MetaDb.path())
    :ok = Sqlite3.execute(other, "BEGIN IMMEDIATE")
    b = "zz-mdb-b-#{System.unique_integer([:positive])}"
    Compos.Core.create_buffer(b)
    idb = Compos.Core.Buffer.id(b)
    during = (try do q.(idb) catch k, e -> {k, e} end)
    IO.puts("DIAG locked: #{inspect(during)}")
    :ok = Sqlite3.execute(other, "ROLLBACK")
    Sqlite3.close(other)
    IO.puts("DIAG after unlock: #{inspect(q.(idb))}")
    IO.puts("DIAG registry: #{inspect(Compos.Core.BufferView.name_of_id(idb))}")
  end
end
