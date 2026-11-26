defmodule Compos.Ui.LiveShared do
  @moduledoc """
  What EditorLive and MobileLive share, so the two clients do not drift:
  the events a window sends (`ui_cmd`, `follow_place`, `block_click`, the
  preview links), the drain of queued change notices, the frame state with
  its re-attach, the buffer subscriptions, and the tree and minibuffer
  helpers. Each LiveView keeps its own `handle_event` head and its own
  refresh; it calls these.
  """

  alias Compos.Core.{Buffer, Editor, Events, Input, SchemeAPI, Session}

  @window_events ~w(ui_cmd follow_place block_click preview_link preview_link_to_group)

  @doc "the event names `window_event/3` answers"
  def window_events, do: @window_events

  @doc """
  Run a window event for FRAME. Answers `:refresh` when the client must
  drain and refresh, `:quiet` when nothing it draws changed (or the event
  was malformed).
  """
  def window_event("ui_cmd", %{"win" => win} = p, frame) do
    in_window(frame, win, fn _id ->
      Session.call_named("ui-command!", [p["cmd"] || false, p["buf"] || false])
    end)
  end

  # the reader's place in a followed block list: a runtime mirror, so a
  # redraw keeps it. A report that answers an older follow-seq is stale.
  def window_event("follow_place", %{"buf" => buf, "stick" => stick, "top" => top} = p, _frame)
      when is_boolean(stick) and is_integer(top) do
    if Buffer.exists?(buf) and p["seq"] in [nil, Buffer.get_local(buf, "follow-seq") || 0] do
      anchor = if is_integer(p["anchor"]), do: p["anchor"], else: false
      offset = if is_integer(p["offset"]), do: p["offset"], else: 0
      Buffer.set_local(buf, "follow-place", [not stick, top, anchor, offset])
    end

    :quiet
  end

  def window_event("block_click", %{"win" => win, "id" => id}, frame) do
    in_window(frame, win, fn _id -> SchemeAPI.block_click(Editor.current_buffer(), id) end)
  end

  def window_event("preview_link", %{"win" => win, "href" => href}, frame)
      when is_binary(href) and byte_size(href) <= 2000 do
    on_window(frame, win, fn id -> Session.call_named("preview-follow-link!", [id, href]) end)
  end

  def window_event("preview_link_to_group", %{"win" => win, "href" => href}, frame)
      when is_binary(href) and byte_size(href) <= 2000 do
    on_window(frame, win, fn id -> Session.call_named("link-follow-to-group", [id, href]) end)
  end

  def window_event(_name, _params, _frame), do: :quiet

  # select window WIN, then run F on the frame's input lane
  defp in_window(frame, win, f) do
    on_window(frame, win, fn id ->
      Editor.set_active(id)
      f.(id)
    end)
  end

  defp on_window(frame, win, f) do
    case win_id(win) do
      id when is_integer(id) -> Input.run(frame, fn -> f.(id) end)
      nil -> :ok
    end

    :refresh
  end

  @doc "a window id from the client: an integer or its decimal text, else nil"
  def win_id(v) when is_integer(v), do: v

  def win_id(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end

  def win_id(_), do: nil

  @doc "coalesce bursts: drop every queued change notice, so one render follows"
  def drain(socket) do
    receive do
      {:frame_change, _} -> drain(socket)
      {:editor_change, _} -> drain(socket)
      {:buffer_change, _, _} -> drain(socket)
      {:buffer_display, _} -> drain(socket)
    after
      0 -> socket
    end
  end

  @doc """
  The render state of frame FID. When the frame was deleted under the
  client (M-x delete-frame elsewhere, RPC), render_state fell back to
  another frame: recreate ours under the same id, so the client's stored
  id stays good.
  """
  def frame_state(fid) do
    {state, effects} = Editor.render_state_and_effects(fid)

    if fid && state.frame != fid do
      {:ok, ^fid} = Editor.attach_frame(fid)
      Editor.render_state_and_effects(fid)
    else
      {state, effects}
    end
  end

  @doc """
  Move the client's buffer subscriptions from OLD to VISIBLE (both
  MapSets): a buffer that left stops feeding it, a new one starts. Each
  buffer feeds both its text changes and its display changes. Answers
  VISIBLE.
  """
  def resubscribe(old, visible) do
    old
    |> MapSet.difference(visible)
    |> Enum.each(fn name ->
      Events.unsubscribe(name)
      Events.unsubscribe_display(name)
    end)

    visible
    |> MapSet.difference(old)
    |> Enum.each(fn name ->
      Events.subscribe(name)
      Events.subscribe_display(name)
    end)

    visible
  end

  @doc "the leaf with window id ID in TREE, or nil"
  def find_leaf(%{type: :leaf, id: id} = leaf, id), do: leaf
  def find_leaf(%{type: :split, children: kids}, id), do: Enum.find_value(kids, &find_leaf(&1, id))
  def find_leaf(_, _), do: nil

  @doc "the first leaf of TREE, or nil"
  def first_leaf(%{type: :leaf} = leaf), do: leaf
  def first_leaf(%{type: :split, children: [kid | _]}), do: first_leaf(kid)
  def first_leaf(_), do: nil

  @doc """
  The minibuffer input split at its point as {before, cursor, after}: the
  cursor holds the grapheme under point, or FILLER at the end.
  """
  def mb_split(%{input: input, point: point}, filler) when is_binary(input) and is_integer(point) do
    point = point |> min(byte_size(input)) |> max(0)
    rest = binary_part(input, point, byte_size(input) - point)

    case String.next_grapheme(rest) do
      nil -> {binary_part(input, 0, point), filler, ""}
      {g, post} -> {binary_part(input, 0, point), g, post}
    end
  end

  def mb_split(mb, filler), do: {Map.get(mb, :input, ""), filler, ""}
end
