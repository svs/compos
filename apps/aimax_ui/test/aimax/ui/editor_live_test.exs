defmodule Aimax.Ui.EditorLiveTest do
  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint Aimax.Ui.Endpoint

  defp keys(view, specs) do
    Enum.each(specs, fn k -> view |> element("#editor") |> render_hook("key", %{"k" => k}) end)
    render(view)
  end

  defp type(view, str), do: keys(view, String.graphemes(str))

  setup do
    Aimax.Core.Editor.minibuffer_close()
    Aimax.Core.Editor.completion_dismiss()
    Aimax.Core.Editor.set_pending([])
    Aimax.Core.Editor.set_total_rows(40)
    Aimax.Core.Editor.delete_other_windows()
    Aimax.Core.Editor.set_window_buffer("ui-test-#{System.unique_integer([:positive])}")
    {:ok, conn: build_conn()}
  end

  test "mounts and shows the window with modeline", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "modeline"
    assert html =~ "ui-test-"
  end

  test "typing renders into the buffer", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    html = type(view, "hello")
    assert html =~ "hello"
    assert html =~ "L1:C5"
  end

  test "minibuffer shows on M-x with selectable candidates", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    html = keys(view, ["M-x"])
    assert html =~ "M-x "
    assert html =~ "mb-cand selected"

    # candidate order is recency-first, so filter before asserting a name
    html = type(view, "backwardchar")
    assert html =~ "backward-char"
    keys(view, ["C-g"])
  end

  test "which-key renders on C-x", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    html = keys(view, ["C-x"])
    assert html =~ "which-key"
    assert html =~ "switch-to-buffer"
    keys(view, ["C-g"])
  end

  test "window splits render as a tree", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    html = keys(view, ["C-x", "3"])
    assert html =~ ~s(class="split h")
    html = keys(view, ["C-x", "1"])
    refute html =~ ~s(class="split h")
  end

  test "undo works through the window", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    html = type(view, "xy")
    assert html =~ "xy"
    html = keys(view, ["C-/"])
    refute html =~ "xy"
  end

  # An overlay range is bytes. A range that ends inside a multi-byte
  # character used to cut the segment mid-character, and Jason killed the
  # socket on the reply: the window went blank and no client could
  # reconnect. The segments now snap to character boundaries.
  test "an overlay that ends inside a multi-byte character still renders",
       %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    buf = Aimax.Core.Editor.current_buffer()
    Aimax.Core.Buffer.append(buf, "    —     — a command", source: {:agent, "test"})

    # the em dash occupies bytes 4..6; end the overlay on byte 5, inside it
    {:ok, _} =
      Aimax.Core.Session.eval(
        ~s{(overlay-set! "#{buf}" 'zz-utf8 (list (list 0 5 "region")))}
      )

    html = render(view)
    assert html =~ "a command"
    assert String.valid?(html)
  end

  # Every dired test read the buffer text, so all of them passed while the
  # window showed nothing. The buffer kept 'render-mode "blocks" from the
  # mode before it, and a leaf that says "blocks" draws cards, not lines.
  # This test reads the window, which is where the listing went missing.
  test "a dired window renders its listing, stale render-mode or not", %{conn: conn} do
    root = Path.join(System.tmp_dir!(), "ui-dired-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "gamma.txt"), "G")
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, view, _} = live(conn, "/")
    {:ok, _} = Aimax.Core.Session.eval(~s{(dired-open "#{root}")})
    assert render(view) =~ "gamma.txt"

    # the local a previous mode left behind must not empty the window
    {:ok, _} = Aimax.Core.Session.eval(~s{(buffer-set-local! "#{root}" 'render-mode "blocks")})
    html = render(view)
    assert html =~ "gamma.txt"
    # the card view draws one div per window; the stylesheet names the
    # class too, so match the div's id rather than the class
    refute html =~ ~s(id="blocks-)
  end

  test "rpc/agent edits to a visible buffer appear live", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    render(view)
    buf = Aimax.Core.Editor.current_buffer()
    Aimax.Core.Buffer.append(buf, "pushed from outside", source: {:agent, "test"})
    # event-driven re-render
    assert render(view) =~ "pushed from outside"
  end
end
