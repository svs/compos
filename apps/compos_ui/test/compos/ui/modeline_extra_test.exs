defmodule Compos.Ui.ModelineExtraTest do
  @moduledoc """
  The frame modeline's extra text is the global-mode-string: one span per
  segment, each with the class its owner chose. A window's modeline-info
  segment runs its buffer's own command.
  """

  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Compos.Core.{Buffer, Editor, Session}

  @endpoint Compos.Ui.Endpoint

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    {:ok, _} = Compos.Core.Session.eval("(test-one-window!)")
    Editor.set_window_buffer("ui-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> Editor.set_modeline_extra("") end)
    {:ok, conn: build_conn()}
  end

  # packages own segments through global-mode-string-set!; a refresh
  # recomposes the extra from them, so the test goes through that door
  test "segments render as classed spans, and no segment hides the extra", %{conn: conn} do
    on_exit(fn ->
      Session.eval(~s[(begin (global-mode-string-remove! 'zz-vm) (global-mode-string-remove! 'zz-agent))])
    end)

    {:ok, _} =
      Session.eval(~s[(begin
        (global-mode-string-set! 'zz-vm "1.2 GiB vm")
        (global-mode-string-set! 'zz-agent (list "ml-attention" "! agent")))])

    {:ok, view, _html} = mount_frame!(conn)
    assert has_element?(view, ".echo-bar .ml-extra .ml-segment", "1.2 GiB vm")
    assert has_element?(view, ".echo-bar .ml-extra .ml-attention", "! agent")

    {:ok, _} =
      Session.eval(~s[(begin (global-mode-string-remove! 'zz-vm) (global-mode-string-remove! 'zz-agent))])

    refute has_element?(view, ".echo-bar .ml-extra .ml-segment", "1.2 GiB vm")
    refute has_element?(view, ".echo-bar .ml-extra .ml-attention", "! agent")
  end

  # the other branch of the one ui_cmd gate: the modeline-info segment
  # sends its buffer, and ui-command! runs that buffer's own command local
  test "modeline-info click runs the buffer's modeline-info-command", %{conn: conn} do
    buf = "*ml-info-test*"
    {:ok, _} = Compos.Core.create_buffer(buf)
    on_exit(fn -> Compos.Core.kill_buffer(buf) end)
    Buffer.append(buf, "x\n", source: :editor)
    Buffer.set_local(buf, "modeline-info", "api · test-model")
    Buffer.set_local(buf, "modeline-info-command", "split-window-below")

    {:ok, view, _html} = mount_frame!(conn)
    # the mounted frame shows what its group shows; the reader clicks in
    # this buffer's window
    {:ok, _} = Session.eval(~s{(switch-to-buffer! "#{buf}")})
    html = render(view)

    assert html =~ "api · test-model"
    assert windows(html) == 1

    view |> element(~s(c-field[name="info"][phx-click="ui_cmd"][phx-value-buf])) |> render_click()
    # the command ran: the frame split, the new window shows another buffer
    assert windows(render(view)) == 2
  end

  # the editor's selected frame: what setup and Session.eval change
  defp mount_frame!(conn) do
    {:ok, raw} = Session.eval("(selected-frame)")
    conn |> put_connect_params(%{"frame" => Jason.decode!(raw)}) |> live("/")
  end

  defp windows(html), do: ~r/<c-window / |> Regex.scan(html) |> length()
end
