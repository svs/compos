defmodule Aimax.SchemeTaskTest do
  use ExUnit.Case

  alias Aimax.Core.{Buffer, SchemeReadLimiter, Session}

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
        [[:aimax, :scheme, :task], [:aimax, :lane, :job]],
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

    assert_receive {:telemetry, [:aimax, :scheme, :task], %{duration: duration}, %{status: :ok}},
                   1_000

    assert duration >= 0

    assert_receive {:telemetry, [:aimax, :lane, :job],
                    %{duration: lane_duration, queue_time: queue_time, backlog: backlog}, _},
                   1_000

    assert lane_duration >= 0
    assert queue_time >= 0
    assert backlog >= 0
  end

  test "parallel tasks serialize writes through the target buffer" do
    name = "*scheme-tasks-#{System.unique_integer([:positive])}*"
    {:ok, ^name} = Aimax.Core.create_buffer(name)

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
