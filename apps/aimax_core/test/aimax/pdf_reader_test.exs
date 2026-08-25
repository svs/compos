defmodule Aimax.Core.PdfReaderTest do
  use ExUnit.Case, async: false

  alias Aimax.Core.{Buffer, Editor, KeyDispatch, Session}

  defp eval!(source) do
    {:ok, printed} = Session.eval(source)
    printed
  end

  defp press(keys), do: Enum.each(List.wrap(keys), &KeyDispatch.handle_key/1)

  setup do
    Editor.minibuffer_close()
    Editor.set_pending([])
    Editor.delete_other_windows()

    eval!(~S"""
    (begin
      (unless (boundp 'zz-pdf-page-count)
        (define zz-pdf-page-count *pdf-page-count*)
        (define zz-pdf-render-page *pdf-render-page*)
        (define zz-pdf-page-text *pdf-page-text*)
        (define zz-pdf-file-exists *pdf-file-exists?*)
        (define zz-pdf-working-copy-exists *pdf-working-copy-exists?*)
        (define zz-pdf-copy-file *pdf-copy-file!*)
        (define zz-pdf-edit-pages *pdf-edit-pages!*)
        (define zz-pdf-undo-edit *pdf-undo-edit!*)
        (define zz-pdf-reset-edit *pdf-reset-edit!*)
        (define zz-pdf-layout-json *pdf-layout-json*)
        (define zz-pdf-page-geometry *pdf-page-geometry*)
        (define zz-pdf-font-metrics *pdf-font-metrics*)
        (define zz-pdf-write-text *pdf-write-text!*))
      (define zz-pdf-copies '())
      (define zz-pdf-orders '())
      (define zz-pdf-undo-count 0)
      (define zz-pdf-reset-count 0)
      (define zz-pdf-writes '())
      (set! *pdf-page-count* (lambda (path) 3))
      (set! *pdf-render-page* (lambda (path page zoom) "aGVsbG8="))
      (set! *pdf-page-text*
        (lambda (path page) (string-append "Text for page " (number->string page))))
      (set! *pdf-file-exists?* (lambda (path) #t))
      (set! *pdf-working-copy-exists?*
        (lambda (path)
          (if (or (member path (map cadr zz-pdf-writes))
                  (member path (map cadr zz-pdf-copies)))
              #t #f)))
      (set! *pdf-copy-file!*
        (lambda (source destination)
          (set! zz-pdf-copies (cons (list source destination) zz-pdf-copies))
          #t))
      (set! *pdf-edit-pages!*
        (lambda (path order undo-path)
          (set! zz-pdf-orders (cons order zz-pdf-orders))
          #t))
      (set! *pdf-undo-edit!*
        (lambda (path undo-path)
          (set! zz-pdf-undo-count (+ zz-pdf-undo-count 1))
          #t))
      (set! *pdf-reset-edit!*
        (lambda (original path undo-path)
          (set! zz-pdf-reset-count (+ zz-pdf-reset-count 1))
          #t))
      (set! *pdf-layout-json*
        (lambda (path)
          "{\"pages\":[{\"blocks\":[{\"type\":\"text\",\"lines\":[{\"bbox\":{\"x\":72,\"y\":138,\"w\":156,\"h\":12},\"font\":{\"name\":\"CIDFont+F2\",\"family\":\"sans-serif\",\"weight\":\"normal\",\"style\":\"normal\",\"size\":14},\"x\":72,\"y\":148,\"text\":\"Apartment Owner's Name: \"}]}]}]}"))
      (set! *pdf-page-geometry* (lambda (path page) '(595.32 841.92 0)))
      (set! *pdf-font-metrics*
        (lambda (font size text) '(69.2 1.1 -0.3 68.3 10.2)))
      (set! *pdf-write-text!*
        (lambda (source destination page x baseline-y text font size)
          (set! zz-pdf-writes
            (cons (list source destination page x baseline-y text font size)
                  zz-pdf-writes))
          #t)))
    """)

    on_exit(fn ->
      eval!(~S"""
      (begin
        (set! *pdf-page-count* zz-pdf-page-count)
        (set! *pdf-render-page* zz-pdf-render-page)
        (set! *pdf-page-text* zz-pdf-page-text)
        (set! *pdf-file-exists?* zz-pdf-file-exists)
        (set! *pdf-working-copy-exists?* zz-pdf-working-copy-exists)
        (set! *pdf-copy-file!* zz-pdf-copy-file)
        (set! *pdf-edit-pages!* zz-pdf-edit-pages)
        (set! *pdf-undo-edit!* zz-pdf-undo-edit)
        (set! *pdf-reset-edit!* zz-pdf-reset-edit)
        (set! *pdf-layout-json* zz-pdf-layout-json)
        (set! *pdf-page-geometry* zz-pdf-page-geometry)
        (set! *pdf-font-metrics* zz-pdf-font-metrics)
        (set! *pdf-write-text!* zz-pdf-write-text)
        (for-each
          (lambda (buf)
            (when (or (equal? (buffer-local buf 'mode-name) "pdf-reader-mode")
                      (equal? (buffer-local buf 'mode-name) "pdf-edit-mode"))
              (buffer-kill! buf)))
          (buffer-list)))
      """)

      Editor.delete_other_windows()
    end)

    :ok
  end

  test "visit opens a PDF as a rendered reader" do
    eval!(~S|(visit "/tmp/reader-guide.PDF")|)
    buf = Editor.current_buffer()

    assert Buffer.get_local(buf, "mode-name") == "pdf-reader-mode"
    assert Buffer.path(buf) == "/tmp/reader-guide.PDF"
    refute Buffer.get_local(buf, "pdf-path")
    assert Buffer.get_local(buf, "pdf-page") == 1
    assert Buffer.get_local(buf, "pdf-total") == 3
    assert Buffer.get_local(buf, "render-mode") == "html"
    refute Buffer.get_local(buf, "preview-authored")
    assert Buffer.read_only?(buf)
    assert Buffer.text(buf) =~ "Page 1 of 3"
    assert Buffer.text(buf) =~ ~s(class="toolbar")
    assert Buffer.text(buf) =~ ~s(class="control-group")
    assert Buffer.text(buf) =~ "Text for page 1"
    assert Buffer.text(buf) =~ "data:image/png;base64,aGVsbG8="
  end

  test "mode setup uses the path of an existing PDF file buffer" do
    eval!(~S"""
    (begin
      (switch-to-buffer! (find-file "/tmp/direct-mode.PdF"))
      (auto-mode "/tmp/direct-mode.PdF"))
    """)

    buf = Editor.current_buffer()
    assert Buffer.get_local(buf, "mode-name") == "pdf-reader-mode"
    assert Buffer.path(buf) == "/tmp/direct-mode.PdF"
    refute Buffer.get_local(buf, "pdf-path")
    assert Buffer.get_local(buf, "pdf-total") == 3
    assert Buffer.text(buf) =~ "Page 1 of 3"
    assert Buffer.text(buf) =~ "data:image/png;base64,aGVsbG8="
    refute Buffer.text(buf) =~ "Missing PDF"
  end

  test "package registration upgrades an existing PDF file buffer" do
    eval!(~S"""
    (begin
      (switch-to-buffer! (find-file "/tmp/already-open.pdf"))
      (set-mode! "text-mode")
      (buffer-set-local! (current-buffer) 'pdf-path "/tmp/stale-copy.pdf")
      (pdf--register-auto-mode!))
    """)

    buf = Editor.current_buffer()
    assert Buffer.get_local(buf, "mode-name") == "pdf-reader-mode"
    assert Buffer.path(buf) == "/tmp/already-open.pdf"
    refute Buffer.get_local(buf, "pdf-path")
    assert Buffer.text(buf) =~ "Page 1 of 3"
  end

  test "mode keys navigate pages and change zoom through key dispatch" do
    eval!(~S|(visit "/tmp/reader-keys.pdf")|)
    buf = Editor.current_buffer()

    press("n")
    assert Buffer.get_local(buf, "pdf-page") == 2
    assert Buffer.text(buf) =~ "Text for page 2"

    press("+")
    assert Buffer.get_local(buf, "pdf-zoom") == 125
    assert Buffer.text(buf) =~ "125%"

    press("<end>")
    press("n")
    assert Buffer.get_local(buf, "pdf-page") == 3

    press("p")
    assert Buffer.get_local(buf, "pdf-page") == 2

    press("<next>")
    assert Buffer.get_local(buf, "pdf-page") == 3
    assert Buffer.text(buf) =~ "Text for page 3"

    press("<prior>")
    assert Buffer.get_local(buf, "pdf-page") == 2
    assert Buffer.text(buf) =~ "Text for page 2"
  end

  test "dark page mode follows key dispatch and keeps the editor palette" do
    eval!(~S|(visit "/tmp/reader-dark.pdf")|)
    buf = Editor.current_buffer()

    press("i")
    assert Buffer.get_local(buf, "pdf-dark?")
    assert Buffer.text(buf) =~ ~s(<body class="dark-page">)
    assert Buffer.text(buf) =~ "filter:invert(1) hue-rotate(180deg)"
    assert Buffer.text(buf) =~ "Light page"
    refute Buffer.get_local(buf, "preview-authored")

    press("i")
    refute Buffer.get_local(buf, "pdf-dark?")
    assert Buffer.text(buf) =~ "Dark page"
  end

  test "single-page documents omit navigation controls" do
    eval!(~S"""
    (begin
      (set! *pdf-page-count* (lambda (path) 1))
      (visit "/tmp/reader-single.pdf"))
    """)

    html = Buffer.text(Editor.current_buffer())
    assert html =~ "Page 1 of 1"
    assert html =~ ~s(aria-label="Zoom")
    refute html =~ ~s(aria-label="Page navigation")
  end

  test "mode setup rebuilds the document and local keys after restore" do
    eval!(~S"""
    (begin
      (define zz-pdf-render-count 0)
      (set! *pdf-render-page*
        (lambda (path page zoom)
          (set! zz-pdf-render-count (+ zz-pdf-render-count 1))
          "aGVsbG8="))
      (visit "/tmp/reader-restore.pdf")
      (buffer-set-local! (current-buffer) 'pdf-page 2)
      (buffer-set-local! (current-buffer) 'pdf-zoom 150)
      (buffer-set-local! (current-buffer) 'pdf-dark? #t)
      (set-mode! "pdf-reader-mode"))
    """)

    buf = Editor.current_buffer()
    assert eval!("zz-pdf-render-count") == "2"
    assert Buffer.text(buf) =~ "Page 2 of 3"
    assert Buffer.text(buf) =~ "150%"
    assert Buffer.text(buf) =~ "Dark page"

    press("n")
    assert Buffer.get_local(buf, "pdf-page") == 3
  end

  test "reader action links use the same Scheme commands" do
    eval!(~S|(visit "/tmp/reader-links.pdf")|)
    buf = Editor.current_buffer()

    eval!(~S|(preview-follow-link! (active-window) "aimax:pdf/next")|)
    assert Buffer.get_local(buf, "pdf-page") == 2

    eval!(~S|(preview-follow-link! (active-window) "aimax:pdf/zoom-in")|)
    assert Buffer.get_local(buf, "pdf-zoom") == 125
  end

  test "pdf-edit-mode creates one stable sibling and preserves the original path" do
    eval!(~S|(visit "/tmp/edit-source.pdf")|)
    eval!(~S|(run-command "pdf-edit-mode")|)
    buf = Editor.current_buffer()

    destination = Buffer.get_local(buf, "pdf-path")

    assert Buffer.get_local(buf, "mode-name") == "pdf-edit-mode"
    assert Buffer.get_local(buf, "pdf-original-path") == "/tmp/edit-source.pdf"
    assert destination != "/tmp/edit-source.pdf"
    assert destination == "/tmp/edit-source-edited.pdf"
    assert eval!("(length zz-pdf-copies)") == "1"
    assert Buffer.text(buf) =~ "Editing generated copy"
    assert Buffer.text(buf) =~ "Original remains unchanged: /tmp/edit-source.pdf"
  end

  test "reopening pdf-edit-mode reuses its existing working copy" do
    eval!(~S|(pdf-edit-open "/tmp/reopen-source.pdf")|)
    first = Buffer.get_local(Editor.current_buffer(), "pdf-path")

    eval!(~S|(pdf-edit-open "/tmp/reopen-source.pdf")|)
    second = Buffer.get_local(Editor.current_buffer(), "pdf-path")

    assert first == "/tmp/reopen-source-edited.pdf"
    assert second == first
    assert eval!("(length zz-pdf-copies)") == "1"
  end

  test "edit keys structurally change only the generated copy" do
    eval!(~S|(pdf-edit-open "/tmp/edit-pages.pdf")|)
    buf = Editor.current_buffer()
    generated = Buffer.get_local(buf, "pdf-path")

    press("D")
    assert Buffer.get_local(buf, "pdf-total") == 4
    assert eval!("(car zz-pdf-orders)") == "(1 1 2 3)"

    press("n")
    press("]")
    assert Buffer.get_local(buf, "pdf-page") == 3
    assert eval!("(car zz-pdf-orders)") == "(1 3 2 4)"

    press("d")
    assert Buffer.get_local(buf, "pdf-total") == 3
    assert eval!("(car zz-pdf-orders)") == "(1 2 4)"

    assert Buffer.get_local(buf, "pdf-original-path") == "/tmp/edit-pages.pdf"
    assert Buffer.get_local(buf, "pdf-path") == generated
    assert generated != "/tmp/edit-pages.pdf"
  end

  test "edit undo and reset retain the generated output path" do
    eval!(~S|(pdf-edit-open "/tmp/edit-undo.pdf")|)
    buf = Editor.current_buffer()
    generated = Buffer.get_local(buf, "pdf-path")

    press("u")
    press("R")

    assert eval!("zz-pdf-undo-count") == "1"
    assert eval!("zz-pdf-reset-count") == "1"
    assert Buffer.get_local(buf, "pdf-path") == generated
    assert Buffer.get_local(buf, "pdf-original-path") == "/tmp/edit-undo.pdf"
  end

  test "find text returns page-space line bounds, baseline, and font data" do
    assert eval!(~S|(length (pdf-find-text "/tmp/form.pdf" "owner's name"))|) == "1"

    assert eval!(~S|(plist-get (car (pdf-find-text "/tmp/form.pdf" "OWNER'S NAME")) 'page)|) ==
             "1"

    assert eval!(~S|(plist-get (car (pdf-find-text "/tmp/form.pdf" "owner's name")) 'x)|) ==
             "72"

    assert eval!(~S|(plist-get (car (pdf-find-text "/tmp/form.pdf" "owner's name")) 'top)|) ==
             "138"

    assert eval!(~S|(plist-get (car (pdf-find-text "/tmp/form.pdf" "owner's name")) 'width)|) ==
             "156"

    assert eval!(~S|(plist-get (car (pdf-find-text "/tmp/form.pdf" "owner's name")) 'baseline-y)|) ==
             "148"

    assert eval!(~S|(plist-get (car (pdf-find-text "/tmp/form.pdf" "owner's name")) 'font-size)|) ==
             "14"

    assert eval!(
             ~S|(plist-get (car (pdf-find-text "/tmp/form.pdf" "owner's name")) 'page-height)|
           ) ==
             "841.92"

    assert eval!(
             ~S|(plist-get (car (pdf-find-text "/tmp/form.pdf" "owner's name")) 'coordinate-system)|
           ) ==
             ~S["PDF points; origin top-left"]

    assert eval!(~S|(plist-get (car (pdf-find-text "/tmp/form.pdf" "owner's name")) 'bounds)|) ==
             ~S["whole matching text line"]
  end

  test "font measurement reports advance and ink bounds in points" do
    assert eval!(~S|(plist-get (pdf-measure-font "Helvetica" 14 "Hello world") 'width)|) ==
             "69.2"

    assert eval!(~S|(plist-get (pdf-measure-font "Helvetica" 14 "Hello world") 'height)|) ==
             "10.5"

    assert eval!(~S|(plist-get (pdf-measure-font "Helvetica" 14 "Hello world") 'ascent)|) ==
             "10.2"

    assert eval!(~S|(plist-get (pdf-measure-font "Helvetica" 14 "Hello world") 'descent)|) ==
             "0.3"
  end

  test "positioned text insertion writes one stable sibling" do
    result = eval!(~S|(pdf-insert-text "/tmp/form.pdf" 1 240 148 "Jane Doe" "Helvetica" 14)|)

    assert result == ~S["/tmp/form-edited.pdf"]
    assert eval!("(length zz-pdf-writes)") == "1"
    assert eval!("(car (car zz-pdf-writes))") == ~S["/tmp/form.pdf"]
    assert eval!("(nth 2 (car zz-pdf-writes))") == "1"
    assert eval!("(nth 3 (car zz-pdf-writes))") == "240"
    assert eval!("(nth 4 (car zz-pdf-writes))") == "148"
    assert eval!("(nth 5 (car zz-pdf-writes))") == ~S["Jane Doe"]
    assert eval!("(nth 6 (car zz-pdf-writes))") == ~S["Helvetica"]
    assert eval!("(nth 7 (car zz-pdf-writes))") == "14"
    refute result == ~S["/tmp/form.pdf"]
  end

  test "later text insertions update the existing generated copy" do
    eval!(~S"""
    (begin
      (define zz-pdf-first-working
        (pdf-insert-text "/tmp/repeated-form.pdf" 1 240 148 "Jane"))
      (define zz-pdf-second-working
        (pdf-insert-text "/tmp/repeated-form.pdf" 1 280 148 "Doe")))
    """)

    first = eval!("zz-pdf-first-working")
    assert first == ~S["/tmp/repeated-form-edited.pdf"]
    assert eval!("zz-pdf-second-working") == first
    assert eval!("(length zz-pdf-writes)") == "2"
    assert eval!("(car (car zz-pdf-writes))") == first
    assert eval!("(cadr (car zz-pdf-writes))") == first
  end

  test "an old chained filename is updated without adding another suffix" do
    chained =
      "/tmp/form-edited-20260825-120000-edited-20260825-120100-edited-20260825-120200.pdf"

    result = eval!(~s|(pdf-insert-text "#{chained}" 1 240 148 "Jane Doe")|)

    assert result == inspect(chained)
    assert eval!("(cadr (car zz-pdf-writes))") == inspect(chained)
  end

  test "text can be inserted after the first located line" do
    eval!(~S|(pdf-insert-text-after "/tmp/form.pdf" "owner's name" "Jane Doe")|)

    assert eval!("(nth 2 (car zz-pdf-writes))") == "1"
    assert eval!("(nth 3 (car zz-pdf-writes))") == "236"
    assert eval!("(nth 4 (car zz-pdf-writes))") == "148"
    assert eval!("(nth 5 (car zz-pdf-writes))") == ~S["Jane Doe"]
    assert eval!("(nth 6 (car zz-pdf-writes))") == ~S["Helvetica"]
    assert eval!("(nth 7 (car zz-pdf-writes))") == "14"
  end
end
