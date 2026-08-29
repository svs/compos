defmodule Compos.Ui.DaemonSwitchTest do
  @moduledoc "A daemon switch keeps the browser tab and changes its endpoint."

  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint Compos.Ui.Endpoint

  alias Compos.Core.{Editor, Session}

  setup do
    path = Application.fetch_env!(:compos_core, :daemon_registry_path)
    File.rm(path)
    {:ok, _} = Session.eval("(daemon-register-current! #f)")
    Editor.minibuffer_close()
    Editor.delete_other_windows()

    on_exit(fn ->
      Compos.Core.kill_buffer("*daemons*")
      File.rm(path)
      Session.eval("(daemon-register-current! #f)")
    end)

    {:ok, conn: build_conn()}
  end

  test "C-x d switches the same client to a second daemon endpoint", %{conn: conn} do
    remote = "http://localhost:4555"
    {:ok, _} = Session.eval(~s{(daemon-register! "feature" "#{remote}" "local")})
    {:ok, view, _html} = live(conn, "/")

    view |> element("#editor") |> render_hook("key", %{"k" => "C-x"})
    view |> element("#editor") |> render_hook("key", %{"k" => "d"})
    assert render(view) =~ "feature"

    view |> element("#editor") |> render_hook("key", %{"k" => "n"})
    view |> element("#editor") |> render_hook("key", %{"k" => "RET"})

    target = remote <> "?daemon-switch=1"
    assert_push_event(view, "navigate", %{url: ^target})
  end

  test "the target daemon announces its restored workspace", %{conn: conn} do
    buffer = "daemon-arrival-#{System.unique_integer([:positive])}"
    Editor.set_window_buffer(buffer)

    {:ok, _} =
      Session.eval(~s{(buffer-set-local! "#{buffer}" 'workspace-root "/srv/feature")})

    {:ok, view, _html} = live(conn, "/?daemon-switch=1")

    assert render(view) =~ "compos · workspace /srv/feature"
  end
end
