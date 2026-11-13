defmodule Compos.Core.Endpoint.Prims do
  @moduledoc "The Scheme primitives of this mechanism; the policy is in Scheme."

  import Compos.Core.Prims
  alias Compos.Core.Session

  alias Compos.Core.Roots

  @doc "Every primitive under its {name, doc} key."
  def entries do
    %{
      # --- Endpoints (Compos.Core.Endpoint; policy in Scheme packages) ------
      {"endpoint-start!",
       "(endpoint-start! NAME SPEC) — open a named connection; SPEC picks the transport and framing."} =>
        fn [name, spec] ->
          case Compos.Core.Endpoint.start(s(name), endpoint_spec(spec)) do
            {:ok, _} -> :void
            {:error, msg} -> raise_scheme("endpoint-start!: #{inspect(msg)}")
          end
        end,
      {"endpoint-stop!", "(endpoint-stop! NAME) — close the connection NAME."} => fn [name] ->
        Compos.Core.Endpoint.stop(s(name))
        :void
      end,
      {"endpoint-send!",
       "(endpoint-send! NAME TEXT) — write one frame; do not wait for an answer."} => fn [
                                                                                           name,
                                                                                           text
                                                                                         ] ->
        Compos.Core.Endpoint.Conn.send_frame(endpoint_conn!(name), s(text))
        :void
      end,
      {"endpoint-ask",
       "(endpoint-ask NAME TEXT UNTIL [TIMEOUT] CB) — send a frame, collect frames up to the sentinel UNTIL; CB gets (OK FRAMES)."} =>
        fn
          [name, text, until, callback] ->
            endpoint_ask(name, text, until, false, callback)

          [name, text, until, timeout, callback] ->
            endpoint_ask(name, text, until, timeout, callback)
        end
    }
  end

  # endpoint spec plist -> the map Endpoint.Conn reads. 'env is itself a
  # plist; 'args is a list of strings; everything else crosses verbatim.
  defp endpoint_spec(plist) do
    plist
    |> plist_to_map()
    |> Map.new(fn
      {"env", v} when is_list(v) ->
        {"env",
         v |> Enum.chunk_every(2) |> Map.new(fn [a, b] -> {to_string(a), to_string(b)} end)}

      {"args", v} when is_list(v) ->
        {"args", Enum.map(v, &to_string/1)}

      {k, v} ->
        {k, v}
    end)
  end

  defp endpoint_conn!(name) do
    case Compos.Core.Endpoint.whereis(s(name)) do
      nil -> raise_scheme("endpoint: no connection #{s(name)}")
      pid -> pid
    end
  end

  defp endpoint_ask(name, text, until, timeout, callback) do
    pid = endpoint_conn!(name)
    sentinel = if until == false, do: nil, else: s(until)
    ms = if is_integer(timeout) and timeout > 0, do: timeout, else: nil
    Compos.Core.Endpoint.Conn.ask(pid, s(text), sentinel, ms, endpoint_cb(callback))
    :void
  end

  # A GC-rooted result callback, same shape as lsp_cb/2: it fires from the
  # conn process, so the Scheme apply always moves to a task.
  defp endpoint_cb(callback) do
    refkey = {:endpoint_call, make_ref()}
    Roots.hold(refkey, callback)

    fn result ->
      Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
        try do
          Session.apply_callback(callback, endpoint_callback_args(result))
        after
          Roots.drop(refkey)
        end
      end)
    end
  end

  defp endpoint_callback_args({:ok, frames}), do: [true, frames]
  defp endpoint_callback_args({:error, msg}), do: [false, to_string(msg)]
end
