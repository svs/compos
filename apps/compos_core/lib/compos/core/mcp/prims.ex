defmodule Compos.Core.MCP.Prims do
  @moduledoc "The Scheme primitives of this mechanism; the policy is in Scheme."

  import Compos.Core.Prims
  alias Compos.Core.Session

  @mcp_wait 30_000
  alias Compos.Core.Roots

  @doc "Every primitive under its {name, doc} key."
  def entries do
    %{
      # --- MCP client (Compos.Core.MCP; policy in packages/mcp.scm) ----------
      {"mcp-connect!", "(mcp-connect! NAME SPEC) — connect an MCP server from a spec plist."} =>
        fn [name, spec] ->
          case Compos.Core.MCP.connect(s(name), mcp_spec(spec)) do
            {:ok, _} -> :void
            {:error, msg} -> raise_scheme("mcp-connect!: #{inspect(msg)}")
          end
        end,
      {"mcp-disconnect!", "(mcp-disconnect! NAME) — disconnect the named MCP server."} => fn [
                                                                                               name
                                                                                             ] ->
        Compos.Core.MCP.disconnect(s(name))
        :void
      end,
      {"mcp-tool-specs", "(mcp-tool-specs NAMES) — return the tool specs of the named servers."} =>
        fn [names] ->
          Compos.Core.MCP.tool_specs(Enum.map(names, &s/1))
        end,
      # Wait for a server that is still shaking hands, up to the same
      # bound. An empty tool list reads as "this server serves nothing",
      # which is a lie the caller cannot tell from the truth.
      {"mcp-await-ready",
       "(mcp-await-ready SERVER [MS]) — wait until the server is ready; return #t or #f."} =>
        fn args ->
          [server | rest] = args
          server = s(server)
          wait = if is_integer(List.first(rest)), do: List.first(rest), else: @mcp_wait

          task =
            Task.Supervisor.async_nolink(Compos.Core.TaskSupervisor, fn ->
              Compos.Core.MCP.await_ready(server, wait)
            end)

          case Task.yield(task, wait) || Task.shutdown(task, :brutal_kill) do
            {:ok, ready?} -> ready?
            _ -> false
          end
        end,
      # Call one tool on one server. The work runs in a task, never here:
      # this process draws the editor, and a server that answers in its own
      # time must not stop it. With a callback the call returns at once;
      # without one the caller waits, bounded, because the eval path (an
      # agent through the compos proxy) needs an answer, not a promise.
      {"mcp-tool-call",
       "(mcp-tool-call SERVER TOOL ARGS [TIMEOUT|CB]) — call one tool; without CB, wait for text."} =>
        fn
          [server, tool, args] ->
            mcp_wait_call(s(server), s(tool), mcp_args(args), @mcp_wait)

          [server, tool, args, timeout] when is_integer(timeout) ->
            mcp_wait_call(s(server), s(tool), mcp_args(args), timeout)

          [server, tool, args, callback] ->
            key = {:mcp_call, make_ref()}
            Roots.hold(key, callback)
            {server, tool, args} = {s(server), s(tool), mcp_args(args)}
            # the callback comes back to the frame and buffer that asked, as a
            # task-run! callback does; a failure then reaches that chat
            fid = Compos.Core.Frame.current()
            buffer = Compos.Core.Frame.buffer_context()

            Task.Supervisor.start_child(Compos.Core.TaskSupervisor, fn ->
              result = Compos.Core.MCP.call_when_ready(server, tool, args, @mcp_wait)

              try do
                Session.apply_callback(callback, mcp_callback_args(result), fid, nil, buffer)
              after
                Roots.drop(key)
              end
            end)

            :void
        end
    }
  end

  # the task owns the timeout, not the connection: Conn gives a tool call
  # two minutes, and the session cannot wait that long for anything
  defp mcp_wait_call(server, tool, args, timeout) do
    task =
      Task.Supervisor.async_nolink(Compos.Core.TaskSupervisor, fn ->
        Compos.Core.MCP.call_when_ready(server, tool, args, timeout)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, text}} -> text
      {:ok, {:error, msg}} -> raise_scheme("mcp-call!: #{msg}")
      _ -> raise_scheme("mcp-call!: #{server} #{tool} did not answer in time")
    end
  end

  # tool arguments come as a JSON string (what an agent writes through
  # eval-scheme) or as a plist (what Scheme code writes)
  defp mcp_args(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp mcp_args(args) when is_list(args) do
    case Session.scheme_to_json(args) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp mcp_args(_), do: %{}
  # (lambda (ok text) ...) — an error is text too, and a handler that only
  # displays the answer needs no second branch
  defp mcp_callback_args({:ok, text}), do: [true, text]
  defp mcp_callback_args({:error, msg}), do: [false, to_string(msg)]

  defp mcp_spec(plist) do
    plist
    |> plist_to_map()
    |> Map.new(fn
      {k, v} when k in ["env", "headers"] and is_list(v) ->
        {k, v |> Enum.chunk_every(2) |> Map.new(fn [a, b] -> {to_string(a), b} end)}

      kv ->
        kv
    end)
  end
end
