defmodule Compos.Ui.BlockList do
  @moduledoc """
  An isolated block list: a block with `isolate #t` draws its children here.

  The isolation is the mechanism. On every patch the LiveView client
  rebuilds the view's HTML and walks the DOM against it. A list drawn in
  place makes one key in a sibling walk every child. As a component with
  unchanged assigns, the diff ships a skip placeholder, and the client
  never enters this subtree. The decorate cache keeps each unchanged
  child as the same term, with its HTML drawn once, so a changed list
  costs only its changed children.

  `follow` is the reader's place when the list follows its tail: the
  BlockFollow hook keeps the tail in view until the reader scrolls up,
  and reports the place with `follow_place`. Events carry no
  `phx-target`: they go to the parent LiveView. A component needs a static
  root tag, and the mode names the list's tag, so the root is a
  `c-list` that the stylesheet removes from the layout.
  """
  use Phoenix.LiveComponent
  import Compos.Ui.ComposML, only: [sigil_M: 2]

  def composml(assigns) do
    ~M"""
    <c-list class="block-list-root">
    <.dynamic_tag
      tag_name={@b.tag}
      id={"blist-#{@win}-#{@b.anchor || "list"}"}
      class={@b.class}
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
    ><%= for c <- @children do %>{Phoenix.HTML.raw(c.frozen)}<% end %></.dynamic_tag>
    </c-list>
    """
  end

  @impl true
  def render(assigns), do: Compos.Ui.Representation.live(__MODULE__, assigns)
end
