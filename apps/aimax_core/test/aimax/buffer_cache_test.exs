defmodule Aimax.BufferCacheTest do
  @moduledoc """
  The buffer cache: content fetched from a slow source keeps a stamp,
  goes stale by TTL, refreshes off the UI lane through a continuation,
  and never doubles an in-flight fetch.
  """

  use ExUnit.Case, async: false

  alias Aimax.Core.{Buffer, Session}

  defp eval!(code) do
    {:ok, out} = Session.eval(code)
    out
  end

  setup do
    on_exit(fn ->
      Aimax.Core.kill_buffer("*zz-cache*")
      Aimax.Core.kill_buffer("*zz-cache-list*")
    end)

    :ok
  end

  test "refresh fetches once, renders on arrival, and stamps the buffer" do
    eval!(~S"""
    (begin
      (define *zz-cache-fetches* 0)
      (define *zz-cache-k* #f)
      (buffer-create "*zz-cache*")
      (cache-declare! "*zz-cache*"
        (lambda (buf k)
          (set! *zz-cache-fetches* (+ *zz-cache-fetches* 1))
          (set! *zz-cache-k* k))
        (lambda (buf data)
          (buffer-delete-range! buf 0 (buffer-size buf))
          (buffer-append! buf data))
        60))
    """)

    # no stamp yet: stale, and the age has nothing to say
    assert eval!(~S{(cache-stale? "*zz-cache*")}) == "#t"
    assert eval!(~S{(cache-age-label "*zz-cache*")}) == "#f"

    # one refresh, and a second while in flight does not double the fetch
    eval!(~S{(cache-refresh! "*zz-cache*")})
    eval!(~S{(cache-refresh! "*zz-cache*")})
    assert eval!("*zz-cache-fetches*") == "1"

    # the data lands: render ran, the stamp is fresh, the flight is over
    eval!(~S{(*zz-cache-k* "rows from the network")})
    assert Buffer.text("*zz-cache*") == "rows from the network"
    assert eval!(~S{(cache-stale? "*zz-cache*")}) == "#f"
    assert eval!(~S{(cache-age-label "*zz-cache*")}) == ~S["just now"]

    # a failed fetch (#f) keeps the cache and still ends the flight
    eval!(~S{(buffer-set-local! "*zz-cache*" 'cache-time #f)})
    eval!(~S{(cache-refresh! "*zz-cache*")})
    eval!(~S{(*zz-cache-k* #f)})
    assert Buffer.text("*zz-cache*") == "rows from the network"
    assert eval!(~S{(buffer-local "*zz-cache*" 'cache-inflight)}) == "#f"
  end

  test "the wake rule: fresh data draws as it is, stale data refetches" do
    eval!(~S"""
    (begin
      (define *zz-cache-fetches* 0)
      (buffer-create "*zz-cache*")
      (cache-declare! "*zz-cache*"
        (lambda (buf k)
          (set! *zz-cache-fetches* (+ *zz-cache-fetches* 1))
          (k "fresh"))
        (lambda (buf data) #t)
        60)
      (cache-stamp! "*zz-cache*"))
    """)

    # inside the TTL a wake costs nothing
    eval!(~S{(cache-wake! "*zz-cache*")})
    assert eval!("*zz-cache-fetches*") == "0"

    # past the TTL a wake fetches again
    eval!(~S{(buffer-set-local! "*zz-cache*" 'cache-time (- (current-time) 3600))})
    eval!(~S{(cache-wake! "*zz-cache*")})
    assert eval!("*zz-cache-fetches*") == "1"

    # a TTL of #f never goes stale by age
    eval!(~S"""
    (begin
      (cache-declare! "*zz-cache*"
        (lambda (buf k) (set! *zz-cache-fetches* (+ *zz-cache-fetches* 1)) (k "x"))
        (lambda (buf data) #t)
        #f)
      (buffer-set-local! "*zz-cache*" 'cache-time (- (current-time) 999999))
      (cache-wake! "*zz-cache*"))
    """)

    assert eval!("*zz-cache-fetches*") == "1"
  end

  test "a list with 'cache-fetch fills from the source and wakes from its rows" do
    eval!(~S"""
    (begin
      (define *zz-cl-fetches* 0)
      (domain! 'ui)
      (effects! '(write))
      (define-list-mode! "zz-cache-list-mode"
        (list
          'buffer "*zz-cache-list*"
          'rows (lambda (buf) (or (buffer-local buf 'list-entries) '()))
          'cache-fetch (lambda (buf k)
                         (set! *zz-cl-fetches* (+ *zz-cl-fetches* 1))
                         (k '("alpha" "beta")))
          'cache-ttl 60
          'columns (lambda (buf) (list (list "name" #f)))
          'cells (lambda (buf row) (list row))
          'title (lambda (buf) "Cached")
          'no-marks #t))
      (list-mode-show! "zz-cache-list-mode"))
    """)

    # the first open had no rows, so the cache fetched them
    assert eval!("*zz-cl-fetches*") == "1"
    assert Buffer.text("*zz-cache-list*") =~ "alpha"

    # a wake inside the TTL redraws the cached rows and fetches nothing
    eval!(
      ~S{(with-current-buffer "*zz-cache-list*" (lambda () (set-mode! "zz-cache-list-mode")))}
    )

    assert eval!("*zz-cl-fetches*") == "1"
    assert Buffer.text("*zz-cache-list*") =~ "alpha"

    # a wake past the TTL fetches again
    eval!(~S{(buffer-set-local! "*zz-cache-list*" 'cache-time (- (current-time) 3600))})

    eval!(
      ~S{(with-current-buffer "*zz-cache-list*" (lambda () (set-mode! "zz-cache-list-mode")))}
    )

    assert eval!("*zz-cl-fetches*") == "2"
  end
end
