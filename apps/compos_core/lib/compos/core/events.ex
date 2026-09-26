defmodule Compos.Core.Events do
  @moduledoc """
  Buffer change events over a duplicate-key Registry (no external deps).

  Long-lived owners subscribe with `%Compos.Core.Buffer.Ref{}` so a rename
  cannot invalidate their topic. Name topics remain as a compatibility alias
  for Scheme/UI code whose ownership is intentionally name-oriented.

  Subscribers receive:

      {:buffer_change, buffer_ref_or_name, %{version: v, pos: p, inserted: text,
                                             deleted: byte_len, source: :user | {:agent, id} | ...}}
  """

  @registry Compos.Core.EventRegistry

  def registry, do: @registry

  @doc "Keep a buffer's previous presentation visible while FUN updates its display."
  def with_display_update(name, fun) do
    token = make_ref()
    {:ok, _} = Registry.register(@registry, {:display_update, name}, token)

    try do
      fun.()
    after
      Registry.unregister_match(@registry, {:display_update, name}, token)
      broadcast_display(name)
    end
  end

  @doc "Whether a live process is assembling this buffer's next presentation."
  def display_updating?(name), do: Registry.lookup(@registry, {:display_update, name}) != []

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

  @doc "Subscribe to derived display data without subscribing to text changes."
  def subscribe_display(name) do
    {:ok, _} = Registry.register(@registry, {:buffer_display, name}, nil)
    :ok
  end

  def unsubscribe_display(name), do: Registry.unregister(@registry, {:buffer_display, name})

  @doc "Display data changed without a text edit. Only display subscribers consume this message."
  def broadcast_display(name) do
    Registry.dispatch(@registry, {:buffer_display, name}, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:buffer_display, name})
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

  @doc """
  A watched directory tree changed (`Compos.Core.Watch`). The message carries
  the root and nothing else: subscribers re-query. One topic for every root,
  because the roots are few and the subscribers filter.

      {:fs_changed, root}
  """
  def subscribe_fs do
    {:ok, _} = Registry.register(@registry, :fs, nil)
    :ok
  end

  def unsubscribe_fs, do: Registry.unregister(@registry, :fs)

  def broadcast_fs(root) do
    Registry.dispatch(@registry, :fs, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:fs_changed, root})
    end)
  end

  @doc """
  Append an event to the durable log (`Compos.Core.Events.Log`) and answer
  its seq. The rest of this module is live only; this is what is kept.
  Scheme subscribers (`scheme/packages/events.scm`) get the event shortly
  after, and a subscriber that was down gets it when it comes back.

  KIND is an atom or a string. DATA is an Elixir term that becomes a
  Scheme value: a map or keyword list becomes a plist, an atom a symbol,
  nil #f.

      Events.publish("whatsapp:" <> jid, :received, %{from: from, text: text, id: id})
  """
  def publish(topic, kind, data \\ nil) when is_binary(topic),
    do: Compos.Core.Events.Log.append(topic, scheme(kind), scheme(data))

  @doc "An Elixir term as the Scheme value the event log keeps."
  def scheme(nil), do: false
  def scheme(b) when is_boolean(b), do: b
  def scheme(a) when is_atom(a), do: {:sym, a |> Atom.to_string() |> String.replace("_", "-")}
  def scheme({:sym, _} = s), do: s
  def scheme(%DateTime{} = t), do: DateTime.to_unix(t)

  def scheme(m) when is_map(m),
    do: Enum.flat_map(Enum.sort(Map.to_list(m)), fn {k, v} -> [scheme(k), scheme(v)] end)

  def scheme([{k, _} | _] = kw) when is_atom(k),
    do: Enum.flat_map(kw, fn {k, v} -> [scheme(k), scheme(v)] end)

  def scheme(l) when is_list(l), do: Enum.map(l, &scheme/1)
  def scheme(t) when is_tuple(t), do: t |> Tuple.to_list() |> scheme()
  def scheme(other), do: other
end
