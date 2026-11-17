;;; pdf-test.scm --- the PDF reader and editor, by the commands that do the work.
;;;
;;; Every test replaces the pdf seams, so no test reads or writes a real
;;; PDF. The seams are globals; t--pdf! puts back what it found. These
;;; were test/pdf_reader_test.exs.

(require 'pdf)

(domain! 'testing)
(effects! '(write))

(define t--pdf-seams
  '(*pdf-page-count* *pdf-render-page* *pdf-page-text* *pdf-file-exists?*
    *pdf-clear-render-cache!* *pdf-working-copy-exists?* *pdf-copy-file!*
    *pdf-edit-pages!* *pdf-undo-edit!* *pdf-reset-edit!* *pdf-layout-json*
    *pdf-page-geometry* *pdf-font-metrics* *pdf-write-text!*))

(define t--pdf-copies '())
(define t--pdf-orders '())
(define t--pdf-undo-count 0)
(define t--pdf-reset-count 0)
(define t--pdf-cache-clear-count 0)
(define t--pdf-render-count 0)
(define t--pdf-writes '())

(define t--pdf-layout
  "{\"pages\":[{\"blocks\":[{\"type\":\"text\",\"lines\":[{\"bbox\":{\"x\":72,\"y\":138,\"w\":156,\"h\":12},\"font\":{\"name\":\"CIDFont+F2\",\"family\":\"sans-serif\",\"weight\":\"normal\",\"style\":\"normal\",\"size\":14},\"x\":72,\"y\":148,\"text\":\"Apartment Owner's Name: \"}]}]}]}")

(define (t--pdf-install!)
  (set! t--pdf-copies '())
  (set! t--pdf-orders '())
  (set! t--pdf-undo-count 0)
  (set! t--pdf-reset-count 0)
  (set! t--pdf-cache-clear-count 0)
  (set! t--pdf-render-count 0)
  (set! t--pdf-writes '())
  (set! *pdf-page-count*
    (lambda (path)
      (if (and (string-contains? path "-edited.pdf") (pair? t--pdf-orders))
          (length (car t--pdf-orders))
          3)))
  (set! *pdf-render-page*
    (lambda (path page zoom)
      (set! t--pdf-render-count (+ t--pdf-render-count 1))
      "aGVsbG8="))
  (set! *pdf-page-text*
    (lambda (path page) (string-append "Text for page " (number->string page))))
  (set! *pdf-file-exists?* (lambda (path) #t))
  (set! *pdf-clear-render-cache!*
    (lambda (path) (set! t--pdf-cache-clear-count (+ t--pdf-cache-clear-count 1)) #t))
  (set! *pdf-working-copy-exists?*
    (lambda (path)
      (if (or (member path (map cadr t--pdf-writes))
              (member path (map cadr t--pdf-copies)))
          #t #f)))
  (set! *pdf-copy-file!*
    (lambda (source destination)
      (set! t--pdf-copies (cons (list source destination) t--pdf-copies))
      #t))
  (set! *pdf-edit-pages!*
    (lambda (path order undo-path) (set! t--pdf-orders (cons order t--pdf-orders)) #t))
  (set! *pdf-undo-edit!*
    (lambda (path undo-path) (set! t--pdf-undo-count (+ t--pdf-undo-count 1)) #t))
  (set! *pdf-reset-edit!*
    (lambda (original path undo-path) (set! t--pdf-reset-count (+ t--pdf-reset-count 1)) #t))
  (set! *pdf-layout-json* (lambda (path) t--pdf-layout))
  (set! *pdf-page-geometry* (lambda (path page) '(595.32 841.92 0)))
  (set! *pdf-font-metrics* (lambda (font size text) '(69.2 1.1 -0.3 68.3 10.2)))
  (set! *pdf-write-text!*
    (lambda (source destination page x baseline-y text font size)
      (set! t--pdf-writes
        (cons (list source destination page x baseline-y text font size) t--pdf-writes))
      #t)))

(define (t--pdf-kill-buffers!)
  (for-each
    (lambda (buf)
      (when (member (buffer-local-value 'mode-name buf) '("pdf-reader-mode" "pdf-edit-mode"))
        (buffer-kill! buf)))
    (buffer-list)))

;; THUNK runs in a frame of its own with the seams stubbed; both go after
(define (t--pdf! thunk)
  (let ((saved (map (lambda (s) (cons s (symbol-value s))) t--pdf-seams)))
    (unwind-protect
      (lambda ()
        (t--pdf-install!)
        (with-frame (lambda (frame) (thunk))))
      (lambda ()
        (for-each (lambda (p) (set-symbol-value! (car p) (cdr p))) saved)
        (t--pdf-kill-buffers!)))))

(define (t--pdf-run! buf cmd)
  (with-current-buffer buf (lambda () (run-command cmd))))

(define (t--pdf-local buf name) (buffer-local-value name buf))

(define (t--pdf-edit-open! path)
  (pdf-edit-open path)
  (current-buffer))

;;; --- the reader -------------------------------------------------------------

(deftest 'pdf-visit-opens-a-rendered-reader
  "visit opens a PDF as a rendered reader"
  (lambda ()
    (t--pdf!
      (lambda ()
        (let* ((buf (visit "/tmp/reader-guide.PDF"))
               (text (buffer-text buf)))
          (check-equal! (t--pdf-local buf 'mode-name) "pdf-reader-mode" "the mode")
          (check-equal! (buffer-file-name buf) "/tmp/reader-guide.PDF" "the path")
          (check-false! (t--pdf-local buf 'pdf-path) "no separate pdf path")
          (check-equal! (t--pdf-local buf 'pdf-page) 1 "the first page")
          (check-equal! (t--pdf-local buf 'pdf-total) 3 "three pages")
          (check-equal! (t--pdf-local buf 'render-mode) "html" "drawn as html")
          (check-false! (t--pdf-local buf 'preview-authored) "not authored")
          (check-true! (buffer-read-only? buf) "read only")
          (check-contains! text "Page 1 of 3" "the status")
          (check-contains! text "class=\"toolbar\"" "the toolbar")
          (check-contains! text "class=\"control-group\"" "the controls")
          (check-contains! text "Text for page 1" "the page text")
          (check-contains! text "data:image/png;base64,aGVsbG8=" "the image"))))))

(deftest 'pdf-mode-setup-uses-the-path-of-a-file-buffer
  "auto-mode on an open PDF file buffer renders that file"
  (lambda ()
    (t--pdf!
      (lambda ()
        (let ((buf (find-file "/tmp/direct-mode.PdF")))
          (with-current-buffer buf (lambda () (auto-mode "/tmp/direct-mode.PdF")))
          (check-equal! (t--pdf-local buf 'mode-name) "pdf-reader-mode" "the mode")
          (check-equal! (buffer-file-name buf) "/tmp/direct-mode.PdF" "the path")
          (check-false! (t--pdf-local buf 'pdf-path) "no separate pdf path")
          (check-equal! (t--pdf-local buf 'pdf-total) 3 "three pages")
          (check-contains! (buffer-text buf) "Page 1 of 3" "the status")
          (check-contains! (buffer-text buf) "data:image/png;base64,aGVsbG8=" "the image")
          (check-false! (string-contains? (buffer-text buf) "Missing PDF") "not missing"))))))

(deftest 'pdf-reader-adopts-a-path-named-buffer-with-no-file
  "a buffer named after a PDF but holding no file still renders it"
  (lambda ()
    (t--pdf!
      (lambda ()
        (let ((buf "/tmp/orphan-name.pdf"))
          (buffer-create buf)
          (with-current-buffer buf (lambda () (set-mode! "pdf-reader-mode")))
          (check-false! (buffer-file-name buf) "no file")
          (check-equal! (t--pdf-local buf 'pdf-path) "/tmp/orphan-name.pdf" "the name is the path")
          (check-equal! (t--pdf-local buf 'pdf-total) 3 "three pages")
          (check-contains! (buffer-text buf) "Page 1 of 3" "the status")
          (check-false! (string-contains? (buffer-text buf) "Missing PDF") "not missing"))))))

(deftest 'pdf-registration-upgrades-an-open-pdf-buffer
  "registering the auto-mode turns an open PDF file buffer into the reader"
  (lambda ()
    (t--pdf!
      (lambda ()
        (let ((buf (find-file "/tmp/already-open.pdf")))
          (with-current-buffer buf
            (lambda ()
              (set-mode! "text-mode")
              (buffer-set-local! buf 'pdf-path "/tmp/stale-copy.pdf")))
          (pdf--register-auto-mode!)
          (check-equal! (t--pdf-local buf 'mode-name) "pdf-reader-mode" "the mode")
          (check-equal! (buffer-file-name buf) "/tmp/already-open.pdf" "the path")
          (check-false! (t--pdf-local buf 'pdf-path) "the stale path goes")
          (check-contains! (buffer-text buf) "Page 1 of 3" "the status"))))))

(deftest 'pdf-commands-navigate-pages-and-zoom
  "next, previous, last and zoom change the page and the scale"
  (lambda ()
    (t--pdf!
      (lambda ()
        (let ((buf (visit "/tmp/reader-keys.pdf")))
          (t--pdf-run! buf "pdf-next-page")
          (check-equal! (t--pdf-local buf 'pdf-page) 2 "next")
          (check-contains! (buffer-text buf) "Text for page 2" "the page text follows")
          (t--pdf-run! buf "pdf-zoom-in")
          (check-equal! (t--pdf-local buf 'pdf-zoom) 125 "zoom in")
          (check-contains! (buffer-text buf) "125%" "the scale shows")
          (t--pdf-run! buf "pdf-last-page")
          (t--pdf-run! buf "pdf-next-page")
          (check-equal! (t--pdf-local buf 'pdf-page) 3 "the last page stops")
          (t--pdf-run! buf "pdf-previous-page")
          (check-equal! (t--pdf-local buf 'pdf-page) 2 "previous")
          (check-contains! (buffer-text buf) "Text for page 2" "the page text follows"))))))

(deftest 'pdf-dark-page-keeps-the-editor-palette
  "pdf-toggle-dark inverts the page only"
  (lambda ()
    (t--pdf!
      (lambda ()
        (let ((buf (visit "/tmp/reader-dark.pdf")))
          (t--pdf-run! buf "pdf-toggle-dark")
          (check-true! (t--pdf-local buf 'pdf-dark?) "dark")
          (check-contains! (buffer-text buf) "<body class=\"dark-page\">" "the body class")
          (check-contains! (buffer-text buf) "filter:invert(1) hue-rotate(180deg)" "the filter")
          (check-contains! (buffer-text buf) "Light page" "the action offers light")
          (check-false! (t--pdf-local buf 'preview-authored) "not authored")
          (t--pdf-run! buf "pdf-toggle-dark")
          (check-false! (t--pdf-local buf 'pdf-dark?) "light again")
          (check-contains! (buffer-text buf) "Dark page" "the action offers dark"))))))

(deftest 'pdf-single-page-omits-navigation
  "a one-page document has zoom and no page navigation"
  (lambda ()
    (t--pdf!
      (lambda ()
        (set! *pdf-page-count* (lambda (path) 1))
        (let ((html (buffer-text (visit "/tmp/reader-single.pdf"))))
          (check-contains! html "Page 1 of 1" "the status")
          (check-contains! html "aria-label=\"Zoom\"" "zoom")
          (check-false! (string-contains? html "aria-label=\"Page navigation\"") "no navigation"))))))

(deftest 'pdf-header-stays-on-one-line
  "the title, status and controls keep one line"
  (lambda ()
    (t--pdf!
      (lambda ()
        (let ((html (buffer-text (visit "/tmp/reader-header.pdf"))))
          (check-contains! html ".toolbar{position:sticky;top:0;z-index:2;display:flex;align-items:center" "the toolbar")
          (check-contains! html "white-space:nowrap;overflow-x:auto" "no wrap")
          (check-contains! html ".controls{display:flex;flex:0 0 auto;align-items:center;gap:8px;flex-wrap:nowrap}" "the controls")
          (check-contains! html "<header class=\"toolbar\"><span class=\"title\"" "the title first")
          (check-false! (string-contains? html "class=\"identity\"") "no identity"))))))

(deftest 'pdf-mode-setup-rebuilds-after-restore
  "set-mode! draws the page and zoom the locals hold"
  (lambda ()
    (t--pdf!
      (lambda ()
        (let ((buf (visit "/tmp/reader-restore.pdf")))
          (buffer-set-local! buf 'pdf-page 2)
          (buffer-set-local! buf 'pdf-zoom 150)
          (buffer-set-local! buf 'pdf-dark? #t)
          (with-current-buffer buf (lambda () (set-mode! "pdf-reader-mode")))
          (check-equal! t--pdf-render-count 2 "one render for the visit, one for the setup")
          (check-contains! (buffer-text buf) "Page 2 of 3" "the page")
          (check-contains! (buffer-text buf) "150%" "the zoom")
          (check-contains! (buffer-text buf) "Dark page" "the dark action")
          (t--pdf-run! buf "pdf-next-page")
          (check-equal! (t--pdf-local buf 'pdf-page) 3 "the commands still work"))))))

(deftest 'pdf-action-links-run-the-commands
  "the reader's links call the same Scheme commands"
  (lambda ()
    (t--pdf!
      (lambda ()
        (let ((buf (visit "/tmp/reader-links.pdf")))
          (window-set-buffer! (selected-window) buf)
          (preview-follow-link! (selected-window) "compos:pdf/next")
          (check-equal! (t--pdf-local buf 'pdf-page) 2 "next")
          (preview-follow-link! (selected-window) "compos:pdf/zoom-in")
          (check-equal! (t--pdf-local buf 'pdf-zoom) 125 "zoom in"))))))

;;; --- the editor -------------------------------------------------------------

(deftest 'pdf-edit-mode-makes-one-stable-sibling
  "pdf-edit-mode edits a -edited copy and leaves the original"
  (lambda ()
    (t--pdf!
      (lambda ()
        (switch-to-buffer! (visit "/tmp/edit-source.pdf"))
        (run-command "pdf-edit-mode")
        (let ((buf (current-buffer)))
          (check-equal! (t--pdf-local buf 'mode-name) "pdf-edit-mode" "the mode")
          (check-equal! (t--pdf-local buf 'pdf-original-path) "/tmp/edit-source.pdf" "the original")
          (check-equal! (t--pdf-local buf 'pdf-path) "/tmp/edit-source-edited.pdf" "the copy")
          (check-equal! (length t--pdf-copies) 1 "one copy")
          (check-contains! (buffer-text buf) "Editing generated copy" "the banner")
          (check-contains! (buffer-text buf) "Original remains unchanged: /tmp/edit-source.pdf"
                           "the original is named"))))))

(deftest 'pdf-edit-reopen-reuses-the-working-copy
  "a second pdf-edit-open copies nothing"
  (lambda ()
    (t--pdf!
      (lambda ()
        (let* ((first (t--pdf-local (t--pdf-edit-open! "/tmp/reopen-source.pdf") 'pdf-path))
               (second (t--pdf-local (t--pdf-edit-open! "/tmp/reopen-source.pdf") 'pdf-path)))
          (check-equal! first "/tmp/reopen-source-edited.pdf" "the copy")
          (check-equal! second first "the same copy")
          (check-equal! (length t--pdf-copies) 1 "one copy"))))))

(deftest 'pdf-edit-commands-change-only-the-copy
  "duplicate, move and delete reorder the generated copy"
  (lambda ()
    (t--pdf!
      (lambda ()
        (let* ((buf (t--pdf-edit-open! "/tmp/edit-pages.pdf"))
               (generated (t--pdf-local buf 'pdf-path)))
          (t--pdf-run! buf "pdf-edit-duplicate-page")
          (check-equal! (t--pdf-local buf 'pdf-total) 4 "four pages")
          (check-equal! (car t--pdf-orders) '(1 1 2 3) "the page is doubled")
          (t--pdf-run! buf "pdf-next-page")
          (t--pdf-run! buf "pdf-edit-move-page-forward")
          (check-equal! (t--pdf-local buf 'pdf-page) 3 "point follows the page")
          (check-equal! (car t--pdf-orders) '(1 3 2 4) "moved later")
          (t--pdf-run! buf "pdf-edit-delete-page")
          (check-equal! (t--pdf-local buf 'pdf-total) 3 "three pages")
          (check-equal! (car t--pdf-orders) '(1 2 4) "deleted")
          (check-equal! (t--pdf-local buf 'pdf-original-path) "/tmp/edit-pages.pdf" "the original")
          (check-equal! (t--pdf-local buf 'pdf-path) generated "the copy stays"))))))

(deftest 'pdf-edit-undo-and-reset-keep-the-copy-path
  "undo and reset act on the copy and keep its path"
  (lambda ()
    (t--pdf!
      (lambda ()
        (let* ((buf (t--pdf-edit-open! "/tmp/edit-undo.pdf"))
               (generated (t--pdf-local buf 'pdf-path)))
          (t--pdf-run! buf "pdf-edit-undo")
          (t--pdf-run! buf "pdf-edit-reset")
          (check-equal! t--pdf-undo-count 1 "one undo")
          (check-equal! t--pdf-reset-count 1 "one reset")
          (check-equal! (t--pdf-local buf 'pdf-path) generated "the copy stays")
          (check-equal! (t--pdf-local buf 'pdf-original-path) "/tmp/edit-undo.pdf" "the original"))))))

;;; --- text -------------------------------------------------------------------

(deftest 'pdf-find-text-answers-page-space-bounds
  "pdf-find-text gives the line bounds, baseline and font in points"
  (lambda ()
    (t--pdf!
      (lambda ()
        (check-equal! (length (pdf-find-text "/tmp/form.pdf" "owner's name")) 1 "one match")
        (check-equal! (plist-get (car (pdf-find-text "/tmp/form.pdf" "OWNER'S NAME")) 'page) 1
                      "case does not matter")
        (let ((hit (car (pdf-find-text "/tmp/form.pdf" "owner's name"))))
          (check-equal! (plist-get hit 'x) 72 "x")
          (check-equal! (plist-get hit 'top) 138 "top")
          (check-equal! (plist-get hit 'width) 156 "width")
          (check-equal! (plist-get hit 'baseline-y) 148 "baseline")
          (check-equal! (plist-get hit 'font-size) 14 "font size")
          (check-equal! (plist-get hit 'page-height) 841.92 "page height")
          (check-equal! (plist-get hit 'coordinate-system) "PDF points; origin top-left" "the system")
          (check-equal! (plist-get hit 'bounds) "whole matching text line" "the bounds"))))))

(deftest 'pdf-measure-font-reports-points
  "advance and ink bounds in points"
  (lambda ()
    (t--pdf!
      (lambda ()
        (let ((m (pdf-measure-font "Helvetica" 14 "Hello world")))
          (check-equal! (plist-get m 'width) 69.2 "width")
          (check-equal! (plist-get m 'height) 10.5 "height")
          (check-equal! (plist-get m 'ascent) 10.2 "ascent")
          (check-equal! (plist-get m 'descent) 0.3 "descent"))))))

(deftest 'pdf-insert-text-writes-one-stable-sibling
  "positioned text goes into the -edited copy"
  (lambda ()
    (t--pdf!
      (lambda ()
        (let ((result (pdf-insert-text "/tmp/form.pdf" 1 240 148 "Jane Doe" "Helvetica" 14)))
          (check-equal! result "/tmp/form-edited.pdf" "the copy")
          (check-equal! (length t--pdf-writes) 1 "one write")
          (check-equal! (car t--pdf-writes)
                        '("/tmp/form.pdf" "/tmp/form-edited.pdf" 1 240 148 "Jane Doe" "Helvetica" 14)
                        "from the original, at the point, in the font"))))))

(deftest 'pdf-later-insertions-update-the-copy
  "the second insertion reads and writes the copy"
  (lambda ()
    (t--pdf!
      (lambda ()
        (let* ((first (pdf-insert-text "/tmp/repeated-form.pdf" 1 240 148 "Jane"))
               (second (pdf-insert-text "/tmp/repeated-form.pdf" 1 280 148 "Doe")))
          (check-equal! first "/tmp/repeated-form-edited.pdf" "the copy")
          (check-equal! second first "the same copy")
          (check-equal! (length t--pdf-writes) 2 "two writes")
          (check-equal! (car (car t--pdf-writes)) first "the source is the copy")
          (check-equal! (cadr (car t--pdf-writes)) first "and so is the destination"))))))

(deftest 'pdf-insert-text-reverts-an-open-copy
  "an open working-copy buffer draws again after an insertion"
  (lambda ()
    (t--pdf!
      (lambda ()
        (let* ((buf (t--pdf-edit-open! "/tmp/live-form.pdf"))
               (renders t--pdf-render-count)
               (result (pdf-insert-text "/tmp/live-form.pdf" 1 240 148 "Jane Doe")))
          (check-equal! result "/tmp/live-form-edited.pdf" "the copy")
          (check-equal! (t--pdf-local buf 'mode-name) "pdf-edit-mode" "still editing")
          (check-equal! t--pdf-render-count (+ renders 1) "one more render")
          (check-equal! t--pdf-cache-clear-count 1 "the cache clears")
          (check-contains! (buffer-text buf) "data:image/png;base64,aGVsbG8=" "the image"))))))

(deftest 'pdf-chained-name-gets-no-new-suffix
  "an old chained -edited name is the copy itself"
  (lambda ()
    (t--pdf!
      (lambda ()
        (let* ((chained "/tmp/form-edited-20260825-120000-edited-20260825-120100-edited-20260825-120200.pdf")
               (result (pdf-insert-text chained 1 240 148 "Jane Doe")))
          (check-equal! result chained "the same name")
          (check-equal! (cadr (car t--pdf-writes)) chained "written in place"))))))

(deftest 'pdf-insert-text-after-a-located-line
  "the text goes after the first line that matches"
  (lambda ()
    (t--pdf!
      (lambda ()
        (pdf-insert-text-after "/tmp/form.pdf" "owner's name" "Jane Doe")
        (check-equal! (cddr (car t--pdf-writes)) '(1 236 148 "Jane Doe" "Helvetica" 14)
                      "page, x after the line, baseline, text and font")))))
