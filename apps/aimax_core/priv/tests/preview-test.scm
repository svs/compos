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
    (let ((source (visit (string-append (aimax-priv-dir) "/tests/preview-test.scm"))))
      (check-equal!
        (preview--file-target source "../packages/preview.scm")
        (string-append (aimax-priv-dir) "/packages/preview.scm")
        "the target is beside the source and not the process directory")
      (check-equal! (document-link--encode-target "../notes/a draft.md")
                    "../notes/a%20draft.md"
                    "the link keeps path separators and encodes spaces"))))

(define (t--preview-link-target)
  (string-append (aimax-priv-dir) "/packages/preview.scm"))

(define (t--preview-link-buffer name text)
  (let ((buf (test-buffer! name text)))
    (buffer-set-local! buf 'default-directory
                       (string-append (aimax-priv-dir) "/tests/"))
    buf))

(define (t--preview-link-confirm! text)
  (minibuffer-change! text)
  (run-command "minibuffer-confirm-input"))

(deftest 'insert-document-link-uses-the-selected-text
  "the command replaces selected text with a relative Markdown link"
  (lambda ()
    (let ((buf (t--preview-link-buffer "zz-preview-selected.md" "Read this")))
      (with-current-buffer buf
        (lambda ()
          (goto-char! 4)
          (set-mark! 0)
          (run-command "insert-document-link")
          (t--preview-link-confirm! (t--preview-link-target))))
      (check-equal! (buffer-text buf) "[Read](../packages/preview.scm) this"
                    "the selection becomes the label")
      (buffer-kill! buf))))

(deftest 'insert-document-link-prompts-for-text-without-a-selection
  "the command asks for link text when no text is selected"
  (lambda ()
    (let ((buf (t--preview-link-buffer "zz-preview-point.md" "Start here")))
      (with-current-buffer buf
        (lambda ()
          (goto-char! 6)
          (set-mark! #f)
          (run-command "insert-document-link")
          (t--preview-link-confirm! (t--preview-link-target))))
      (check-contains! (plist-get (minibuffer-state) 'prompt) "Link text:"
                       "the second prompt asks for the label")
      (t--preview-link-confirm! "Preview package")
      (check-equal! (buffer-text buf)
                    "Start [Preview package](../packages/preview.scm)here"
                    "the typed label appears at point")
      (buffer-kill! buf))))

(deftest 'a-markdown-page-carries-the-configured-engine
  "the engine choice is policy, so Scheme puts it on the buffer"
  (lambda ()
    (let ((buf (test-buffer! "zz-preview-engine.md" "# title\n")))
      (with-current-buffer buf
        (lambda ()
          (check-equal! (buffer-local buf 'preview-engine) #f
                        "a plain source buffer names no engine")
          (run-command "preview-mode")
          (check-equal! (buffer-local buf 'render-mode) "markdown"
                        "the page renders as markdown")
          (check-equal! (buffer-local buf 'preview-engine) markdown-preview-engine
                        "and it carries the configured engine")))
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
          (check-equal! (buffer-local buf 'render-mode) "markdown"
                        "the setup draws the page")
          (check-true! (buffer-read-only? buf)
                       "preview starts as a reading view")
          (run-command "preview-mode")
          (check-false! (minor-mode-on? buf "preview-mode")
                        "the disabled mode leaves no durable entry")
          (check-false! (buffer-local buf 'render-mode)
                        "the teardown shows the source")
          (check-true! (buffer-read-only? buf)
                       "unpreview does not imply permission to edit")))
      (buffer-kill! buf))))

(deftest 'making-a-preview-writable-also-unpreviews-it
  "read-only-mode exposes editable source and removes the preview mode"
  (lambda ()
    (let ((buf (test-buffer! "zz-preview-edit.html" "<p>hi</p>\n")))
      (with-current-buffer buf
        (lambda ()
          (run-command "preview-mode")
          (run-command "read-only-mode")
          (check-false! (buffer-read-only? buf)
                        "the buffer is writable")
          (check-false! (minor-mode-on? buf "preview-mode")
                        "the reading mode is off")
          (check-false! (buffer-local buf 'render-mode)
                        "the editable source is visible")
          (restore-minor-modes! buf)
          (check-false! (buffer-local buf 'render-mode)
                        "reload does not restore the disabled preview")))
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

(deftest 'the-engine-setting-decides-which-renderer-a-page-gets
  "changing the setting changes the next page, and only that"
  (lambda ()
    (let ((saved markdown-preview-engine)
          (buf (test-buffer! "zz-preview-engine-2.md" "# title\n")))
      (set! markdown-preview-engine "earmark")
      (preview-set-engine! buf)
      (check-equal! (buffer-local buf 'preview-engine) "earmark"
                    "the buffer takes the setting it was given")
      (set! markdown-preview-engine "tree-sitter")
      (preview-set-engine! buf)
      (check-equal! (buffer-local buf 'preview-engine) "tree-sitter"
                    "and follows it back again")
      (set! markdown-preview-engine saved)
      (buffer-kill! buf))))

(deftest 'an-html-page-names-no-markdown-engine
  "only a markdown page carries the local the markdown renderer reads"
  (lambda ()
    (let ((buf (test-buffer! "zz-preview-engine.html" "<p>hi</p>\n")))
      (with-current-buffer buf
        (lambda ()
          (run-command "preview-mode")
          (check-equal! (buffer-local buf 'render-mode) "html"
                        "the page renders as html")
          (check-equal! (buffer-local buf 'preview-engine) #f
                        "and names no markdown engine")))
      (buffer-kill! buf))))
