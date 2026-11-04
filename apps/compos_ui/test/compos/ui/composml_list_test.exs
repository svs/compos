defmodule Compos.Ui.ComposMLListTest do
  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Compos.Core.{Buffer, Editor, KeyDispatch, Session}
  @endpoint Compos.Ui.Endpoint

  defp eval!(s) do
    assert {:ok, result} = Session.eval(s)
    result
  end

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    {:ok, _} = Compos.Core.Session.eval("(test-one-window!)")
    buf = "*semantic-list-test*"

    eval!(~S"""
    (begin
      (define zz-semantic-preview nm--maybe-preview!)
      (define zz-semantic-previewed #f)
      (set! nm--maybe-preview! (lambda (buf) (set! zz-semantic-previewed (car (list-current buf)))))
      (define zz-semantic-rows '(("one" "Subject <one>" "Alice" ("inbox" "unread") "Today")
                                ("two" "Subject two" "Bob" ("inbox") "Yesterday")))
      (define-list-mode! "zz-semantic-list-mode"
        (list 'rows (lambda (buf) zz-semantic-rows)
              'key (lambda (buf row) (car row))
              'row-columns (lambda (buf) (nm--search-columns buf))
              'row-cells (lambda (buf row) (nm--search-cells buf row))
              'on-click (lambda (buf th) (nm--click-thread! buf th))
              'composml-root (lambda (buf) (list 'tag "mailbox" 'attrs '(("source" "test") ("query" "tag:inbox"))))
              'collection "mail-threads"
              'composml (lambda (buf row) (nm--thread-composml buf row))
              'title (lambda (buf) "Mail")))
      (buffer-create "*semantic-list-test*")
      (switch-to-buffer! "*semantic-list-test*")
      (set-mode! "zz-semantic-list-mode"))
    """)

    on_exit(fn ->
      Session.eval("(set! nm--maybe-preview! zz-semantic-preview)")
      if Buffer.exists?(buf), do: Compos.Core.kill_buffer(buf)
    end)

    %{buf: buf}
  end

  test "semantic mail scales through buffer-local text scale commands", %{buf: buf} do
    {:ok, view, _} = live(build_conn(), "/")
    Editor.local_bind_key(buf, ["<f9>"], "text-scale-increase")
    KeyDispatch.handle_key("<f9>")
    assert Buffer.get_local(buf, "text-scale") == 1
    assert has_element?(view, ~s(mailbox.blocks-view[style*="--text-scale-factor:1.2"] mail-subject))

    Editor.local_bind_key(buf, ["<f9>"], "text-scale-reset")
    KeyDispatch.handle_key("<f9>")
    assert Buffer.get_local(buf, "text-scale") == 0
    refute has_element?(view, ~s(mailbox.blocks-view[style*="--text-scale-factor:1.2"]))
  end

  test "two visual lines become one semantic record with shared field roles", %{buf: buf} do
    {:ok, view, html} = live(build_conn(), "/")
    assert has_element?(view, ~s(mailbox[source="test"][query="tag:inbox"][phx-hook="BlockScroll"] mail-threads))
    refute has_element?(view, "c-group.blocks-view")
    doc = LazyHTML.from_document(html)
    assert Enum.count(LazyHTML.query(doc, "mail-threads > mail-thread")) == 2

    assert has_element?(
             view,
             ~s(mail-thread[record-id="one"][selected="true"] mail-subject[field="primary"]),
             "Subject <one>"
           )

    assert has_element?(view, ~s(mail-thread[record-id="one"] mail-tag), "unread")
    assert html =~ "Subject &lt;one&gt;"
    assert Buffer.text(buf) =~ "Alice"
    view |> element(~s(mail-thread[record-id="two"])) |> render_click()
    assert eval!(~S|(car (list-current "*semantic-list-test*"))|) == ~s("two")
    eval!(~S|(list-goto-index! "*semantic-list-test*" 0)|)

    Editor.local_bind_key(buf, ["<f9>"], "list-next")
    KeyDispatch.handle_key("<f9>")
    assert eval!(~S|(car (list-current "*semantic-list-test*"))|) == ~s("two")
    # The frame render supplies current per-window point, without rebuilding rows.
    {:ok, _, html} = live(build_conn(), "/")

    assert Enum.count(
             LazyHTML.query(
               LazyHTML.from_document(html),
               ~s(mail-thread[record-id="two"][selected="true"])
             )
           ) == 1
  end

  test "refresh and mode re-entry rebuild records while retaining stable selection" do
    eval!(~S|(list-goto-index! "*semantic-list-test*" 1)|)

    eval!(
      ~S|(begin (set! zz-semantic-rows (reverse zz-semantic-rows)) (list-refresh! "*semantic-list-test*"))|
    )

    assert eval!(~S|(car (list-current "*semantic-list-test*"))|) == ~s("two")
    eval!(~S|(begin (set-mode! "text-mode") (set-mode! "zz-semantic-list-mode"))|)
    assert Buffer.get_local("*semantic-list-test*", "render-mode") == "blocks"
    {:ok, _, html} = live(build_conn(), "/")
    assert Enum.count(LazyHTML.query(LazyHTML.from_document(html), "mail-thread")) == 2
  end

  test "mailboxes and plain messages preserve typed fields and identities" do
    eval!(~S"""
    (buffer-set-local! "*semantic-list-test*" 'render-blocks
      (list (list 'tag "mailboxes" 'class "semantic-list"
                  'children (list (nm--mailbox-composml "*semantic-list-test*" '("Inbox" "tag:inbox" 184 12))))))
    """)

    {:ok, view, _} = live(build_conn(), "/")

    assert has_element?(
             view,
             ~s(mailboxes > mailbox[query="tag:inbox"] mailbox-name[field="primary"]),
             "Inbox"
           )

    assert has_element?(view, ~s(mailbox unread-count[field="count"]), "12")
    assert has_element?(view, ~s(mailbox message-count[field="count"]), "184")

    result =
      eval!(
        ~S|(nm--msg-composml '(id "message-1" headers (From "Alice" To "Bob") body ((id 1 content-type "text/plain" content "Hello <Bob>"))))|
      )

    assert result =~ "mail-message"
    assert result =~ "message-1"
    assert result =~ "Hello <Bob>"
  end

  test "lists without a semantic callback retain text rendering" do
    eval!(~S"""
    (begin
      (define-list-mode! "zz-plain-list-mode"
        (list 'rows (lambda (buf) '("plain"))
              'render (lambda (buf row) row)))
      (set-mode! "zz-plain-list-mode")
      (list-refresh! "*semantic-list-test*"))
    """)

    assert Buffer.get_local("*semantic-list-test*", "render-mode") in [nil, false]
    {:ok, view, _} = live(build_conn(), "/")
    refute has_element?(view, "mail-threads")
    assert Buffer.text("*semantic-list-test*") =~ "plain"
    assert has_element?(view, "c-list.buf c-item c-line")
  end

  test "marking a semantic row shows a visible indicator and clearing removes it", %{buf: buf} do
    Editor.local_bind_key(buf, ["<f8>"], "notmuch-mark-toggle")
    KeyDispatch.handle_key("<f8>")
    assert eval!(~S|(nm--any-marked? "*semantic-list-test*")|) == "#t"
    {:ok, view, _} = live(build_conn(), "/")
    assert has_element?(view, ~s(mail-thread[record-id="one"][marked="true"] .list-mark), "✱")
    Editor.local_bind_key(buf, ["<f7>"], "notmuch-unmark-all")
    KeyDispatch.handle_key("<f7>")
    {:ok, view, _} = live(build_conn(), "/")
    refute has_element?(view, "mail-thread .list-mark")
  end

  test "clicking a thread follows the keyboard preview path without changing marks" do
    eval!(~S|(nm--toggle-selection! "*semantic-list-test*" "one")|)
    {:ok, view, _} = live(build_conn(), "/")
    row = ~s(mail-thread[record-id="two"])
    view |> element(row) |> render_click()
    assert eval!("zz-semantic-previewed") == ~s("two")
    assert eval!(~S|(car (list-current "*semantic-list-test*"))|) == ~s("two")
    assert eval!(~S|(list-marks "*semantic-list-test*")|) == ~s{(("one" "*"))}
    refute has_element?(view, row <> " .list-mark")
  end
end
