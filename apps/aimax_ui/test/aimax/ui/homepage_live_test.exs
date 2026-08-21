defmodule Aimax.Ui.HomepageLiveTest do
  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint Aimax.Ui.Endpoint

  test "renders the Operad homepage and its primary message" do
    {:ok, _view, html} = live(build_conn(), "/operad")

    assert html =~ "The OS for"
    assert html =~ "knowledge work."
    assert html =~ "Operad — the thinking person’s browser"
    assert html =~ "Everything stays within arm’s reach."
    assert html =~ "Not a chat window."
    assert html =~ "/images/operad-sentry-workspace.png"
    refute html =~ "hero-product"
    assert html =~ "Read."
    assert html =~ "Write."
    assert html =~ "Communicate."
    assert html =~ "Monitor."
    assert html =~ "Fix."
    assert html =~ "The right thing appears beside the work."
    assert html =~ "Reach for a command, not another app."
    assert html =~ "Your whole working world. Within reach."
    assert html =~ "/images/operad-fractal-master.png"
    assert html =~ "Get early access"
  end

  test "keeps the editor on the root route" do
    Aimax.Core.Editor.set_window_buffer("homepage-route-test")
    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "homepage-route-test"
    refute html =~ "The OS for knowledge work"
  end
end
