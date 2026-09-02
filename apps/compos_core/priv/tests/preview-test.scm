;;; preview-test.scm --- RET in a rendered page.
;;;
;;; RET inserts one newline in the source. Every
;;; assertion here calls the command's own function and reads the buffer.
;;; Nothing presses a key: the binding is a preference, the behaviour is
;;; what these tests are for.

(domain! 'testing)
(effects! '(read))

(define (t--preview-ret name text at)
  (let ((buf (test-buffer! name text)))
    (with-current-buffer buf
      (lambda ()
        (goto-char! at)
        (preview-newline!)
        (let ((r (list (buffer-text buf) (point))))
          (buffer-kill! buf)
          r)))))

(deftest 'ret-at-a-line-end-inserts-one-newline
  "RET at a line end adds one source newline"
  (lambda ()
    (let ((r (t--preview-ret "zz-preview-end.md" "para1\npara2\n" 5)))
      (check-equal! (car r) "para1\n\npara2\n" "one newline is added")
      (check-equal! (cadr r) 6 "point moves one character"))))

(deftest 'ret-at-the-end-of-the-document-inserts-one-newline
  "RET on the last line adds one source newline"
  (lambda ()
    (let ((r (t--preview-ret "zz-preview-eof.md" "para1\n" 5)))
      (check-equal! (car r) "para1\n\n" "one blank line ends the paragraph")
      (check-equal! (cadr r) 6 "point moves one character"))))

(deftest 'ret-inside-a-paragraph-inserts-one-newline
  "RET in a paragraph adds one source newline"
  (lambda ()
    (let ((r (t--preview-ret "zz-preview-split.md" "hello world\n" 5)))
      (check-equal! (car r) "hello\n world\n" "one newline splits the text")
      (check-equal! (cadr r) 6 "point moves one character"))))

(deftest 'ret-at-the-start-of-a-block-inserts-one-newline
  "RET at a block start adds one source newline"
  (lambda ()
    (let ((r (t--preview-ret "zz-preview-block-start.md"
                             "intro\n\n# Head\n" 7)))
      (check-equal! (car r) "intro\n\n\n# Head\n" "one newline is added")
      (check-equal! (cadr r) 8 "point moves one character"))))

(deftest 'ret-on-a-blank-line-inserts-one-newline
  "RET extends a blank-line run by one newline"
  (lambda ()
    (let ((r (t--preview-ret "zz-preview-run.md" "a\n\n\n\n\nb\n" 3)))
      (check-equal! (car r) "a\n\n\n\n\n\nb\n" "one newline is added")
      (check-equal! (cadr r) 4 "point moves one character"))))

(deftest 'ret-inside-a-fence-stays-a-plain-newline
  "every character inside a fence is literal, RET included"
  (lambda ()
    (let ((r (t--preview-ret "zz-preview-fence.md" "```\ncode\n```\n" 8)))
      (check-equal! (car r) "```\ncode\n\n```\n" "the code gains one line")
      (check-equal! (cadr r) 9 "point moves one character"))))

(deftest 'ret-on-a-table-row-stays-a-plain-newline
  "a table row means nothing once a block break splits it"
  (lambda ()
    (let ((r (t--preview-ret "zz-preview-table.md" "| a | b |\n" 9)))
      (check-equal! (car r) "| a | b |\n\n" "the row gains one newline")
      (check-equal! (cadr r) 10 "point moves one character"))))

(deftest 'ret-in-a-list-writes-the-next-marker
  "a bullet repeats, so the list continues"
  (lambda ()
    (let ((r (t--preview-ret "zz-preview-bullet.md" "- one\n" 5)))
      (check-equal! (car r) "- one\n- \n" "the next item carries the bullet")
      (check-equal! (cadr r) 8 "point stands after the marker"))))

(deftest 'ret-in-an-ordered-list-counts-on
  "an ordered item names the next number"
  (lambda ()
    (let ((r (t--preview-ret "zz-preview-ordered.md" "1. one\n" 6)))
      (check-equal! (car r) "1. one\n2. \n" "the next item is number two")
      (check-equal! (cadr r) 10 "point stands after the marker"))))

(deftest 'ret-on-an-empty-item-ends-the-list
  "RET on an item with no text drops the marker and opens a block"
  (lambda ()
    (let ((r (t--preview-ret "zz-preview-list-end.md" "- one\n- \n" 8)))
      (check-equal! (car r) "- one\n\n" "the empty item is gone")
      (check-equal! (cadr r) 6 "point stands on the blank line"))))

(deftest 'a-list-marker-names-the-item-that-follows-it
  "the marker reader answers the indent, the next marker, and its width"
  (lambda ()
    (check-equal! (preview--next-marker "  - text") '("  " "-" 4)
                  "a bullet repeats at its own indent")
    (check-equal! (preview--next-marker "3) text") '("" "4)" 3)
                  "an ordered item keeps its delimiter and counts on")
    (check-equal! (preview--next-marker "plain text") #f
                  "a paragraph is not a list item")))

(deftest 'only-an-editable-markdown-page-changes-what-ret-means
  "a source buffer and a read-only page keep the plain newline"
  (lambda ()
    (let ((buf (test-buffer! "zz-preview-gate.md" "text\n")))
      (with-current-buffer buf
        (lambda ()
          (check-equal! (preview--markdown-edit?) #f
                        "a buffer showing its source is not a rendered page")
          (buffer-set-local! buf 'render-mode "markdown")
          (check-equal! (preview--markdown-edit?) #t
                        "a rendered Markdown page takes one newline")
          (buffer-set-read-only! buf #t)
          (check-equal! (preview--markdown-edit?) #f
                        "a read-only page keeps the plain newline")
          (buffer-set-read-only! buf #f)))
      (buffer-kill! buf))))

(deftest 'document-links-resolve-beside-the-source-document
  "a relative document link keeps the source document as its base"
  (lambda ()
    (let ((source (visit (string-append (compos-priv-dir) "/tests/preview-test.scm"))))
      (check-equal!
        (preview--file-target source "../packages/preview.scm")
        (string-append (compos-priv-dir) "/packages/preview.scm")
        "the target is beside the source and not the process directory")
      (check-equal! (document-link--encode-target "../notes/a draft.md")
                    "../notes/a%20draft.md"
                    "the link keeps path separators and encodes spaces"))))

(define (t--preview-link-target)
  (string-append (compos-priv-dir) "/packages/preview.scm"))

;; a Markdown document standing in the tests directory
(define (t--preview-link-buffer name text)
  (let ((buf (test-buffer! name text)))
    (buffer-set-local! buf 'default-directory
                       (string-append (compos-priv-dir) "/tests/"))
    (with-current-buffer buf (lambda () (set-mode! "morg-mode")))
    buf))

(define (t--preview-link-confirm! text)
  (minibuffer-change! text)
  (run-command "minibuffer-confirm-input"))

(deftest 'insert-file-link-uses-the-selected-text
  "in a Markdown document the command replaces selected text with a relative Markdown link"
  (lambda ()
    (let ((buf (t--preview-link-buffer "zz-preview-selected.md" "Read this")))
      (with-current-buffer buf
        (lambda ()
          (goto-char! 4)
          (set-mark! 0)
          (run-command "insert-file-link")
          (t--preview-link-confirm! (t--preview-link-target))))
      (check-equal! (buffer-text buf) "[Read](../packages/preview.scm) this"
                    "the selection becomes the label")
      (buffer-kill! buf))))

(deftest 'insert-file-link-prompts-for-text-without-a-selection
  "the command asks for link text when no text is selected; the file name is the default"
  (lambda ()
    (let ((buf (t--preview-link-buffer "zz-preview-point.md" "Start here")))
      (with-current-buffer buf
        (lambda ()
          (goto-char! 6)
          (set-mark! #f)
          (run-command "insert-file-link")
          (t--preview-link-confirm! (t--preview-link-target))))
      (check-contains! (plist-get (minibuffer-state) 'prompt) "Link text (default preview.scm):"
                       "the second prompt asks for the label and offers the file name")
      (t--preview-link-confirm! "Preview package")
      (check-equal! (buffer-text buf)
                    "Start [Preview package](../packages/preview.scm)here"
                    "the typed label appears at point")
      (buffer-kill! buf))))

(deftest 'an-org-page-still-draws-in-the-iframe
  "an .org page renders as markdown; a Markdown file draws rows instead"
  (lambda ()
    (let ((buf (test-buffer! "zz-preview-engine.org" "* title\n")))
      (with-current-buffer buf
        (lambda ()
          (run-command "preview-mode")
          (check-equal! (buffer-local buf 'render-mode) "markdown"
                        "the page renders as markdown")))
      (buffer-kill! buf))))

(deftest 'preview-mode-membership-owns-the-rendered-view
  "the mode list records the preview state that reload restores"
  (lambda ()
    (let ((buf (test-buffer! "zz-preview-mode.md" "# title\n")))
      (with-current-buffer buf
        (lambda ()
          (run-command "preview-mode")
          (check-true! (minor-mode-on? buf "preview-mode")
                       "the enabled mode is durable")
          (check-false! (buffer-local buf 'render-mode)
                        "a Markdown page is the buffer's own rows, not an iframe")
          (check-true! (buffer-local buf 'preview-rows)
                        "the setup draws the rows")
          (check-false! (buffer-read-only? buf)
                        "preview does not change edit permission")
          (run-command "preview-mode")
          (check-false! (minor-mode-on? buf "preview-mode")
                        "the disabled mode leaves no durable entry")
          (check-false! (buffer-local buf 'render-mode)
                        "the teardown shows the source")
          (check-false! (buffer-read-only? buf)
                        "unpreview also leaves edit permission alone")
          (buffer-set-read-only! buf #t)
          (run-command "preview-mode")
          (check-true! (buffer-read-only? buf)
                       "preview preserves an existing read-only state")
          (run-command "preview-mode")
          (check-true! (buffer-read-only? buf)
                       "unpreview preserves an existing read-only state")))
      (buffer-kill! buf))))

(deftest 'turning-preview-off-restores-the-morg-source-font
  "preview removes its variable font and preserves other source remaps"
  (lambda ()
    (let ((buf (test-buffer! "zz-preview-font.md" "# title\n")))
      (with-current-buffer buf
        (lambda ()
          (face-remap-in! buf 'default '(family "JetBrains Mono" size "13px"))
          (buffer-set-local! buf 'text-scale 1)
          (text-scale-sync! buf)
          (run-command "preview-mode")
          (check-contains! (buffer-local buf 'style) "--default-family:Spectral"
                           "preview applies its variable font")
          (run-command "preview-mode")
          (check-contains! (buffer-local buf 'style) "--default-family:JetBrains Mono"
                           "source restores its own font")
          (run-command "preview-mode")
          ;; This is the state an old desktop restored: its saved source
          ;; look accidentally contains preview's derived default face.
          (buffer-set-local! buf 'preview-rows-saved
            (list (buffer-local buf 'face-remap) (buffer-local buf 'style)))
          (run-command "preview-mode")
          (check-false! (string-contains? (or (buffer-local buf 'style) "")
                                          "--default-family:Spectral")
                        "the variable font leaves with preview")
          (check-contains! (buffer-local buf 'style) "--text-scale-factor:1.2"
                           "an unrelated source remap remains")
          (check-false! (member 'preview-rows-saved
                                (or (buffer-local buf 'desktop-skip-locals) '()))
                        "the source baseline persists across restore")))
      (buffer-kill! buf))))

(deftest 'read-only-mode-does-not-change-preview-mode
  "edit permission and rendered preview are independent modes"
  (lambda ()
    (let ((buf (test-buffer! "zz-preview-edit.html" "<p>hi</p>\n")))
      (with-current-buffer buf
        (lambda ()
          (run-command "preview-mode")
          (run-command "read-only-mode")
          (check-true! (buffer-read-only? buf)
                       "read-only-mode controls edit permission")
          (check-true! (minor-mode-on? buf "preview-mode")
                       "the preview mode stays on")
          (check-equal! (buffer-local buf 'render-mode) "html"
                        "the rendered view stays visible")
          (run-command "read-only-mode")
          (check-false! (buffer-read-only? buf)
                        "the preview can also be writable")
          (check-true! (minor-mode-on? buf "preview-mode")
                       "making it writable leaves preview on")
          (restore-minor-modes! buf)
          (check-equal! (buffer-local buf 'render-mode) "html"
                        "reload reapplies preview without changing permission")
          (check-false! (buffer-read-only? buf)
                        "reload leaves edit permission alone")))
      (buffer-kill! buf))))

(deftest 'preview-mode-reapply-preserves-the-last-choice
  "reload rebuilds an enabled preview and leaves a disabled preview off"
  (lambda ()
    (let ((buf (test-buffer! "zz-preview-reapply.html" "<p>hi</p>\n")))
      (with-current-buffer buf
        (lambda ()
          (run-command "preview-mode")
          (buffer-set-local! buf 'render-mode #f)
          (restore-minor-modes! buf)
          (check-equal! (buffer-local buf 'render-mode) "html"
                        "reapply rebuilds the enabled preview")
          (run-command "preview-mode")
          (restore-minor-modes! buf)
          (check-false! (buffer-local buf 'render-mode)
                        "reapply leaves the disabled preview off")))
      (buffer-kill! buf))))

(deftest 'an-html-page-renders-as-html
  "an .html file takes the html renderer, not the markdown one"
  (lambda ()
    (let ((buf (test-buffer! "zz-preview-engine.html" "<p>hi</p>\n")))
      (with-current-buffer buf
        (lambda ()
          (run-command "preview-mode")
          (check-equal! (buffer-local buf 'render-mode) "html"
                        "the page renders as html")))
      (buffer-kill! buf))))

(deftest 'a-morg-buffer-previews-by-its-mode-not-its-name
  "a scratch has no extension, and the mode is the truth"
  (lambda ()
    (let ((buf (test-buffer! "zz-preview-unnamed" "# t\n")))
      (with-current-buffer buf
        (lambda ()
          (set-mode! "morg-mode")
          (check-equal! (preview-renderer-for buf) "rows"
                        "an unnamed morg buffer takes the rows renderer")
          (enable-minor-mode! buf "preview-mode")
          (check-true! (equal? (buffer-local buf 'preview-rows) #t)
                       "and preview-mode draws the rows in place")))
      (buffer-kill! buf))))
