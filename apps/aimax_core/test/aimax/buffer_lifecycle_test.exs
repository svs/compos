defmodule Aimax.BufferLifecycleTest do
  use ExUnit.Case, async: false

  alias Aimax.Core.{Buffer, BufferStore, Editor, Events, Session}

  defp unique(label), do: "*#{label}-#{System.unique_integer([:positive])}*"

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, tries - 1)
    end
  end

  defp evict(name) do
    :ok = Buffer.checkpoint_now(name)
    [{pid, _}] = Registry.lookup(Aimax.Core.BufferRegistry, name)
    :ok = DynamicSupervisor.terminate_child(Aimax.Core.BufferSupervisor, pid)
  end

  test "a buffer owns its checkpoint; reads stay dormant and selection wakes literal state" do
    name = unique("checkpoint")
    {:ok, ^name} = Aimax.Core.create_buffer(name)
    Buffer.append(name, "literal transcript", source: :editor)
    Buffer.goto(name, 7)
    Buffer.set_local(name, "mode-name", "Fundamental")
    id = Buffer.eviction_info(name).id

    evict(name)
    assert eventually(fn -> not Buffer.exists?(name) end)
    assert BufferStore.known?(name)

    assert Buffer.text(name) == "literal transcript"
    assert Buffer.point(name) == 7
    refute Buffer.exists?(name)

    Editor.set_window_buffer(name)
    assert Buffer.exists?(name)
    assert Buffer.eviction_info(name).id == id
    Editor.set_window_buffer("*scratch*")
    Aimax.Core.kill_buffer(name)
  end

  test "an immutable buffer ref survives rename, eviction, and wake" do
    old = unique("ref-old")
    new = unique("ref-new")
    {:ok, ^old} = Aimax.Core.create_buffer(old, text: "stable")
    ref = Buffer.ref(old)
    id = Buffer.id(ref)

    assert {:ok, ^new} = Aimax.Core.rename_buffer(ref, new)
    refute Buffer.exists?(old)
    assert Buffer.exists?(ref)
    assert Buffer.name(ref) == new
    assert Buffer.text(ref) == "stable"
    assert Buffer.id(new) == id

    Events.subscribe(ref)
    Buffer.append(new, "!", source: :editor)
    assert_receive {:buffer_change, ^ref, %{inserted: "!"}}

    evict(new)
    assert eventually(fn -> not Buffer.exists?(new) end)
    refute Buffer.exists?(ref)
    assert Buffer.name(ref) == new
    assert Buffer.text(ref) == "stable!"
    refute Buffer.exists?(ref)

    Buffer.append(ref, " object", source: :editor)
    assert Buffer.exists?(ref)
    assert Buffer.name(ref) == new
    assert Buffer.text(new) == "stable! object"

    assert :ok = Aimax.Core.kill_buffer(ref)
    refute Buffer.exists?(ref)
    assert Buffer.name(ref) == nil
  end

  test "waking completes mode setup internally before returning" do
    name = unique("mode-wake")
    mode = "wake-mode-#{System.unique_integer([:positive])}"
    {:ok, ^name} = Aimax.Core.create_buffer(name)

    assert {:ok, _} =
             Session.eval(~s{
               (begin
                 (define-mode "#{mode}"
                   (lambda ()
                     (buffer-set-local! (current-buffer) 'wake-count
                       (+ 1 (or (buffer-local (current-buffer) 'wake-count) 0)))))
                 (with-current-buffer "#{name}" (lambda () (set-mode! "#{mode}"))))
             })

    assert Buffer.get_local(name, "wake-count") == 1
    Editor.set_window_buffer("*scratch*")
    evict(name)
    assert eventually(fn -> not Buffer.exists?(name) end)

    # A non-displaying buffer operation wakes and restores synchronously.
    Buffer.set_local(name, "poke", true)
    assert Buffer.get_local(name, "wake-count") == 2
    assert Editor.current_buffer() == "*scratch*"

    evict(name)
    assert eventually(fn -> not Buffer.exists?(name) end)

    # An Editor-originated wake restores after the server call, also before
    # its public API returns.
    Editor.set_window_buffer(name)
    assert Buffer.get_local(name, "wake-count") == 3

    Editor.set_window_buffer("*scratch*")
    evict(name)
    assert eventually(fn -> not Buffer.exists?(name) end)
    assert {:ok, _} = Session.eval(~s{(switch-to-buffer! "#{name}")})
    assert Buffer.get_local(name, "wake-count") == 4

    Editor.set_window_buffer("*scratch*")
    Aimax.Core.kill_buffer(name)
  end

  test "rename moves the file and carries stable buffer identity, windows, and history" do
    root = Path.join(System.tmp_dir!(), "aimax-rename-#{System.unique_integer([:positive])}")
    source = Path.join(root, "old.txt")
    destination = Path.join(root, "nested/new.txt")
    File.mkdir_p!(root)
    File.write!(source, "hello")
    {:ok, ^source} = Aimax.Core.open_file(source)
    Editor.set_window_buffer(source)
    id = Buffer.eviction_info(source).id

    assert {:ok, ^destination} = Aimax.Core.rename_file(source, destination)
    refute File.exists?(source)
    assert File.read!(destination) == "hello"
    refute Buffer.exists?(source)
    assert Buffer.exists?(destination)
    assert Buffer.path(destination) == destination
    assert Buffer.eviction_info(destination).id == id
    assert Editor.current_buffer() == destination
    assert destination in Editor.buffer_mru()

    Editor.set_window_buffer("*scratch*")
    Aimax.Core.kill_buffer(destination)
    File.rm_rf!(root)
  end

  test "idle buffers leave memory but remain in history and wake on selection" do
    old = Application.get_env(:aimax_core, :buffer_idle_timeout_ms)
    Application.put_env(:aimax_core, :buffer_idle_timeout_ms, 30)

    on_exit(fn ->
      Application.put_env(:aimax_core, :buffer_idle_timeout_ms, old || 24 * 60 * 60 * 1_000)
    end)

    name = unique("idle")
    {:ok, ^name} = Aimax.Core.create_buffer(name)
    Buffer.append(name, "sleeping", source: :editor)
    Buffer.touch(name)

    assert eventually(fn -> not Buffer.exists?(name) end)
    assert name in Editor.buffer_mru()
    refute Buffer.exists?(name)

    Editor.set_window_buffer(name)
    assert Buffer.exists?(name)
    assert Buffer.text(name) == "sleeping"

    Editor.set_window_buffer("*scratch*")
    Aimax.Core.kill_buffer(name)
  end

  test "intentional kill removes the durable checkpoint and history entry" do
    name = unique("kill")
    {:ok, ^name} = Aimax.Core.create_buffer(name)
    Buffer.append(name, "gone", source: :editor)
    :ok = Buffer.checkpoint_now(name)
    assert BufferStore.known?(name)

    :ok = Aimax.Core.kill_buffer(name)
    refute BufferStore.known?(name)
    refute name in Editor.buffer_mru()
  end

  test "renaming a dormant file updates its catalog without retaining a process" do
    root =
      Path.join(System.tmp_dir!(), "aimax-dormant-rename-#{System.unique_integer([:positive])}")

    source = Path.join(root, "before.txt")
    destination = Path.join(root, "after.txt")
    File.mkdir_p!(root)
    File.write!(source, "dormant")
    {:ok, ^source} = Aimax.Core.open_file(source)
    id = Buffer.eviction_info(source).id
    evict(source)
    assert eventually(fn -> not Buffer.exists?(source) end)

    assert {:ok, ^destination} = Aimax.Core.rename_file(source, destination)
    assert eventually(fn -> not Buffer.exists?(destination) end)
    refute BufferStore.known?(source)
    assert BufferStore.known?(destination)

    assert Buffer.text(destination) == "dormant"
    refute Buffer.exists?(destination)
    Editor.set_window_buffer(destination)
    assert Buffer.eviction_info(destination).id == id
    Editor.set_window_buffer("*scratch*")
    Aimax.Core.kill_buffer(destination)
    File.rm_rf!(root)
  end

  test "binary files open read-only and survive save and checkpoint byte-for-byte" do
    path = Path.join(System.tmp_dir!(), "aimax-binary-#{System.unique_integer([:positive])}.etf")
    bytes = <<0, 255, 131, 116, 1, 2, 128>>
    File.write!(path, bytes)

    assert {:ok, _} = Session.eval(~s{(visit "#{path}")})
    assert Editor.current_buffer() == path
    assert String.valid?(Buffer.text(path))
    assert Buffer.read_only?(path)
    assert Buffer.get_local(path, "binary-file") == true
    assert {:ok, ^path} = Buffer.save(path)
    assert File.read!(path) == bytes

    evict(path)
    assert eventually(fn -> not Buffer.exists?(path) end)
    Editor.set_window_buffer(path)
    assert Buffer.read_only?(path)
    assert Buffer.get_local(path, "binary-file") == true
    assert {:ok, ^path} = Buffer.save(path)
    assert File.read!(path) == bytes

    Editor.set_window_buffer("*scratch*")
    Aimax.Core.kill_buffer(path)
    File.rm!(path)
  end
end
