defmodule Compos.Ui.MobileLiveTest do
  @moduledoc """
  The phone client, driven the way the phone drives it: every tap
  arrives as a named event, and the page is read back by what it names.
  The selectors are ComposML's domain elements and their state
  attributes, never a style class.
  """

  use ExUnit.Case

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint Compos.Ui.Endpoint

  # The page is a projection of what phone.scm answers, so the test
  # answers for it: fixed rows, and taps that leave a message to read.
  @policy ~S"""
  (begin
    (define (phone-attach!) #t)
    (define (phone-view buf) (list "ph-test-group" (and buf (string-prefix? "ph-chat" buf) #t)))
    (define (phone-chats q cur)
      (filter (lambda (r) (string-contains? (cadr r) q))
              '(("ph-chat-1" "First chat" "g · idle" #f) ("ph-chat-2" "Second chat" "g · working" #f))))
    (define (phone-buffers q cur)
      (list (list "this group" (list (list cur cur "g" #t)))))
    (define (phone-groups q)
      (filter (lambda (r) (string-contains? (cadr r) q))
              '(("ph-g1" "First" "" #t) ("ph-g2" "Second" "" #f))))
    (define (phone-show! name) (message (string-append "show " name)))
    (define (phone-group! id) (message (string-append "group " id)))
    (define (phone-new-chat!) (message "new chat"))
    (define (phone-send! chat text) (message (string-append "sent " text)))
    #t)
  """

  defp hook(view, event, payload) do
    view |> element("#hh") |> render_hook(event, payload)
  end

  setup do
    Compos.Core.Editor.minibuffer_close()
    Compos.Core.Editor.completion_dismiss()
    Compos.Core.Editor.set_pending([])
    Compos.Core.Editor.set_total_rows(40)
    {:ok, _} = Compos.Core.Session.eval(@policy)
    {:ok, _} = Compos.Core.Session.eval("(test-one-window!)")
    Compos.Core.Editor.set_window_buffer("ph-test-#{System.unique_integer([:positive])}")
    {:ok, conn: build_conn()}
  end

  test "the page names its header, its one window and the four places of the bar", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")
    buf = Compos.Core.Editor.current_buffer()

    assert has_element?(view, "c-frame#hh > c-modeline c-field[name='group']", "ph-test-group")
    assert has_element?(view, "c-frame#hh > c-modeline c-buffer-name", buf)
    assert has_element?(view, ~s(c-frame#hh > c-window > c-buffer[buffer="#{buf}"]))

    for tab <- ~w(chats buffers groups) do
      assert has_element?(view, "c-frame#hh > c-tabs > c-tab[data-nav='#{tab}']")
    end

    # no chat on show: no composer
    refute has_element?(view, "input#composer")
    refute has_element?(view, "c-list")
  end

  test "the chats place lists the chats, narrows them, and a tap shows one", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")

    hook(view, "nav", %{"to" => "chats"})
    assert has_element?(view, "c-tabs > c-tab[data-nav='chats'][selected='true']")
    assert has_element?(view, "c-list[data-sheet='chats'] c-item c-label", "First chat")
    assert has_element?(view, "c-list[data-sheet='chats'] c-item c-hint", "g · working")

    hook(view, "sheet_filter", %{"value" => "Second"})
    refute has_element?(view, "c-list[data-sheet='chats'] c-item c-label", "First chat")

    hook(view, "pick", %{"id" => "ph-chat-2"})
    refute has_element?(view, "c-list")
    assert has_element?(view, "c-echo", "show ph-chat-2")
  end

  test "New chat heads the chats and starts one at once", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")
    refute has_element?(view, "c-tabs > c-tab[data-nav='new']")
    hook(view, "nav", %{"to" => "chats"})
    assert has_element?(view, "c-list[data-sheet='chats'] c-item[data-nav='new']", "New chat")
    hook(view, "nav", %{"to" => "new"})
    refute has_element?(view, "c-list")
    assert has_element?(view, "c-echo", "new chat")
  end

  test "the buffers place marks the shown buffer; its place closes it again", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")
    buf = Compos.Core.Editor.current_buffer()

    hook(view, "nav", %{"to" => "buffers"})
    assert has_element?(view, "c-list[data-sheet='buffers'] c-headline", "this group")
    assert has_element?(view, "c-list[data-sheet='buffers'] c-item[current='true'] c-label", buf)

    hook(view, "nav", %{"to" => "buffers"})
    refute has_element?(view, "c-list")
  end

  test "the groups place: RET in the filter takes the first group it leaves", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")

    hook(view, "nav", %{"to" => "groups"})
    assert has_element?(view, "c-list[data-sheet='groups'] c-item[current='true'] c-label", "First")

    hook(view, "sheet_filter", %{"key" => "Enter", "value" => "Sec"})
    refute has_element?(view, "c-list")
    assert has_element?(view, "c-echo", "group ph-g2")
  end

  test "a chat on show has the composer, and it sends to the chat", %{conn: conn} do
    # the page's own frame may show any buffer: here every buffer is a chat
    {:ok, _} = Compos.Core.Session.eval(~S{(define (phone-view buf) (list "ph-test-group" #t))})
    {:ok, view, _html} = live(conn, "/m")

    assert has_element?(view, "c-frame#hh > c-prompt input#composer")
    assert has_element?(view, "c-tabs > c-tab[data-nav='chats'][selected='true']")
    hook(view, "compose", %{"text" => "hello"})
    assert has_element?(view, "c-echo", "sent hello")
  end

  test "a prompt is a sheet of rows, and a tap on one accepts it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/m")

    {:ok, _} =
      Compos.Core.Session.eval(
        ~s{(minibuffer-read "Pick: " (list "alpha" "beta" "gamma") (lambda (s) (message (string-append "picked " s))))}
      )

    render(view)
    assert has_element?(view, "c-minibuffer c-headline", "Pick")
    assert has_element?(view, "c-minibuffer c-completion[selected='true'] c-label", "alpha")

    hook(view, "cand", %{"i" => 2})
    refute has_element?(view, "c-minibuffer")
    assert has_element?(view, "c-echo", "picked gamma")
  end
end
