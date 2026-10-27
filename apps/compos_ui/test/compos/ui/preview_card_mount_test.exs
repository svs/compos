defmodule Compos.Ui.PreviewCardMountTest do
  @moduledoc """
  The card is split first and shows the list's buffer for one render. Under
  the window's own id the client patched the PreviewCard hook onto that
  element, and LiveView mounts a hook only on insert, so the card stayed
  hidden. The card renders under an id of its own, which the client inserts.
  """
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  alias Compos.Core.{Editor, Session}

  defp leaves(%{type: :leaf} = node), do: [node]
  defp leaves(%{children: children}), do: Enum.flat_map(children, &leaves/1)

  test "the card and the pane under the same window id render under different element ids" do
    previous = Editor.last_active_frame()
    {:ok, frame} = Editor.attach_frame(nil)

    try do
      assert {:ok, _} =
               Session.eval(
                 """
                 (test-buffer! "*zz-mount-owner*" "row")
                 (test-buffer! "*zz-mount-target*" "body")
                 (switch-to-buffer-here! "*zz-mount-owner*")
                 (listing-preview! "*zz-mount-owner*" "*zz-mount-target*")
                 """,
                 frame
               )

      state = Editor.render_state(frame)

      card =
        Enum.find(leaves(state.tree), &String.contains?(&1.window_class || "", "listing-preview"))

      assert card

      as_card =
        render_component(&Compos.Ui.EditorLive.window/1,
          node: Map.put(card, :lines, []),
          active: state.active,
          completion: nil
        )

      assert as_card =~ ~s(id="preview-#{card.id}")
      assert as_card =~ ~s(phx-hook="PreviewCard")
      # the same window as a pane: the id the split rendered first
      assert Compos.Ui.EditorLive.window_dom_id(card.id, false) == "win-#{card.id}"
    after
      Session.eval(
        ~S{(listing-preview-dismiss! "*zz-mount-owner*")
        (for-each buffer-kill! '("*zz-mount-owner*" "*zz-mount-target*"))},
        frame
      )

      Editor.delete_frame(frame)
      Editor.select_frame(previous)
    end
  end
end
