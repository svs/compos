defmodule Compos.Core.Agent.Backend.JsonLines do
  @moduledoc """
  The stdio half that the ACP and Codex app server backends share: the
  adapter transport, the line buffer of JSON frames, request ids and the
  RPCs in flight. Each backend keeps its own vocabulary. OPTS are
  `JsonRpc` envelope options; the Codex app server passes `header: false`.

  The state map holds `transport`, `tp`, `partial`, `next_id` and
  `pending_rpc` (id -> the method the answer belongs to).
  """

  alias Compos.Core.JsonRpc

  @doc "Open the adapter CONFIG names, DEFAULT-CMD when it names none, for this process: the transport fields of a state."
  def open(config, default_cmd) do
    transport = Compos.Core.Agent.Transport.impl()
    cmd = Map.get(config, "cmd", default_cmd)

    {:ok, tp} =
      transport.open(cmd, [cd: Map.get(config, "cwd"), env: Map.get(config, "env")], self())

    %{transport: transport, tp: tp, partial: "", next_id: 1, pending_rpc: %{}}
  end

  @doc "What a message to the backend is: {:data, bytes} or {:exit, status} from its transport, or :other."
  def classify({:acp_data, data}, _state), do: {:data, data}
  def classify({port, {:data, data}}, %{tp: port}), do: {:data, data}
  def classify({:acp_exit, status}, _state), do: {:exit, status}
  def classify({port, {:exit_status, status}}, %{tp: port}), do: {:exit, status}
  def classify(_msg, _state), do: :other

  @doc "Feed DATA in; HANDLE gets (state, frame) for each complete frame."
  def ingest(state, data, handle) do
    {frames, partial} = JsonRpc.decode_lines(state.partial <> data)
    Enum.reduce(frames, %{state | partial: partial}, &handle.(&2, &1))
  end

  @doc "Send a request and keep its id in flight under PENDING, the method when nil."
  def request(state, method, params, pending, opts) do
    id = state.next_id
    send_frame(state, JsonRpc.request(id, method, params, opts))
    %{state | next_id: id + 1, pending_rpc: Map.put(state.pending_rpc, id, pending || method)}
  end

  def notify(state, method, params, opts),
    do: send_frame(state, JsonRpc.notification(method, params, opts))

  def respond(state, id, result, opts), do: send_frame(state, JsonRpc.response(id, result, opts))

  def respond_error(state, id, code, message, opts),
    do: send_frame(state, JsonRpc.error(id, code, message, opts))

  def send_frame(state, frame) do
    state.transport.send_frame(state.tp, JsonRpc.encode(frame))
    state
  end

  def close(state), do: state.transport.close(state.tp)
end
