;;; goto-address-test.scm --- URLs and file paths are links in any buffer.

(domain! 'testing)
(effects! '(write))

(define t--ga-buf "zz-goto-address.txt")

(define (t--ga! text)
  (test-buffer! t--ga-buf text)
  ;; the change hook is debounced; paint now so the test reads the truth
  (goto-address-paint! t--ga-buf)
  t--ga-buf)

(define (t--ga-links)
  (filter (lambda (o) (string-prefix? "link goto-address link-to:" (caddr o)))
          (buffer-overlays t--ga-buf)))

(define (t--ga-done!) (when (buffer-known? t--ga-buf) (buffer-kill! t--ga-buf)))

(define t--ga-file (string-append (compos-priv-dir) "/init.scm"))

(deftest 'a-url-in-plain-text-is-a-link
  "a fundamental buffer paints its URL with the link face and its target"
  (lambda ()
    (t--ga! "see https://example.com/a?b=1. and more\n")
    (let ((ls (t--ga-links)))
      (check-equal! (length ls) 1 "one link")
      (check-equal! (list (car (car ls)) (cadr (car ls))) '(4 29)
                    "the range covers the URL and not the period")
      (check-equal! (goto-address-href-at t--ga-buf 10) "https://example.com/a?b=1"
                    "the target reads back off the overlay"))
    (t--ga-done!)))

(deftest 'a-file-path-that-exists-is-a-link-with-its-line
  "path:LINE paints as a link whose target carries ?line="
  (lambda ()
    (t--ga! (string-append "at " t--ga-file ":3 here\n"))
    (let ((ls (t--ga-links)))
      (check-equal! (length ls) 1 "the path is one link")
      (check-equal! (goto-address-href-at t--ga-buf 5)
                    (string-append t--ga-file "?line=3")
                    "the target is the path with its line as a query"))
    (t--ga-done!)))

(deftest 'a-path-that-names-no-file-is-prose
  "a path-shaped word that is not on disk paints nothing"
  (lambda ()
    (t--ga! "/no/such/dir/zz-file.txt and apps/zz-nope/x.ex:9\n")
    (check-equal! (length (t--ga-links)) 0 "no link for a missing file")
    (t--ga-done!)))

(deftest 'a-relative-path-resolves-beside-the-file-then-from-the-project-root
  "docs/BLOCKS.md in a file deep in the repo is the repository's docs/BLOCKS.md"
  (lambda ()
    (let ((name (string-append (compos-priv-dir) "/editor/zz-ga-relative.txt")))
      (test-buffer! name "see docs/BLOCKS.md and ./blocks/block.scm here\n")
      (goto-address-paint! name)
      (check-equal! (goto-address-href-at name 5)
                    (string-append (project-root-cached (compos-priv-dir)) "/docs/BLOCKS.md")
                    "not beside the file, so the project root answers")
      (check-equal! (goto-address-href-at name 24)
                    (string-append (compos-priv-dir) "/editor/blocks/block.scm")
                    "beside the file wins")
      (buffer-kill! name))))

(deftest 'a-change-repaints-only-the-lines-it-touched
  "the untouched links stay, the touched line is read again"
  (lambda ()
    (t--ga! "a https://one.example\nplain\nb https://three.example\n")
    (check-equal! (length (t--ga-links)) 2 "the first paint: two links")
    ;; line 2 gains a URL at its end: the change is inside that line
    (buffer-insert! t--ga-buf 27 " https://two.example")
    (goto-address-repaint! t--ga-buf 27 " https://two.example")
    (let ((ls (t--ga-links)))
      (check-equal! (length ls) 3 "one link per line")
      (check-equal! (goto-address-href-at t--ga-buf 2) "https://one.example"
                    "the line above kept its link")
      (check-equal! (goto-address-href-at t--ga-buf 30) "https://two.example"
                    "the touched line has its new link")
      (check-equal! (goto-address-href-at t--ga-buf 52) "https://three.example"
                    "the line below followed the rope"))
    ;; the first URL loses its scheme: a deletion touches line 1 alone
    (buffer-delete-range! t--ga-buf 2 8)
    (goto-address-repaint! t--ga-buf 2 "")
    (check-equal! (length (t--ga-links)) 2 "the broken URL is prose again")
    (check-equal! (goto-address-href-at t--ga-buf 22) "https://two.example"
                  "the second line still answers, at its moved offset")
    (t--ga-done!)))

(deftest 'path-parts-split-the-line-and-column
  "path:LINE:COL -> (PATH LINE); a bare path has no line"
  (lambda ()
    (check-equal! (goto-address-path-parts "a/b.ex:12:4") '("a/b.ex" 12) "line and column")
    (check-equal! (goto-address-path-parts "a/b.ex:12") '("a/b.ex" 12) "line alone")
    (check-equal! (goto-address-path-parts "a/b.ex") '("a/b.ex" #f) "no line")))

(deftest 'a-new-buffer-is-watched-without-asking
  "no mode to turn on: a buffer that appears has its change hook"
  (lambda ()
    (t--ga! "https://example.com\n")
    (check-true! (assoc t--ga-buf *goto-address-hooks*) "the buffer is watched")
    (check-equal! (length (t--ga-links)) 1 "and painted")
    (goto-address-unwatch! t--ga-buf)
    (check-equal! (length (t--ga-links)) 0 "unwatch clears the links")
    (t--ga-done!)))

(deftest 'a-document-link-with-a-line-lands-on-it
  "following path?line=N visits the file and puts point on line N"
  (lambda ()
    (let ((known (buffer-known? t--ga-file)))
      (t--ga! (string-append t--ga-file ":4\n"))
      (preview--follow-document! t--ga-buf (goto-address-href-at t--ga-buf 1) #f)
      (check-equal! (current-buffer) t--ga-file "the file is current")
      (check-equal! (line-number-at-pos (point)) 4 "point stands on line 4")
      (unless known (buffer-kill! t--ga-file))
      (t--ga-done!))))

(deftest 'm-dot-follows-the-link-at-point-before-it-looks-for-a-definition
  "code-goto-definition on a painted path visits the file"
  (lambda ()
    (let* ((name (string-append (compos-priv-dir) "/editor/zz-ga-mdot.txt"))
           (target (string-append (compos-priv-dir) "/editor/blocks/block.scm"))
           (known (buffer-known? target)))
      ;; a relative path beside the buffer's file, with its line
      (test-buffer! name "see blocks/block.scm:2 here\n")
      (goto-address-paint! name)
      (buffer-goto! name 6)
      ;; read where the command left point inside its own buffer context:
      ;; with-current-buffer restores the caller's buffer on the way out
      (let ((landed #f))
        (with-current-buffer name
          (lambda ()
            (run-command "code-goto-definition")
            (set! landed (list (current-buffer) (line-number-at-pos (point))))))
        (check-equal! (car landed) target "M-. followed the path link")
        (check-equal! (cadr landed) 2 "and landed on its line"))
      (unless known (buffer-kill! target))
      (buffer-kill! name))))

(deftest 'c-c-ret-falls-through-to-the-buffers-finder
  "with no link at point, goto-address-at-point runs what M-. runs here"
  (lambda ()
    ;; the global finder reads "define NAME" by words
    (t--ga! "define zz-thing 1\n\nzz-thing\n")
    (buffer-goto! t--ga-buf 19)
    (with-current-buffer t--ga-buf (lambda () (run-command "goto-address-at-point")))
    (check-equal! (buffer-point t--ga-buf) 0
                  "the buffer's definition finder took point to the define")
    (t--ga-done!)))

(deftest 'an-org-file-link-is-the-file-it-names
  "file:PATH with no host, the Org spelling, resolves as a path beside the buffer's file"
  (lambda ()
    (let ((name (string-append (compos-priv-dir) "/tests/zz-ga-org.org")))
      (test-buffer! name "see [[file:../editor/blocks/block.scm][the block]] and [[file:../zz-nope.scm][x]]\n")
      (goto-address-paint! name)
      (check-equal! (goto-address-href-at name 8)
                    (string-append (compos-priv-dir) "/editor/blocks/block.scm")
                    "the target is the file, not a file: URL")
      (check-false! (goto-address-href-at name 60) "a file: link to no file paints nothing")
      (buffer-kill! name))))

;;; --- inserting ---------------------------------------------------------------

(define (t--ga-confirm! text)
  (minibuffer-change! text)
  (run-command "minibuffer-confirm-input"))

;; a buffer of MODE (or none) standing in the tests directory
(define (t--ga-insert-buffer! name text mode)
  (let ((buf (test-buffer! name text)))
    (buffer-set-local! buf 'default-directory (string-append (compos-priv-dir) "/tests/"))
    (when mode (with-current-buffer buf (lambda () (set-mode! mode))))
    buf))

(define t--ga-insert-target (string-append (compos-priv-dir) "/packages/preview.scm"))

(deftest 'file-relative-name-walks-up-then-down
  "the path from DIR to TARGET, and . for the directory itself"
  (lambda ()
    (check-equal! (file-relative-name "/a/b/c/d.md" "/a/b/x/") "../c/d.md" "one up, then down")
    (check-equal! (file-relative-name "/a/b/c/d.md" "/a/b/c/") "d.md" "beside: the name alone")
    (check-equal! (file-relative-name "/a/b/c/d.md" "/a/b/c/e/f/") "../../d.md" "two up")
    (check-equal! (file-relative-name "/a/b/c/" "/a/b/c/") "." "the directory itself")))

(deftest 'insert-file-link-writes-the-path-alone-in-a-plain-buffer
  "a mode with no link syntax gets the relative path at point and no label prompt"
  (lambda ()
    (let ((buf (t--ga-insert-buffer! "zz-ga-insert-plain.txt" "see  here" #f)))
      (with-current-buffer buf
        (lambda ()
          (goto-char! 4)
          (set-mark! #f)
          (run-command "insert-file-link")
          (t--ga-confirm! t--ga-insert-target)))
      (check-false! (minibuffer-active?) "no second prompt")
      (check-equal! (buffer-text buf) "see ../packages/preview.scm here"
                    "the relative path stands at point")
      (buffer-kill! buf))))

(deftest 'insert-file-link-writes-the-modes-syntax
  "an Org buffer gets [[file:PATH][LABEL]], the selection as the label"
  (lambda ()
    (let ((buf (t--ga-insert-buffer! "zz-ga-insert.org" "Read this" "org-mode")))
      (with-current-buffer buf
        (lambda ()
          (goto-char! 4)
          (set-mark! 0)
          (run-command "insert-file-link")
          (t--ga-confirm! t--ga-insert-target)))
      (check-equal! (buffer-text buf) "[[file:../packages/preview.scm][Read]] this"
                    "the selection became the label")
      (buffer-kill! buf))))

(deftest 'insert-file-link-offers-the-file-name-as-the-label
  "with no selection an empty answer to the label prompt takes the file's name"
  (lambda ()
    (let ((buf (t--ga-insert-buffer! "zz-ga-insert-default.org" "" "org-mode")))
      (with-current-buffer buf
        (lambda ()
          (set-mark! #f)
          (run-command "insert-file-link")
          (t--ga-confirm! t--ga-insert-target)))
      (check-contains! (plist-get (minibuffer-state) 'prompt) "(default preview.scm)"
                       "the prompt names the default")
      (t--ga-confirm! "")
      (check-equal! (buffer-text buf) "[[file:../packages/preview.scm][preview.scm]]"
                    "the file name is the label")
      (buffer-kill! buf))))

(deftest 'insert-document-link-is-the-older-name
  "the old command opens the same file prompt"
  (lambda ()
    (let ((buf (t--ga-insert-buffer! "zz-ga-insert-old.txt" "" #f)))
      (with-current-buffer buf (lambda () (run-command "insert-document-link")))
      (check-contains! (plist-get (minibuffer-state) 'prompt) "Insert link to file:"
                       "the file prompt is up")
      (minibuffer-cancel!)
      (buffer-kill! buf))))

(deftest 'a-listing-takes-no-links
  "a buffer that becomes a list mode loses its links; the row is the action"
  (lambda ()
    (t--ga! "https://example.com\n")
    (check-equal! (length (t--ga-links)) 1 "plain text: one link")
    (with-current-buffer t--ga-buf (lambda () (set-mode! "messages-mode")))
    (check-false! (assoc t--ga-buf *goto-address-hooks*) "a list mode is not watched")
    (check-equal! (length (t--ga-links)) 0 "and wears no link")
    (t--ga-done!)))
