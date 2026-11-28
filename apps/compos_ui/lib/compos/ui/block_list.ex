defmodule Compos.Ui.BlockList do
  @moduledoc """
  An isolated block list: a block with `isolate #t` draws its children here.

  The list uses a Phoenix LiveView stream (`phx-update="stream"`) so updates
  send and patch only the children that changed instead of re-sending and
  morphdom-walking every item in the list.

  `follow` is the reader's place when the list follows its tail: the
  BlockFollow hook keeps the tail in view until the reader scrolls up,
  and reports the place with `follow_place`. Events carry no
  `phx-target`: they go to the parent LiveView. A component needs a static
  root tag, and the mode names the list's tag, so the root is a
  `c-list` that the stylesheet removes from the layout.
  """
  use Phoenix.LiveComponent
  import Compos.Ui.ComposML, only: [sigil_M: 2]

  @impl true
  def update(assigns, socket) do
    children = Map.get(assigns, :children, [])
    base_assigns = Map.delete(assigns, :children)
    prefix = assigns.id
    items = Enum.map(children, &stream_item/1)
    new_keys = Enum.map(items, & &1.id)
    new_parts = Map.new(items, &{&1.id, &1.parts})

    first? = not Map.has_key?(socket.assigns, :prev_keys)

    socket =
      if first? do
        stream_configure(socket, :items, dom_id: &"#{prefix}-#{&1.id}")
      else
        socket
      end

    # The list's element is new with each instance of the component and on
    # every buffer or tag switch. LiveView's stream reset stashes existing
    # items whose dom_id reappears and morphs them detached; when another
    # buffer or a reindexed list puts a different tag at the same index,
    # morphdom cannot swap tags on a detached node and leaves the old
    # element empty. Putting the tag in the item id prevents same-buffer
    # collisions; rotating list_id prevents cross-buffer and rejoin carryover.
    fresh? =
      not Map.has_key?(socket.assigns, :list_id) or
        socket.assigns[:prev_buf] != assigns.buf or
        socket.assigns[:prev_tag] != assigns.b.tag

    socket =
      if fresh?,
        do: assign(socket, :list_id, "#{prefix}-g#{System.unique_integer([:positive])}"),
        else: socket

    socket =
      socket
      |> assign(base_assigns)
      |> sync_stream(first? or fresh?, prefix, items, new_keys, assigns.buf, assigns.b.tag)
      |> assign(
        prev_keys: new_keys,
        prev_parts: new_parts,
        prev_buf: assigns.buf,
        prev_tag: assigns.b.tag
      )

    {:ok, socket}
  end

  defp stream_item(c) do
    key = Map.get(c, :stream_key) || "i-#{System.unique_integer([:positive])}"
    parts = Map.get(c, :frozen_parts) || %{tag: "c-group", attrs: [], inner: Map.get(c, :frozen, "")}
    %{id: "#{key}-#{parts.tag}", parts: parts}
  end

  defp sync_stream(socket, true, _prefix, items, _new_keys, _buf, _tag) do
    stream(socket, :items, items, reset: true)
  end

  defp sync_stream(socket, false, prefix, items, new_keys, buf, tag) do
    prev_keys = socket.assigns.prev_keys
    prev_parts = socket.assigns.prev_parts

    if socket.assigns.prev_buf != buf or socket.assigns.prev_tag != tag do
      stream(socket, :items, items, reset: true)
    else
      new_set = MapSet.new(new_keys)
      prev_kept = Enum.filter(prev_keys, &MapSet.member?(new_set, &1))

      if List.starts_with?(new_keys, prev_kept) do
        removed = Enum.reject(prev_keys, &MapSet.member?(new_set, &1))

        socket =
          Enum.reduce(removed, socket, fn key, acc ->
            stream_delete_by_dom_id(acc, :items, "#{prefix}-#{key}")
          end)

        kept_count = length(prev_kept)
        {existing_items, added_items} = Enum.split(items, kept_count)

        socket =
          Enum.reduce(existing_items, socket, fn item, acc ->
            if Map.get(prev_parts, item.id) == item.parts do
              acc
            else
              stream_insert(acc, :items, item)
            end
          end)

        Enum.reduce(added_items, socket, fn item, acc ->
          stream_insert(acc, :items, item, at: -1)
        end)
      else
        stream(socket, :items, items, reset: true)
      end
    end
  end

  def composml(assigns) do
    ~M"""
    <c-list class="block-list-root">
    <.dynamic_tag
      tag_name={@b.tag}
      id={@list_id}
      class={@b.class}
      phx-update="stream"
      data-block-list="true"
      phx-hook={@follow && "BlockFollow"}
      data-buf={@buf}
      data-win={@win}
      {if @follow, do: [{"follow-tail", to_string(@follow.stick)}], else: []}
      data-stick={@follow && to_string(@follow.stick)}
      data-scroll-top={@follow && @follow.top}
      data-scroll-anchor={@follow && @follow.anchor}
      data-scroll-offset={@follow && @follow.offset}
      data-follow-seq={@follow && @follow.seq}
      {@b.attrs}
    ><.dynamic_tag
      :for={{dom_id, item} <- @streams.items}
      id={dom_id}
      tag_name={item.parts.tag}
      {item.parts.attrs}
    >{Phoenix.HTML.raw(item.parts.inner)}</.dynamic_tag></.dynamic_tag>
    </c-list>
    """
  end

  @impl true
  def render(assigns), do: Compos.Ui.Representation.live(__MODULE__, assigns)
end
