defmodule Compos.SchemeTaskTest do
  use ExUnit.Case

  alias Compos.Core.{Buffer, SchemeReadLimiter, Session}

  test "the global read admission limit is bounded" do
    assert SchemeReadLimiter.limit() in 4..16
  end

  test "the global read admission limit queues excess work" do
    owner = self()
    limit = SchemeReadLimiter.limit()

    holders =
      for n <- 1..limit do
        Task.async(fn ->
          SchemeReadLimiter.run(fn ->
            send(owner, {:entered, n, self()})

            receive do
              :release -> :ok
            end
          end)
        end)
      end

    entered =
      for _ <- 1..limit do
        assert_receive {:entered, _n, pid}, 1_000
        pid
      end

    waiter =
      Task.async(fn ->
        SchemeReadLimiter.run(fn -> send(owner, :waiter_entered) end)
      end)

    refute_receive :waiter_entered, 50
    send(hd(entered), :release)
    assert_receive :waiter_entered, 1_000
    assert Task.await(waiter) == :waiter_entered

    Enum.each(tl(entered), &send(&1, :release))
    Enum.each(holders, &Task.await/1)
  end

  defp eval!(source, timeout \\ 30_000) do
    {:ok, printed} = Session.eval(source, nil, timeout)
    printed
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(10)
        eventually(fun, tries - 1)
    end
  end

  # task-run! cancels its task after the callback. A cancel stops the task
  # with an exit signal, so the task itself never drops its root: each
  # task left its result in the root table, 196 MB on a dev daemon.
  test "a task that task-run! completed leaves no root" do
    task_roots = fn ->
      Enum.find_value(Compos.Core.Roots.summary(), 0, fn
        {"scheme_task", count, _bytes, _key} -> count
        _ -> nil
      end)
    end

    before = task_roots.()
    eval!("(define *task-root-result* #f)")

    eval!("""
    (task-run!
      (lambda () (list 1 2 3))
      (lambda (ok value) (set! *task-root-result* (list ok value))))
    """)

    eventually(fn -> Session.eval("*task-root-result*") == {:ok, "(#t (1 2 3))"} end)
    eventually(fn -> task_roots.() <= before end)
  end

  # A task that the heap bound kills, or a daemon from before the cancel
  # fix, has a root and no process. The second sweep drops it.
  test "the sweep drops the root of a task with no process, on its second pass" do
    id = :erlang.unique_integer([:positive, :monotonic])
    Compos.Core.Roots.put({:scheme_task, id}, {:ok, [1, 2, 3]})

    seen = Compos.Core.SchemeTask.sweep_roots(MapSet.new())
    assert id in seen
    assert Compos.Core.Roots.get({:scheme_task, id}) != nil

    Compos.Core.SchemeTask.sweep_roots(seen)
    assert Compos.Core.Roots.get({:scheme_task, id}) == nil
  end

  test "task-run returns immediately and delivers its result to Scheme" do
    eval!("(define *task-run-result* #f)")

    printed =
      eval!("""
      (task-run!
        (lambda () 42)
        (lambda (ok value) (set! *task-run-result* (list ok value))))
      """)

    assert printed =~ "SchemeTask.Ref"
    eventually(fn -> Session.eval("*task-run-result*") == {:ok, "(#t 42)"} end)
  end

  test "task and lane telemetry expose scheduler pressure" do
    owner = self()
    id = "scheme-task-telemetry-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        id,
        [[:compos, :scheme, :task], [:compos, :lane, :job]],
        fn event, measurements, metadata, _config ->
          send(owner, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)

    assert "42" ==
             eval!("""
             (let* ((task (task-spawn (lambda () 42)))
                    (value (task-await task)))
               (task-cancel! task)
               value)
             """)

    assert_receive {:telemetry, [:compos, :scheme, :task], %{duration: duration}, %{status: :ok}},
                   1_000

    assert duration >= 0

    assert_receive {:telemetry, [:compos, :lane, :job],
                    %{duration: lane_duration, queue_time: queue_time, backlog: backlog}, _},
                   1_000

    assert lane_duration >= 0
    assert queue_time >= 0
    assert backlog >= 0
  end

  test "task-run!'s callback runs with the buffer that was current when the task was spawned" do
    name = "*scheme-task-buf-#{System.unique_integer([:positive])}*"
    {:ok, ^name} = Compos.Core.create_buffer(name)

    eval!("(define *task-run-buffer* #f)")

    eval!("""
    (with-current-buffer #{inspect(name)}
      (lambda ()
        (task-run!
          (lambda () 42)
          (lambda (ok value) (set! *task-run-buffer* (current-buffer))))))
    """)

    eventually(fn -> Session.eval("*task-run-buffer*") == {:ok, "\"#{name}\""} end)
  end

  test "parallel tasks serialize writes through the target buffer" do
    name = "*scheme-tasks-#{System.unique_integer([:positive])}*"
    {:ok, ^name} = Compos.Core.create_buffer(name)

    assert "(1 2 3 4)" ==
             eval!("""
             (let* ((buf #{inspect(name)})
                    (tasks
                      (map (lambda (n)
                             (task-spawn
                               (lambda ()
                                 (buffer-append! buf (number->string n))
                                 n)))
                           '(1 2 3 4)))
                    (values (map task-await tasks)))
               (for-each task-cancel! tasks)
               values)
             """)

    text = Buffer.text(name)
    assert String.length(text) == 4
    assert Enum.sort(String.graphemes(text)) == ~w(1 2 3 4)
  end
end
