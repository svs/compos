defmodule Compos.WaitUntilTest do
  @moduledoc """
  (wait-until PRED TIMEOUT-MS INTERVAL-MS) — the wait a Scheme test needs.

  A Scheme test runs inside one eval, on one lane. Work it waits for
  happens somewhere else: a subprocess handshake, a debounce, a fetch that
  answers through a callback. This is mechanism, so it is tested here:
  what it answers, that it gives up, and that it can see the other lane at
  all — which it could not until the read cache was cleared between polls.
  """

  use ExUnit.Case

  alias Compos.Core.Session

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  test "a predicate that is already true answers at once" do
    assert eval!("(wait-until (lambda () #t))") == "#t"
  end

  test "a predicate that never holds answers #f at the deadline, not later" do
    started = System.monotonic_time(:millisecond)
    assert eval!("(wait-until (lambda () #f) 200 10)") == "#f"
    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed >= 200, "gave up before the deadline"
    assert elapsed < 1_500, "overran the deadline by #{elapsed - 200}ms"
  end

  # Lane.run gives an eval 30s. A wait that outlived that would report as a
  # frozen lane with no name on it, so the primitive caps itself first.
  test "a timeout past the cap is capped, and still answers" do
    started = System.monotonic_time(:millisecond)
    assert eval!("(wait-until (lambda () #f) 999999 50)") == "#f"
    assert System.monotonic_time(:millisecond) - started < 20_000
  end

  test "it sees a buffer another process wrote" do
    eval!(~s{(buffer-create "*zz-wait-buf*")})
    on_exit(fn -> Compos.Core.kill_buffer("*zz-wait-buf*") end)

    spawn(fn ->
      Process.sleep(80)
      Compos.Core.Buffer.append("*zz-wait-buf*", "landed", source: :editor)
    end)

    assert eval!(~s"""
           (wait-until (lambda () (string-contains? (buffer-text "*zz-wait-buf*") "landed")) 3000 10)
           """) == "#t"
  end

  # The reason this test exists: reads of shared frames are cached per
  # process and cleared once per exec. Polling happens INSIDE one exec, so
  # a predicate over a global used to re-read its own first answer until
  # the deadline and always answer #f.
  test "it sees a Scheme global another lane set mid-eval" do
    eval!("(define *zz-wait-global* #f)")
    parent = self()

    spawn(fn ->
      Process.sleep(80)
      Session.eval("(set-symbol-value! (quote *zz-wait-global*) #t)", nil, 5_000, {:rpc, parent})
    end)

    assert eval!("(wait-until (lambda () *zz-wait-global*) 3000 10)") == "#t"
  end

  test "false is the only false value, so nil and () are true" do
    assert eval!("(wait-until (lambda () '()) 500 10)") == "#t"
    assert eval!("(wait-until (lambda () 0) 500 10)") == "#t"
  end
end
