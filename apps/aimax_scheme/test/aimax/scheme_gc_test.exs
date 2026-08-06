defmodule Aimax.Scheme.GCTest do
  use ExUnit.Case, async: true

  alias Aimax.Scheme

  test "sweep drops dead frames and keeps captured state intact" do
    interp = Scheme.new()
    base = map_size(interp.store.frames)

    # each call allocates a frame nothing captures
    {:ok, _, interp} =
      Scheme.eval_string(interp, "(define (burn n) (if (= n 0) 0 (burn (- n 1)))) (burn 500)")

    assert map_size(interp.store.frames) > base + 400

    # a stateful counter closure must survive the sweep with its state
    {:ok, _, interp} =
      Scheme.eval_string(interp, """
      (define make-counter (lambda () (let ((n 0)) (lambda () (set! n (+ n 1)) n))))
      (define c (make-counter))
      (c)
      """)

    swept = Scheme.gc(interp, [])
    assert map_size(swept.store.frames) < base + 100

    {:ok, val, _} = Scheme.eval_string(swept, "(c)")
    assert val == 2
  end

  test "roots keep otherwise-unreachable closures alive" do
    interp = Scheme.new()
    {:ok, closure, interp} = Scheme.eval_string(interp, "(let ((x 42)) (lambda () x))")

    # rooted (e.g. a command table or reactor handler): still callable
    kept = Scheme.gc(interp, [%{handler: [closure]}])
    assert {:ok, 42, _} = Scheme.call(kept, closure, [])

    # unrooted: its captured frame is collected
    dropped = Scheme.gc(interp, [])
    assert map_size(dropped.store.frames) < map_size(kept.store.frames)
  end
end
