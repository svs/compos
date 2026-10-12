defmodule Compos.Core.LLMWatchdog do
  @moduledoc """
  Finds a dead model connection before a request waits on it.

  Every model call shares ReqLLM.Finch, whose HTTP/2 pools each hold one
  open connection. A connection the network drops without a close (an
  idle timeout in a router, a sleep, a change of network) still takes
  writes, so a request sent on it waits about three minutes for a reply
  that never comes, and every request after it waits too. Finch's own
  keepalive ping fails only when the write fails; it never misses a PONG.

  Each interval this pings every open connection and waits for the PONG.
  One that does not answer in time is killed: its supervisor connects
  afresh, and a request waiting on it fails at once (the request monitors
  its pool) into the retry in Compos.Core.LLM. The pings also keep an
  idle connection busy enough that a router has no reason to drop it.
  """

  use GenServer

  alias Compos.Core.Session

  @interval_ms 30_000
  @pong_ms 5_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Ping every open model connection now; answers how many were replaced."
  def check, do: GenServer.call(__MODULE__, :check, @pong_ms * 3)

  @impl true
  def init(_opts) do
    schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:check, state) do
    sweep()
    schedule()
    {:noreply, state}
  end

  @impl true
  def handle_call(:check, _from, state), do: {:reply, sweep(), state}

  defp schedule do
    Process.send_after(self(), :check, Application.get_env(:compos_core, :llm_watchdog_ms, @interval_ms))
  end

  defp sweep do
    silent =
      connections()
      |> Task.async_stream(fn pid -> {pid, silent?(pid)} end,
        timeout: @pong_ms * 2,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, {pid, true}} -> [pid]
        _ -> []
      end)

    if silent != [] do
      Session.message(
        "llm: #{length(silent)} model connection(s) stopped answering; connecting afresh",
        "warning"
      )

      Enum.each(silent, &Process.exit(&1, :kill))
    end

    length(silent)
  end

  # only a missing PONG condemns a connection: an error reply means the
  # pool is already reconnecting or draining on its own
  defp silent?(pid) do
    :gen_statem.call(pid, :ping, @pong_ms)
    false
  catch
    :exit, {:timeout, _} -> true
    :exit, _ -> false
  end

  # the connected HTTP/2 pools: each registers itself under the pool name
  # while it holds a live connection, and unregisters when it loses it
  defp connections do
    {:ok, config} = Registry.meta(ReqLLM.Finch, :config)

    config.registry_name
    |> Registry.select([{{:_, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.flat_map(fn
      {pid, Finch.HTTP2.Pool} -> [pid]
      _ -> []
    end)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end
end
