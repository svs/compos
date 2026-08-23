;;; annotate-test.scm --- margin notes on a document.
;;;
;;; An annotation names a line and a piece of text on it. The overlay is
;;; painted from that, the relocation follows an edit above, and the
;;; margin shows the thread.
;;;
;;; Thirteen tests stay in ExUnit: ten press keys, and three write an
;;; annotation store to disk beside the document.

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
