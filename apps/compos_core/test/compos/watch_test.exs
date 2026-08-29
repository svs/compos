defmodule Compos.WatchTest.NoBackend do
  @moduledoc """
  A watcher backend that watches nothing. The test sends `:file_event`
  itself, so the debounce and the filter run with no fsevents underneath.
  """

  def start_link(_opts), do: Agent.start_link(fn -> :watching end)
  def subscribe(_pid), do: :ok
end

defmodule Compos.WatchTest do
  @moduledoc """
  Compos.Core.Watch.

  Each test starts its own named watcher with `start_supervised!`, because
  the umbrella runs every app's tests in one BEAM and the global watcher
  belongs to the running editor.

  Two kinds of test, for a reason. macOS fsevents coalesces: three writes in
  one directory can arrive as one event, and a later report can arrive a
  second apart. Counting against it is a coin toss. So the debounce and the
  `.git` filter run against injected `:file_event` messages, which is the
  same code path the backend drives, and the filesystem tests only assert
  that a real write reaches a real subscriber.
  """

  use ExUnit.Case

  alias Compos.Core.{Events, Session, Watch}

  # 150 ms debounce; give a real fsevent room before we decide nothing came
  @settle 700

  setup do
    dir = Path.join(System.tmp_dir!(), "compos-watch-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "sub/.git/objects/aa"))
    File.mkdir_p!(Path.join(dir, ".git/refs/heads"))

    server = :"watch_#{System.unique_integer([:positive])}"
    start_supervised!({Watch, name: server})

    Events.subscribe_fs()
    on_exit(fn -> Events.unsubscribe_fs() end)
    on_exit(fn -> File.rm_rf!(dir) end)

    # the event names the root as Watch expanded it, not as fsevents saw it
    %{dir: dir, real: Path.expand(dir), server: server}
  end

  defp touch(dir, rel, body \\ "x") do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end

  # Watch with the silent backend, so every event the test sees is one the
  # test sent. fsevents replays what it buffered before the subscription, and
  # no amount of settling makes that reliable.
  defp watch_quietly(ctx, opts \\ []) do
    Application.put_env(:compos_core, :fs_backend, Compos.WatchTest.NoBackend)
    on_exit(fn -> Application.delete_env(:compos_core, :fs_backend) end)

    {:ok, root} = Watch.watch(ctx.dir, ctx.server, opts)
    {root, backend(ctx.server)}
  end

  # the backend pid Watch subscribed to, so a test can deliver the same
  # message the backend delivers
  defp backend(server) do
    [{pid, _root}] = server |> :sys.get_state() |> Map.fetch!(:pids) |> Map.to_list()
    pid
  end

  defp event(ctx, pid, rel) do
    send(ctx.server, {:file_event, pid, {Path.join(ctx.real, rel), [:modified]}})
  end

  # swallow events until the mailbox stays empty for longer than the debounce
  # window, so the next assertion starts from real silence
  defp quiet do
    receive do
      {:fs_changed, _} -> quiet()
    after
      400 -> :ok
    end
  end

  # --- debounce and filtering, driven directly -------------------------------

  test "a burst becomes one event, and the next burst its own", ctx do
    {root, pid} = watch_quietly(ctx)

    event(ctx, pid, "a.txt")
    event(ctx, pid, "b.txt")
    event(ctx, pid, "c.txt")

    assert_receive {:fs_changed, ^root}, @settle
    refute_receive {:fs_changed, _}, @settle

    event(ctx, pid, "d.txt")
    assert_receive {:fs_changed, ^root}, @settle
    refute_receive {:fs_changed, _}, @settle
  end

  test "a long stream of writes still refreshes before it ends", ctx do
    {root, pid} = watch_quietly(ctx)

    # events closer together than the debounce window would reset the timer
    # forever; the 1 s ceiling broadcasts anyway
    task =
      Task.async(fn ->
        Enum.each(1..40, fn n ->
          event(ctx, pid, "stream-#{n}.txt")
          Process.sleep(50)
        end)
      end)

    assert_receive {:fs_changed, ^root}, 1_500
    Task.await(task)
  end

  # a repository is a deep watch: the diff buffer follows the whole tree
  test "git's object churn is silent, the index and the refs are not", ctx do
    {_root, pid} = watch_quietly(ctx, deep: true)

    event(ctx, pid, "sub/.git/objects/aa/bbccdd")
    event(ctx, pid, ".git/objects/ee/ff0011")
    event(ctx, pid, ".git/index.lock")
    event(ctx, pid, ".git/COMMIT_EDITMSG")
    refute_receive {:fs_changed, _}, @settle

    for path <- [".git/index", ".git/HEAD", ".git/refs/heads/main", "sub/.git/index"] do
      event(ctx, pid, path)
      assert_receive {:fs_changed, _}, @settle, "expected #{path} to make the tree stale"
      quiet()
    end
  end

  test "a watch is shallow: a change below a child directory is silent", ctx do
    {root, pid} = watch_quietly(ctx)

    event(ctx, pid, "sub/deep.txt")
    event(ctx, pid, "sub/deeper/deep.txt")
    refute_receive {:fs_changed, _}, @settle

    event(ctx, pid, "top.txt")
    assert_receive {:fs_changed, ^root}, @settle
  end

  test "a deep reference sees the whole tree, and its leave ends that", ctx do
    {root, pid} = watch_quietly(ctx)
    {:ok, ^root} = Watch.watch(ctx.dir, ctx.server, deep: true)

    event(ctx, pid, "sub/deep.txt")
    assert_receive {:fs_changed, ^root}, @settle
    quiet()

    :ok = Watch.unwatch(ctx.dir, ctx.server, deep: true)
    assert Watch.watching(ctx.server) == [root]

    event(ctx, pid, "sub/deep.txt")
    refute_receive {:fs_changed, _}, @settle

    event(ctx, pid, "top.txt")
    assert_receive {:fs_changed, ^root}, @settle
  end

  test "the Scheme handler runs once at a time per root, then once more for a burst during the run",
       ctx do
    {root, pid} = watch_quietly(ctx)
    buf = "*watch-coalesce*"
    Compos.Core.create_buffer(buf)
    on_exit(fn -> Compos.Core.kill_buffer(buf) end)

    # a slow handler: one second per run, so three bursts land inside one run
    {:ok, _} =
      Session.eval("""
      (on-fs-change!
        (lambda (r)
          (if (equal? r "#{ctx.real}")
              (begin
                (buffer-append! "#{buf}" "run\\n")
                (shell-command->string "sleep 1")))))
      """)

    for rel <- ["a.txt", "b.txt", "c.txt"] do
      event(ctx, pid, rel)
      assert_receive {:fs_changed, ^root}, @settle
      Process.sleep(200)
    end

    # the first burst starts a run, the second marks the root pending, the
    # third changes nothing: two runs in all, never three
    assert wait_for(
             fn ->
               Process.sleep(500)
               Compos.Core.Buffer.text(buf) == "run\nrun\n"
             end,
             10
           )

    Process.sleep(1_500)
    assert Compos.Core.Buffer.text(buf) == "run\nrun\n"
  end

  test "an event for an unwatched backend is ignored", ctx do
    send(ctx.server, {:file_event, self(), {Path.join(ctx.real, "a.txt"), [:modified]}})

    refute_receive {:fs_changed, _}, @settle
    assert Watch.watching(ctx.server) == []
  end

  # --- the subscription itself -----------------------------------------------

  test "watching is refcounted and normalizes the root", ctx do
    {:ok, root} = Watch.watch(ctx.dir, ctx.server)
    assert {:ok, ^root} = Watch.watch(Path.join(ctx.dir, "sub/.."), ctx.server)
    assert Watch.watching(ctx.server) == [root]

    # one reference left: still watching
    :ok = Watch.unwatch(ctx.dir, ctx.server)
    assert Watch.watching(ctx.server) == [root]

    :ok = Watch.unwatch(ctx.dir, ctx.server)
    assert Watch.watching(ctx.server) == []
  end

  test "unwatching a root nobody watches is quiet", ctx do
    assert :ok = Watch.unwatch(ctx.dir, ctx.server)
    assert Watch.watching(ctx.server) == []
  end

  test "a path that is not a directory is refused", ctx do
    touch(ctx.dir, "file.txt")

    assert {:error, msg} = Watch.watch(Path.join(ctx.dir, "file.txt"), ctx.server)
    assert msg =~ "not a directory"
    assert Watch.watching(ctx.server) == []
  end

  # --- against the real filesystem -------------------------------------------

  test "a real write on disk reaches a subscriber", ctx do
    {:ok, root} = Watch.watch(ctx.dir, ctx.server)

    # fsevents arms a moment after the subscription and coalesces after that,
    # so write until it answers rather than assume one write is enough
    assert wait_for(
             fn ->
               touch(ctx.dir, "real.txt", "#{System.unique_integer()}")

               receive do
                 {:fs_changed, ^root} -> true
               after
                 400 -> false
               end
             end,
             15
           )
  end

  # --- the Scheme surface ----------------------------------------------------

  test "on-fs-change! handlers run with the root", ctx do
    buf = "*watch-test*"
    Compos.Core.create_buffer(buf)

    {:ok, _} = Session.eval(~s[(watch-path! "#{ctx.dir}")])

    on_exit(fn ->
      Session.eval(~s[(unwatch-path! "#{ctx.dir}")])
      Compos.Core.kill_buffer(buf)
    end)

    {:ok, printed} = Session.eval("(watched-paths)")
    assert printed =~ ctx.real

    # the handler list is global and lives for the session, so keep this one
    # inert for every root but ours
    {:ok, _} =
      Session.eval("""
      (on-fs-change!
        (lambda (root)
          (if (equal? root "#{ctx.real}")
              (buffer-append! "#{buf}" (string-append root "\\n")))))
      """)

    assert wait_for(
             fn ->
               touch(ctx.dir, "scheme.txt", "#{System.unique_integer()}")
               Process.sleep(400)
               Compos.Core.Buffer.text(buf) =~ ctx.real
             end,
             15
           )
  end

  defp wait_for(fun, tries)
  defp wait_for(_fun, 0), do: false
  defp wait_for(fun, tries), do: fun.() or wait_for(fun, tries - 1)
end
