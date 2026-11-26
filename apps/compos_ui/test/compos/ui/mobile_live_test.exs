defmodule Compos.Ui.MobileLiveTest do
  @moduledoc """
  The handheld client, driven the way the phone drives it: every tap
  arrives as a named event, and the page is read back by what it names.
  The selectors are ComposML's domain elements (modeline, window, line,
  prompt, echo, tabs, list, item, minibuffer, completion) and their
  state attributes, never a style class.
  """

  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint Compos.Ui.Endpoint

  # The handheld's policy is the handheld package, which lives outside
  # this tree. The page is a projection of what it answers, so the test
  # answers for it: fixed rows, and taps that leave a message to read.
  @policy ~S"""
  (begin
    (define (handheld-view buf)
      (list "hh-test-group" #f
            '(("buffers-title" "Buffers") ("groups-title" "Groups") ("commands-title" "Commands")
              ("empty" "Nothing here") ("matchless" "No match") ("placeholder" "Ask"))
            '()))
    (define (handheld-groups . q)
      (filter (lambda (r) (or (null? q) (string-contains? (cadr r) (car q))))
              '(("hh-g1" "First" #t) ("hh-g2" "Second" #f))))
    (define (handheld-buffers cur . q)
      (list (list "this group" (list (list cur cur "fundamental" #t)))))
    (define (handheld-commands buf)
      (list (list "recent" '(("keyboard-quit" "Quit")))))
    (define (handheld-search buf q)
      (filter (lambda (r) (string-contains? (car r) q))
              '(("keyboard-quit" "Quit") ("save-buffer" "Save the buffer"))))
    (define (handheld-run-command! name) (message (string-append "ran " name)))
    (define (handheld-group! id) (message (string-append "group " id)))
    (define (handheld-buffer! name) (message (string-append "buffer " name)))
    (define (handheld-compose! text) (message (string-append "sent " text)))
    (define (handheld-chat!) (message "chat"))
    (define (handheld-scrub! n)
      (goto-char! (line-start-position (max 1 (min n (line-number-at-pos (buffer-size (current-buffer)))))))
      n)
    #t)
  """

  defp hook(view, event, payload) do
    view |> element("#hh") |> render_hook(event, payload)
  end

  # a plain text buffer in the window, point at its start
  defp lines_buffer(text) do
    buf = "hh-lines-#{System.unique_integer([:positive])}"
    {:ok, _} = Compos.Core.create_buffer(buf)
    Compos.Core.Buffer.insert(buf, text)
    on_exit(fn -> Compos.Core.kill_buffer(buf) end)
    {:ok, _} = Compos.Core.Session.eval(~s{(switch-to-buffer! "#{buf}")})
    {:ok, _} = Compos.Core.Session.eval("(goto-char! 0)")
    buf
  end

  setup do
    Compos.Core.Editor.minibuffer_close()
    Compos.Core.Editor.completion_dismiss()
    Compos.Core.Editor.set_pending([])
    Compos.Core.Editor.set_total_rows(40)
    {:ok, _} = Compos.Core.Session.eval(@policy)
    {:ok, _} = Compos.Core.Session.eval("(test-one-window!)")
    Compos.Core.Editor.set_window_buffer("hh-test-#{System.unique_integer([:positive])}")
    {:ok, conn: build_conn()}
  end

  test "the page names its modeline, its one window, the composer, and the bar's tabs", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")
    buf = Compos.Core.Editor.current_buffer()

    assert has_element?(view, "c-frame#hh > c-modeline c-buffer-name[modified]")
    assert has_element?(view, ~s(c-frame#hh > c-window > c-buffer[buffer="#{buf}"]))
    assert has_element?(view, "c-frame#hh > c-prompt input#composer")
    assert has_element?(view, "c-frame#hh > c-prompt c-action#composer-send")

    for tab <- ~w(chat buffers groups commands) do
      assert has_element?(view, "c-frame#hh > c-tabs > c-tab[data-nav='#{tab}']")
    end

    refute has_element?(view, "c-list")
    refute has_element?(view, "c-minibuffer")
  end

  test "a buffer's lines are lines, and the one at point is current", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")
    lines_buffer("one\ntwo\nthree\n")
    # the phone's row count refreshes the page at once
    hook(view, "viewport", %{"rows" => 40})

    assert has_element?(view, "c-buffer c-line[number='1'][current='true']", "one")
    assert has_element?(view, "c-buffer c-line[number='2'][current='false']", "two")
  end

  test "the buffers tab opens a list of buffers with the shown one current; the tab closes it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")
    buf = Compos.Core.Editor.current_buffer()

    hook(view, "nav", %{"to" => "buffers"})
    assert has_element?(view, "c-tabs > c-tab[data-nav='buffers'][selected='true']")
    assert has_element?(view, "c-list[data-sheet='buffers'] c-item[kind='buffer'][current='true'] c-label", buf)

    hook(view, "nav", %{"to" => "buffers"})
    refute has_element?(view, "c-list")
    assert has_element?(view, "c-tabs > c-tab[data-nav='buffers'][selected='false']")
  end

  test "the commands list narrows by its filter, and RET hands the first command to the policy", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")

    hook(view, "nav", %{"to" => "commands"})
    assert has_element?(view, "c-list[data-sheet='commands'] c-field[name='filter'] input")
    assert has_element?(view, "c-list[data-sheet='commands'] c-headline", "recent")

    hook(view, "sheet_filter", %{"value" => "save"})
    assert has_element?(view, "c-list[data-sheet='commands'] c-item[kind='command'] c-label", "save-buffer")
    assert has_element?(view, "c-list[data-sheet='commands'] c-item[kind='command'] c-hint", "Save the buffer")
    refute has_element?(view, "c-list[data-sheet='commands'] c-item c-label", "keyboard-quit")

    hook(view, "sheet_filter", %{"value" => "nothing-matches-this"})
    assert has_element?(view, "c-list[data-sheet='commands'] c-empty", "No match")

    # RET in the filter takes the first row it leaves
    hook(view, "sheet_filter", %{"key" => "Enter", "value" => "quit"})
    refute has_element?(view, "c-list")
    assert has_element?(view, "c-prompt c-echo", "ran keyboard-quit")
  end

  test "the groups tab lists the groups with the frame's current, and a picked one is handed to the policy", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")

    hook(view, "nav", %{"to" => "groups"})
    assert has_element?(view, "c-list[data-sheet='groups'] c-headline", "Groups")
    assert has_element?(view, "c-list[data-sheet='groups'] c-item[kind='group'][current='true'] c-label", "First")
    assert has_element?(view, "c-list[data-sheet='groups'] c-item[kind='group'][current='true'] c-status", "here")
    assert has_element?(view, "c-list[data-sheet='groups'] c-item[kind='group'][current='false'] c-label", "Second")

    hook(view, "sheet_filter", %{"value" => "Sec"})
    refute has_element?(view, "c-list[data-sheet='groups'] c-item c-label", "First")

    hook(view, "pick", %{"kind" => "group", "id" => "hh-g2"})
    refute has_element?(view, "c-list")
    assert has_element?(view, "c-prompt c-echo", "group hh-g2")
  end

  test "a prompt is a minibuffer of completions, and a tap on one accepts it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")

    {:ok, _} =
      Compos.Core.Session.eval(
        ~s{(minibuffer-read "Pick: " (list "alpha" "beta" "gamma") (lambda (s) (message (string-append "picked " s))))}
      )

    render(view)
    assert has_element?(view, "#hh[data-mb='true']")
    assert has_element?(view, "c-minibuffer c-headline", "Pick")
    assert has_element?(view, "c-minibuffer c-completions c-completion[selected='true'] c-label", "alpha")
    assert has_element?(view, "c-minibuffer c-completions c-completion[selected='false'] c-label", "beta")
    assert has_element?(view, "c-prompt c-label", "Pick:")

    hook(view, "cand", %{"i" => 2})
    refute has_element?(view, "c-minibuffer")
    assert has_element?(view, "c-prompt c-echo", "picked gamma")
  end

  test "the composer hands its line to the policy", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")
    assert has_element?(view, "c-prompt input#composer[placeholder='Ask']")
    hook(view, "compose", %{"text" => "hello"})
    assert has_element?(view, "c-prompt c-echo[error='false']", "sent hello")
  end

  test "the rail moves point to the line the drag names", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")
    lines_buffer("one\ntwo\nthree\nfour\nfive\n")
    hook(view, "viewport", %{"rows" => 40})
    assert has_element?(view, "c-window > c-position[data-rail]")

    hook(view, "rail", %{"frac" => 0.0})
    assert has_element?(view, "c-line[number='1'][current='true']", "one")

    hook(view, "rail", %{"frac" => 1.0})
    assert has_element?(view, "c-line[number='6'][current='true']")
  end

  test "a split frame draws only the selected window", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")
    n = System.unique_integer([:positive])
    b1 = "hh-split-a-#{n}"
    b2 = "hh-split-b-#{n}"
    {:ok, _} = Compos.Core.create_buffer(b1)
    {:ok, _} = Compos.Core.create_buffer(b2)
    Compos.Core.Buffer.insert(b1, "alpha-pane-text")
    Compos.Core.Buffer.insert(b2, "beta-pane-text")
    on_exit(fn -> for b <- [b1, b2], do: Compos.Core.kill_buffer(b) end)

    {:ok, _} = Compos.Core.Session.eval(~s{(switch-to-buffer! "#{b1}")})
    {:ok, _} = Compos.Core.Session.eval("(split-window! 'h)")
    {:ok, _} = Compos.Core.Session.eval(~s{(switch-to-buffer! "#{b2}")})

    render(view)
    assert has_element?(view, "c-window", "beta-pane-text")
    refute has_element?(view, "c-window", "alpha-pane-text")
    assert [_] = Regex.scan(~r/<c-window[\s>]/, render(view))
  end
end
