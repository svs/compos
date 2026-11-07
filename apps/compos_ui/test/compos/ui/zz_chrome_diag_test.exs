defmodule Compos.Ui.ZzChromeDiagTest do
  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint Compos.Ui.Endpoint

  defp keys(view, specs) do
    Enum.each(specs, fn k -> view |> element("#editor") |> render_hook("key", %{"k" => k}) end)
    render(view)
  end

  setup do
    Compos.Core.Editor.set_pending([])
    {:ok, _} = Compos.Core.Session.eval("(test-one-window!)")
    Compos.Core.Editor.set_window_buffer("ui-diag-#{System.unique_integer([:positive])}")
    :ok
  end

  test "diag" do
    buf = Compos.Core.Editor.current_buffer()
    {:ok, _} = Compos.Core.Session.eval("(begin (local-set-key* \"#{buf}\" \"<f9> a\" \"backward-char\") (local-set-key* \"#{buf}\" \"<f9> C-a\" \"backward-char\"))")
    {:ok, view, _} = live(build_conn(), "/")
    keys(view, ["<f9>"])
    Process.sleep(800)
    html = render(view)
    IO.puts("WKCALL " <> inspect(Compos.Core.Session.call_named("which-key-groups", [["<f9>"]])))
    IO.puts("WKROWS " <> inspect(Compos.Core.Session.call_named("which-key-rows", [["<f9>"]])))
    IO.puts("WKUP #{html =~ "wk-title"} #{html =~ "Unmodified"}")
    IO.puts("WK " <> inspect(Regex.run(~r/wk-groups.{0,1500}/s, html)))
    keys(view, ["C-g"])
    {:ok, _} = Compos.Core.Session.eval("(require 'show-keys)")
    {:ok, _} = Compos.Core.Session.eval("(customize-set! 'show-keys-mode #t)")
    keys(view, ["C-x"])
    html = keys(view, ["C-g"])
    IO.puts("PENDING #{inspect(Compos.Core.Editor.render_state().pending)} " <> inspect(Regex.run(~r/class="keycast".{0,600}/s, html)))
  end
end
