defmodule Compos.Core.Browser.Prims do
  @moduledoc "The Scheme primitives of this mechanism; the policy is in Scheme."

  import Compos.Core.Prims
  alias Compos.Core.{Frame}
  alias Compos.Core.Session

  alias Compos.Core.Roots

  @doc "Every primitive under its {name, doc} key."
  def entries do
    %{
      # --- browser (Compos.Core.Browser; policy in chrome.scm) ---------------
      # Outbound: OP is the extension verb ("tabs", "eval", "read", "overlay",
      # "type", "click"...), ARGS a plist, CALLBACK gets a plist back — 'ok #t
      # plus the reply, or 'ok #f and 'error. Async because a page operation is
      # slow and keystrokes must not block behind it.
      {"browser-call",
       "(browser-call OP ARGS CB) — send OP to the browser; CB gets a reply plist."} => fn [
                                                                                             op,
                                                                                             args,
                                                                                             callback
                                                                                           ] ->
        key = {:browser, make_ref()}
        Roots.put(key, callback)
        # the frame that asked, carried across the round-trip: a command that
        # queries the browser and only then prompts must prompt in the frame
        # it came from, not in whichever was last active when the reply landed
        fid = Frame.current()
        # and the buffer that asked, so a failed callback reaches that chat
        buffer = Frame.buffer_context()

        Compos.Core.Browser.call(
          s(op),
          browser_args(args),
          fn reply ->
            try do
              Session.apply_callback(callback, [browser_reply(reply)], fid, nil, buffer)
            after
              Roots.drop(key)
            end
          end,
          fid
        )

        :void
      end,
      # The same call, waited on. A tool the model calls has to RETURN what the
      # page said: a callback answers later, and by then the model's turn is
      # over. The wait is safe because the reply runs in the bridge's own task
      # and never re-enters this process — it only sends a message here. It
      # does hold the interpreter, so the ceiling is low and the default lower.
      {"browser-call-sync",
       "(browser-call-sync OP ARGS [MS]) — send OP and wait for the reply plist (default 2s, max 5s)."} =>
        fn args ->
          [op, a | rest] = args
          ms = rest |> List.first() |> browser_wait_ms()
          me = self()
          ref = make_ref()

          Compos.Core.Browser.call(
            s(op),
            browser_args(a),
            fn reply -> send(me, {:browser_sync, ref, reply}) end,
            Frame.current()
          )

          receive do
            {:browser_sync, ^ref, reply} -> browser_reply(reply)
          after
            ms -> [{:sym, "ok"}, false, {:sym, "error"}, "the browser did not answer in time"]
          end
        end,
      # Inbound: HANDLER answers what the browser asks — (HANDLER OP ARGS).
      # M-x in a tab is this: the extension asks "commands", chrome.scm says
      # what the list is. Rooted, since it outlives the call that made it.
      {"browser-serve!",
       "(browser-serve! HANDLER) — set the handler for browser requests: (HANDLER OP ARGS)."} =>
        fn [handler] ->
          Roots.put({:browser_handler, :serve}, handler)
          Compos.Core.Browser.serve(handler)
          :void
        end,
      {"browser-connected?",
       "(browser-connected?) — return #t when a browser extension is connected."} => fn [] ->
        Compos.Core.Browser.connected?()
      end,
      # A chord arriving from a tab goes through the same dispatcher the GUI
      # uses. It has to run OFF this process: KeyDispatch calls back into
      # Session, and calling it from inside Session would deadlock — hence the
      # task, and hence no return value to hand back.
      #
      # The whole sequence goes in ONE task, in order. A task per key races,
      # and a prefix that arrives after its own suffix composes into nothing —
      # which is exactly how C-x b silently did nothing.
      # the Task waits on the input queue, so the injected sequence runs
      # after the event that asked for it and cannot interleave with a
      # user keystroke mid-chord (dup #23). It carries the caller's frame.
      {"dispatch-keys",
       "(dispatch-keys KEYS) — dispatch key chords through the serialized GUI input queue, in order."} =>
        fn [specs] ->
          keys = Enum.map(specs, &s/1)
          fid = Compos.Core.Frame.current()

          Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
            Enum.each(keys, &Compos.Core.Input.dispatch(fid, &1))
          end)

          :void
        end
    }
  end

  # Scheme plist -> JSON object for the extension. #f becomes null here,
  # because to the extension an omitted argument is absent, not false.
  defp browser_args(args), do: Compos.Core.Plist.to_json(args, :null)
  # the interpreter waits here, so the ceiling is 5s and the default 2s: a page
  # that is slower than that is a page the caller should ask about again
  defp browser_wait_ms(ms) when is_integer(ms) and ms > 0, do: min(ms, 5_000)
  defp browser_wait_ms(_), do: 2_000

  defp browser_reply({:ok, result}) when is_map(result),
    do: [{:sym, "ok"}, true | Compos.Core.LLM.json_to_scheme(result)]

  defp browser_reply({:ok, _}), do: [{:sym, "ok"}, true]
  defp browser_reply({:error, msg}), do: [{:sym, "ok"}, false, {:sym, "error"}, msg]
end
