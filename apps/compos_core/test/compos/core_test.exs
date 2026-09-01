defmodule Compos.CoreTest do
  use ExUnit.Case

  alias Compos.Core
  alias Compos.Core.{Buffer, Events, Reactor, Rope, Session}

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  describe "Rope" do
    test "insert/delete/slice round-trip" do
      rope = Rope.new("hello world")
      assert Rope.byte_size(rope) == 11

      rope = Rope.insert(rope, 5, ",")
      assert Rope.to_binary(rope) == "hello, world"

      rope = Rope.delete(rope, 0, 7)
      assert Rope.to_binary(rope) == "world"

      assert Rope.slice(Rope.new("abcdef"), 2, 3) == "cde"
    end

    test "handles large texts across leaf boundaries" do
      big = String.duplicate("0123456789", 1_000)
      rope = Rope.new(big)
      rope = Rope.insert(rope, 5_000, "MARK")
      assert Rope.slice(rope, 4_998, 8) == "89MARK01"
      assert Rope.byte_size(rope) == 10_004
      assert Rope.to_binary(Rope.delete(rope, 5_000, 4)) == big
    end

    test "out-of-bounds edits raise" do
      assert_raise ArgumentError, fn -> Rope.insert(Rope.new("ab"), 5, "x") end
      assert_raise ArgumentError, fn -> Rope.delete(Rope.new("ab"), 1, 5) end
    end
  end

  describe "Buffer" do
    test "create, append, insert, delete, text" do
      name = uniq("buf")
      {:ok, ^name} = Core.create_buffer(name)
      assert name in Core.list_buffers()

      :ok = Buffer.append(name, "hello")
      :ok = Buffer.insert_at(name, 5, " world")
      assert Buffer.text(name) == "hello world"

      :ok = Buffer.delete_range(name, 0, 6)
      assert Buffer.text(name) == "world"
      assert Buffer.version(name) == 3
    end

    test "reads the line at point atomically" do
      name = uniq("line-at-point")
      {:ok, ^name} = Core.create_buffer(name)
      :ok = Buffer.append(name, "zero\nhéllo\nlast")
      :ok = Buffer.goto(name, 8)

      assert Buffer.line_at_point(name) == {2, "héllo"}
    end

    test "change events carry provenance" do
      name = uniq("evt")
      {:ok, _} = Core.create_buffer(name)
      :ok = Events.subscribe(name)

      Buffer.append(name, "by user")
      assert_receive {:buffer_change, ^name, %{inserted: "by user", source: :user}}

      Buffer.append(name, "by agent", source: {:agent, "triage"})
      assert_receive {:buffer_change, ^name, %{source: {:agent, "triage"}}}
    end

    test "opens files" do
      path = Path.join(System.tmp_dir!(), "compos-test-#{System.unique_integer()}.txt")
      File.write!(path, "file content")
      {:ok, name} = Core.open_file(path)
      assert Buffer.text(name) == "file content"
      File.rm!(path)
    end
  end

  describe "Reactor" do
    test "fires debounced on matching changes, accumulating them" do
      name = uniq("log")
      {:ok, _} = Core.create_buffer(name)
      me = self()

      {:ok, _id} =
        Reactor.on_change(
          name,
          {:contains, "ERROR"},
          fn changes -> send(me, {:fired, changes}) end,
          debounce: 30,
          eager: true
        )

      Buffer.append(name, "INFO fine\n")
      Buffer.append(name, "ERROR one\n")
      Buffer.append(name, "ERROR two\n")

      assert_receive {:fired, changes}, 500
      assert Enum.map(changes, & &1.inserted) == ["ERROR one\n", "ERROR two\n"]
      refute_receive {:fired, _}, 100
    end

    test "a buffer killed inside the debounce ends its rule, not the Reactor" do
      name = uniq("short-lived")
      {:ok, _} = Core.create_buffer(name)
      reactor = Process.whereis(Reactor)

      # not eager: the fire path reads the buffer's name to ask if it is on screen
      {:ok, id} = Reactor.on_change(name, :any, fn _ -> :ok end, debounce: 30)
      Buffer.append(name, "one line\n")
      :ok = Core.kill_buffer(name)

      Process.sleep(120)
      assert Process.whereis(Reactor) == reactor, "the Reactor survived the dead buffer"
      refute Enum.any?(Reactor.rules(), &(&1.id == id)), "the dead buffer's rule is gone"
    end

    test "ignores agent-sourced edits by default (loop prevention)" do
      name = uniq("loop")
      {:ok, _} = Core.create_buffer(name)
      me = self()

      {:ok, _} =
        Reactor.on_change(name, :any, fn changes -> send(me, {:fired, changes}) end, eager: true)

      Buffer.append(name, "agent output", source: {:agent, "x"})
      refute_receive {:fired, _}, 100

      Buffer.append(name, "human edit")
      assert_receive {:fired, [%{inserted: "human edit"}]}, 500
    end

    test "subscribes once per buffer and unsubscribes with the last rule" do
      name = uniq("subscriptions")
      {:ok, _} = Core.create_buffer(name)
      ref = Buffer.ref(name)

      ids =
        for _ <- 1..3 do
          {:ok, id} = Reactor.on_change(name, :any, fn _ -> :ok end, eager: true)
          id
        end

      assert length(Registry.lookup(Events.registry(), {:buffer_change, ref})) == 1

      Enum.each(Enum.take(ids, 2), &Reactor.remove/1)
      assert length(Registry.lookup(Events.registry(), {:buffer_change, ref})) == 1

      Reactor.remove(List.last(ids))
      assert Registry.lookup(Events.registry(), {:buffer_change, ref}) == []
    end

    test "serializes one rule and coalesces changes while its handler runs" do
      name = uniq("serialized-handler")
      {:ok, _} = Core.create_buffer(name)
      test = self()

      {:ok, rule} =
        Reactor.on_change(
          name,
          :any,
          fn changes ->
            send(test, {:handler_started, self(), changes})

            receive do
              :release -> :ok
            after
              1_000 -> {:error, "test handler timed out"}
            end
          end,
          eager: true
        )

      Buffer.append(name, "one")
      assert_receive {:handler_started, first, [%{inserted: "one"}]}, 500

      Buffer.append(name, "two")
      Buffer.append(name, "three")
      refute_receive {:handler_started, _, _}, 100

      send(first, :release)

      assert_receive {:handler_started, second, changes}, 500
      assert Enum.map(changes, & &1.inserted) == ["two", "three"]
      send(second, :release)

      Reactor.remove(rule)
    end

    test "retains a batch when its handler reports an error" do
      name = uniq("failed-handler")
      {:ok, _} = Core.create_buffer(name)

      {:ok, id} =
        Reactor.on_change(name, :any, fn _ -> {:error, "broken"} end, eager: true)

      Buffer.append(name, "keep me")

      assert eventually(fn ->
               rule = Enum.find(Reactor.rules(), &(&1.id == id))
               rule.pending != [] and not rule.in_flight and rule.timer == nil
             end)

      rule = Enum.find(Reactor.rules(), &(&1.id == id))
      assert Enum.map(rule.pending, & &1.inserted) == ["keep me"]
      Reactor.remove(id)
    end

    test "retains a batch when its handler task is killed" do
      name = uniq("killed-handler")
      {:ok, _} = Core.create_buffer(name)
      test = self()

      {:ok, id} =
        Reactor.on_change(
          name,
          :any,
          fn _changes ->
            send(test, {:handler_task, self()})
            Process.sleep(:infinity)
          end,
          eager: true
        )

      Buffer.append(name, "keep this too")
      assert_receive {:handler_task, task}, 500
      Process.exit(task, :kill)

      assert eventually(fn ->
               rule = Enum.find(Reactor.rules(), &(&1.id == id))
               rule.pending != [] and rule.in_flight == false
             end)

      rule = Enum.find(Reactor.rules(), &(&1.id == id))
      assert Enum.map(rule.pending, & &1.inserted) == ["keep this too"]
      Reactor.remove(id)
    end

    test "a rule follows immutable buffer identity through rename and wake" do
      old = uniq("reactor-old")
      new = uniq("reactor-new")
      {:ok, _} = Core.create_buffer(old)
      ref = Buffer.ref(old)
      me = self()

      {:ok, rule} =
        Reactor.on_change(old, :any, fn changes -> send(me, {:fired, changes}) end, eager: true)

      assert {:ok, ^new} = Core.rename_buffer(ref, new)
      Buffer.append(ref, "renamed")
      assert_receive {:fired, [%{inserted: "renamed"}]}, 500

      :ok = Buffer.checkpoint_now(ref)
      [{pid, _}] = Registry.lookup(Compos.Core.BufferRegistry, new)
      :ok = DynamicSupervisor.terminate_child(Compos.Core.BufferSupervisor, pid)
      assert eventually(fn -> not Buffer.exists?(ref) end)

      Buffer.append(ref, " and awake")
      assert_receive {:fired, [%{inserted: " and awake"}]}, 500

      Reactor.remove(rule)
      Core.kill_buffer(ref)
    end
  end

  test "a stale name reads as absent instead of exiting through :noproc" do
    name = uniq("stale-local")
    {:ok, _} = Core.create_buffer(name)
    :ok = Core.kill_buffer(name)

    assert Buffer.get_local(name, "anything") == nil
    assert Buffer.locals(name) == %{}
    # a name with neither a process nor a checkpoint reads as empty text, so
    # one dead buffer cannot raise out of a whole list render (buffer.ex)
    assert Buffer.text(name) == ""
    assert Buffer.ref(name) == nil
  end

  test "killing every buffer leaves a live scratch buffer" do
    Enum.each(Core.list_buffers(), &Core.kill_buffer/1)

    # Async tests can hold live buffers during the sweep, so the sweep
    # cannot prove the global last-kill path. The stable invariants:
    # the editor lands on a live buffer, and scratch comes back on the
    # first switch.
    current = Compos.Core.Editor.current_buffer()
    assert Buffer.exists?(current)

    {:ok, _} = Session.eval(~s{(switch-to-buffer! "*scratch*")})
    assert Buffer.exists?("*scratch*")
    assert Compos.Core.Editor.current_buffer() == "*scratch*"
    assert :ok = Buffer.append("*scratch*", "still live")
  end

  describe "Session (Scheme wired to buffers)" do
    test "scheme can create and edit buffers" do
      name = uniq("scm")

      {:ok, _} =
        Session.eval("""
        (buffer-create "#{name}")
        (buffer-append! "#{name}" "hello from scheme")
        """)

      assert Buffer.text(name) == "hello from scheme"
      {:ok, printed} = Session.eval(~s{(buffer-text "#{name}")})
      assert printed == inspect("hello from scheme")
    end

    test "scheme reads a named buffer's line at point" do
      name = uniq("scheme-line-at-point")
      {:ok, ^name} = Core.create_buffer(name)
      :ok = Buffer.append(name, "alpha\nbeta\ngamma")
      :ok = Buffer.goto(name, 7)

      assert {:ok, "(2 \"beta\")"} =
               Session.eval(~s{(buffer-line-at-point "#{name}")})
    end

    test "eval-region evaluates buffer text in the live interpreter" do
      name = uniq("code")
      {:ok, _} = Core.create_buffer(name)
      Buffer.append(name, "(define answer 42)")

      {:ok, _} = Session.eval(~s{(eval-buffer "#{name}")})
      assert {:ok, "42"} = Session.eval("answer")

      # region: just the sub-expression "(define answer 42)" -> re-eval a slice
      {:ok, _} = Session.eval(~s{(eval-region "#{name}" 0 18)})
    end

    test "(message ...) lands in *Messages*" do
      {:ok, _} = Session.eval(~s{(message "hello echo area")})
      assert elem(Compos.Core.Session.eval("(messages-text)"), 1) =~ "hello echo area"
    end

    test "errors are reported, session survives" do
      assert {:error, msg} = Session.eval("(undefined-fn 1)")
      assert msg =~ "unbound"
      assert {:ok, "3"} = Session.eval("(+ 1 2)")
    end
  end

  defp eventually(fun, tries \\ 50)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, tries - 1)
    end
  end
end
