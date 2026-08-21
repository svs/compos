defmodule Aimax.Core.LLMSession do
  @moduledoc """
  Backend-neutral LLM session facade.

  Frontends open a session, send messages, and consume the normalized event
  stream without knowing whether the selected connector is the stateless
  ReqLLM lane or a stateful ACP adapter. `Aimax.Core.Agent` remains the
  process that implements ordering, queuing, permissions, and lifecycle; this
  module is the public boundary and owns each frontend's callbacks.

  Callback entries are optional. Chats use the registered default callbacks,
  while inline/document sessions install callbacks scoped to their session id.
  """

  alias Aimax.Core.Agent

  @escaped :aimax_escaped_closures
  @callback_kinds [:context, :handler, :record, :permission]

  def open(id, config, callbacks \\ %{}) when is_binary(id) and is_map(config) do
    put_callbacks(id, callbacks)

    case Agent.start(id, config) do
      {:ok, _pid} = ok ->
        ok

      error ->
        delete_callbacks(id)
        error
    end
  end

  def send(id, text, display \\ nil), do: Agent.prompt(id, text, display)
  def dequeue(id, text), do: Agent.dequeue(id, text)
  def cancel(id), do: Agent.cancel(id)
  def set_model(id, model), do: Agent.set_model(id, model)
  def set_effort(id, effort), do: Agent.set_effort(id, effort)
  def set_mode(id, mode), do: Agent.set_mode(id, mode)

  def respond_permission(id, rpc_id, option_id),
    do: Agent.respond_permission(id, rpc_id, option_id)

  def permission_deadline(id, ms), do: Agent.permission_deadline(id, ms)
  def append(id, text), do: Agent.append_at_mark(id, text)
  def mark(id), do: Agent.mark(id)
  def info(id), do: Agent.info(id)
  def list, do: Agent.list()
  def running?(id), do: Agent.running?(id)

  def close(id) do
    result = Agent.kill(id)
    delete_callbacks(id)
    result
  end

  @doc false
  def callback(id, kind) when kind in @callback_kinds do
    case :ets.lookup(@escaped, {:llm_session, id, kind}) do
      [{_, callback}] -> callback
      [] -> nil
    end
  end

  defp put_callbacks(id, callbacks) do
    Enum.each(@callback_kinds, fn kind ->
      case Map.get(callbacks, kind) do
        nil -> :ok
        callback -> :ets.insert(@escaped, {{:llm_session, id, kind}, callback})
      end
    end)
  end

  defp delete_callbacks(id) do
    Enum.each(@callback_kinds, &:ets.delete(@escaped, {:llm_session, id, &1}))
  end
end
