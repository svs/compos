defmodule Compos.Ui.MobileLiveTest do
  @moduledoc """
  The handheld client, driven the way the phone drives it: every gesture
  arrives as a key or a named event, and the page is read back as HTML.
  Nothing here names a production binding; the chord test binds its own
  key under <f9>.
  """

  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint Compos.Ui.Endpoint

  defp hook(view, event, payload) do
    view |> element("#hh") |> render_hook(event, payload)
  end

  # a chord goes through dispatch-keys, which queues the keys behind the
  # event that asked for them; the page shows the result a moment later
  defp eventually(view, selector, text, tries \\ 40) do
    cond do
      has_element?(view, selector, text) -> true
      tries == 0 -> false
      true -> Process.sleep(25); render(view); eventually(view, selector, text, tries - 1)
    end
  end

  setup do
    Compos.Core.Editor.minibuffer_close()
    Compos.Core.Editor.completion_dismiss()
    Compos.Core.Editor.set_pending([])
    Compos.Core.Editor.set_total_rows(40)
    {:ok, _} = Compos.Core.Session.eval("(test-one-window!)")
    Compos.Core.Editor.set_window_buffer("hh-test-#{System.unique_integer([:positive])}")
    {:ok, conn: build_conn()}
  end

  test "mounts one window with a modeline, a composer, a tab rail, and the chord key", %{conn: conn} do
    {:ok, view, html} = live(conn, "/m")
    assert has_element?(view, "#hh > .hh-modeline")
    assert has_element?(view, "#hh > .hh-composer #composer")
    assert has_element?(view, "#hh > .hh-tabs")
    assert has_element?(view, "#chord-key")
    assert html =~ "hh-test-"
    refute has_element?(view, ".hh-fan")
  end

  test "the panel opens on the modifiers and the plain keys, and a cap presses its chord", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")
    {:ok, _} = Compos.Core.Session.eval(~s{(global-set-key "<f9> q" "keyboard-quit")})
    on_exit(fn -> Compos.Core.Session.eval(~s{(global-unset-key "<f9> q")}) end)

    # the root: a square for every modifier and every plain key, nothing
    # latched, so there is nothing to go back to
    hook(view, "fan", %{"open" => true})
    assert has_element?(view, "#keys-panel .hh-keycap .hh-cap-key", "C-")
    assert has_element?(view, "#keys-panel .hh-keycap .hh-cap-key", "<f9>")
    refute has_element?(view, "#keys-panel .hh-keys-back")

    # a modifier or a prefix presses nothing: the caps become what it
    # leaves to press, and the back control says where the panel stands
    hook(view, "fan_tab", %{"t" => "<f9>"})
    assert has_element?(view, "#keys-panel .hh-keys-back", "<f9>")
    assert has_element?(view, "#keys-panel .hh-keycap .hh-cap-key", "q")
    assert has_element?(view, "#keys-panel .hh-keycap .hh-cap-cmd", "keyboard-quit")

    # back lets the step go: the root again
    hook(view, "fan_back", %{})
    refute has_element?(view, "#keys-panel .hh-keys-back")
    assert has_element?(view, "#keys-panel .hh-keycap .hh-cap-key", "<f9>")

    # a cap that ends a binding is the whole chord: the prefix and the key
    # both go through
    hook(view, "fan_tab", %{"t" => "<f9>"})
    hook(view, "fan_run", %{"s" => "<f9>", "k" => "q", "c" => "keyboard-quit"})
    refute has_element?(view, "#keys-panel")
    assert has_element?(view, ".hh-echo", "Quit")
    refute has_element?(view, ".hh-ml-pending")
  end

  test "a modifier cap leads the grid, whatever the key sort says", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")
    {:ok, _} = Compos.Core.Session.eval(~s{(global-set-key "<f9> a" "keyboard-quit")})
    {:ok, _} = Compos.Core.Session.eval(~s{(global-set-key "<f9> C-b" "keyboard-quit")})

    on_exit(fn ->
      Compos.Core.Session.eval(~s{(global-unset-key "<f9> a")})
      Compos.Core.Session.eval(~s{(global-unset-key "<f9> C-b")})
    end)

    # the rows sort by key, so "a" comes before "C-b"; the cap for the
    # modifier still leads, because a modifier is what you reach for first
    hook(view, "fan", %{"open" => true})
    hook(view, "fan_tab", %{"t" => "<f9>"})

    caps =
      ~r{<c-text class="hh-cap-key[^"]*">([^<]*)</c-text>}
      |> Regex.scan(render(view))
      |> Enum.map(fn [_, key] -> key end)

    assert ["C-" | rest] = caps
    assert "a" in rest
  end

  test "typing in the panel searches every command, and a match runs by name", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")

    {:ok, _} =
      Compos.Core.Session.eval(
        ~s{(define-command "zz-hh-search-target" "Search target for the handheld test" (lambda () (message "zz target ran")))}
      )

    {:ok, _} = Compos.Core.Session.eval(~s{(global-set-key "<f9> q" "keyboard-quit")})
    on_exit(fn -> Compos.Core.Session.eval(~s{(global-unset-key "<f9> q")}) end)

    hook(view, "fan", %{"open" => true})
    assert has_element?(view, "#keys-panel .hh-keycap")

    # a command no key reaches is found by a word of its doc, and M-x is its key
    hook(view, "fan_filter", %{"q" => "search target handheld"})
    assert has_element?(view, "#keys-panel [data-section='matches'] .hh-key-row .hh-key-cmd", "zz-hh-search-target")
    assert has_element?(view, "#keys-panel [data-section='matches'] .hh-key-row .hh-key-box", "M-x")
    refute has_element?(view, "#keys-panel [data-section='plain']")

    # a bound command is found too
    hook(view, "fan_filter", %{"q" => "keyboard-quit"})
    assert has_element?(view, "#keys-panel [data-section='matches'] .hh-key-row .hh-key-cmd", "keyboard-quit")

    # empty text is the caps again
    hook(view, "fan_filter", %{"q" => "  "})
    refute has_element?(view, "#keys-panel [data-section='matches']")
    assert has_element?(view, "#keys-panel .hh-keycap")

    # a tap on a match runs the command by name and closes the panel
    hook(view, "fan_filter", %{"q" => "zz-hh-search"})
    hook(view, "fan_run", %{"s" => "matches", "k" => "M-x", "c" => "zz-hh-search-target"})
    refute has_element?(view, "#keys-panel")
    assert has_element?(view, ".hh-echo", "zz target ran")
  end

  test "the panel opens on the pending prefix's tab and does not press it twice", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")
    {:ok, _} = Compos.Core.Session.eval(~s{(global-set-key "<f9> q" "keyboard-quit")})
    on_exit(fn -> Compos.Core.Session.eval(~s{(global-unset-key "<f9> q")}) end)

    hook(view, "key", %{"k" => "<f9>"})
    assert has_element?(view, ".hh-ml-pending", "<f9>-")
    hook(view, "fan", %{"open" => true})
    assert has_element?(view, "#keys-panel .hh-keys-back", "<f9>")
    # the frame is the one holding it, so the panel offers to let it go
    assert has_element?(view, "#keys-panel .hh-keys-release", "<f9>")

    hook(view, "fan_run", %{"s" => "<f9>", "k" => "q"})
    assert has_element?(view, ".hh-echo", "Quit")
    refute has_element?(view, ".hh-ml-pending")
  end

  test "the release lets the frame's prefix go and keeps the panel open", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")
    {:ok, _} = Compos.Core.Session.eval(~s{(global-set-key "<f9> q" "keyboard-quit")})
    on_exit(fn -> Compos.Core.Session.eval(~s{(global-unset-key "<f9> q")}) end)

    hook(view, "key", %{"k" => "<f9>"})
    hook(view, "fan", %{"open" => true})
    hook(view, "fan_release", %{})
    assert has_element?(view, "#keys-panel")
    refute has_element?(view, ".hh-ml-pending")
  end

  test "a prompt renders as a sheet and a tap on a row accepts it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")

    {:ok, _} =
      Compos.Core.Session.eval(
        ~s{(minibuffer-read "Pick: " (list "alpha" "beta" "gamma") (lambda (s) (message (string-append "picked " s))))}
      )

    html = render(view)
    assert html =~ "hh-sheet"
    assert has_element?(view, "#hh[data-mb='true']")
    assert has_element?(view, ".hh-row", "beta")

    hook(view, "cand", %{"i" => 2})
    refute has_element?(view, ".hh-sheet")
    assert has_element?(view, ".hh-echo", "picked gamma")
  end

  test "the composer sends a chord through the keymap and a command by name", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")
    {:ok, _} = Compos.Core.Session.eval(~s{(global-set-key "<f9> m" "keyboard-quit")})
    on_exit(fn -> Compos.Core.Session.eval(~s{(global-unset-key "<f9> m")}) end)

    hook(view, "compose", %{"text" => "<f9> m"})
    assert eventually(view, ".hh-echo", "Quit")

    hook(view, "compose", %{"text" => "M-x hh-no-such-command"})
    assert has_element?(view, ".hh-echo", "No command named hh-no-such-command")
  end

  test "the tab rail is the groups: the current one opens its buffers, another one its chat", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")
    buf = Compos.Core.Editor.current_buffer()
    {:ok, g} = Compos.Core.Session.eval(~s{(group-ensure! "#{buf}")})
    g = String.trim(g, "\"")
    render(view)
    assert has_element?(view, ".hh-tab.on")

    # founding the group put the frame in it: a tap is the buffer prompt
    hook(view, "tab", %{"buf" => g})
    assert has_element?(view, "#hh[data-mb='true']")
    hook(view, "key", %{"k" => "C-g"})
    refute has_element?(view, "#hh[data-mb='true']")

    # a second group takes the frame; the tap on the first is a switch
    other = "hh-g2-#{System.unique_integer([:positive])}"
    {:ok, _} = Compos.Core.Session.eval(~s{(switch-to-group! (group-record-create! "#{other}"))})
    render(view)
    hook(view, "tab", %{"buf" => g})
    # the chat draws as its block tree, the chat's own layout
    assert has_element?(view, ~s(c-buffer.hh-blocks.agent-view))
  end

  test "the rail moves point to the line the drag names", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")
    buf = Compos.Core.Editor.current_buffer()
    Compos.Core.Buffer.insert(buf, "one\ntwo\nthree\nfour\nfive\n")
    hook(view, "rail", %{"frac" => 1.0})
    assert Compos.Core.Buffer.line_of(buf, Compos.Core.Buffer.point(buf)) == 6
    hook(view, "rail", %{"frac" => 0.0})
    assert Compos.Core.Buffer.point(buf) == 0
  end
end
