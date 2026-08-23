;;; annotate-test.scm --- margin notes on a document.
;;;
;;; An annotation names a line and a piece of text on it. The overlay is
;;; painted from that, the relocation follows an edit above, and the
;;; margin shows the thread.
;;;
;;; Nothing here presses a key. Every list verb is a command, and the
;;; store is written and read with write-file! and read-file.
;;;
;;; One test stays in ExUnit: a margin card CLICK. It arrives on
;;; SchemeAPI.block_click/2, which looks a handler up in ETS and applies
;;; it — Scheme has no way into that path, which is what makes it the
;;; bridge. What the handler then does is annotate--click!, tested above.

(domain! 'testing)
(effects! '(write))

(define t--ann-buf "*zz-annotate*")
(define t--ann-text "alpha beta\ngamma delta\nepsilon zeta\n")

(define (t--ann-fresh!)
  (test-buffer! t--ann-buf t--ann-text)
  t--ann-buf)

(define (t--ann-add! spec) (annotate! t--ann-buf spec))

(define (t--ann-llm-warning!)
  (t--ann-add! '(source "llm" severity "warning" line 2 match "delta"
                 title "Overstated claim" who "claude" when "now")))

(define (t--ann-reader-note!)
  (t--ann-add! '(source "reader" severity "note" line 3 match "zeta"
                 title "Keep, verbatim" who "Ada R." when "Wed")))

