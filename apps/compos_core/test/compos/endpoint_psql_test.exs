defmodule Compos.EndpointPsqlTest do
  @moduledoc """
  The endpoint mechanism carrying a real psql session.

  This is the acceptance condition the mechanism was built for: a database
  connector is Scheme policy over an `exec` endpoint, and core adds no
  database code. The connector below is deliberately written in Scheme, in
  the test, to prove the primitives are sufficient without a package.

  Skipped when no local PostgreSQL answers.
  """

  use ExUnit.Case

  alias Compos.Core.{Endpoint, Session}

  @sentinel "__compos_end__"

  setup_all do
    psql = System.find_executable("psql")

    ready? =
      psql != nil and
        match?({_, 0}, System.cmd("pg_isready", [], stderr_to_stdout: true))

    if ready?, do: {:ok, psql_path: psql}, else: :ok
  end

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp wait_until(fun, tries \\ 400) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true ->
        Process.sleep(10)
        wait_until(fun, tries - 1)
    end
  end

  @tag :psql
  test "a Scheme connector runs queries over one long-lived psql", ctx do
    if ctx[:psql_path] == nil do
      IO.puts("skipped: no local PostgreSQL")
    else
      # the whole connector: start a session, ask, strip psql's row footer.
      # Every line of this is policy, and none of it is in Elixir.
      eval!("""
      (define (pg-open name db)
        (endpoint-start! name
          (list 'command "#{ctx[:psql_path]}"
                'args (list "-qAX" "--set" "ON_ERROR_STOP=0" db)
                'framing "line")))

      (define (pg-query name sql k)
        (endpoint-ask name
          (string-append sql "\\n\\\\echo #{@sentinel}")
          "#{@sentinel}"
          (lambda (ok frames)
            (k ok (if ok (pg-strip frames) frames)))))

      (define (pg-strip frames)
        (filter (lambda (l)
                  (not (or (string-suffix? " row)" l)
                           (string-suffix? " rows)" l))))
                frames))
      """)

      eval!(~s|(pg-open "pg-test" "postgres")|)
      wait_until(fn -> Endpoint.whereis("pg-test") != nil end)
      on_exit(fn -> Endpoint.stop("pg-test") end)

      # one connection, three queries — the point of a persistent endpoint
      eval!("(define r1 'pending)")
      eval!("(define r2 'pending)")
      eval!("(define r3 'pending)")

      eval!(~s|(pg-query "pg-test" "select 1 as n;" (lambda (ok v) (set! r1 (list ok v))))|)
      eval!(~s|(pg-query "pg-test" "select 'ada' as who;" (lambda (ok v) (set! r2 (list ok v))))|)

      eval!(
        ~s|(pg-query "pg-test" "select * from (values (1,'a'),(2,'b')) t(id,name);" | <>
          ~s|(lambda (ok v) (set! r3 (list ok v))))|
      )

      wait_until(fn -> eval!("r3") != "pending" end)

      assert eval!("r1") == ~s|(#t ("n" "1"))|
      assert eval!("r2") == ~s|(#t ("who" "ada"))|
      assert eval!("r3") == "(#t (\"id|name\" \"1|a\" \"2|b\"))"

      # the session stayed up across all three: no reconnect tax
      assert eval!(~s|(endpoint-detail "pg-test")|) =~ ~s|status "ready"|
    end
  end

  @tag :psql
  test "a SQL error comes back as frames, not a dead connection", ctx do
    if ctx[:psql_path] == nil do
      IO.puts("skipped: no local PostgreSQL")
    else
      # psql writes errors to stderr, so the connector asks for it on the
      # same stream — otherwise a failed query is an empty answer with no
      # way to say why
      eval!("""
      (endpoint-start! "pg-err"
        (list 'command "#{ctx[:psql_path]}" 'args (list "-qAX" "postgres")
              'framing "line" 'stderr "merge"))
      """)

      wait_until(fn -> Endpoint.whereis("pg-err") != nil end)
      on_exit(fn -> Endpoint.stop("pg-err") end)

      eval!("(define e 'pending)")

      eval!("""
      (endpoint-ask "pg-err" "select * from no_such_table;\n\\echo #{@sentinel}"
        "#{@sentinel}" (lambda (ok v) (set! e (list ok v))))
      """)

      wait_until(fn -> eval!("e") != "pending" end)
      assert eval!("e") =~ "no_such_table"

      # the endpoint survived the error and still serves the next query
      eval!("(define after 'pending)")

      eval!("""
      (endpoint-ask "pg-err" "select 7;\n\\echo #{@sentinel}"
        "#{@sentinel}" (lambda (ok v) (set! after (list ok v))))
      """)

      wait_until(fn -> eval!("after") != "pending" end)
      assert eval!("after") =~ "7"
      assert eval!(~s|(endpoint-detail "pg-err")|) =~ ~s|status "ready"|
    end
  end
end
