defmodule Aimax.SingleActorTest do
  use ExUnit.Case

  alias Aimax.Core.{Lane, Session}

  setup do
    previous = Application.get_env(:aimax_core, :scheme_execution, :lanes)
    Application.put_env(:aimax_core, :scheme_execution, :single_actor)

    on_exit(fn ->
      Lane.kill(:scheme)
      Application.put_env(:aimax_core, :scheme_execution, previous)
    end)

    :ok
  end

  test "routes logical owners through one Scheme worker" do
    assert Lane.route(:ui) == :scheme
    assert Lane.route({:rpc, self()}) == :scheme

    assert Lane.run({:group, "one"}, fn _from -> {:reply, Lane.current()} end) == :scheme
    assert Lane.run({:rpc, self()}, fn _from -> {:reply, Lane.current()} end) == :scheme
  end

  test "telemetry keeps the logical owner separate from the physical lane" do
    handler = {__MODULE__, self(), System.unique_integer()}
    test = self()

    :ok =
      :telemetry.attach(
        handler,
        [:aimax, :lane, :job],
        fn _, _, metadata, _ ->
          send(test, {:lane_metadata, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert Lane.run({:buffer, "one"}, fn _from -> {:reply, :ok} end, 5_000, "read file") ==
             :ok

    assert_receive {:lane_metadata, %{lane: :scheme, owner: {:buffer, "one"}, label: "read file"}}
  end

  test "serializes jobs from different logical owners" do
    test = self()

    first =
      Task.async(fn ->
        Lane.run(:ui, fn _from ->
          send(test, {:started, :first, self()})

          receive do
            :release -> {:reply, :first}
          end
        end)
      end)

    assert_receive {:started, :first, worker}, 500

    second =
      Task.async(fn ->
        Lane.run({:rpc, self()}, fn _from ->
          send(test, {:started, :second})
          {:reply, :second}
        end)
      end)

    refute_receive {:started, :second}, 100
    send(worker, :release)
    assert Task.await(first) == :first
    assert_receive {:started, :second}, 500
    assert Task.await(second) == :second
  end

  test "runs an escaped callback after its registering eval" do
    name = "single-actor-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             Session.eval(
               "(begin (buffer-create \"#{name}\") (define *single-hits* 0) " <>
                 "(define *single-rule* #f))",
               nil,
               5_000,
               {:rpc, self()}
             )

    assert {:ok, "(#f 0)"} =
             Session.eval(
               """
               (let ((tag "local"))
                 (set! *single-rule*
                   (on-change! "#{name}"
                     (lambda (p i d s)
                       (set! *single-hits* (+ *single-hits* (string-length tag))))
                     'eager))
                 (buffer-insert! "#{name}" 0 "x")
                 (list (wait-until (lambda () (> *single-hits* 0)) 100 10)
                       *single-hits*))
               """,
               nil,
               5_000,
               {:rpc, self()}
             )

    assert eventually(fn ->
             Session.eval("*single-hits*", nil, 5_000, :observer) == {:ok, "5"}
           end)

    Session.eval("(remove-on-change! *single-rule*)", nil, 5_000, :observer)
    Aimax.Core.kill_buffer(name)
  end

  defp eventually(fun, tries \\ 30) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(20)
        eventually(fun, tries - 1)
    end
  end
end
