defmodule Aimax.Scheme.GCTest do
  use ExUnit.Case, async: true

  alias Aimax.Scheme

  test "sweep drops dead frames and keeps captured state intact" do
    interp = Scheme.new()
    base = Scheme.frame_count(interp)

    # each call allocates a frame nothing captures
    {:ok, _, interp} =
      Scheme.eval_string(interp, "(define (burn n) (if (= n 0) 0 (burn (- n 1)))) (burn 500)")

    assert Scheme.frame_count(interp) > base + 400

    # a stateful counter closure must survive the sweep with its state
    {:ok, _, interp} =
      Scheme.eval_string(interp, """
      (define make-counter (lambda () (let ((n 0)) (lambda () (set! n (+ n 1)) n))))
      (define c (make-counter))
      (c)
      """)

    swept = Scheme.gc(interp, [])
    assert Scheme.frame_count(swept) < base + 100

    {:ok, val, _} = Scheme.eval_string(swept, "(c)")
    assert val == 2
  end

  test "roots keep otherwise-unreachable closures alive" do
    interp = Scheme.new()
    {:ok, closure, interp} = Scheme.eval_string(interp, "(let ((x 42)) (lambda () x))")

    base = Scheme.frame_count(interp)

    # rooted (e.g. a command table or reactor handler): still callable
    kept = Scheme.gc(interp, [%{handler: [closure]}])
    assert Scheme.frame_count(kept) == base
    assert {:ok, 42, _} = Scheme.call(kept, closure, [])

    # unrooted: its captured frame is collected (the store is shared, so
    # this second sweep mutates the same world the first one kept)
    dropped = Scheme.gc(interp, [])
    assert Scheme.frame_count(dropped) < base
  end

  test "exec publishes only escaped frames, not every let and call" do
    interp = Scheme.new() |> Scheme.flush()
    base = Scheme.frame_count(interp)

    # a frame-heavy exec whose result is a plain number: nothing escapes
    {:ok, 0, interp} =
      Scheme.exec(interp, fn interp ->
        Scheme.eval_string(
          interp,
          "(define (burn n) (if (= n 0) 0 (let ((x n)) (burn (- n 1))))) (burn 2000)"
        )
      end)

    # the dead let/call frames were dropped at flush, not published
    assert Scheme.frame_count(interp) < base + 50
  end

  test "a closure that escapes through a primitive resolves from another process" do
    holder = :ets.new(:escape_test, [:public])

    interp =
      Scheme.new(primitives: %{"stash" => fn [c] -> :ets.insert(holder, {:c, c}) && true end})
      |> Scheme.flush()

    # the closure's let frame is local to the exec; stash is the escape
    {:ok, _, interp} =
      Scheme.exec(interp, fn interp ->
        Scheme.eval_string(interp, "(let ((n 41)) (stash (lambda () (+ n 1))))")
      end)

    [{:c, closure}] = :ets.lookup(holder, :c)

    # another process resolves the captured frame from the shared tier
    task = Task.async(fn -> Scheme.exec(interp, fn i -> Scheme.call(i, closure, []) end) end)
    assert {:ok, 42, _} = Task.await(task)
  end

  test "a primitive can call an escaped closure before its eval exits" do
    test = self()

    interp =
      Scheme.new(
        primitives: %{
          "hold" => fn [closure] ->
            send(test, {:escaped, closure})

            receive do
              :release -> true
            end
          end
        }
      )
      |> Scheme.flush()

    eval =
      Task.async(fn ->
        Scheme.exec(interp, fn interp ->
          Scheme.eval_string(interp, "(let ((n 41)) (hold (lambda () (+ n 1))))")
        end)
      end)

    assert_receive {:escaped, closure}, 500

    callback =
      Task.async(fn -> Scheme.exec(interp, fn i -> Scheme.call(i, closure, []) end) end)

    assert {:ok, 42, _} = Task.await(callback)
    send(eval.pid, :release)
    assert {:ok, true, _} = Task.await(eval)
  end

  test "a result closure's frames survive the selective flush" do
    interp = Scheme.new() |> Scheme.flush()

    {:ok, closure, interp} =
      Scheme.exec(interp, fn interp ->
        Scheme.eval_string(interp, "(let ((x 7)) (lambda () x))")
      end)

    task = Task.async(fn -> Scheme.exec(interp, fn i -> Scheme.call(i, closure, []) end) end)
    assert {:ok, 7, _} = Task.await(task)
  end

  test "an interpreter snapshot has private mutable globals" do
    interp = Scheme.new() |> Scheme.flush()

    {:ok, _, interp} =
      Scheme.exec(interp, fn interp -> Scheme.eval_string(interp, "(define isolated-value 1)") end)

    snapshot = Scheme.snapshot(interp)

    actor =
      Task.async(fn ->
        private = Scheme.from_snapshot(snapshot)

        {:ok, _, private} =
          Scheme.exec(private, fn private ->
            Scheme.eval_string(private, "(set! isolated-value 2)")
          end)

        Scheme.exec(private, fn private -> Scheme.eval_string(private, "isolated-value") end)
      end)

    assert {:ok, 2, _} = Task.await(actor)
    assert {:ok, 1, _} = Scheme.exec(interp, &Scheme.eval_string(&1, "isolated-value"))
  end
end