;; annotate-mode opens a margin window. Put the buffer and the window back.
(define (t--ann-done!)
  (when (buffer-known? t--ann-buf)
    (when (member "annotate-mode" (or (buffer-local t--ann-buf 'minor-modes) '()))
      (disable-minor-mode! t--ann-buf "annotate-mode"))
    (buffer-kill! t--ann-buf))
  (when (buffer-known? "*margin*") (buffer-kill! "*margin*")))

;;; --- the overlay --------------------------------------------------------------

(deftest 'annotate-paints-an-overlay-on-the-matched-text
  "the line and the match name the span, so an edit elsewhere cannot move it"
  (lambda ()
    (t--ann-fresh!)
    (t--ann-llm-warning!)
    ;; "alpha beta\n" is 11 bytes; "delta" sits at 17..22
    (check-true! (member '(17 22 "ann-llm") (buffer-overlays t--ann-buf))
                 "the span is painted")
    (t--ann-done!)))

(deftest 'a-resolved-annotation-paints-nothing
  "resolving is not deleting, but it does clear the ink"
  (lambda ()
    (t--ann-fresh!)
    (let ((id (t--ann-llm-warning!)))
      (annotate--update! t--ann-buf id 'state "resolved")
      (annotate--paint! t--ann-buf)
      (check-equal! (buffer-overlays t--ann-buf) '() "no overlay is left"))
    (t--ann-done!)))

(deftest 'relocate-follows-the-text-through-an-edit-above
  "the line number moves with the text, and the overlay follows it"
  (lambda ()
    (t--ann-fresh!)
    (t--ann-llm-warning!)
    (buffer-insert! t--ann-buf 0 "intro\n")
    (annotate--relocate! t--ann-buf)
    (annotate--paint! t--ann-buf)
    (check-equal! (plist-get (car (buffer-annotations t--ann-buf)) 'line) 3
                  "the line moved down by one")
    (check-true! (member '(23 28 "ann-llm") (buffer-overlays t--ann-buf))
                 "and the overlay with it")
    (t--ann-done!)))

(deftest 'annotate-clear-drops-one-source-and-keeps-the-rest
  "a checker sweep must not take a person's note with it"
  (lambda ()
    (t--ann-fresh!)
    (t--ann-llm-warning!)
    (t--ann-reader-note!)
    (annotate-clear! t--ann-buf "llm")
    (check-equal! (length (buffer-annotations t--ann-buf)) 1 "the reader note stays")
    (t--ann-done!)))

;;; --- the margin ---------------------------------------------------------------

(deftest 'a-margin-click-runs-the-verb
  "the card's buttons are the same verbs the keys run"
  (lambda ()
    (t--ann-fresh!)
    (let ((id (t--ann-llm-warning!)))
      (enable-minor-mode! t--ann-buf "annotate-mode")
      (annotate--click! t--ann-buf "resolve" (annotate--find t--ann-buf id))
      (check-equal! (plist-get (annotate--find t--ann-buf id) 'state) "resolved"
                    "the verb ran"))
    (t--ann-done!)))

(deftest 'a-reply-joins-the-annotations-thread-and-the-margin-shows-it
  "an annotation is a conversation, not a one-line verdict"
  (lambda ()
    (t--ann-fresh!)
    (let ((id (t--ann-llm-warning!)))
      (enable-minor-mode! t--ann-buf "annotate-mode")
      (buffer-set-local! t--ann-buf 'ann-selected id)
      (annotate-reply! t--ann-buf id "Second this.")
      (check-equal! (length (plist-get (annotate--find t--ann-buf id) 'thread)) 1
                    "the reply is in the thread")
      (check-contains! (value->string (annotate--margin-blocks "*margin*"))
                       "Second this." "and the margin shows it"))
    (t--ann-done!)))

(deftest 'turning-annotate-mode-off-closes-the-margin-window
  "the margin belongs to the mode, not to the frame"
  (lambda ()
    (t--ann-fresh!)
    (t--ann-llm-warning!)
    (enable-minor-mode! t--ann-buf "annotate-mode")
    (display-buffer-other-window! "*margin*")
    (disable-minor-mode! t--ann-buf "annotate-mode")
    (check-false! (window-showing "*margin*") "the window is closed")
    (t--ann-done!)))

;;; --- the suggestion -----------------------------------------------------------

(deftest 'the-suggestion-prompt-carries-the-span-the-context-and-the-ask
  "a model that cannot see the line cannot rewrite it"
  (lambda ()
    (t--ann-fresh!)
    (t--ann-llm-warning!)
    (let* ((a (car (buffer-annotations t--ann-buf)))
           (text (buffer-text t--ann-buf))
           (at (annotate--locate text (annotate--line-bounds text) a))
           (prompt (annotate--suggest-prompt t--ann-buf a at)))
      (check-contains! prompt "delta" "the span")
      (check-contains! prompt "gamma delta" "the line it sits on")
      (check-contains! prompt "Overstated claim" "what the annotation said")
      (check-contains! prompt "ONLY the replacement text" "and the ask"))
    (t--ann-done!)))

(deftest 'an-empty-suggestion-reply-changes-nothing
  "a model that answers whitespace has not suggested a fix"
  (lambda ()
    (t--ann-fresh!)
    (let ((id (t--ann-llm-warning!)))
      (annotate--suggest-apply! t--ann-buf id "delta" "   ")
      (check-false! (plist-get (annotate--find t--ann-buf id) 'fix-new)
                    "no fix was recorded"))
    (t--ann-done!)))

;;; --- the store and the sources ------------------------------------------------

(deftest 'a-non-file-buffer-has-no-store
  "there is nowhere to put it, so nothing pretends there is"
  (lambda ()
    (t--ann-fresh!)
    (check-false! (annotate-store-file t--ann-buf) "no store file")
    (t--ann-done!)))

(deftest 'the-mode-help-names-annotate-add-and-its-key
  "describe-mode is where a person learns the mode"
  (lambda ()
    (t--ann-fresh!)
    (enable-minor-mode! t--ann-buf "annotate-mode")
    (with-current-buffer t--ann-buf (lambda () (run-command "describe-mode")))
    (let ((help (buffer-text "*Help*")))
      (check-contains! help "C-c ! a" "the key")
      (check-contains! help "annotate-add" "the command")
      (check-contains! help "Margin notes" "and what the mode is for"))
    (when (buffer-known? "*Help*") (buffer-kill! "*Help*"))
    (t--ann-done!)))

(deftest 'the-check-source-reports-tree-sitter-error-nodes
  "the grammar already knows the file is broken"
  (lambda ()
    (when (member "json" (ts-langs))
      (t--ann-fresh!)
      (buffer-set-local! t--ann-buf 'ts-lang "json")
      (test-buffer! t--ann-buf "[1,,]\n")
      (annotate--check! t--ann-buf)
      (check-equal! (plist-get (car (buffer-annotations t--ann-buf)) 'source) "check"
                    "the annotation names the check source")
      (t--ann-done!))))


;;; --- the list -------------------------------------------------------------------

(define (t--ann-list!)
  ;; the list is built for the CURRENT buffer, so the document must be it
  (switch-to-buffer! t--ann-buf)
  (run-command "annotate-list")
  "*annotations*")

(deftest 'annotate-next-steps-to-the-annotation-and-selects-it
  "the point moves to the span, and the span shows as selected"
  (lambda ()
    (t--ann-fresh!)
    (enable-minor-mode! t--ann-buf "annotate-mode")
    (t--ann-llm-warning!)
    (with-current-buffer t--ann-buf (lambda () (run-command "annotate-next")))
    (check-equal! (buffer-point t--ann-buf) 17 "point sits on the span")
    (check-true! (buffer-local t--ann-buf 'ann-selected) "and it is the selected one")
    (check-true! (member '(17 22 "ann-selected") (buffer-overlays t--ann-buf))
                 "with the selected face")
    (t--ann-done!)))

(deftest 'the-list-shows-the-rows-and-the-tabs-narrow-them
  "all, then errors, then the author — and back"
  (lambda ()
    (t--ann-fresh!)
    (t--ann-llm-warning!)
    (t--ann-reader-note!)
    (let ((list-buf (t--ann-list!)))
      (check-equal! (current-buffer) list-buf "the list has the focus")
      (let ((text (buffer-text list-buf)))
        (check-contains! text "Overstated claim" "the warning")
        (check-contains! text "Keep, verbatim" "the note")
        (check-contains! text "[all 2]" "and the tab counts both"))

      ;; all -> errors: the warning stays, the note goes
      (run-command "annotate-tab-next")
      (let ((text (buffer-text list-buf)))
        (check-contains! text "[errors 1]" "the errors tab")
        (check-contains! text "Overstated claim" "keeps the warning")
        (check-false! (string-contains? text "Keep, verbatim") "and drops the note"))

      (run-command "annotate-tab-next")
      (check-contains! (buffer-text list-buf) "[claude 1]" "then the author tab")

      (run-command "annotate-tab-prev")
      (run-command "annotate-tab-prev")
      (check-contains! (buffer-text list-buf) "[all 2]" "and back to all"))
    (t--ann-done!)))

(deftest 'resolve-toggles-the-row-at-point
  "resolving is not deleting: the same key reopens it"
  (lambda ()
    (t--ann-fresh!)
    (let ((id (t--ann-llm-warning!)))
      (t--ann-list!)
      (run-command "annotate-resolve")
      (check-equal! (plist-get (annotate--find t--ann-buf id) 'state) "resolved" "resolved")
      (run-command "annotate-resolve")
      (check-equal! (plist-get (annotate--find t--ann-buf id) 'state) "open" "and open again"))
    (t--ann-done!)))

(deftest 'apply-fix-edits-the-document-and-resolves-the-annotation
  "the suggestion is applied where the span is"
  (lambda ()
    (t--ann-fresh!)
    (let ((id (t--ann-add! '(source "llm" severity "suggestion" line 1 match "beta"
                             title "Rename" who "claude" when "now"
                             fix-old "beta" fix-new "betta"))))
      (t--ann-list!)
      (run-command "annotate-apply-fix")
      (check-contains! (buffer-text t--ann-buf) "alpha betta" "the document took the fix")
      (check-equal! (plist-get (annotate--find t--ann-buf id) 'state) "resolved"
                    "and the annotation is resolved"))
    (t--ann-done!)))

(deftest 'apply-fix-reports-a-stale-fix-instead-of-editing
  "the text moved under the annotation, so the fix no longer fits"
  (lambda ()
    (t--ann-fresh!)
    (t--ann-add! '(source "llm" severity "suggestion" line 1 match "beta"
                   title "Rename" who "claude" when "now"
                   fix-old "beta" fix-new "betta"))
    (buffer-delete-range! t--ann-buf 6 4)
    (t--ann-list!)
    (run-command "annotate-apply-fix")
    (check-contains! (buffer-text t--ann-buf) "alpha \ngamma" "the document is untouched")
    (t--ann-done!)))

(deftest 'dismiss-hides-the-row-for-this-session-only
  "the annotation is still there; it is the view that dropped it"
  (lambda ()
    (t--ann-fresh!)
    (t--ann-llm-warning!)
    (t--ann-reader-note!)
    (t--ann-list!)
    (run-command "annotate-dismiss")
    (check-equal! (length (annotate-visible t--ann-buf)) 1 "one row is visible")
    (check-equal! (length (buffer-annotations t--ann-buf)) 2 "and both are still kept")
    (t--ann-done!)))

(deftest 'a-suggestion-reply-becomes-the-fix
  "the model answers with the replacement, trimmed"
  (lambda ()
    (t--ann-fresh!)
    (let ((id (t--ann-llm-warning!)))
      (annotate--suggest-apply! t--ann-buf id "delta" "  epsilon  ")
      (check-equal! (plist-get (annotate--find t--ann-buf id) 'fix-new) "epsilon"
                    "the fix is the trimmed reply")
      (t--ann-list!)
      (run-command "annotate-apply-fix")
      (check-contains! (buffer-text t--ann-buf) "gamma epsilon" "and applying it edits the line"))
    (t--ann-done!)))

;;; --- the margin -----------------------------------------------------------------

(deftest 'annotate-mode-builds-the-margin-cards
  "one card per annotation, and the selected one opens"
  (lambda ()
    (t--ann-fresh!)
    (let ((id (t--ann-llm-warning!)))
      (t--ann-reader-note!)
      (enable-minor-mode! t--ann-buf "annotate-mode")
      (check-true! (buffer-known? "*margin*") "the margin exists")

      (let ((blocks (value->string (annotate--margin-blocks "*margin*"))))
        (check-contains! blocks "margin · 2 annotations" "the header counts them")
        (check-contains! blocks "Overstated claim" "the first card")
        (check-contains! blocks "Keep, verbatim" "the second"))

      (buffer-set-local! t--ann-buf 'ann-selected id)
      (let ((blocks (value->string (annotate--margin-blocks "*margin*"))))
        (check-contains! blocks "ann-card open" "the selected card opens")
        (check-contains! blocks (string-append "ann:resolve:" id) "with its action chips")))
    (t--ann-done!)))

(deftest 'annotate-margin-mode-by-hand-redirects-instead-of-hijacking-the-buffer
  "the margin is a mode for the margin buffer, not for a document"
  (lambda ()
    (t--ann-fresh!)
    (with-current-buffer t--ann-buf (lambda () (run-command "annotate-margin-mode")))
    (check-false! (buffer-local t--ann-buf 'render-mode) "the document is not made a margin")
    (t--ann-done!)))

;;; --- the store ------------------------------------------------------------------

(define (t--ann-store-clean! buf)
  (let ((path (annotate-store-file buf)))
    (when (and path (file-exists? path)) (delete-file! path)))
  (when (buffer-known? buf) (buffer-kill! buf)))

(deftest 'annotations-of-a-file-buffer-live-in-a-file-and-load-back
  "a document's notes outlive the buffer that showed them"
  (lambda ()
    (let ((fbuf (string-append (aimax-home) "/zz-annotate-notes.txt")))
      (write-file! fbuf "alpha beta\ngamma delta\n")
      (test-buffer! fbuf "alpha beta\ngamma delta\n")
      (annotate! fbuf '(source "reader" severity "note" line 2 match "delta"
                        title "Stored" who "you" when "now"))

      (let ((path (annotate-store-file fbuf)))
        (check-true! (file-exists? path) "the store file was written")
        (check-contains! (read-file path) "Stored" "and holds the note")

        ;; a fresh buffer with no locals reads the file back on mode enable
        (buffer-set-local! fbuf 'annotations '())
        (enable-minor-mode! fbuf "annotate-mode")
        (check-equal! (length (buffer-annotations fbuf)) 1 "the note came back")
        (disable-minor-mode! fbuf "annotate-mode")
        (delete-file! path))
      (t--ann-store-clean! fbuf)
      (delete-file! fbuf))))

(deftest 'the-store-keeps-reader-and-llm-annotations-never-checker-ones
  "a checker's diagnostics are live, and re-derived every time"
  (lambda ()
    (let ((fbuf (string-append (aimax-home) "/zz-annotate-checked.txt")))
      (write-file! fbuf "alpha beta\n")
      (test-buffer! fbuf "alpha beta\n")
      (annotate! fbuf '(source "check" severity "error" line 1 match "alpha"
                        title "Diag" who "ts" when "live"))
      (annotate! fbuf '(source "llm" severity "note" line 1 match "beta"
                        title "Kept" who "claude" when "now"))

      (let ((stored (read-file (annotate-store-file fbuf))))
        (check-contains! stored "Kept" "the llm note is stored")
        (check-false! (string-contains? stored "Diag") "the checker's is not"))
      (t--ann-store-clean! fbuf)
      (delete-file! fbuf))))

(deftest 'a-file-inside-a-project-stores-its-annotations-in-the-project
  "the notes travel with the repository, not with the machine"
  (lambda ()
    (let* ((root (string-append (aimax-home) "/zz-annotate-repo"))
           (fbuf (string-append root "/src/x.txt")))
      (shell-command->string (string-append "rm -rf " root))
      (make-directory! (string-append root "/.git"))
      (make-directory! (string-append root "/src"))
      (write-file! fbuf "alpha beta\n")
      (test-buffer! fbuf "alpha beta\n")

      (check-equal! (annotate-store-file fbuf)
                    (string-append root "/.aimax/annotations/src%2Fx.txt.scm")
                    "the store sits under the project")
      (annotate! fbuf '(source "reader" severity "note" line 1 match "beta"
                        title "In repo" who "you" when "now"))
      (check-contains! (read-file (string-append root "/.aimax/annotations/src%2Fx.txt.scm"))
                       "In repo" "and holds the note")

      (when (buffer-known? fbuf) (buffer-kill! fbuf))
      (shell-command->string (string-append "rm -rf " root)))))
