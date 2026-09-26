defmodule Compos.Ui.HomepageLiveTest do
  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint Compos.Ui.Endpoint

  test "renders the Compos homepage with its compositional identity" do
    {:ok, _view, html} = live(build_conn(), "/compos")

    assert html =~ "COMPOS / QUIET COMPUTING ENVIRONMENT"
    assert html =~ "compos-wordmark"
    assert html =~ "compos.in · © 2026 Compos"
    assert html =~ "/images/compos-logo.png"
    assert html =~ "/images/compos-study-symbolic-composition-v1.png"
    assert html =~ "Harness for Power Users."
    assert html =~ "It&#39;s like Emacs, but it&#39;s on the BEAM."
    assert html =~ "the working context is explicit, inspectable, and composed by you."
    assert html =~ "System model"
    assert html =~ "Material with identity"
    assert html =~ "A projection, not a container"
    assert html =~ "A reversible state transition"
    assert html =~ "/images/compos-sentry-workspace.png"
    assert html =~ "mailto:hello@compos.in"
  end

  test "keeps the editor on the root route" do
    Compos.Core.Editor.set_window_buffer("homepage-route-test")
    {:ok, _view, html} = live(build_conn(), "/")

    assert html =~ "homepage-route-test"
    refute html =~ "Harness for Power Users"
  end
end
