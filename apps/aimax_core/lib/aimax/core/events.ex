defmodule Aimax.Core.Events do
  @moduledoc """
  Buffer change events over a duplicate-key Registry (no external deps).

  Subscribers receive:

      {:buffer_change, buffer_name, %{version: v, pos: p, inserted: text,
                                      deleted: byte_len, source: :user | {:agent, id} | ...}}
  """

  @registry Aimax.Core.EventRegistry

  def registry, do: @registry

  def subscribe(buffer_name) do
    {:ok, _} = Registry.register(@registry, {:buffer_change, buffer_name}, nil)
    :ok
  end

  def unsubscribe(buffer_name) do
    Registry.unregister(@registry, {:buffer_change, buffer_name})
  end

  def broadcast(buffer_name, change) do
    msg = {:buffer_change, buffer_name, change}

    Registry.dispatch(@registry, {:buffer_change, buffer_name}, fn entries ->
      for {pid, _} <- entries, do: send(pid, msg)
    end)
  end

  @doc "Editor-state (windows/minibuffer/echo/keymap) change notifications."
  def subscribe_editor do
    {:ok, _} = Registry.register(@registry, :editor, nil)
    :ok
  end

  def broadcast_editor(what) do
    Registry.dispatch(@registry, :editor, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:editor_change, what})
    end)
  end

  @doc """
  One frame's view changed. Clients subscribe to their own frame so frame
  A's window churn never re-renders frame B; `:editor` stays the firehose
  for non-view subscribers (Desktop, Reactor, Agent).
  """
  def subscribe_frame(id) do
    {:ok, _} = Registry.register(@registry, {:frame, id}, nil)
    :ok
  end

  def unsubscribe_frame(id) do
    Registry.unregister(@registry, {:frame, id})
  end

  def broadcast_frame(id) do
    Registry.dispatch(@registry, {:frame, id}, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:frame_change, id})
    end)
  end
end
