defmodule Compos.Core.Browser do
  @moduledoc """
  The wire between this daemon and the compos Chrome extension.

  Symmetric: the daemon asks the browser to do things (list tabs, run JS, read
  a page, type into it) and the browser asks the daemon to do things (what
  commands exist, run this one, handle this chord). A frame carrying `op` is a
  request; one carrying `ok` is a reply — so both sides can number their
  requests independently.

  Mechanism only. Which commands a tab is offered, what a chord means, and what
  a page's text becomes are all `scheme/packages/chrome.scm`. This module ships JSON in
  both directions and never interprets it.

  Inbound requests are answered by a Scheme closure registered with
  `serve/1`. It runs in a task, never in this process: a handler that blocks on
  the interpreter must not stall the socket, and one that crashes must not take
  the bridge — and with it every buffer — down.

  More than one extension may be connected: one per Chrome profile that has
  it installed. Each keeps its own socket. A call goes to the extension that
  owns the tab or the window it names, then to the one the calling frame's
  editor page registered from, and only then to the most recent. A request
  is answered on the socket it came from. With a single socket, as before,
  there was one profile's tabs, and the last profile to connect took every
  call — a background tab opened in a profile without the reader's login.
  """
  use GenServer
  require Logger

  alias Compos.Core.Session

  @timeout 30_000

  def start_link(_ \\ []), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "The transport process claims the bridge on connect."
  def attach(pid), do: GenServer.cast(__MODULE__, {:attach, pid})

  @doc "Released on disconnect; in-flight calls fail rather than hang."
  def detach(pid), do: GenServer.cast(__MODULE__, {:detach, pid})

  @doc """
  Raw frame in from the extension. The transport passes its own pid, so a
  request is answered on the socket it came from and a socket that attached
  before this module was loaded is adopted on its first frame.
  """
  def incoming(text), do: GenServer.cast(__MODULE__, {:incoming, nil, text})
  def incoming(pid, text), do: GenServer.cast(__MODULE__, {:incoming, pid, text})

  @doc "Register the Scheme closure that answers the extension's requests."
  def serve(handler), do: GenServer.cast(__MODULE__, {:serve, handler})

  @doc "Is an extension listening?"
  def connected?, do: GenServer.call(__MODULE__, :connected?)

  @doc """
  One map per connected extension, the newest first: the Chrome profile it
  runs in as the extension reported it — `"id"` (the stable key),
  `"email"`, `"name"` and `"label"` — or only `"connected"` for an
  extension too old to say. Pass `"profile" => ID` in a call's args to send
  it to that profile.
  """
  def profiles, do: GenServer.call(__MODULE__, :profiles)

  @doc """
  Send OP with ARGS; CALLBACK gets `{:ok, result}` or `{:error, message}`.
  FRAME is the compos frame that asked, so a call that names no tab or window
  goes to the extension that frame's editor page lives in.

  Async on purpose — a page operation is slow and the Session process must stay
  free to service keystrokes while it runs.
  """
  def call(op, args, callback, frame \\ nil) when is_function(callback, 1),
    do: GenServer.cast(__MODULE__, {:call, op, args, callback, frame})

  @impl true
  def init(_), do: {:ok, fresh()}

  defp fresh do
    %{
      socks: [],
      home: nil,
      windows: %{},
      tabs: %{},
      frames: %{},
      pending: %{},
      probes: %{},
      profiles: %{},
      next_id: 1,
      handler: nil
    }
  end

  # A daemon that reloads this module keeps the one-socket state it started
  # with. Carry that socket over rather than crash the bridge.
  defp norm(state), do: state |> norm_socks() |> Map.put_new(:profiles, %{})

  defp norm_socks(%{socks: _, probes: _} = state), do: state
  defp norm_socks(%{socks: _} = state), do: Map.put(state, :probes, %{})

  defp norm_socks(%{sock: sock} = old) do
    pending = Map.new(old.pending, fn {id, {cb, timer}} -> {id, {cb, timer, sock}} end)

    %{
      fresh()
      | socks: if(sock, do: [sock], else: []),
        pending: pending,
        next_id: old.next_id,
        handler: old.handler
    }
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    state = norm(state)
    {:reply, state.socks != [], state}
  end

  def handle_call(:profiles, _from, state) do
    state = norm(state)
    list = Enum.map(state.socks, fn s -> Map.get(state.profiles, s, %{"connected" => true}) end)
    {:reply, list, state}
  end

  @impl true
  def handle_cast(msg, state), do: cast(msg, norm(state))

  defp cast({:attach, pid}, state) do
    state = adopt(state, pid, :newest)
    Logger.info("browser: extension attached (#{length(state.socks)} connected)")

    # Tell Scheme the browser is here, so it can warm anything it wants ready
    # before the first keystroke — the tab list, in chrome.scm's case. Without
    # it the first C-x b of a session opens with no tabs and only the second
    # one has them, which reads as the feature being broken.
    if state.handler do
      handler = state.handler
      run(fn -> Session.call_fn(handler, ["attached", []], nil, "browser attached") end)
    end

    {:noreply, state}
  end

  defp cast({:detach, pid}, state), do: {:noreply, forget(state, pid)}

  defp cast({:serve, handler}, state), do: {:noreply, %{state | handler: handler}}

  # A call that names a tab or a window no connected extension is known to
  # own asks every extension for its tabs first, then routes. Before, it fell
  # through to the newest socket, and a tab meant for this frame's window
  # opened in another profile's reader window, logged out and out of sight.
  defp cast({:call, op, args, callback, fid}, state) do
    if unowned(state, Map.new(args)) != [] and length(state.socks) > 1,
      do: {:noreply, probe(state, {:call, op, args, callback, fid, :probed})},
      else: cast({:call, op, args, callback, fid, :probed}, state)
  end

  defp cast({:probed, token}, state) do
    case Map.get(state.probes, token) do
      {1, call} -> cast(call, %{state | probes: Map.delete(state.probes, token)})
      {n, call} -> {:noreply, put_in(state.probes[token], {n - 1, call})}
      nil -> {:noreply, state}
    end
  end

  defp cast({:call, op, args, callback, fid, :probed}, state) do
    amap = Map.new(args)

    case {unowned(state, amap), route(state, amap, fid)} do
      {[{key, v} | _], _} when length(state.socks) > 1 ->
        run(fn -> callback.({:error, "#{key} #{v} is in no connected browser"}) end)
        {:noreply, state}

      {_, nil} ->
        run(fn -> callback.({:error, "no browser: load the compos extension in Chrome"}) end)
        {:noreply, state}

      {_, sock} ->
        id = state.next_id
        frame = args |> Map.new() |> Map.merge(%{"id" => id, "op" => op})
        Logger.info("browser => #{op} #{brief(args)}")
        send(sock, {:browser_send, Jason.encode!(frame)})

        timer = Process.send_after(self(), {:timeout, id}, @timeout)
        pending = Map.put(state.pending, id, {callback, timer, sock})
        {:noreply, %{state | next_id: id + 1, pending: pending}}
    end
  end

  defp cast({:incoming, from, text}, state) do
    state = if from, do: adopt(state, from, :oldest), else: state

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

      # which Chrome profile this socket is, sent on connect and again when
      # its name changes in the extension's options
      {:ok, %{"event" => "profile"} = msg} ->
        p = Map.take(msg, ["id", "email", "name", "label"])
        Logger.info("browser: profile #{p["label"]} (#{p["id"]})")
        {:noreply, if(from, do: put_in(state.profiles[from], p), else: state)}

      # a reply to something we asked
      {:ok, %{"id" => id, "ok" => _} = msg} ->
        {:noreply, resolve(state, id, reply_of(msg))}

      # a request from the browser
      {:ok, %{"id" => id, "op" => op} = msg} ->
        state = if from, do: learn_request(state, from, op, msg), else: state
        {:noreply, serve_request(state, from, id, op, msg)}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:timeout, id}, state),
    do: {:noreply, resolve(norm(state), id, {:error, "browser timed out"}, :expired)}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, forget(norm(state), pid)}

  def handle_info(_msg, state), do: {:noreply, state}

  # --- which extension ---------------------------------------------------------

  # A socket joins once. :newest takes the calls that name nothing; a socket
  # adopted from its traffic goes last, so it never steals them.
  defp adopt(state, pid, where) do
    if pid in state.socks do
      state
    else
      Process.monitor(pid)
      socks = if where == :newest, do: [pid | state.socks], else: state.socks ++ [pid]
      %{state | socks: socks}
    end
  end

  defp forget(state, pid) do
    {mine, rest} = Enum.split_with(state.pending, fn {_id, {_cb, _t, sock}} -> sock == pid end)

    # every in-flight call fails loudly on disconnect: a silently dropped
    # callback leaves a Scheme closure rooted forever
    Enum.each(mine, fn {_id, {callback, timer, _sock}} ->
      Process.cancel_timer(timer)
      run(fn -> callback.({:error, "browser disconnected"}) end)
    end)

    keep = fn map -> map |> Enum.reject(fn {_k, v} -> v == pid end) |> Map.new() end

    %{
      state
      | socks: List.delete(state.socks, pid),
        home: if(state.home == pid, do: nil, else: state.home),
        windows: keep.(state.windows),
        tabs: keep.(state.tabs),
        frames: keep.(state.frames),
        profiles: Map.delete(state.profiles, pid),
        pending: Map.new(rest)
    }
  end

  # The profile the call names, then the tab, then the window, then the
  # frame's own editor page, then the profile the editor registered from,
  # then the newest.
  defp route(state, args, fid) do
    by_profile(state, args) || route_owned(state, args, fid)
  end

  # the socket of the profile ARGS name: by id, email, name or label
  defp by_profile(state, args) do
    case arg(args, "profile") do
      p when is_binary(p) and p != "" ->
        Enum.find(state.socks, fn s ->
          prof = Map.get(state.profiles, s, %{})
          p in [prof["id"], prof["email"], prof["name"], prof["label"]]
        end)

      _ ->
        nil
    end
  end

  defp route_owned(state, args, fid) do
    owner = fn map, key ->
      case arg(args, key) do
        nil -> nil
        v -> live(state, Map.get(map, v))
      end
    end

    owner.(state.tabs, "tab") ||
      owner.(state.windows, "window") ||
      (fid && live(state, Map.get(state.frames, fid))) ||
      live(state, state.home) ||
      List.first(state.socks)
  end

  # the tab and window ARGS name that no live extension is known to own;
  # a call that names a connected profile owns nothing to look for
  defp unowned(state, args) do
    if by_profile(state, args), do: [], else: unowned_ids(state, args)
  end

  defp unowned_ids(state, args) do
    for {key, map} <- [{"tab", state.tabs}, {"window", state.windows}],
        v = arg(args, key),
        v not in [nil, false],
        live(state, Map.get(map, v)) == nil,
        do: {key, v}
  end

  # Ask every extension for its tabs; the replies teach the maps, and the
  # last one to answer, or to time out, releases CALL.
  defp probe(state, call) do
    token = make_ref()
    state = put_in(state.probes[token], {length(state.socks), call})

    Enum.reduce(state.socks, state, fn sock, s ->
      id = s.next_id
      send(sock, {:browser_send, Jason.encode!(%{"id" => id, "op" => "tabs"})})
      timer = Process.send_after(self(), {:timeout, id}, 5_000)
      done = fn _ -> GenServer.cast(__MODULE__, {:probed, token}) end
      %{s | next_id: id + 1, pending: Map.put(s.pending, id, {done, timer, sock})}
    end)
  end

  defp arg(args, key), do: Map.get(args, key) || Map.get(args, String.to_atom(key))

  defp live(_state, nil), do: nil
  defp live(state, pid), do: if(pid in state.socks, do: pid, else: nil)

  # The editor page registers the window it sits in; that profile is home.
  defp learn_request(state, from, op, msg) do
    state = if op == "register", do: %{state | home: from}, else: state
    state = if msg["window"], do: put_in(state.windows[msg["window"]], from), else: state
    if msg["frame"], do: put_in(state.frames[msg["frame"]], from), else: state
  end

  # A reply names the tabs and windows that profile holds.
  defp learn_reply(state, sock, {:ok, %{} = r}) do
    state = if r["tab"], do: put_in(state.tabs[r["tab"]], sock), else: state
    state = if r["window"], do: put_in(state.windows[r["window"]], sock), else: state

    case r["tabs"] do
      list when is_list(list) ->
        Enum.reduce(list, state, fn
          %{} = t, s ->
            s = if t["id"], do: put_in(s.tabs[t["id"]], sock), else: s
            if t["window"], do: put_in(s.windows[t["window"]], sock), else: s

          _, s ->
            s
        end)

      _ ->
        state
    end
  end

  defp learn_reply(state, _sock, _reply), do: state

  # --- inbound ---------------------------------------------------------------

  defp serve_request(%{handler: nil} = state, from, id, _op, _msg) do
    push(answer_to(state, from), %{
      "id" => id,
      "ok" => false,
      "error" => "this daemon serves no browser requests"
    })

    state
  end

  defp serve_request(state, from, id, op, msg) do
    handler = state.handler
    sock = answer_to(state, from)
    args = Map.drop(msg, ["id", "op"])

    # The frame the request came from — one browser window, one compos frame.
    # Session stamps it for the duration of the Scheme call, so chrome.scm's
    # minibuffer and window calls resolve to the right frame with no plumbing
    # of their own.
    fid = msg["frame"]
    Logger.info("browser <- #{op} #{brief(args)} frame=#{fid || "-"}")

    run(fn ->
      reply =
        case Session.call_fn(handler, [op, Compos.Core.LLM.json_to_scheme(args)], fid, "browser #{op}") do
          {:ok, value} ->
            result = Session.scheme_to_json(value)
            Logger.info("browser -> #{op} ok #{brief(result)}")
            %{"id" => id, "ok" => true, "result" => result}

          {:error, reason} ->
            Logger.warning("browser -> #{op} FAILED: #{reason}")
            %{"id" => id, "ok" => false, "error" => reason}
        end

      push(sock, reply)
    end)

    state
  end

  # the socket that asked, else the one calls go to
  defp answer_to(state, from), do: live(state, from) || route(state, %{}, nil)

  defp push(nil, _frame), do: :ok
  defp push(sock, frame), do: send(sock, {:browser_send, Jason.encode!(frame)})

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

      {{callback, timer, sock}, rest} ->
        if expired != :expired, do: Process.cancel_timer(timer)

        case reply do
          {:ok, r} -> Logger.info("browser <= ok #{brief(r)}")
          {:error, e} -> Logger.warning("browser <= FAILED: #{e}")
        end

        reply = with_profile(reply, Map.get(state.profiles, sock))
        run(fn -> callback.(reply) end)
        learn_reply(%{state | pending: rest}, sock, reply)
    end
  end

  # A list of tabs or windows says which profile it came from, on the reply
  # and on each item, so a caller that merges every profile's lists can
  # still tell them apart.
  defp with_profile({:ok, %{} = r}, %{} = p) when map_size(p) > 0 do
    label = p["label"]
    tag = fn
      %{} = item -> Map.put(item, "profile", label)
      other -> other
    end

    r =
      Enum.reduce(["tabs", "windows"], r, fn key, acc ->
        case acc[key] do
          list when is_list(list) -> Map.put(acc, key, Enum.map(list, tag))
          _ -> acc
        end
      end)

    if Map.has_key?(r, "tabs") or Map.has_key?(r, "windows"),
      do: {:ok, Map.merge(r, %{"profile" => label, "profile-id" => p["id"]})},
      else: {:ok, r}
  end

  defp with_profile(reply, _profile), do: reply

  # Anything touching Scheme runs off this process. Doing it inline would
  # serialise the bridge behind the interpreter, and a crash here trips the
  # supervisor's restart limit — which takes every buffer with it.
  defp run(fun) do
    Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
      try do
        fun.()
      catch
        kind, err -> Logger.error("browser task #{kind}: #{inspect(err)}")
      end
    end)

    :ok
  end
end
