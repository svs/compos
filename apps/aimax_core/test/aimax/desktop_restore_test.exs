defmodule Aimax.DesktopRestoreTest do
  @moduledoc """
  R3's round-trip suite: the frontend is a function of daemon state, so a
  daemon restart gives back what was on screen. Each R3 slice adds its
  round-trip here.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Desktop, Editor, KeyDispatch, Session}

  defp leaves(%{type: :leaf} = leaf), do: [leaf]
  defp leaves(%{type: :split, children: children}), do: Enum.flat_map(children, &leaves/1)

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp eventually(fun, tries \\ 50) do
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

  # A restart/idle eviction keeps the buffer's checkpoint. `kill-buffer` is
  # intentionally different now: it deletes that durable identity.
  defp evict(name) do
    :ok = Buffer.checkpoint_now(name)
    [{pid, _}] = Registry.lookup(Aimax.Core.BufferRegistry, name)
    :ok = DynamicSupervisor.terminate_child(Aimax.Core.BufferSupervisor, pid)
    assert eventually(fn -> not Buffer.exists?(name) end)
  end

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    :ok
  end

  test "desktop-clear saves modified files and removes the cleared desktop" do
    n = System.unique_integer([:positive])
    path = Path.join(System.tmp_dir!(), "desktop-clear-#{n}.txt")
    clean = "*desktop-clear-#{n}*"
    File.write!(path, "saved\n")

    on_exit(fn ->
      File.rm(path)
      for b <- [path, clean], Buffer.exists?(b), do: Aimax.Core.kill_buffer(b)
    end)

    eval!(~s{(begin (visit "#{path}")
                    (insert! "agent ")
                    (buffer-create "#{clean}"))})

    KeyDispatch.handle_key("M-x")
    Enum.each(String.graphemes("desktop-clear"), &KeyDispatch.handle_key/1)
    KeyDispatch.handle_key("RET")

    assert Editor.render_state().minibuffer.prompt ==
             "Save #{path}? (y, n, A all, N none) "

    KeyDispatch.handle_key("y")

    assert File.read!(path) == "agent saved\n"
    refute Buffer.exists?(path)
    refute Buffer.exists?(clean)
    assert Editor.current_buffer() == "*scratch*"
    assert eval!("*minibuffer-history*") == "()"

    assert :ok = Desktop.save_now()
    assert :ok = Desktop.restore_now()
    refute Buffer.exists?(path)
    refute Buffer.exists?(clean)
  end

  test "desktop-clear keeps a modified file that the user does not save" do
    n = System.unique_integer([:positive])
    path = Path.join(System.tmp_dir!(), "desktop-keep-#{n}.txt")
    clean = "*desktop-doomed-#{n}*"
    File.write!(path, "saved\n")

    on_exit(fn ->
      File.rm(path)
      for b <- [path, clean], Buffer.exists?(b), do: Aimax.Core.kill_buffer(b)
    end)

    eval!(~s{(begin (visit "#{path}")
                    (insert! "unsaved ")
                    (buffer-create "#{clean}"))})

    eval!(~s{(run-command "desktop-clear")})
    KeyDispatch.handle_key("n")

    assert Buffer.exists?(path)
    assert Buffer.text(path) == "unsaved saved\n"
    assert File.read!(path) == "saved\n"
    refute Buffer.exists?(clean)
  end

  test "C-g quits desktop-clear without killing buffers" do
    n = System.unique_integer([:positive])
    path = Path.join(System.tmp_dir!(), "desktop-quit-#{n}.txt")
    clean = "*desktop-quit-#{n}*"
    File.write!(path, "saved\n")

    on_exit(fn ->
      File.rm(path)
      for b <- [path, clean], Buffer.exists?(b), do: Aimax.Core.kill_buffer(b)
    end)

    eval!(~s{(begin (visit "#{path}")
                    (insert! "unsaved ")
                    (buffer-create "#{clean}")
                    (run-command "desktop-clear"))})

    KeyDispatch.handle_key("C-g")

    refute Editor.render_state().minibuffer
    assert Buffer.exists?(path)
    assert Buffer.exists?(clean)
    assert Buffer.text(path) == "unsaved saved\n"
    assert File.read!(path) == "saved\n"
  end

  test "A saves every remaining file and N saves none" do
    n = System.unique_integer([:positive])
    a = Path.join(System.tmp_dir!(), "desktop-all-a-#{n}.txt")
    b = Path.join(System.tmp_dir!(), "desktop-all-b-#{n}.txt")
    File.write!(a, "a\n")
    File.write!(b, "b\n")

    on_exit(fn ->
      for path <- [a, b] do
        File.rm(path)
        if Buffer.exists?(path), do: Aimax.Core.kill_buffer(path)
      end
    end)

    eval!(~s{(begin (visit "#{a}") (insert! "saved ")
                    (visit "#{b}") (insert! "also ")
                    (run-command "desktop-clear"))})
    KeyDispatch.handle_key("A")

    assert File.read!(a) == "saved a\n"
    assert File.read!(b) == "also b\n"
    refute Buffer.exists?(a)
    refute Buffer.exists?(b)

    File.write!(a, "original\n")
    eval!(~s{(begin (visit "#{a}") (insert! "discarded ")
                    (run-command "desktop-clear"))})
    KeyDispatch.handle_key("N")

    assert File.read!(a) == "original\n"
    refute Buffer.exists?(a)
  end

  # S2: one restore path. The mode setup fn rebuilds presentation from
  # the locals it finds, so the locals MUST be on the buffer before it
  # runs — a probe mode makes the order observable.
  test "locals go down before the mode setup runs" do
    eval!("""
    (define-mode "zz-probe-mode"
      (lambda ()
        (buffer-set-local! (current-buffer) 'seen
          (or (buffer-local (current-buffer) 'probe) "MISSING"))))
    """)

    name = "*probe-#{System.unique_integer([:positive])}*"
    on_exit(fn -> Aimax.Core.kill_buffer(name) end)

    eval!("""
    (begin (switch-to-buffer! "#{name}")
           (set-mode! "zz-probe-mode")
           (buffer-set-local! (current-buffer) 'probe "marker"))
    """)

    assert :ok = Desktop.save_now()
    Editor.set_window_buffer("*scratch*")
    evict(name)

    assert :ok = Desktop.restore_now()
    assert Buffer.exists?(name)
    assert Buffer.get_local(name, "seen") == "marker"
  end

  test "group records restore before buffer runtime validates memberships" do
    n = System.unique_integer([:positive])
    name = "*group-restore-#{n}*"
    original = "group-restore-#{n}"
    group = "group-restored-name-#{n}"

    on_exit(fn ->
      if Buffer.exists?(name), do: Aimax.Core.kill_buffer(name)
      Session.eval(~s{(group-record-delete! "#{group}")})
    end)

    eval!("""
    (begin
      (switch-to-buffer! "#{name}")
      (buffer-add-group! "#{name}" "#{original}")
      (group-rename! "#{original}" "#{group}")
      (switch-to-group! "#{group}"))
    """)

    assert Editor.render_state().frame_group == group
    assert :ok = Desktop.save_now()

    Editor.set_window_buffer("*scratch*")
    evict(name)

    # Simulate the fresh Scheme defaults seen before desktop restore.
    eval!("""
    (begin
      (set! *group-records* '())
      (set! *group-next-id* 0)
      (set-frame-local! 'current-group #f)
      (set-frame-group-label! #f))
    """)

    assert :ok = Desktop.restore_now()
    assert Buffer.exists?(name)
    assert eval!(~s{(buffer-group-summary "#{name}")}) == inspect(group)
    assert Editor.render_state().frame_group == group
  end

  # a mode can declare a local as DERIVED: the desktop then skips it, and
  # the setup fn rebuilds it from its source — a diff's render-blocks
  test "desktop-skip-locals keeps a derived local out of the savefile" do
    name = "*skip-#{System.unique_integer([:positive])}*"
    on_exit(fn -> Aimax.Core.kill_buffer(name) end)

    eval!("""
    (begin (switch-to-buffer! "#{name}")
           (buffer-set-local! (current-buffer) 'keep "small")
           (buffer-set-local! (current-buffer) 'heavy "HUGE DERIVED STATE")
           (buffer-set-local! (current-buffer) 'desktop-skip-locals '(heavy)))
    """)

    assert :ok = Desktop.save_now()
    Editor.set_window_buffer("*scratch*")
    evict(name)

    assert :ok = Desktop.restore_now()
    assert Buffer.exists?(name)
    assert Buffer.get_local(name, "keep") == "small"
    assert Buffer.get_local(name, "heavy") in [nil, false]
  end

  # S1: a manual scroll is daemon state — it survives save/restore,
  # pinned where the reader left it.
  test "a pinned scroll survives restore" do
    name = "*scrolled-#{System.unique_integer([:positive])}*"
    on_exit(fn -> Aimax.Core.kill_buffer(name) end)
    Aimax.Core.create_buffer(name)
    Buffer.append(name, String.duplicate("line\n", 200))
    Editor.set_window_buffer(name)

    active = Editor.snapshot().active
    Editor.scroll_window(active, 10)
    assert %{manual: true, top: 10} = Editor.render_state().tree |> leaves() |> hd()

    assert :ok = Desktop.save_now()
    Editor.set_window_buffer("*scratch*")
    evict(name)
    assert :ok = Desktop.restore_now()

    leaf = Editor.render_state().tree |> leaves() |> Enum.find(&(&1.buffer == name))
    assert %{manual: true, top: 10} = leaf
  end

  # S9: a key ends the manual override in the window that received it —
  # not in the other window, whose reading position is not the typist's
  test "a key unpins only the window it landed in" do
    name = "*pin-#{System.unique_integer([:positive])}*"
    on_exit(fn -> Aimax.Core.kill_buffer(name) end)
    Aimax.Core.create_buffer(name)
    Buffer.append(name, String.duplicate("line\n", 200))
    Editor.set_window_buffer(name)

    KeyDispatch.handle_key("C-x")
    KeyDispatch.handle_key("2")
    active = Editor.snapshot().active
    other = Editor.render_state().tree |> leaves() |> Enum.find(&(&1.id != active))
    Editor.scroll_window(other.id, 10)

    KeyDispatch.handle_key("C-f")

    assert %{manual: true} =
             Editor.render_state().tree |> leaves() |> Enum.find(&(&1.id == other.id))

    KeyDispatch.handle_key("C-x")
    KeyDispatch.handle_key("1")
  end

  # S8: `buffer-set-local! 'mode-name X` without `define-mode X` is a
  # bug — restore re-runs the setup fn, and a name with no setup restores
  # to nothing. Scan the sources for literal writers, check the registry.
  test "every literal mode-name write names a registered mode" do
    priv = to_string(:code.priv_dir(:aimax_core))
    src = priv |> Path.join("**/*.scm") |> Path.wildcard() |> Enum.map_join("\n", &File.read!/1)

    written =
      ~r/'mode-name\s+"([^"]+)"/
      |> Regex.scan(src)
      |> Enum.map(fn [_, m] -> m end)
      |> Enum.uniq()

    assert written != []

    for mode <- written do
      assert eval!(~s{(and (assoc "#{mode}" *mode-setups*) #t)}) == "#t",
             ~s{mode-name "#{mode}" is written but no define-mode registers it}
    end
  end

  # S4/S6: a tool card has ONE open-state — the 'agent-open-cards chat
  # local. It drives the rich view's <details>, the plain view's fold,
  # and it survives restore.
  test "a tool card's open state drives both views and survives restore" do
    name = "*card-#{System.unique_integer([:positive])}*"
    on_exit(fn -> Aimax.Core.kill_buffer(name) end)

    eval!("""
    (begin (switch-to-buffer! "#{name}")
           (buffer-append! "#{name}" "> run tool\\nbody line one\\nbody line two\\n")
           (buffer-set-local! "#{name}" 'agent-tool-bodies (list (list "t1" 11)))
           (agent-add-fold! "#{name}" 11 39)
           (agent-card-set-open! "#{name}" "t1" #t))
    """)

    assert eval!(~s{(agent-card-open? "#{name}" "t1")}) == "#t"
    # an open card means no hidden range in the plain view
    assert eval!(~s{(buffer-hidden "#{name}")}) == "()"

    assert :ok = Desktop.save_now()
    Editor.set_window_buffer("*scratch*")
    evict(name)
    assert eventually(fn -> not Buffer.exists?(name) end)
    assert :ok = Desktop.restore_now()

    assert eval!(~s{(agent-card-open? "#{name}" "t1")}) == "#t"

    # TAB's fold and the card list stay one state: toggling closes both
    eval!(~s{(agent-card-toggle! "#{name}" "t1")})
    assert eval!(~s{(agent-card-open? "#{name}" "t1")}) == "#f"
    assert eval!(~s{(buffer-hidden "#{name}")}) != "()"
  end

  # S2 for file buffers: set-mode! re-runs unconditionally after the
  # locals return, so org's setup re-derives hidden ranges from the
  # restored 'org-folds local — the folds you left are the folds you get.
  test "a restored org file comes back folded" do
    path = Path.join(System.tmp_dir!(), "aimax-restore-#{System.unique_integer([:positive])}.org")
    File.write!(path, "* one\nbody one\n* two\nbody two\n")
    on_exit(fn -> File.rm(path) end)

    eval!(~s{(visit "#{path}")})
    assert Buffer.get_local(path, "mode-name") == "org-mode"

    eval!(~s{(org-set-folds! "#{path}" (list 0))})
    hidden = eval!(~s{(buffer-hidden "#{path}")})
    assert hidden != "()"

    assert :ok = Desktop.save_now()
    Editor.set_window_buffer("*scratch*")
    evict(path)
    assert eventually(fn -> not Buffer.exists?(path) end)

    assert :ok = Desktop.restore_now()
    assert Buffer.exists?(path)
    assert eval!(~s{(buffer-hidden "#{path}")}) == hidden
  end

  # savehist. Which commands you use is daemon state like any other, but a
  # global was the one kind the desktop dropped — so every restart threw
  # the minibuffer history away and M-x fell back to alphabetical.
  test "minibuffer history survives save and restore" do
    eval!(~s{(set! *minibuffer-history* (list (list 'M-x (list "delete-other-windows"))))})
    assert :ok = Desktop.save_now()

    # a restart starts from the stdlib's empty default
    eval!("(set! *minibuffer-history* '())")
    assert :ok = Desktop.restore_now()
    assert eval!("*minibuffer-history*") =~ "delete-other-windows"

    # and the prompt leads with it again
    KeyDispatch.handle_key("M-x")
    assert [%{label: "delete-other-windows"} | _] = Editor.render_state().minibuffer.candidates
    KeyDispatch.handle_key("C-g")
  end

  # the mechanism, not the one variable: a global rides along by naming
  # itself, and one that does not is still dropped
  test "a global that names itself survives; one that does not is dropped" do
    eval!("""
    (define *dr-kept* "boot")
    (define *dr-dropped* "boot")
    (persist-global! 'dr-kept
      (lambda () *dr-kept*)
      (lambda (v) (set! *dr-kept* v)))
    """)

    eval!(~s{(begin (set! *dr-kept* "used") (set! *dr-dropped* "used"))})
    assert :ok = Desktop.save_now()

    eval!(~s{(begin (set! *dr-kept* "boot") (set! *dr-dropped* "boot"))})
    assert :ok = Desktop.restore_now()

    assert eval!("*dr-kept*") == ~s{"used"}
    assert eval!("*dr-dropped*") == ~s{"boot"}
  end

  test "LLM configuration history survives desktop restore" do
    eval!(~s{
      (set! *llm-config-history*
        '(("codex-app-server" "gpt-5.6-terra" "high")))
    })
    assert :ok = Desktop.save_now()

    eval!("(set! *llm-config-history* '())")
    assert :ok = Desktop.restore_now()

    assert eval!("*llm-config-history*") ==
             ~s{(("codex-app-server" "gpt-5.6-terra" "high"))}
  end

  # unsaved edits are state: a modified file buffer's text rides the
  # desktop and lays back over what visit read from disk
  test "unsaved edits in a file buffer survive restore" do
    path = Path.join(System.tmp_dir!(), "dr-unsaved-#{System.unique_integer([:positive])}.md")

    on_exit(fn ->
      Editor.set_window_buffer("*scratch*")
      Aimax.Core.kill_buffer(path)
    end)

    File.write!(path, "on disk\n")
    eval!(~s{(visit "#{path}")})
    Buffer.append(path, "unsaved tail", source: :editor)
    assert Buffer.modified?(path)

    assert :ok = Desktop.save_now()
    evict(path)
    assert :ok = Desktop.restore_now()

    assert Buffer.text(path) =~ "unsaved tail"
    assert Buffer.modified?(path)
    File.rm(path)
  end

  # the other half of the same rule: a save that landed before the restart
  # means the texts match, nothing is replaced, and the buffer stays clean
  test "a clean file buffer restores clean" do
    path = Path.join(System.tmp_dir!(), "dr-clean-#{System.unique_integer([:positive])}.md")

    on_exit(fn ->
      Editor.set_window_buffer("*scratch*")
      Aimax.Core.kill_buffer(path)
    end)

    File.write!(path, "saved text\n")
    eval!(~s{(visit "#{path}")})
    refute Buffer.modified?(path)

    assert :ok = Desktop.save_now()
    evict(path)
    assert :ok = Desktop.restore_now()

    assert Buffer.text(path) == "saved text\n"
    refute Buffer.modified?(path)
    File.rm(path)
  end

  # a deleted file is not a deleted buffer: the snapshot text is the only
  # copy of that work, so the buffer comes back anyway
  test "unsaved edits survive even when the file vanished" do
    path = Path.join(System.tmp_dir!(), "dr-gone-#{System.unique_integer([:positive])}.md")

    on_exit(fn ->
      Editor.set_window_buffer("*scratch*")
      Aimax.Core.kill_buffer(path)
    end)

    File.write!(path, "doomed\n")
    eval!(~s{(visit "#{path}")})
    Buffer.append(path, "last words", source: :editor)

    assert :ok = Desktop.save_now()
    evict(path)
    File.rm!(path)
    assert :ok = Desktop.restore_now()

    assert Buffer.exists?(path)
    assert Buffer.text(path) =~ "last words"
  end

  # The Session evaluates one form at a time. A slow form parked every
  # caller behind it, and the save died on the timeout, so nothing reached
  # the disk until the daemon restarted.
  test "a busy Session does not stop the save" do
    assert :ok = Desktop.save_now()
    before = File.read!(Desktop.path())

    busy =
      Task.async(fn ->
        Session.eval(~s{(shell-command->string "sleep 4")})
      end)

    # give the Session time to pick the slow form up
    Process.sleep(200)

    assert :ok = Desktop.save_now()
    assert Process.alive?(Process.whereis(Desktop))

    after_save = File.read!(Desktop.path())
    assert :erlang.binary_to_term(after_save)[:version] == 3

    # the previous globals ride along instead of being dropped
    assert :erlang.binary_to_term(after_save)[:globals] ==
             :erlang.binary_to_term(before)[:globals]

    Task.await(busy, 15_000)
  end

  # Each buffer owns its checkpoint and writes it on its own debounce. A
  # forced checkpoint of a buffer that did not change writes no file.
  test "a clean buffer rewrites no checkpoint" do
    name = "*dr-clean-#{System.unique_integer([:positive])}*"
    on_exit(fn -> Aimax.Core.kill_buffer(name) end)

    {:ok, _} = Aimax.Core.create_buffer(name)
    Buffer.append(name, "one edit", source: :editor)
    :ok = Buffer.checkpoint_now(name)

    file = Aimax.Core.BufferStore.checkpoint_path(Buffer.id(name))
    stamp = File.stat!(file, time: :posix).mtime
    Process.sleep(1_100)

    :ok = Buffer.checkpoint_now(name)
    assert File.stat!(file, time: :posix).mtime == stamp

    Buffer.append(name, " and another", source: :editor)
    :ok = Buffer.checkpoint_now(name)
    assert File.stat!(file, time: :posix).mtime > stamp
  end
end
