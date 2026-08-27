defmodule Aimax.SchemeTablesTest do
  @moduledoc """
  The Scheme world's ETS tables outlive the process that runs Scheme.

  `Aimax.Core.Session` loads the stdlib, reloads files, rebinds primitives and
  sweeps frames. It used to own the tables too, so one crash there destroyed
  every registered command and the whole environment, and every lane worker
  holding the published handle read a dead table id.

  The restart here goes through the supervisor rather than `Process.exit`.
  Killing Session repeatedly trips the supervisor's restart intensity and
  takes the whole application down, which is a fact about restart intensity
  and not about ETS.
  """

  use ExUnit.Case, async: false

  alias Aimax.Core.{SchemeAPI, SchemeTables, Session}

  # A restart reloads the stdlib, so the interpreter comes back at its boot
  # state. Anything a run set at RUNTIME is gone, and every later test in this
  # partition shares this editor. test_helper.exs turns worktree isolation off
  # once for the whole run; put it back, or a hundred chat and agent tests
  # start creating checkouts and fail long after this file finished.
  defp restart_session! do
    :ok = Supervisor.terminate_child(Aimax.Core.Supervisor, Session)
    {:ok, pid} = Supervisor.restart_child(Aimax.Core.Supervisor, Session)
    assert Session.ready?()
    {:ok, _} = Session.eval("(customize-set! 'agent-worktree-isolation #f)")
    pid
  end

  test "the table owner, not Session, owns the named tables" do
    owner = Process.whereis(SchemeTables)
    assert is_pid(owner)

    for table <- SchemeTables.named_tables() do
      assert :ets.info(table, :owner) == owner,
             "#{inspect(table)} is owned by #{inspect(:ets.info(table, :owner))}"
    end
  end

  test "the environment table names the owner as its heir" do
    tid = :persistent_term.get({Session, :interp}).store.tid
    assert :ets.info(tid, :owner) == Process.whereis(Session)
    assert :ets.info(tid, :heir) == Process.whereis(SchemeTables)
  end

  test "the Scheme world survives the process that runs it" do
    table = SchemeAPI.commands_table()
    table_id = :ets.whereis(table)
    env = :persistent_term.get({Session, :interp}).store.tid
    assert Session.command_names() != []

    restart_session!()

    # the SAME named table, not a replacement: a lane worker that cached the
    # id never reads a dead one, and the new Session refilled it
    assert :ets.whereis(table) == table_id
    assert :ets.info(table, :owner) == Process.whereis(SchemeTables)
    assert Session.command_names() != []

    # the old environment transferred to the owner instead of dying with the
    # process, so work still holding it can finish
    assert :ets.info(env, :owner) == Process.whereis(SchemeTables)

    # and the new Session built its own
    fresh = :persistent_term.get({Session, :interp}).store.tid
    refute fresh == env
    assert :ets.info(fresh, :owner) == Process.whereis(Session)

    # the editor works
    assert {:ok, "3"} = Session.eval("(+ 1 2)")
  end
end
