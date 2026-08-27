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

    group = "preview-link-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             Session.eval(~s{
               (let ((id (group-record-create! "#{group}")))
                 (buffer-add-group! "#{source}" id)
                 (switch-to-group! id))})

    on_exit(fn ->
      Session.eval(~s{
        (begin
          (let ((id (group-resolve-id "#{group}")))
            (when id
              (let ((chat (group-primary-chat id)))
                (when (and chat (buffer-known? chat)) (buffer-kill! chat)))
              (group-record-delete! id)))
          (let ((id (group-resolve-id "chosen-link-group")))
            (when id (group-record-delete! id))))})
    end)

    {:ok, conn: build_conn(), source: source, target: target, group: group}
  end

  test "a document link follows inside the current group", %{
    conn: conn,
    target: target,
    group: group
  } do
    {:ok, view, _html} = live(conn, "/")
    win = Editor.render_state().tree.id

    view
    |> element("#editor")
    |> render_hook("preview_link", %{"win" => win, "href" => "linked%20note.md#details"})

    assert Editor.current_buffer() == target
    assert Buffer.text(target) == "# Details\n\nOpened.\n"
    assert {:ok, "#t"} = Session.eval(~s{(buffer-in-group? "#{target}" "#{group}")})
  end

  test "the explicit link action asks for a named destination group", %{
    conn: conn,
    target: target
  } do
    {:ok, view, _html} = live(conn, "/")
    win = Editor.render_state().tree.id

    view
    |> element("#editor")
    |> render_hook("preview_link_to_group", %{
      "win" => win,
      "href" => "linked%20note.md#details"
    })

    assert {:ok, _} =
             Session.eval(~s{
               (begin
                 (minibuffer-change! "chosen-link-group")
                 (run-command "minibuffer-confirm"))})

    assert Editor.current_buffer() == target
    assert {:ok, ~s{"chosen-link-group"}} = Session.eval("(group-name (frame-group))")

    assert {:ok, "#t"} =
             Session.eval(~s{(buffer-in-group? "#{target}" "chosen-link-group")})
  end

  test "a reply action link fills the current group's chat without sending", %{
    conn: conn,
    group: group
  } do
    {:ok, view, _html} = live(conn, "/")
    win = Editor.render_state().tree.id

    view
    |> element("#editor")
    |> render_hook("preview_link", %{
      "win" => win,
      "href" => "aimax:reply/Use%20the%20safe%20option."
    })

    assert {:ok, ~s{"Use the safe option."}} =
             Session.eval(~s{(chat-input-text (group-chat "#{group}"))})

    assert {:ok, "0"} = Session.eval(~s{(chat-turn-count (group-chat "#{group}"))})
  end
end
