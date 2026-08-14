defmodule Aimax.DesktopRestoreTest do
  @moduledoc """
  R3's round-trip suite: the frontend is a function of daemon state, so a
  daemon restart gives back what was on screen. Each R3 slice adds its
  round-trip here.
  """

  use ExUnit.Case

  alias Aimax.Core.{Buffer, Desktop, Editor, Session}

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
