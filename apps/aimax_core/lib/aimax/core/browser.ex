defmodule Aimax.Core.Browser do
  @moduledoc """
  The wire between this daemon and the ai-max Chrome extension.

  Symmetric: the daemon asks the browser to do things (list tabs, run JS, read
  a page, type into it) and the browser asks the daemon to do things (what
  commands exist, run this one, handle this chord). A frame carrying `op` is a
  request; one carrying `ok` is a reply — so both sides can number their
  requests independently.

  Mechanism only. Which commands a tab is offered, what a chord means, and what
  a page's text becomes are all `priv/chrome.scm`. This module ships JSON in
  both directions and never interprets it.

  Inbound requests are answered by a Scheme closure registered with
  `serve/1`. It runs in a task, never in this process: a handler that blocks on
  the interpreter must not stall the socket, and one that crashes must not take
  the bridge — and with it every buffer — down.
  """
  use GenServer
  require Logger

  alias Aimax.Core.Session

  @timeout 30_000

  def start_link(_ \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "The transport process claims the bridge on connect."
  def attach(pid), do: GenServer.cast(__MODULE__, {:attach, pid})

  @doc "Released on disconnect; in-flight calls fail rather than hang."
  def detach(pid), do: GenServer.cast(__MODULE__, {:detach, pid})

  @doc "Raw frame in from the extension."
  def incoming(text), do: GenServer.cast(__MODULE__, {:incoming, text})

  @doc "Register the Scheme closure that answers the extension's requests."
  def serve(handler), do: GenServer.cast(__MODULE__, {:serve, handler})

  @doc "Is an extension listening?"
  def connected?, do: GenServer.call(__MODULE__, :connected?)

  @doc """
  Send OP with ARGS; CALLBACK gets `{:ok, result}` or `{:error, message}`.

  Async on purpose — a page operation is slow and the Session process must stay
  free to service keystrokes while it runs.
  """
  def call(op, args, callback) when is_function(callback, 1),
    do: GenServer.cast(__MODULE__, {:call, op, args, callback})

  @impl true
  def init(_), do: {:ok, %{sock: nil, pending: %{}, next_id: 1, handler: nil}}

  @impl true
  def handle_call(:connected?, _from, state), do: {:reply, state.sock != nil, state}

  @impl true
  def handle_cast({:attach, pid}, state) do
    Logger.info("browser: extension attached")
    Process.monitor(pid)
    state = %{state | sock: pid}

    # Tell Scheme the browser is here, so it can warm anything it wants ready
    # before the first keystroke — the tab list, in chrome.scm's case. Without
    # it the first C-x b of a session opens with no tabs and only the second
    # one has them, which reads as the feature being broken.
    if state.handler do
      handler = state.handler
      run(fn -> Session.call_fn(handler, ["attached", []], nil) end)
    end

    {:noreply, state}
  end

  def handle_cast({:detach, pid}, %{sock: pid} = state), do: {:noreply, drop(state)}
  def handle_cast({:detach, _pid}, state), do: {:noreply, state}

  def handle_cast({:serve, handler}, state), do: {:noreply, %{state | handler: handler}}

  def handle_cast({:call, _op, _args, callback}, %{sock: nil} = state) do
    run(fn -> callback.({:error, "no browser: load the ai-max extension in Chrome"}) end)
    {:noreply, state}
  end

  def handle_cast({:call, op, args, callback}, state) do
    id = state.next_id
    frame = args |> Map.new() |> Map.merge(%{"id" => id, "op" => op})
    Logger.info("browser => #{op} #{brief(args)}")
    send(state.sock, {:browser_send, Jason.encode!(frame)})

    timer = Process.send_after(self(), {:timeout, id}, @timeout)
    {:noreply, %{state | next_id: id + 1, pending: Map.put(state.pending, id, {callback, timer})}}
  end

  def handle_cast({:incoming, text}, state) do
    case Jason.decode(text) do
      # the extension's own console, forwarded. Its service worker log lives in
      # a devtools window nobody has open, so an error in there used to be
      # invisible from here — one stream is worth a lot when the bug could be
      # in either half.
      {:ok, %{"event" => "log", "level" => level, "text" => line}} ->
        if level == "error",
          do: Logger.error("browser-ext: #{line}"),
          else: Logger.warning("browser-ext: #{line}")

        {:noreply, state}
      # a reply to something we asked
      {:ok, %{"id" => id, "ok" => _} = msg} -> {:noreply, resolve(state, id, reply_of(msg))}
      # a request from the browser
      {:ok, %{"id" => id, "op" => op} = msg} -> {:noreply, serve_request(state, id, op, msg)}
      _ -> {:noreply, state}
    end
  end

  @impl true
  def handle_info({:timeout, id}, state),
    do: {:noreply, resolve(state, id, {:error, "browser timed out"}, :expired)}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{sock: pid} = state),
    do: {:noreply, drop(state)}

  def handle_info(_msg, state), do: {:noreply, state}

  # --- inbound ---------------------------------------------------------------

  defp serve_request(%{handler: nil} = state, id, _op, _msg) do
    push(state, %{"id" => id, "ok" => false, "error" => "this daemon serves no browser requests"})
    state
  end

  defp serve_request(state, id, op, msg) do
    handler = state.handler
    sock = state.sock
    args = Map.drop(msg, ["id", "op"])

    # The frame the request came from — one browser window, one ai-max frame.
    # Session stamps it for the duration of the Scheme call, so chrome.scm's
    # minibuffer and window calls resolve to the right frame with no plumbing
    # of their own.
    fid = msg["frame"]
    Logger.info("browser <- #{op} #{brief(args)} frame=#{fid || "-"}")

    run(fn ->
      reply =
        case Session.call_fn(handler, [op, Aimax.Core.LLM.json_to_scheme(args)], fid) do
          {:ok, value} ->
            result = Session.scheme_to_json(value)
            Logger.info("browser -> #{op} ok #{brief(result)}")
            %{"id" => id, "ok" => true, "result" => result}

          {:error, reason} ->
            Logger.warning("browser -> #{op} FAILED: #{reason}")
            %{"id" => id, "ok" => false, "error" => reason}
        end

      send(sock, {:browser_send, Jason.encode!(reply)})
    end)

    state
  end

  defp push(%{sock: nil}, _frame), do: :ok
  defp push(%{sock: sock}, frame), do: send(sock, {:browser_send, Jason.encode!(frame)})

  # --- outbound --------------------------------------------------------------

  # One line per hop, short enough to read in a tail. A bridge failure used to
  # be invisible here — you saw keystrokes in the LiveView log and nothing at
  # all about what the browser was asked or answered.
  defp brief(v) do
    s = inspect(v, limit: 6, printable_limit: 90)
    if String.length(s) > 160, do: String.slice(s, 0, 157) <> "...", else: s
  end

  defp reply_of(%{"ok" => true, "result" => result}), do: {:ok, result}
  defp reply_of(%{"ok" => true}), do: {:ok, %{}}
  defp reply_of(%{"error" => error}), do: {:error, to_string(error)}
  defp reply_of(_), do: {:error, "malformed reply"}

  defp resolve(state, id, reply, expired \\ nil) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        state

      {{callback, timer}, rest} ->
        if expired != :expired, do: Process.cancel_timer(timer)

        case reply do
          {:ok, r} -> Logger.info("browser <= ok #{brief(r)}")
          {:error, e} -> Logger.warning("browser <= FAILED: #{e}")
        end

        run(fn -> callback.(reply) end)
        %{state | pending: rest}
    end
  end

  # every in-flight call fails loudly on disconnect: a silently dropped
  # callback leaves a Scheme closure rooted forever
  defp drop(state) do
    Enum.each(state.pending, fn {_id, {callback, timer}} ->
      Process.cancel_timer(timer)
      run(fn -> callback.({:error, "browser disconnected"}) end)
    end)

    %{state | sock: nil, pending: %{}}
  end

  # Anything touching Scheme runs off this process. Doing it inline would
  # serialise the bridge behind the interpreter, and a crash here trips the
  # supervisor's restart limit — which takes every buffer with it.
  defp run(fun) do
    Task.Supervisor.start_child(Aimax.Core.TaskSupervisor, fn ->
      try do
        fun.()
      catch
        kind, err -> Logger.error("browser task #{kind}: #{inspect(err)}")
      end
    end)

    :ok
  end
end
