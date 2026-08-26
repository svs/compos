defmodule Aimax.Ui.PreviewLinkTest do
  @moduledoc "Rendered Markdown links open files through Scheme policy."

  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint Aimax.Ui.Endpoint

  alias Aimax.Core.{Buffer, Editor, Session}

  setup do
    Editor.minibuffer_close()
    Editor.set_total_rows(40)
    Editor.delete_other_windows()

    root =
      Path.join(System.tmp_dir!(), "aimax-preview-link-#{System.unique_integer([:positive])}")

    source = Path.join(root, "draft.md")
    target = Path.join(root, "linked note.md")
    File.mkdir_p!(root)
    File.write!(source, "[linked note](linked%20note.md#details)\n")
    File.write!(target, "# Details\n\nOpened.\n")

    on_exit(fn ->
      Aimax.Core.kill_buffer(source)
      Aimax.Core.kill_buffer(target)
      File.rm_rf(root)
      Editor.delete_other_windows()
    end)

    {:ok, ^source} = Aimax.Core.open_file(source)
    Editor.set_window_buffer(source)
    assert {:ok, _} = Session.eval(~s{(run-command "writing-mode")})

    {:ok, conn: build_conn(), source: source, target: target}
  end

  test "a writing preview opens a relative encoded file link", %{conn: conn, target: target} do
    {:ok, view, _html} = live(conn, "/")
    win = Editor.render_state().tree.id

    view
    |> element("#editor")
    |> render_hook("preview_link", %{"win" => win, "href" => "linked%20note.md#details"})

    assert Editor.current_buffer() == target
    assert Buffer.text(target) == "# Details\n\nOpened.\n"
  end
end
