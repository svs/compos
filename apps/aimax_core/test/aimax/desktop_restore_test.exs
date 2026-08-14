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
      fun.() -> true
      tries == 0 -> false
      true -> (Process.sleep(20); eventually(fun, tries - 1))
    end
  end

  setup do
    Editor.minibuffer_close()
    Editor.delete_other_windows()
    :ok
  end

  # S2: one restore path. The mode setup fn rebuilds presentation from
  # the locals it finds, so the locals MUST be on the buffer before it
  # runs — a probe mode makes the order observable.
  test "locals go down before the mode setup runs" do
    eval!("""
    (define-mode "probe-mode"
      (lambda ()
        (buffer-set-local! (current-buffer) 'seen
          (or (buffer-local (current-buffer) 'probe) "MISSING"))))
    """)

    name = "*probe-#{System.unique_integer([:positive])}*"
    on_exit(fn -> Aimax.Core.kill_buffer(name) end)

    eval!("""
    (begin (switch-to-buffer! "#{name}")
           (set-mode! "probe-mode")
           (buffer-set-local! (current-buffer) 'probe "marker"))
    """)

    assert :ok = Desktop.save_now()
    Editor.set_window_buffer("*scratch*")
    Aimax.Core.kill_buffer(name)
    assert eventually(fn -> not Buffer.exists?(name) end)

    assert :ok = Desktop.restore_now()
    assert Buffer.exists?(name)
    assert Buffer.get_local(name, "seen") == "marker"
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
    Aimax.Core.kill_buffer(name)
    assert eventually(fn -> not Buffer.exists?(name) end)
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
    Aimax.Core.kill_buffer(name)
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
    Aimax.Core.kill_buffer(path)
    assert eventually(fn -> not Buffer.exists?(path) end)

    assert :ok = Desktop.restore_now()
    assert Buffer.exists?(path)
    assert eval!(~s{(buffer-hidden "#{path}")}) == hidden
  end
end
