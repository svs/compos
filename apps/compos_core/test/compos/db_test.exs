defmodule Compos.DBTest do
  @moduledoc """
  The database mechanism, driven the way a Scheme package drives it.

  These run against the local PostgreSQL and are skipped without one. The
  point of each is a promise the README made: one live connection across
  many queries, parameters bound rather than spliced, results that keep
  their column names, and errors that carry SQLSTATE.
  """

  use ExUnit.Case

  alias Compos.Core.{DB, Session}

  setup_all do
    ready? = match?({_, 0}, System.cmd("pg_isready", [], stderr_to_stdout: true))
    if ready?, do: {:ok, pg: true}, else: :ok
  rescue
    _ -> :ok
  end

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp wait_until(fun, tries \\ 400) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(10)
        wait_until(fun, tries - 1)
    end
  end

  defp ask!(name, sql, params, var) do
    eval!("(define #{var} 'pending)")
    eval!(~s|(db-query "#{name}" #{sql} #{params} (lambda (ok v) (set! #{var} (list ok v))))|)
    wait_until(fn -> eval!(var) != "pending" end)
    eval!(var)
  end

  defp open!(name) do
    eval!(~s|(db-connect! "#{name}" '(adapter "postgres" database "postgres"))|)
    wait_until(fn -> DB.whereis(name) != nil end)
    on_exit(fn -> DB.disconnect(name) end)
  end

  describe "without a server" do
    test "an unknown adapter is refused by name" do
      assert {:error, msg} = DB.connect("t-bad", %{"adapter" => "oracle"})
      assert msg =~ "unknown db adapter"
      assert msg =~ "postgres"
    end

    test "a bad connection name is refused" do
      assert {:error, msg} = DB.connect("Bad Name!", %{})
      assert msg =~ "db names are"
    end

    test "a query on a name nobody opened answers, rather than hanging" do
      eval!("(define x 'pending)")
      eval!(~s|(db-query "t-missing" "select 1" (lambda (ok v) (set! x (list ok v))))|)
      wait_until(fn -> eval!("x") != "pending" end)
      assert eval!("x") =~ "no connection"
    end

    test "a synchronous query raises when the connection is missing" do
      assert {:error, message} = Session.eval(~s|(db-query "t-sync-missing" "select 1")|)
      assert message =~ "no connection"
    end

    test "a transaction raises when the connection is missing" do
      assert {:error, message} =
               Session.eval(
                 ~s|(db-with-transaction "t-tx-missing" (lambda (tx) (db-query tx "select 1")))|
               )

      assert message =~ "no connection"
    end

    test "the adapter list names what this build can open" do
      assert eval!("(db-adapters)") =~ "postgres"
    end
  end

  describe "with PostgreSQL" do
    @describetag :pg

    test "one connection serves many queries and keeps column names", ctx do
      if ctx[:pg] == nil do
        IO.puts("skipped: no local PostgreSQL")
      else
        open!("t-db")

        assert ask!("t-db", ~s|"select 1 as n"|, "'()", "r1") ==
                 ~s|(#t (columns ("n") rows ((1)) count 1 command "select"))|

        assert ask!("t-db", ~s|"select 'ada' as who"|, "'()", "r2") ==
                 ~s|(#t (columns ("who") rows (("ada")) count 1 command "select"))|

        # the same connection served both: no reconnect tax
        assert eval!(~s|(db-connected? "t-db")|) == "#t"
      end
    end

    test "a synchronous query returns the result on its calling lane", ctx do
      if ctx[:pg] == nil do
        IO.puts("skipped: no local PostgreSQL")
      else
        open!("t-sync")

        assert eval!(~s|(db-query "t-sync" "select 7 as n")|) ==
                 ~s|(columns ("n") rows ((7)) count 1 command "select")|
      end
    end

    test "a transaction returns the procedure value and rolls back failures", ctx do
      if ctx[:pg] == nil do
        IO.puts("skipped: no local PostgreSQL")
      else
        open!("t-sync-tx")
        eval!(~s|(db-query "t-sync-tx" "create temporary table tx_values (n int)")|)

        assert eval!("""
               (db-with-transaction "t-sync-tx"
                 (lambda (tx)
                   (db-query tx "insert into tx_values values ($1)" (list 7))
                   (db-query tx "select n from tx_values")))
               """) == ~s|(columns ("n") rows ((7)) count 1 command "select")|

        assert eval!("""
               (db-with-transaction "t-sync-tx"
                 (lambda (tx)
                   (db-query tx "select 1")
                   42))
               """) == "42"

        assert {:error, message} =
                 Session.eval("""
                 (db-with-transaction "t-sync-tx"
                   (lambda (tx)
                     (db-query tx "insert into tx_values values (9)")
                     (db-query tx "select * from no_such_table")))
                 """)

        assert message =~ "42P01"

        assert eval!(~s|(db-value (db-query "t-sync-tx" "select count(*) from tx_values"))|) ==
                 "1"
      end
    end

    test "a transaction handle cannot escape its procedure", ctx do
      if ctx[:pg] == nil do
        IO.puts("skipped: no local PostgreSQL")
      else
        open!("t-tx-scope")

        assert eval!("""
               (define escaped-tx #f)
               (db-with-transaction "t-tx-scope"
                 (lambda (tx)
                   (set! escaped-tx tx)
                   'committed))
               """) == "committed"

        assert {:error, message} = Session.eval(~s|(db-query escaped-tx "select 1")|)
        assert message =~ "no longer active"
      end
    end

    test "parameters are bound, so a quote in a value is just a value", ctx do
      if ctx[:pg] == nil do
        IO.puts("skipped: no local PostgreSQL")
      else
        open!("t-param")

        # the classic injection payload, passed as data
        got = ask!("t-param", ~s|"select $1::text as v"|, ~s|(list "'; drop table x --")|, "p")
        assert got =~ "drop table x"
        assert got =~ "count 1"
      end
    end

    test "SQL NULL is distinguishable from an empty string", ctx do
      if ctx[:pg] == nil do
        IO.puts("skipped: no local PostgreSQL")
      else
        open!("t-null")
        got = ask!("t-null", ~s|"select null::text as a, '' as b"|, "'()", "n")
        assert got == ~s|(#t (columns ("a" "b") rows ((#f "")) count 1 command "select"))|
      end
    end

    test "a numeric keeps its precision as text rather than becoming a float", ctx do
      if ctx[:pg] == nil do
        IO.puts("skipped: no local PostgreSQL")
      else
        open!("t-num")
        got = ask!("t-num", ~s|"select 0.1234567890123456789::numeric as d"|, "'()", "d")
        assert got =~ "0.1234567890123456789"
      end
    end

    test "an error carries its SQLSTATE and the connection survives it", ctx do
      if ctx[:pg] == nil do
        IO.puts("skipped: no local PostgreSQL")
      else
        open!("t-err")

        bad = ask!("t-err", ~s|"select * from no_such_table"|, "'()", "e")
        assert bad =~ "#f"
        # 42P01 is undefined_table
        assert bad =~ "42P01"

        # still usable afterwards
        assert ask!("t-err", ~s|"select 7 as n"|, "'()", "after") =~ "rows ((7))"
      end
    end

    test "an explicit transaction rolls back on one connection", ctx do
      if ctx[:pg] == nil do
        IO.puts("skipped: no local PostgreSQL")
      else
        open!("t-tx")

        ask!("t-tx", ~s|"create temporary table t_tx (n int)"|, "'()", "c")
        ask!("t-tx", ~s|"begin"|, "'()", "b")
        ask!("t-tx", ~s|"insert into t_tx values (1)"|, "'()", "i")
        assert ask!("t-tx", ~s|"select count(*) from t_tx"|, "'()", "mid") =~ "rows ((1))"
        ask!("t-tx", ~s|"rollback"|, "'()", "rb")

        # begin/insert/rollback all reached the same session, which is the
        # reason this mechanism keeps one connection per name
        assert ask!("t-tx", ~s|"select count(*) from t_tx"|, "'()", "post") =~ "rows ((0))"
      end
    end

    test "many rows come back in order with their types decoded", ctx do
      if ctx[:pg] == nil do
        IO.puts("skipped: no local PostgreSQL")
      else
        open!("t-rows")

        got =
          ask!(
            "t-rows",
            ~s|"select * from (values (1,'a',true),(2,'b',false)) t(id,name,ok) order by id"|,
            "'()",
            "m"
          )

        assert got ==
                 ~s|(#t (columns ("id" "name" "ok") rows ((1 "a" #t) (2 "b" #f)) count 2 command "select"))|
      end
    end
  end
end
