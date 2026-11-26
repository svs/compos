defmodule Compos.Core.Conn do
  @moduledoc """
  What every connection process shares: the status calls, the spawn of
  its subprocess, the bounded frame log, and how a connection fails and
  leaves its last words. `LSP.Conn`, `MCP.Conn` and `Endpoint.Conn` use
  it; each keeps its own protocol and its own state.

  A state map that uses these helpers holds `name`, `status` and `log`.
  The log is newest first while it lives in the process (a cheap
  prepend), and `entries/1` reverses it on the way out.
  """

  require Logger

  alias Compos.Core.{Session, SpawnDir}

  @log_max 200
  @log_line 4_000

  @doc "Call PID with MSG; answer FALLBACK when it is busy or gone."
  def call(pid, msg, fallback) do
    GenServer.call(pid, msg, 5_000)
  catch
    :exit, _ -> fallback
  end

  @doc "Add one entry to the bounded log. A message that is not text is logged as its JSON."
  def log(state, dir, msg) do
    entry = %{at: System.system_time(:millisecond), dir: dir, text: log_text(msg)}
    %{state | log: Enum.take([entry | state.log], @log_max)}
  end

  @doc "The log of STATE, oldest first: [%{at, dir, text}]."
  def entries(state), do: Enum.reverse(state.log)

  defp log_text(msg) when is_binary(msg), do: String.slice(msg, 0, @log_line)
  defp log_text(msg), do: msg |> Jason.encode!() |> String.slice(0, @log_line)

  @doc """
  Spawn the \"command\" of SPEC as a Port with its \"args\" and \"env\".
  OPTS: `cd:` the directory, checked with `SpawnDir.check/2` under the
  `label:` (a key that is present is checked, nil included); `flags:`
  more Port options. Answers {:ok, port, exe} or {:error, msg}.
  """
  def spawn(spec, opts \\ []) do
    cmd = spec["command"]

    case System.find_executable(cmd) do
      nil ->
        {:error, "command not found: #{cmd}"}

      exe ->
        cd = Keyword.get(opts, :cd)

        if Keyword.has_key?(opts, :cd) do
          with {:error, text} <- SpawnDir.check(cd, "#{opts[:label]} #{exe}"), do: raise(text)
        end

        env =
          for {k, v} <- spec["env"] || %{} do
            {String.to_charlist(k), String.to_charlist(to_string(v))}
          end

        port_opts =
          [:binary, :exit_status, args: spec["args"] || [], env: env] ++
            if(cd, do: [cd: cd], else: []) ++ Keyword.get(opts, :flags, [])

        {:ok, Port.open({:spawn_executable, exe}, port_opts), exe}
    end
  end

  def port_alive?(port), do: port != nil and Port.info(port) != nil

  @doc "Close PORT when it still runs."
  def close_port(port), do: if(port_alive?(port), do: Port.close(port), else: :ok)

  @doc """
  Mark STATE failed, tell the user `KIND: name failed — msg`, and stop on
  the next message. Callable from any context: a continue, a reduce over
  frames, the reply of a task.
  """
  def fail_boot(state, kind, msg) do
    Session.message("#{kind}: #{state.name} failed — #{msg}")
    send(self(), :stop_conn)
    %{log(state, :note, "failed — #{msg}") | status: :error}
  end

  @doc """
  The last words of a stopping connection. A connection that fails takes
  its log with it, and its status view would have nothing to show, so
  REGISTRY remembers status, reason and log under KEY and is notified.
  Answers the status.
  """
  def leave(state, registry, key, reason) do
    status = if state.status == :error, do: :error, else: :stopped
    registry.remember(key, %{status: status, reason: reason_text(reason), log: entries(state)})
    registry.notify(key, status)
    status
  end

  defp reason_text(:normal), do: ""
  defp reason_text(:shutdown), do: ""
  defp reason_text(reason), do: inspect(reason)

  @doc "Run CB with RESULT; a callback that raises is logged under KIND, never fatal."
  def safe_cb(cb, result, kind) when is_function(cb, 1) do
    cb.(result)
  rescue
    e -> Logger.warning("#{kind} callback failed: #{Exception.message(e)}")
  end

  def safe_cb(_, _, _), do: :ok
end
