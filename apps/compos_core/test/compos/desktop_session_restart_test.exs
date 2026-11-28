defmodule Compos.DesktopSessionRestartTest do
  @moduledoc """
  Every persisted global lives in a Scheme variable, so the Session owns
  them all. When the Session dies, its replacement boots a new interpreter
  holding only the defvar defaults, while the frames and buffers on the
  Elixir side carry on unchanged. The desktop must put the values back, and
  it must never write the defaults over the file in the meantime.

  On 2026-09-11 it wrote them: one autosave replaced 35 group records, the
  group graveyard, both connector catalogs and every history with the
  empty set.
  """

  use ExUnit.Case

  alias Compos.Core.{Buffer, Desktop, Editor, Session}

  defp eventually(fun, tries \\ 200) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true ->
        Process.sleep(50)
        eventually(fun, tries - 1)
    end
  end

  defp group_record?(name) do
    case Session.eval(~s{(and (member "#{name}" (map group-record-name *group-records*)) #t)}) do
      {:ok, "#t"} -> true
      _ -> false
    end
  catch
    _, _ -> false
  end

  # A replacement Session registers its name before init/1 loads the stdlib.
  # A call queues behind that load, so it returns only once the new
  # interpreter is published.
  defp booted?(dead) do
    case Process.whereis(Session) do
      nil -> false
      ^dead -> false
      pid -> GenServer.call(pid, :await_boot, 60_000) != nil
    end
  catch
    :exit, _ -> false
  end

  # The replacement publishes only when its load ends, so a poll inside that
  # window must see ready? answer false. Polling must never call booted?,
  # which blocks until the load is over and so always misses the window.
  defp unpublished?(tries \\ 400) do
    cond do
      not Session.ready?() -> true
      tries == 0 -> false
      true ->
        Process.sleep(5)
        unpublished?(tries - 1)
    end
  end

  # Desktop recovers asynchronously. A test that drives its state by hand
  # must start from a quiet process, or a reseed left over from an earlier
  # test clears the flag it just set.
  defp settle(tries \\ 400) do
    quiet? =
      case Process.whereis(Desktop) do
        nil ->
          false

        pid ->
          :sys.get_state(pid).scheme_stale? == false and
            elem(Process.info(pid, :message_queue_len), 1) == 0
      end

    cond do
      quiet? -> true
      tries == 0 -> false
      true ->
        Process.sleep(25)
        settle(tries - 1)
    end
  end

  defp desktop_file do
    dir = Path.join(System.tmp_dir!(), "desktop-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    previous = Application.get_env(:compos_core, :desktop_path)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:compos_core, :desktop_path, previous),
        else: Application.delete_env(:compos_core, :desktop_path)

      File.rm_rf(dir)
    end)

    path = Path.join(dir, "desktop.etf")
    Application.put_env(:compos_core, :desktop_path, path)
    path
  end

  test "a save writes the held globals while the Scheme world has not taken them back" do
    assert settle()
    path = desktop_file()
    held = [[{:sym, "registers"}, [["a", "the held value"]]]]

    on_exit(fn ->
      :sys.replace_state(Desktop, fn state -> %{state | scheme_stale?: false} end)
    end)

    :sys.replace_state(Desktop, fn state ->
      %{state | globals: held, scheme_stale?: true}
    end)

    assert :ok = Desktop.save_now()

    assert %{globals: ^held} = path |> File.read!() |> :erlang.binary_to_term()
  end

  test "a save reads the Scheme world again once it holds the globals" do
    assert settle()
    path = desktop_file()

    :sys.replace_state(Desktop, fn state ->
      %{state | globals: [[{:sym, "registers"}, [["a", "stale"]]]], scheme_stale?: false}
    end)

    assert :ok = Desktop.save_now()

    %{globals: globals} = path |> File.read!() |> :erlang.binary_to_term()
    keys = for [{:sym, key}, _value] <- globals, do: key
    assert "groups-v2" in keys
  end

  # Kill only a booted Session: a kill during the stdlib load is a second
  # crash inside one boot, and quick crashes spend the supervisor's
  # restart intensity.
  defp kill_session do
    assert eventually(fn -> Session.ready?() and booted?(nil) end)
    session = Process.whereis(Session)
    ref = Process.monitor(session)
    Process.exit(session, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 10_000
    session
  end

  defp messages_since(id) do
    for {mid, _ts, _level, _src, _grp, _proj, text} <- Session.messages(), mid > id, do: text
  end

  @tag timeout: 180_000
  test "no caller gets the dead interpreter while the replacement loads" do
    assert settle()
    dead = kill_session()

    # The window is the whole stdlib load, about 2.5s. Nothing may read a
    # published handle during it: the old environment table is dropped
    # thirty seconds later, so every write against it is thrown away.
    assert unpublished?(), "the dead interpreter stayed published"

    assert eventually(fn -> booted?(dead) end)
    assert Session.ready?()
  end

  @tag timeout: 180_000
  test "an open prompt does not survive the restart as a dead closure" do
    {:ok, _} = Session.eval(~s{(read-string "probe: " (lambda (s) s))})
    assert Editor.render_state().minibuffer

    dead = kill_session()
    assert eventually(fn -> booted?(dead) end)

    assert eventually(fn -> is_nil(Editor.render_state().minibuffer) end),
           "the prompt stayed open with an on_confirm in the dead environment"
  end

  @tag timeout: 180_000
  test "every live buffer gets its Scheme runtime rebuilt, not only the visible ones" do
    assert settle()
    name = "*restart-offscreen-#{System.unique_integer([:positive])}*"
    on_exit(fn -> if Buffer.exists?(name), do: Compos.Core.kill_buffer(name) end)

    {:ok, _} =
      Session.eval(~s{(with-current-buffer (buffer-create "#{name}")
                        (lambda () (set-mode! "text-mode")))})

    assert Buffer.exists?(name)
    shown = Editor.list_windows_all() |> Enum.map(fn {_w, b, _f} -> b end)
    refute name in shown

    # The local map is Editor state, so it outlives the crash on its own.
    # Clearing it first makes the rebuild the only thing that can put it
    # back: set-mode! is what calls use-local-map!, and set-mode! runs only
    # from restore-buffer-runtime!.
    assert Editor.buffer_local_map(name) == "text-mode-map"
    {:ok, _} = Session.eval(~s{(clear-local-map! "#{name}")})
    refute Editor.buffer_local_map(name) == "text-mode-map"

    mark = System.unique_integer([:positive, :monotonic])
    dead = kill_session()
    assert eventually(fn -> booted?(dead) end)

    assert eventually(fn -> Editor.buffer_local_map(name) == "text-mode-map" end),
           "a live buffer no window shows never had its mode setup run again"

    assert eventually(fn ->
             Enum.any?(
               messages_since(mark),
               &String.starts_with?(&1, "The Scheme world restarted.")
             )
           end),
           "the editor never reported the restart in *Messages*"

    # The monitor and the Session's own notice both point at one death, so
    # one death must cost one recovery, not two sweeps of every buffer.
    Process.sleep(1_500)

    reports =
      Enum.count(messages_since(mark), &String.starts_with?(&1, "The Scheme world restarted."))

    assert reports == 1, "one Session death recovered #{reports} times"
  end

  test "a hot reload that adds a state key does not break the desktop" do
    assert settle()

    # what the previous module built, before the Session keys existed
    :sys.replace_state(Desktop, fn state -> Map.take(state, [:timer, :globals]) end)

    path = desktop_file()
    assert :ok = Desktop.save_now()
    assert %{globals: globals} = path |> File.read!() |> :erlang.binary_to_term()
    assert is_list(globals)

    # and the monitor arms itself, without waiting for this process to restart
    assert eventually(fn -> match?({_pid, _ref}, :sys.get_state(Desktop).session) end)
  end

  @tag timeout: 180_000
  test "the group records come back after the Session dies" do
    name = "restart-probe-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      Session.eval(~s{(group-record-delete! "#{name}")})
    end)

    {:ok, _} = Session.eval(~s{(group-record-create! "#{name}")})
    assert group_record?(name)

    # the desktop reads the globals on every save, so this is where it takes
    # its copy of the record
    assert :ok = Desktop.save_now()

    session = kill_session()

    # Session.ready? reads the published handle, and that is still the dead
    # interpreter until the replacement finishes its own init. Wait for the
    # new process to answer instead.
    assert eventually(fn -> booted?(session) end)

    # the new interpreter starts with (defvar '*group-records* '())
    assert eventually(fn -> group_record?(name) end),
           "the desktop did not put the group records back into the new interpreter"
  end
end
