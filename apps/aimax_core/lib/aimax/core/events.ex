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
end
