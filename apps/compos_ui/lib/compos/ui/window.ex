defmodule Compos.Ui.Window do
  @moduledoc """
  One window of the editor, isolated in a LiveComponent.

  The isolation is the mechanism, the same one `Compos.Ui.AgentTranscript`
  uses: the component's `assign` skips a value equal to the one it holds,
  so a window whose node, active flag, and completion did not change has
  no changed assign, renders nothing, and the diff carries a skip
  placeholder for it. Only the window that changed renders, and inside it
  the keyed line comprehension sends only the lines that changed.

  The template stays in `Compos.Ui.EditorLive.window/1`, next to the helpers
  it calls. Events here carry no `phx-target`: they go to the parent
  LiveView, which owns every handler.
  """
  use Phoenix.LiveComponent

  @impl true
  def render(assigns), do: Compos.Ui.EditorLive.window(assigns)
end
