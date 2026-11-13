defmodule Compos.Core.LSP.Prims do
  @moduledoc "The Scheme primitives of this mechanism; the policy is in Scheme."

  import Compos.Core.Prims
  alias Compos.Core.Session

  alias Compos.Core.Roots

  @doc "Every primitive under its {name, doc} key."
  def entries do
    %{
      # --- LSP client (Compos.Core.LSP; policy in packages/lsp.scm) ----------
      {"lsp-start!", "(lsp-start! NAME ROOT SPEC) — start a language server for a project root."} =>
        fn [name, root, spec] ->
          case Compos.Core.LSP.start(s(name), s(root), lsp_spec(spec)) do
            {:ok, _} -> :void
            {:error, msg} -> raise_scheme("lsp-start!: #{inspect(msg)}")
          end
        end,
      {"lsp-stop!",
       "(lsp-stop! ID) — stop the connection \"name@root\" with the shutdown handshake."} => fn [
                                                                                                  id
                                                                                                ] ->
        case Compos.Core.LSP.parse_id(s(id)) do
          {name, root} -> Compos.Core.LSP.stop(name, root)
          _ -> :ok
        end

        :void
      end,
      {"lsp-open!", "(lsp-open! ID BUF) — open BUF on the server and keep it in sync."} => fn [
                                                                                                id,
                                                                                                buf
                                                                                              ] ->
        {pid, _key} = lsp_conn!(id)
        Compos.Core.LSP.Conn.open_doc(pid, s(buf))
        :void
      end,
      {"lsp-close!", "(lsp-close! ID BUF) — close BUF on the server."} => fn [id, buf] ->
        case Compos.Core.LSP.parse_id(s(id)) do
          {name, root} ->
            case Compos.Core.LSP.whereis(name, root) do
              nil -> :ok
              pid -> Compos.Core.LSP.Conn.close_doc(pid, s(buf))
            end

          _ ->
            :ok
        end

        :void
      end,
      {"lsp-notify!", "(lsp-notify! ID METHOD PARAMS) — send a notification to the server."} =>
        fn [id, method, params] ->
          {pid, _key} = lsp_conn!(id)
          Compos.Core.LSP.Conn.notify(pid, s(method), Session.scheme_to_json(params))
          :void
        end,
      {"lsp-buffer-request",
       "(lsp-buffer-request ID METHOD BUF BYTE-POS [EXTRA] CB) — request at a buffer position; CB gets (OK RESULT)."} =>
        fn
          [id, method, buf, pos, callback] ->
            {pid, key} = lsp_conn!(id)

            Compos.Core.LSP.Conn.buffer_request(
              pid,
              s(method),
              s(buf),
              pos,
              %{},
              lsp_cb(callback, key)
            )

            :void

          [id, method, buf, pos, extra, callback] ->
            {pid, key} = lsp_conn!(id)

            Compos.Core.LSP.Conn.buffer_request(
              pid,
              s(method),
              s(buf),
              pos,
              Session.scheme_to_json(extra),
              lsp_cb(callback, key)
            )

            :void
        end
    }
  end

  # MCP spec plist: 'env and 'headers values are themselves plists -> maps
  # spec plist -> the map LSP.Conn reads: env becomes a map; settings and
  # init-options become JSON-ready values (they cross the wire verbatim)
  defp lsp_spec(plist) do
    plist
    |> plist_to_map()
    |> Map.new(fn
      {"env", v} when is_list(v) ->
        {"env", v |> Enum.chunk_every(2) |> Map.new(fn [a, b] -> {to_string(a), b} end)}

      {"settings", v} ->
        {"settings", Compos.Core.Plist.to_json(v)}

      {"init-options", v} ->
        {"init_options", Compos.Core.Plist.to_json(v)}

      kv ->
        kv
    end)
  end

  defp lsp_conn!(id) do
    with {name, root} <- Compos.Core.LSP.parse_id(s(id)),
         pid when pid != nil <- Compos.Core.LSP.whereis(name, root) do
      {pid, {name, root}}
    else
      _ -> raise_scheme("lsp: no connection #{s(id)}")
    end
  end

  # A GC-rooted result callback. It fires from the conn process, so the
  # Scheme apply always moves to a task. The apply runs on the :ui lane
  # on purpose: the exec that created the callback runs there too, and
  # lane order guarantees its frames flush before the callback needs
  # them — a fast server on another lane would apply a closure whose
  # environment is not published yet.
  defp lsp_cb(callback, _key) do
    refkey = {:lsp_call, make_ref()}
    Roots.hold(refkey, callback)

    fn result ->
      Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
        try do
          Session.apply_callback(callback, lsp_callback_args(result))
        after
          Roots.drop(refkey)
        end
      end)
    end
  end

  defp lsp_callback_args({:ok, result}), do: [true, Compos.Core.LLM.json_to_scheme(result)]
  defp lsp_callback_args({:error, msg}), do: [false, to_string(msg)]
end
