defmodule Compos.Ui.DisplayUpdateTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Compos.Core.{Buffer, Editor, Events, Session}
  @endpoint Compos.Ui.Endpoint

  test "a display update retains the old presentation until the final text and point are ready" do
    Editor.minibuffer_close()
    {:ok, _} = Compos.Core.Session.eval("(test-one-window!)")
    name = "zz-display-#{System.unique_integer([:positive])}"
    Compos.Core.create_buffer(name, text: "STABLE_PRESENTATION")
    Editor.set_window_buffer(name)
    {:ok, view, _} = live(build_conn(), "/")
    assert render(view) =~ "STABLE_PRESENTATION"
    previous_window = view |> element(".window") |> render()
    parent = self()

    task =
      Task.async(fn ->
        Events.with_display_update(name, fn ->
          Buffer.replace_range(name, 0, byte_size(Buffer.text(name)), "HALF_WRITTEN",
            source: :editor
          )

          send(parent, {:half_written, self()})

          receive do
            :finish -> :ok
          end

          Buffer.replace_range(name, 0, byte_size(Buffer.text(name)), "FINAL_PRESENTATION",
            source: :editor
          )
        end)
      end)

    assert_receive {:half_written, writer}
    on_exit(fn -> send(writer, :finish) end)
    html = render(view)
    assert html =~ "STABLE_PRESENTATION"
    refute html =~ "HALF_WRITTEN"
    assert view |> element(".window") |> render() == previous_window
    send(writer, :finish)
    Task.await(task)
    html = render(view)
    assert html =~ "FINAL_PRESENTATION"
    refute html =~ "STABLE_PRESENTATION"
    Compos.Core.kill_buffer(name)
  end

  test "Scheme display boundaries nest and release after errors" do
    name = "zz-display-errors"
    Compos.Core.create_buffer(name)

    Events.with_display_update(name, fn ->
      assert Events.display_updating?(name)
      Events.with_display_update(name, fn -> assert Events.display_updating?(name) end)
      assert Events.display_updating?(name)
    end)

    refute Events.display_updating?(name)

    assert {:error, _} =
             Session.eval("""
             (with-buffer-display-update "#{name}" (lambda () (error "display-test-error")))
             """)

    refute Events.display_updating?(name)
    Compos.Core.kill_buffer(name)
  end
end
