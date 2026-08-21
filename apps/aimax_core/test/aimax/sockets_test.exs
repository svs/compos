defmodule Aimax.SocketsTest do
  @moduledoc """
  The sockets buffer (packages/sockets.scm) and the mechanism under it:
  Proc enumeration and restart, the listener inventory, and the list buffer
  driven the way a person drives it — through KeyDispatch.
  """

  use ExUnit.Case

  alias Aimax.Core.{Daemon, Editor, KeyDispatch, Proc, Session}

  defp eval!(src) do
    {:ok, printed} = Session.eval(src)
    printed
  end

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  defp wait_until(fun, tries \\ 300) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true ->
        Process.sleep(20)
        wait_until(fun, tries - 1)
    end
  end

  defp start_proc!(name, cmd) do
    {:ok, pid} = Proc.start(name, cmd)

    on_exit(fn ->
      Proc.kill(name)
      Aimax.Core.kill_buffer(name)
    end)

    pid
  end

  describe "the proc mechanism" do
    test "list names every running process buffer with its command" do
      start_proc!("*sock-proc-a*", "cat")
      assert {"*sock-proc-a*", "cat"} in Proc.list()
    end

    test "restart runs the same command under a new process" do
      pid = start_proc!("*sock-proc-b*", "cat")

      assert {:ok, new_pid} = Proc.restart("*sock-proc-b*")
      assert new_pid != pid
      assert Proc.running?("*sock-proc-b*")
      assert {"*sock-proc-b*", "cat"} in Proc.list()
    end

    test "restart of an unknown buffer says so" do
      assert {:error, :no_process} = Proc.restart("*sock-proc-none*")
    end
  end

  describe "the listener inventory" do
    test "names rpc, http and app in order" do
      assert ["rpc", "http", "app"] = Enum.map(Daemon.listeners(), & &1.name)
    end

    # solo-app runs boot neither aimax_rpc nor aimax_ui; the partitioned
    # suite boots both — the statuses must stay honest in either context
    test "every status is up, down or off; the unconfigured app server is off" do
      listeners = Daemon.listeners()
      assert Enum.all?(listeners, &(&1.status in ["up", "down", "off"]))
      # app_port is nil in the test env: off, not down — nothing is broken
      assert %{status: "off"} = Enum.find(listeners, &(&1.name == "app"))
    end

    test "the rpc row carries the configured socket path" do
      rpc = Enum.find(Daemon.listeners(), &(&1.name == "rpc"))
      assert rpc.address =~ "sock"
    end

    test "restart_listener refuses an unknown name" do
      assert {:error, :unknown_listener} = Daemon.restart_listener("nope")
    end

    test "restart_listener on rpc bounces it, or reports it absent" do
      case Process.whereis(Aimax.Rpc.Supervisor) do
        nil -> assert {:error, :not_running} = Daemon.restart_listener("rpc")
        _pid -> assert :ok = Daemon.restart_listener("rpc")
      end
    end
  end

  describe "the sockets buffer" do
    setup do
      Editor.minibuffer_close()
      Editor.delete_other_windows()
      on_exit(fn -> Aimax.Core.kill_buffer("*sockets*") end)
      :ok
    end

    defp open_sockets do
      eval!(~s{(run-command "sockets")})
      eval!(~s{(switch-to-buffer! "*sockets*")})
    end

    defp goto_row(id) do
      found =
        eval!(~s{(begin
                    (beginning-of-buffer!)
                    (let loop ((n 100))
                      (cond ((equal? (list-current "*sockets*") "#{id}") #t)
                            ((= n 0) #f)
                            (else (next-line!) (loop (- n 1))))))})

      assert found == "#t", "row #{id} not in *sockets*"
    end

    test "lists the listeners and the running process buffers" do
      start_proc!("*sock-shell*", "cat")
      open_sockets()

      text = eval!(~s{(buffer-text "*sockets*")})
      assert text =~ "listener"
      assert text =~ "rpc"
      assert text =~ "http"
      assert text =~ "browser"
      assert text =~ "*sock-shell*"
      assert text =~ "cat"
    end

    test "k on a proc row kills the process" do
      start_proc!("*sock-shell-k*", "cat")
      open_sockets()
      goto_row("proc:*sock-shell-k*")

      press("k")
      wait_until(fn -> not Proc.running?("*sock-shell-k*") end)
      refute eval!(~s{(buffer-text "*sockets*")}) =~ "*sock-shell-k*"
    end

    test "r on a proc row restarts the process under the same name" do
      pid = start_proc!("*sock-shell-r*", "cat")
      open_sockets()
      goto_row("proc:*sock-shell-r*")

      press("r")
      wait_until(fn -> Proc.running?("*sock-shell-r*") end)
      assert {"*sock-shell-r*", "cat"} in Proc.list()
      [{new_pid, _}] = Registry.lookup(Aimax.Core.ProcRegistry, "*sock-shell-r*")
      assert new_pid != pid
    end
  end
end
