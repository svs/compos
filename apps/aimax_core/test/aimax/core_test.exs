defmodule Aimax.CoreTest do
  use ExUnit.Case

  alias Aimax.Core
  alias Aimax.Core.{Buffer, Events, Reactor, Rope, Session}

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
      path = Path.join(System.tmp_dir!(), "aimax-test-#{System.unique_integer()}.txt")
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
        Reactor.on_change(name, {:contains, "ERROR"}, fn changes -> send(me, {:fired, changes}) end,
          debounce: 30
        )

      Buffer.append(name, "INFO fine\n")
      Buffer.append(name, "ERROR one\n")
      Buffer.append(name, "ERROR two\n")

      assert_receive {:fired, changes}, 500
      assert Enum.map(changes, & &1.inserted) == ["ERROR one\n", "ERROR two\n"]
      refute_receive {:fired, _}, 100
    end

    test "ignores agent-sourced edits by default (loop prevention)" do
      name = uniq("loop")
      {:ok, _} = Core.create_buffer(name)
      me = self()

      {:ok, _} = Reactor.on_change(name, :any, fn changes -> send(me, {:fired, changes}) end)

      Buffer.append(name, "agent output", source: {:agent, "x"})
      refute_receive {:fired, _}, 100

      Buffer.append(name, "human edit")
      assert_receive {:fired, [%{inserted: "human edit"}]}, 500
    end
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

    test "eval-region evaluates buffer text in the live interpreter" do
      name = uniq("code")
      {:ok, _} = Core.create_buffer(name)
      Buffer.append(name, "(define answer 42)")

      {:ok, _} = Session.eval(~s{(eval-buffer "#{name}")})
      assert {:ok, "42"} = Session.eval("answer")

      # region: just the sub-expression "(define answer 42)" -> re-eval a slice
      {:ok, _} = Session.eval(~s{(eval-region "#{name}" 0 18)})
    end

    test "(message ...) lands in *messages*" do
      {:ok, _} = Session.eval(~s{(message "hello echo area")})
      assert Buffer.text("*messages*") =~ "hello echo area"
    end

    test "errors are reported, session survives" do
      assert {:error, msg} = Session.eval("(undefined-fn 1)")
      assert msg =~ "unbound"
      assert {:ok, "3"} = Session.eval("(+ 1 2)")
    end
  end
end
