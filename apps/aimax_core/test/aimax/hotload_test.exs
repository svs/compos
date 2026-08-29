defmodule Aimax.HotloadTest.NoBackend do
  @moduledoc """
  A watcher backend that watches nothing. The test sends `:file_event`
  itself, so the filter and the debounce run with no fsevents underneath.
  """

  def start_link(_opts), do: Agent.start_link(fn -> :watching end)
  def subscribe(_pid), do: :ok
end

defmodule Aimax.HotloadTest.Recompiler do
  @moduledoc "The recompiler seam: it reports to the test instead of compiling."

  def ok(pid) do
    send(pid, :recompiled)
    :ok
  end

  def fail(pid) do
    send(pid, :recompiled)
    {:error, "== Compilation error in file lib/x.ex ==\n** (SyntaxError) missing terminator"}
  end
end

defmodule Aimax.HotloadTest do
  @moduledoc """
  Aimax.Core.Hotload: a saved file reaches the running daemon.

  fsevents coalesces and replays, so counting real filesystem events is a
  coin toss. The debounce and the filter run against injected `:file_event`
  messages instead — the same code path the backend drives.
  """

  use ExUnit.Case

  alias Aimax.Core.{Hotload, Session}

  # 200 ms debounce; give the flush room, then prove no second one follows
  @settle 1_500

  setup do
    Application.put_env(:aimax_core, :fs_backend, Aimax.HotloadTest.NoBackend)
    Application.put_env(:aimax_core, :hotload_recompile, {Aimax.HotloadTest.Recompiler, :ok, [self()]})

    on_exit(fn ->
      Application.delete_env(:aimax_core, :fs_backend)
      Application.delete_env(:aimax_core, :hotload_recompile)
    end)

    :ok
  end

  defp start_hotload do
    name = :"hotload_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: name, start: {Hotload, :start_link, [[name: name, roots: [tmp()]]]}})
    name
  end

  defp tmp, do: System.tmp_dir!()

  defp save(server, path) do
    send(server, {:file_event, self(), {path, [:modified, :closed]}})
    path
  end

  defp scm(name, body) do
    path = Path.join(tmp(), name)
    File.write!(path, body)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # The reload is asynchronous by design: the save arms a debounce. Poll for
  # the value the reload should leave, never for "any answer" — the old
  # binding is still there and answers at once.
  defp eventually(fun, want, tries \\ 60) do
    case fun.() do
      ^want ->
        want

      other ->
        if tries == 0 do
          other
        else
          Process.sleep(50)
          eventually(fun, want, tries - 1)
        end
    end
  end

  describe "the filter" do
    test "names the three source kinds and nothing else" do
      assert Hotload.source?("/p/apps/aimax_core/priv/packages/git.scm")
      assert Hotload.source?("/p/apps/aimax_ui/lib/aimax/ui/editor_live.ex")
      assert Hotload.source?("/p/apps/aimax_ui/lib/aimax/ui/page.heex")

      refute Hotload.source?("/p/apps/aimax_core/lib/aimax/core/native/thing.rs")
      refute Hotload.source?("/p/README.md")
      refute Hotload.source?("/p/apps/aimax_core/priv/packages")
    end

    test "refuses a partial write, so a reload never sees half a file" do
      # Emacs writes a lock file and a backup beside the real one
      refute Hotload.source?("/p/apps/aimax_core/priv/.#git.scm")
      refute Hotload.source?("/p/apps/aimax_core/priv/git.scm~")
      refute Hotload.source?("/p/apps/aimax_core/priv/#git.scm#")
    end

    test "refuses build output and session state, which the daemon writes constantly" do
      refute Hotload.source?("/p/_build/dev/lib/aimax_core/priv/editor.scm")
      refute Hotload.source?("/p/deps/phoenix/lib/phoenix.ex")
      refute Hotload.source?("/p/apps/aimax_core/native/aimax_ts/target/debug/build.ex")
      refute Hotload.source?("/p/.git/COMMIT_EDITMSG.ex")
      refute Hotload.source?("/home/u/.aimax/buffers/scratch.scm")
      refute Hotload.source?("/home/u/.aimax/chats/a/turn.scm")
    end

    test "refuses a tree-sitter query, which is Scheme only to look at" do
      # installing a grammar drops this beside the shared object. Read as
      # editor Scheme it answers "unbound variable: [" for the query's
      # alternation, then "unbound variable: atx_heading" for a node name.
      refute Hotload.source?("/home/u/.aimax/grammars/markdown-highlights.scm")
      refute Hotload.source?("/home/u/.aimax/grammars/src/markdown/queries/highlights.scm")
    end
  end

  describe "the debounce" do
    test "one burst of saves is one recompile" do
      server = start_hotload()

      for f <- ~w(a.ex b.ex c.heex),
          do: save(server, Path.join(tmp(), "zz-hotload-#{f}"))

      assert_receive :recompiled, @settle
      refute_receive :recompiled, 500
    end

    test "a burst with no Elixir in it never calls the compiler" do
      server = start_hotload()
      path = scm("zz-hotload-quiet.scm", "(define zz-hotload-quiet 1)\n")
      save(server, path)

      assert {:ok, "1"} = eventually(fn -> Session.eval("zz-hotload-quiet") end, {:ok, "1"})
      refute_received :recompiled
    end
  end

  describe "reloading" do
    test "a saved .scm reaches the live session" do
      server = start_hotload()
      path = scm("zz-hotload-mark.scm", "(define zz-hotload-mark 1)\n")

      save(server, path)
      assert {:ok, "1"} = eventually(fn -> Session.eval("zz-hotload-mark") end, {:ok, "1"})

      # and the next save carries only what changed
      File.write!(path, "(define zz-hotload-mark 2)\n")
      save(server, path)
      assert {:ok, "2"} = eventually(fn -> Session.eval("zz-hotload-mark") end, {:ok, "2"})
    end

    test "reload/2 reports what it did" do
      server = start_hotload()
      path = scm("zz-hotload-report.scm", "(define zz-hotload-report 1)\n(define zz-report-b 2)\n")

      report = Hotload.reload([path], server)

      assert report =~ "1 file"
      assert report =~ "2 forms"
    end

    test "a compile failure is reported, and the daemon stays up" do
      Application.put_env(
        :aimax_core,
        :hotload_recompile,
        {Aimax.HotloadTest.Recompiler, :fail, [self()]}
      )

      server = start_hotload()
      report = Hotload.reload([Path.join(tmp(), "zz-hotload-broken.ex")], server)

      assert report =~ "compile failed"
      assert Process.alive?(Process.whereis(server))
      # the compile ran out of process: the VM keeps every module it had
      assert :code.is_loaded(Aimax.Core.Editor) != false
      assert :code.is_loaded(Aimax.Core.Buffer) != false
    end

    # A primitive is an anonymous fun captured from Aimax.Core.SchemeAPI when
    # the session booted. Recompiling that module purges the version the funs
    # came from, and the next Scheme call raises "function #Function<...> is
    # invalid, likely because it points to an old version of the code" — the
    # whole editor dead from one dev recompile. Every recompile must rebind.
    test "a recompile rebinds the Scheme primitives" do
      server = start_hotload()
      :persistent_term.put({Session, :primitive_stamp}, :stale)
      assert Session.primitives_stale?()

      assert Hotload.reload([Path.join(tmp(), "zz-hotload-touch.ex")], server) =~ "recompiled"

      refute Session.primitives_stale?(), "the recompile left the primitives unbound"
      assert {:ok, _} = Session.eval("(buffer-list)")
    end

    test "rebinding keeps every primitive callable" do
      :persistent_term.put({Session, :primitive_stamp}, :stale)

      assert :ok = Session.refresh_primitives_if_stale()
      refute Session.primitives_stale?()

      # a builtin, a SchemeAPI primitive, and a Session primitive
      assert {:ok, "3"} = Session.eval("(+ 1 2)")
      assert {:ok, _} = Session.eval(~s{(buffer-text "*scratch*")})
      assert {:ok, _} = Session.eval("(command-names)")
    end

    test "a rebind keeps the stdlib's alias and wrapper over a Session primitive" do
      :persistent_term.put({Session, :primitive_stamp}, :stale)
      assert :ok = Session.refresh_primitives_if_stale()

      # editor.scm aliases define-command, then wraps the same name in
      # Scheme. The alias must hold a live fun, and the wrapper must still
      # be the wrapper. The wrapper returns the name; the raw one returns
      # void, so the printed value says which one ran.
      assert {:ok, ~s{"zz-rebind-probe"}} =
               Session.eval(~s{(define-command "zz-rebind-probe" "probe" (lambda () 1))}),
             "the rebind put the raw primitive back over editor.scm's wrapper"

      assert {:ok, ""} =
               Session.eval(~s{(define-command--raw "zz-rebind-raw" (lambda () 1))}),
             "the alias of a Session primitive kept a purged fun"
    end

    test "a Scheme error is reported, and the daemon stays up" do
      server = start_hotload()
      path = scm("zz-hotload-bad.scm", "(this-name-does-not-exist)\n")

      report = Hotload.reload([path], server)

      assert report =~ "reload failed"
      assert Process.alive?(Process.whereis(server))
    end
  end

  # An in-process `mix compile` unloads a stale module before it compiles
  # the new one. Aimax.Core.Editor died in that gap twice on 2026-08-29:
  # once when the compile failed, once when a caller arrived during it.
  # Compile.swap/1 loads the new beam first and purges the old one after,
  # so a caller always finds a current version.
  describe "the module swap" do
    alias Aimax.Core.Hotload.Compile

    setup do
      dir = Path.join(tmp(), "zz-swap-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      true = Code.append_path(dir)
      mod = :"zz_swap_probe_#{System.unique_integer([:positive])}"

      on_exit(fn ->
        :code.purge(mod)
        :code.delete(mod)
        Code.delete_path(dir)
        File.rm_rf!(dir)
      end)

      %{dir: dir, mod: mod}
    end

    # an Erlang module compiled from forms: `:compile.forms` writes nothing
    # into this VM, so the beam on disk can differ from the module loaded
    defp write_probe(dir, mod, value) do
      forms = [
        {:attribute, 1, :module, mod},
        {:attribute, 1, :export, [v: 0]},
        {:function, 1, :v, 0, [{:clause, 1, [], [], [{:integer, 1, value}]}]}
      ]

      {:ok, ^mod, bin} = :compile.forms(forms, [])
      File.write!(Path.join(dir, "#{mod}.beam"), bin)
    end

    test "a changed beam replaces the loaded module", %{dir: dir, mod: mod} do
      write_probe(dir, mod, 1)
      assert Code.ensure_loaded?(mod)
      assert mod.v() == 1

      write_probe(dir, mod, 2)
      assert %{reloaded: [^mod], removed: []} = Compile.swap([dir])
      assert mod.v() == 2
    end

    test "an unchanged beam is left alone", %{dir: dir, mod: mod} do
      write_probe(dir, mod, 1)
      assert Code.ensure_loaded?(mod)

      assert %{reloaded: [], removed: []} = Compile.swap([dir])
    end

    test "a module the VM never loaded needs no swap", %{dir: dir, mod: mod} do
      write_probe(dir, mod, 1)
      assert %{reloaded: [], removed: []} = Compile.swap([dir])
      assert mod.v() == 1
    end

    test "a caller never finds the module missing during a swap", %{dir: dir, mod: mod} do
      write_probe(dir, mod, 1)
      assert Code.ensure_loaded?(mod)

      caller =
        Task.async(fn ->
          hammer(mod, %{errors: [], values: MapSet.new()})
        end)

      # swap the module repeatedly while the caller hammers it
      for value <- 2..12 do
        write_probe(dir, mod, value)
        assert %{reloaded: [^mod]} = Compile.swap([dir])
      end

      send(caller.pid, :stop)
      %{errors: errors, values: values} = Task.await(caller)

      assert errors == [], "a caller saw: #{inspect(Enum.take(errors, 3))}"
      assert MapSet.member?(values, 12)
      assert MapSet.subset?(values, MapSet.new(1..12))
    end

    defp hammer(mod, acc) do
      receive do
        :stop -> acc
      after
        0 ->
          acc =
            try do
              %{acc | values: MapSet.put(acc.values, mod.v())}
            rescue
              e -> %{acc | errors: [Exception.message(e) | acc.errors]}
            end

          hammer(mod, acc)
      end
    end

    test "a removed beam unloads the module", %{dir: dir, mod: mod} do
      write_probe(dir, mod, 1)
      assert Code.ensure_loaded?(mod)

      File.rm!(Path.join(dir, "#{mod}.beam"))
      assert %{reloaded: [], removed: [^mod]} = Compile.swap([dir])
      assert :code.is_loaded(mod) == false
      refute Code.ensure_loaded?(mod)
    end

    test "the project ebins are the umbrella apps" do
      ebins = Compile.ebins()
      assert Enum.any?(ebins, &String.ends_with?(&1, "/aimax_core/ebin"))
      assert Enum.all?(ebins, &File.dir?/1)
    end
  end
end
