defmodule Compos.CallbackBufferTest do
  @moduledoc """
  An async callback runs for the buffer that started it, not for the buffer
  the UI shows when the answer comes back. A chat's job: topics follow its
  current buffer (event-job-topic), so this is what lets a job: event that
  an agent publishes from a callback wake that agent's chat. task-run!, MCP,
  browser and shell callbacks already do it; these are the other doors.
  """

  use ExUnit.Case, async: false

  alias Compos.Core.Session

  @asker "zz-callback-asker"

  defp eval!(code) do
    {:ok, printed} = Session.eval(code)
    printed
  end

  defp seen do
    deadline = System.monotonic_time(:millisecond) + 5_000

    Stream.repeatedly(fn ->
      v = eval!("*zz-cb-seen*")
      if v != "#f" or System.monotonic_time(:millisecond) > deadline, do: v, else: (Process.sleep(20) && nil)
    end)
    |> Enum.find(& &1)
  end

  # start DOOR from the asker buffer; its callback notes the buffer it runs in
  defp ask(door) do
    eval!("""
    (begin
      (buffer-create "#{@asker}")
      (define *zz-cb-seen* #f)
      (define (zz-cb-note . _) (set! *zz-cb-seen* (current-buffer)))
      (with-current-buffer "#{@asker}" (lambda () #{door}))
      #t)
    """)

    seen()
  end

  setup do
    on_exit(fn -> Session.eval(~s{(buffer-kill! "#{@asker}")}) end)
    :ok
  end

  test "an llm callback runs for the buffer that asked" do
    Application.put_env(:compos_core, :llm_request_fun, fn _prompt -> {:ok, "ok"} end)
    on_exit(fn -> Application.delete_env(:compos_core, :llm_request_fun) end)

    assert ask("(llm \"hi\" zz-cb-note)") == inspect(@asker)
  end

  test "a debounce callback runs for the buffer that asked" do
    assert ask("(debounce! \"zz-cb\" 10 zz-cb-note 1)") == inspect(@asker)
  end

  test "a db-query callback runs for the buffer that asked" do
    assert ask("(db-query \"zz-no-such-db\" \"select 1\" '() zz-cb-note)") == inspect(@asker)
  end
end
