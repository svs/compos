;;; llm-rewrite-test.scm --- a rewrite waits below the passage it rewrites.
;;;
;;; Nothing is replaced while you decide: the passage stays, and the model's
;;; version sits in a fenced block under it. The fence is a real delimiter:
;;; the bare buffer says what the block is and what it was asked, and no
;;; renderer is needed to read it. The block has three views of the same
;;; two texts: theirs (the rewrite, the default), all (the unified diff,
;;; a ```diff fence), and ours (the passage). Keeping the block puts the
;;; text between the fences in the passage's place; putting it back
;;; removes the block.

(domain! 'testing)
(effects! '(write))

(define t--rw-buf "zz-llm-rewrite")
(define t--rw-what "say it in French")

(define (t--rw! text) (test-buffer! t--rw-buf text) t--rw-buf)

(define (t--rw-done!)
  (when (buffer-known? t--rw-buf)
    (for-each (lambda (s)
                (let ((chat (plist-get s 'chat)))
                  (when (and chat (buffer-known? chat)) (buffer-kill! chat))))
              (or (buffer-local t--rw-buf 'rewrite-sessions) '()))
    (diff-block-release! t--rw-buf)
    (buffer-kill! t--rw-buf)))

;; the document every verb below works on, with the rewrite of "Two."
;; already waiting under it
(define (t--rw-propose! buf s e ours theirs note)
  (diff-block-propose! buf s e ours theirs note))

(define (t--rw-proposed!)
  (t--rw! "One.\n\nTwo.\n")
  (t--rw-propose! t--rw-buf 6 10 "Two." "Deux." t--rw-what)
  t--rw-buf)

;; what the document reads with BLOCK waiting under the passage
(define (t--rw-doc block)
  (string-append "One.\n\nTwo.\n\n" block "\n"))

(deftest 'a-fenced-reply-loses-its-fence
  "the passage it answers has no fence, so the rewrite gains none"
  (lambda ()
    (check-equal! (llm-rewrite-clean "```scheme\n(+ 1 1)\n```") "(+ 1 1)"
                  "the fence lines are gone")
    (check-equal! (llm-rewrite-clean "plain answer") "plain answer"
                  "an unfenced reply is untouched")))

(deftest 'a-rewrite-keeps-the-indentation-it-arrives-with
  "blank edges go; the first line's own spaces stay"
  (lambda ()
    (check-equal! (llm-rewrite-clean "\n\n    indented\n  less\n\n")
                  "    indented\n  less"
                  "only the blank lines around it are dropped")))

(deftest 'the-mode-chooses-which-directives-lead
  "prose and code want opposite things from a model"
  (lambda ()
    (t--rw! "x")
    (buffer-set-local! t--rw-buf 'mode-name "markdown-mode")
    (check-equal! (car (llm-rewrite-directives t--rw-buf))
                  (car *llm-rewrite-prose-directives*)
                  "a document leads with prose")
    (buffer-set-local! t--rw-buf 'mode-name "elixir-mode")
    (check-equal! (car (llm-rewrite-directives t--rw-buf))
                  (car *llm-rewrite-code-directives*)
                  "a source file leads with code")
    (t--rw-done!)))

(deftest 'the-fence-line-is-the-diff-its-view-and-its-keys
  "diff, the view, then the keys from the buffer's own keymap"
  (lambda ()
    ;; no verb key is bound in this buffer, so the line is view alone
    (check-equal! (diff-block-theirs-text "new text" "zz-rw-nokeys")
                  "```diff theirs\nnew text\n```"
                  "theirs: the rewrite alone")
    ;; bind a dummy key to one verb: the fence names it — no test names
    ;; a production key
    (let ((b (test-buffer! "zz-rw-keyed" "x")))
      (local-set-key* b "<f9>" "diff-block-accept")
      (check-equal! (diff-block-theirs-text "new" b)
                    "```diff theirs · <f9> keep\nnew\n```"
                    "the bound verb stands on the fence with its key")
      (local-unset-key* b "<f9>")
      (buffer-kill! b))
    (check-equal! (block-body (diff-block-theirs-text "new text" "zz-rw-nokeys"))
                  "new text"
                  "and the fences come off by structure")
    (check-equal! (block-body "no fences here")
                  "no fences here"
                  "a block whose fences were edited away stays whole")))

(deftest 'the-all-view-is-a-diff-fence
  "old lines over new, with the shared ends as context, in a ```diff block"
  (lambda ()
    (check-equal! (diff-block-all-text "a\nb\nc" "a\nX\nc" "zz-rw-nokeys")
                  "```diff all\n a\n-b\n+X\n c\n```"
                  "one hunk between the shared ends, and the kind says diff")))

(deftest 'the-ours-view-is-the-passage-alone
  "a one-sided view is prose in the diff fence, never diff paint"
  (lambda ()
    (check-equal! (diff-block-ours-text "Two." "zz-rw-nokeys")
                  "```diff ours\nTwo.\n```"
                  "the fence args say which side this is")))

(deftest 'the-block-faces-follow-the-view
  "the all view reads by prefix; a one-sided view must not"
  (lambda ()
    (check-equal! (diff-block--block-faces 0 "-b\n+X" 'all)
                  '((0 2 diff-del) (3 5 diff-add))
                  "the old line and the new one")
    (check-equal! (diff-block--block-faces 0 "- a bullet" 'theirs)
                  '()
                  "a dash in prose is not a deleted line")))

(deftest 'a-rewrite-lands-below-the-passage
  "theirs by default, with the passage untouched above it"
  (lambda ()
    (t--rw-proposed!)
    (check-equal! (buffer-text t--rw-buf)
                  (t--rw-doc (diff-block-theirs-text "Deux." t--rw-buf))
                  "the block sits under the passage, one blank line down")
    (check-equal! (diff-block-state (diff-block-pending t--rw-buf)) 'theirs
                  "and it reads as theirs: the new text, not a diff")
    (check-equal! (diff-block-ours (diff-block-pending t--rw-buf)) "Two."
                  "the passage is remembered as it was asked about")
    (t--rw-done!)))

(deftest 'the-key-cycles-theirs-all-ours
  "the diff is a key away, and every view comes from the same two strings"
  (lambda ()
    (t--rw-proposed!)
    (diff-block-cycle! t--rw-buf)
    (check-equal! (buffer-text t--rw-buf)
                  (t--rw-doc (diff-block-all-text "Two." "Deux." t--rw-buf))
                  "first all: the unified diff")
    (diff-block-cycle! t--rw-buf)
    (check-equal! (buffer-text t--rw-buf)
                  (t--rw-doc (diff-block-ours-text "Two." t--rw-buf))
                  "then ours: the passage alone")
    (diff-block-cycle! t--rw-buf)
    (check-equal! (buffer-text t--rw-buf)
                  (t--rw-doc (diff-block-theirs-text "Deux." t--rw-buf))
                  "and back to theirs")
    (t--rw-done!)))

(deftest 'keeping-a-rewrite-puts-it-in-the-passages-place
  "the passage, the block and the break between them become one text"
  (lambda ()
    (t--rw-proposed!)
    (with-current-buffer t--rw-buf (lambda () (set-mark! 3)))
    (diff-block-accept! t--rw-buf)
    (check-equal! (buffer-text t--rw-buf) "One.\n\nDeux.\n"
                  "the rewrite stands where the passage did, header and all gone")
    (check-false! (diff-block-pending t--rw-buf) "and nothing waits")
    (check-false! (with-current-buffer t--rw-buf (lambda () (mark)))
                  "and the decision cleared the mark")
    (t--rw-done!)))

(deftest 'keeping-a-diff-block-lands-the-rewrite-it-describes
  "a diff is a view of two strings, not text to paste"
  (lambda ()
    (t--rw-proposed!)
    (diff-block-cycle! t--rw-buf)
    (diff-block-accept! t--rw-buf)
    (check-equal! (buffer-text t--rw-buf) "One.\n\nDeux.\n"
                  "no markers, no header")
    (t--rw-done!)))

(deftest 'keeping-a-block-you-edited-keeps-your-edit
  "a whole block is your text, not a view"
  (lambda ()
    (t--rw-proposed!)
    (buffer-replace! t--rw-buf "Deux." "Deux!")
    (diff-block-accept! t--rw-buf)
    (check-equal! (buffer-text t--rw-buf) "One.\n\nDeux!\n"
                  "what you saw is what landed")
    (t--rw-done!)))

(deftest 'putting-it-back-removes-only-the-block
  "the passage was never touched, so there is nothing to restore"
  (lambda ()
    (t--rw-proposed!)
    (diff-block-reject! t--rw-buf)
    (check-equal! (buffer-text t--rw-buf) "One.\n\nTwo.\n"
                  "the document is as it was")
    (check-false! (diff-block-pending t--rw-buf) "and nothing waits")
    (t--rw-done!)))

(deftest 'asking-again-rewrites-the-block-not-the-passage
  "so a reject after any number of rounds still has the original"
  (lambda ()
    (t--rw-proposed!)
    (llm-rewrite--refine! t--rw-buf "Zwei." "now in German")
    (check-equal! (buffer-text t--rw-buf)
                  (t--rw-doc (diff-block-theirs-text "Zwei." t--rw-buf))
                  "the second round replaced the first, and says so")
    (diff-block-reject! t--rw-buf)
    (check-equal! (buffer-text t--rw-buf) "One.\n\nTwo.\n"
                  "and the passage is still the passage")
    (t--rw-done!)))

(deftest 'a-rewrite-never-lands-on-changed-text
  "the reply is about a passage that is no longer there"
  (lambda ()
    (t--rw! "One.\n\nTwo.\n")
    (t--rw-propose! t--rw-buf 6 10 "Zero." "Nul." "in French")
    (check-equal! (buffer-text t--rw-buf) "One.\n\nTwo.\n"
                  "the buffer is untouched")
    (check-false! (diff-block-pending t--rw-buf) "and nothing waits")
    (t--rw-done!)))

(deftest 'an-edited-block-stays
  "a rewrite you have since edited is your text"
  (lambda ()
    (t--rw-proposed!)
    (buffer-replace! t--rw-buf "Deux." "Deux!")
    (diff-block-reject! t--rw-buf)
    (check-equal! (buffer-text t--rw-buf)
                  (t--rw-doc (diff-block-theirs-text "Deux!" t--rw-buf))
                  "a reject takes back nothing you wrote")
    (check-true! (diff-block-pending t--rw-buf) "and it still waits")
    (t--rw-done!)))

(deftest 'a-record-from-an-older-build-is-no-record
  "a hot reload can land between the proposal and the decision"
  (lambda ()
    (t--rw! "One.\n\nTwo.\n")
    (buffer-set-local! t--rw-buf 'diff-block '(6 10 "Two." "Deux." "in French"))
    (check-false! (diff-block-pending t--rw-buf)
                  "the old five-field shape is not read")
    (diff-block-accept! t--rw-buf)
    (check-equal! (buffer-text t--rw-buf) "One.\n\nTwo.\n"
                  "and no verb edits the document by arithmetic")
    (t--rw-done!)))

;;; The review prompt is the same key that made the rewrite, so the decision
;;; is reachable from the only window that can hold it.

(define (t--rw-review! answer)
  (llm-rewrite--review! t--rw-buf (diff-block-pending t--rw-buf) answer))







(deftest 'a-blank-instruction-makes-the-selection-the-instruction
  "A blank answer, at the waiting diff or the options prompt, sends the passage as its own instruction."
  (lambda ()
    (t--rw-options!)
    (let ((calls '()))
      (with-stub 'llm (lambda (prompt callback) (set! calls (append calls (list prompt))))
        (lambda ()
          (t--rw-review! "")
          (diff-block-reject! t--rw-buf)
          (with-stub 'minibuffer-read
            (lambda (prompt choices callback) (callback ""))
            (lambda () (llm-rewrite--options-menu! t--rw-buf)))))
      (check-equal! (length calls) 2 "both blank answers asked the model")
      (check-true! (number? (string-index (cadr calls) "is its own instruction"))
                   "the passage is the instruction"))
    (t--rw-done!)))

(deftest 'rewrite-options-forget-a-block-that-went-away
  "A recorded options span over other text is no block: keeping writes a new one and touches nothing else."
  (lambda ()
    (t--rw-proposed!)
    (llm-rewrite--new-session! t--rw-buf 6 10 "Two.")
    (llm-rewrite--save-session! t--rw-buf
      (plist-put (llm-rewrite--session t--rw-buf) 'block (list 0 4)))
    (llm-rewrite--keep-option! t--rw-buf)
    (check-true! (string-prefix? "One." (buffer-text t--rw-buf)) "the text under the stale span stands")
    (check-true! (string-index (buffer-text t--rw-buf) "```options") "a new options block landed")
    (t--rw-done!)))

(deftest 'rewriting-a-block-keeps-the-cursor-in-it
  "Redrawing the diff keeps a cursor inside it where it was."
  (lambda ()
    (t--rw-proposed!)
    (let* ((spans (diff-block--spans t--rw-buf))
           (at (+ (nth 2 spans) 5)))
      (buffer-goto! t--rw-buf at)
      (llm-rewrite--refine! t--rw-buf "Zwei." "German")
      (check-equal! (buffer-point t--rw-buf) at "the cursor did not move"))
    (t--rw-done!)))

(deftest 'notes-are-filled-in-place-and-nothing-else-changes
  "Following the notes, the model names words; the passage around them is kept byte for byte."
  (lambda ()
    (let* ((p "code [word for beams], a <a word for vessel>. [[link]] [t](u) <br> <https://x>")
           (notes (llm-rewrite--notes p)))
      (check-equal! (map caddr notes) '("word for beams" "a word for vessel")
                    "links, tags and urls are not notes")
      (check-equal! (llm-rewrite--fill-notes p notes "1: girders\n2. vessel")
                    "code girders, a vessel. [[link]] [t](u) <br> <https://x>" "filled in place")
      (check-false! (llm-rewrite--fill-notes p notes "1: girders") "a missing note fills nothing"))
    (t--rw! "it needs [word for beams] now.")
    (llm-rewrite--new-session! t--rw-buf 0 29 "it needs [word for beams] now.")
    (let ((landed #f))
      (with-stub 'llm (lambda (prompt callback) (callback "It needs: rafters, and more\n1: girders"))
        (lambda ()
          (llm-rewrite--ask! t--rw-buf "it needs [word for beams] now." *llm-rewrite-self-directive*
            (lambda (new) (set! landed new)))))
      (check-equal! landed "it needs girders now." "only the note changed"))
    (t--rw-done!)))

(deftest 'an-empty-answer-decides-nothing
  "leaving the prompt is not a decision"
  (lambda ()
    (t--rw-proposed!)
    (t--rw-review! "")
    (check-equal! (buffer-text t--rw-buf)
                  (t--rw-doc (diff-block-theirs-text "Deux." t--rw-buf))
                  "the document stands")
    (check-true! (diff-block-pending t--rw-buf) "and the rewrite still waits")
    (t--rw-done!)))

(deftest 'asking-for-a-rewrite-consumes-the-region
  "the command has the region, so the selection does not linger"
  (lambda ()
    (t--rw! "One.\n\nTwo.\n")
    (with-current-buffer t--rw-buf
      (lambda ()
        (goto-char! 10)
        (set-mark! 6)
        (llm-rewrite--start! t--rw-buf)
        (check-false! (mark) "the mark is gone the moment the ask begins")
        (run-command "minibuffer-cancel")))
    (t--rw-done!)))

(define (t--rw-options!)
  (t--rw-proposed!)
  (llm-rewrite--new-session! t--rw-buf 6 10 "Two.")
  (llm-rewrite--keep-option! t--rw-buf))

(deftest 'rewrite-options-keep-the-source-and-all-saved-drafts
  "Keeping an option does not accept the diff."
  (lambda ()
    (t--rw-options!)
    (check-equal! (block-text-at t--rw-buf 6 10) "Two." "source stays")
    (llm-rewrite--refine! t--rw-buf "Zwei." "German")
    (llm-rewrite--keep-option! t--rw-buf)
    (llm-rewrite--keep-option! t--rw-buf)
    (let* ((s (llm-rewrite--session t--rw-buf))
           (span (llm-rewrite--range t--rw-buf s "block")))
      (check-equal! (map cadr (plist-get s 'options)) '("Two." "Deux." "Zwei.")
                    "original plus two drafts, no duplicate")
      (check-equal! (block-text-at t--rw-buf (car span) (cadr span))
                    (llm-rewrite--options-text s) "options are a real document block"))
    (t--rw-done!)))

(deftest 'rewrite-options-survive-rejection-and-follow-edits-above
  "The saved alternatives remain after the preview is dismissed."
  (lambda ()
    (t--rw-options!)
    (diff-block-reject! t--rw-buf)
    (buffer-insert! t--rw-buf 0 "Intro.\n")
    (llm-rewrite--choose-option! t--rw-buf 1)
    (let* ((s (llm-rewrite--session t--rw-buf))
           (span (llm-rewrite--range t--rw-buf s "source")))
      (check-equal! (block-text-at t--rw-buf (car span) (cadr span)) "Deux."
                    "the tracked source receives the option")
      (check-true! (llm-rewrite--options-valid? t--rw-buf s) "options remain intact"))
    (llm-rewrite--choose-option! t--rw-buf 0)
    (let* ((s (llm-rewrite--session t--rw-buf))
           (span (llm-rewrite--range t--rw-buf s "source")))
      (check-equal! (block-text-at t--rw-buf (car span) (cadr span)) "Two." "original is option zero"))
    (t--rw-done!)))

(deftest 'rewrite-options-survive-direct-diff-acceptance
  "Accept through the diff command, then choose the original."
  (lambda ()
    (t--rw-options!)
    (with-current-buffer t--rw-buf (lambda () (run-command "diff-block-accept")))
    (check-equal! (plist-get (llm-rewrite--session t--rw-buf) 'current) "Deux."
                  "the diff decision updates the session")
    (llm-rewrite--choose-option! t--rw-buf 0)
    (check-equal! (block-text-at t--rw-buf 6 10) "Two." "original restored")
    (check-true! (llm-rewrite--options-valid? t--rw-buf (llm-rewrite--session t--rw-buf))
                 "saved block remains")
    (t--rw-done!)))

(deftest 'rewrite-options-choose-while-a-preview-is-waiting
  "Choosing an option dismisses an unedited preview first."
  (lambda ()
    (t--rw-options!)
    (llm-rewrite--choose-option! t--rw-buf 1)
    (check-false! (diff-block-pending t--rw-buf) "preview is gone")
    (check-equal! (block-text-at t--rw-buf 6 11) "Deux." "saved option chosen")
    (t--rw-done!)))

(deftest 'rewrite-options-hide-and-show-without-changing-text
  "Folding changes presentation only."
  (lambda ()
    (t--rw-options!)
    (let ((text (buffer-text t--rw-buf))
          (tag (llm-rewrite--face (llm-rewrite--session t--rw-buf) "fold")))
      (llm-rewrite--toggle-options! t--rw-buf)
      (check-true! (pair? (fold-get t--rw-buf tag)) "options hidden")
      (llm-rewrite--toggle-options! t--rw-buf)
      (check-equal! (fold-get t--rw-buf tag) '() "options visible")
      (check-equal! (buffer-text t--rw-buf) text "document unchanged"))
    (t--rw-done!)))

(deftest 'rewrite-options-protect-edited-source-and-options
  "Neither saved drafts nor the user's changed passage are overwritten."
  (lambda ()
    (t--rw-options!)
    (let* ((s (llm-rewrite--session t--rw-buf))
           (span (llm-rewrite--range t--rw-buf s "block")))
      (buffer-insert! t--rw-buf (+ (car span) 15) "manual")
      (let ((text (buffer-text t--rw-buf)))
        (llm-rewrite--keep-option! t--rw-buf)
        (check-equal! (buffer-text t--rw-buf) text "edited options stay")))
    (diff-block-reject! t--rw-buf)
    (buffer-insert! t--rw-buf 7 "manual")
    (let ((text (buffer-text t--rw-buf)))
      (llm-rewrite--choose-option! t--rw-buf 1)
      (check-equal! (buffer-text t--rw-buf) text "edited source stays"))
    (t--rw-done!)))

(deftest 'rewrite-iteration-sends-the-conversation-and-ignores-stale-replies
  "A later instruction sees earlier replies; superseded replies cannot land."
  (lambda ()
    (t--rw! "Two.")
    (llm-rewrite--new-session! t--rw-buf 0 4 "Two.")
    (let ((calls '()) (landed '()))
      (with-stub 'llm (lambda (prompt callback) (set! calls (append calls (list (list prompt callback)))))
        (lambda ()
          (llm-rewrite--ask! t--rw-buf "Two." "French" (lambda (s) (set! landed (cons s landed))))
          ((cadr (car calls)) "Deux.")
          (llm-rewrite--ask! t--rw-buf "Deux." "shorter" (lambda (s) (set! landed (cons s landed))))
          (llm-rewrite--ask! t--rw-buf "Deux." "German" (lambda (s) (set! landed (cons s landed))))
          ((cadr (cadr calls)) "stale")
          ((cadr (nth 2 calls)) "Zwei.")
          (check-equal! landed '("Zwei." "Deux.") "stale response discarded")
          (let* ((s (llm-rewrite--session t--rw-buf))
                 (chat (plist-get s 'chat)))
            (check-equal! (buffer-text chat) (plist-get s 'history) "chat holds the same history")
            (check-true! (number? (string-index (car (cadr calls)) "Deux.")) "prior reply is sent")
            (check-true! (number? (string-index (car (cadr calls)) "French")) "prior instruction is sent")))))
    (t--rw-done!)))

(deftest 'rewrite-options-rebuild-after-mode-setup
  "Saved document locals rebuild tracking and folds without a live model."
  (lambda ()
    (t--rw-options!)
    (diff-block-reject! t--rw-buf)
    (buffer-insert! t--rw-buf 0 "Intro.\n")
    (llm-rewrite--checkpoint! t--rw-buf)
    (llm-rewrite--toggle-options! t--rw-buf)
    (let* ((s (llm-rewrite--session t--rw-buf))
           (id (plist-get s 'id)))
      (for-each (lambda (part) (overlay-clear! t--rw-buf (llm-rewrite--face s part)))
                '("source" "block"))
      (fold-set! t--rw-buf (llm-rewrite--face s "fold") '())
      (with-current-buffer t--rw-buf (lambda () (set-mode! "text-mode")))
      (check-equal! (plist-get (llm-rewrite--session t--rw-buf) 'id) id "session identity survives")
      (check-true! (pair? (fold-get t--rw-buf (llm-rewrite--face s "fold"))) "hidden options rebuilt")
      (llm-rewrite--choose-option! t--rw-buf 1)
      (let* ((s (llm-rewrite--session t--rw-buf))
             (src (llm-rewrite--range t--rw-buf s "source")))
        (check-equal! (block-text-at t--rw-buf (car src) (cadr src)) "Deux." "selection still works")))
    (t--rw-done!)))

(deftest 'rewrite-options-command-runs-through-key-dispatch
  "A test-owned key saves the preview as an option."
  (lambda ()
    (t--rw-proposed!)
    (llm-rewrite--new-session! t--rw-buf 6 10 "Two.")
    (switch-to-buffer! t--rw-buf)
    (local-set-key* t--rw-buf "<f9> r" "llm-rewrite-keep-option")
    (trace-key! '("<f9>" "r"))
    (check-equal! (length (plist-get (llm-rewrite--session t--rw-buf) 'options)) 2
                  "the dispatched command saved an option")
    (check-equal! (block-text-at t--rw-buf 6 10) "Two." "source unchanged")
    (t--rw-done!)))

(deftest 'rewrite-diff-does-not-accept-over-an-edited-passage
  "The preview cannot overwrite newer source edits."
  (lambda ()
    (t--rw-options!)
    (buffer-insert! t--rw-buf 7 "manual")
    (let ((text (buffer-text t--rw-buf)))
      (diff-block-accept! t--rw-buf)
      (check-equal! (buffer-text t--rw-buf) text "source edit is preserved")
      (check-true! (pair? (diff-block-pending t--rw-buf)) "preview remains"))
    (t--rw-done!)))

(deftest 'rewrite-prompts-take-instructions-and-the-blocks-hold-the-actions
  "The prompts offer instructions only; the actions are keys on the fence lines and stay bound after the diff goes."
  (lambda ()
    (t--rw-options!)
    (with-stub 'minibuffer-read
      (lambda (prompt choices callback)
        (check-equal! (car choices) "try again" "iterating, try again leads")
        (check-equal! (cdr choices) (llm-rewrite-directives t--rw-buf) "then only instructions"))
      (lambda () (llm-rewrite--again! t--rw-buf (diff-block-pending t--rw-buf))))
    (with-stub 'minibuffer-read
      (lambda (prompt choices callback)
        (check-equal! choices (llm-rewrite-directives t--rw-buf) "only instructions are offered"))
      (lambda () (llm-rewrite--options-menu! t--rw-buf)))
    (let ((calls '()))
      (with-stub 'llm (lambda (prompt callback) (set! calls (cons prompt calls)))
        (lambda () (t--rw-review! "try again")))
      (check-true! (number? (string-index (car calls) "is its own instruction"))
                   "try again goes back to the passage's notes"))
    (diff-block-reject! t--rw-buf)
    (switch-to-buffer! t--rw-buf)
    (check-equal! (key-binding-dispatch '("C-c" "x")) '("command" "llm-rewrite-cancel")
                  "cancel stays bound for the options block")
    (check-equal! (key-binding-dispatch '("C-c" "h")) '("command" "llm-rewrite-show-chat")
                  "the chat key stays bound for the options block")
    (t--rw-done!)))

(deftest 'rewrite-options-fence-names-keys-and-promotes-at-point
  "The options block names its keys; C-c p promotes the draft under point, C-c u puts the original back."
  (lambda ()
    (t--rw-options!)
    (diff-block-reject! t--rw-buf)
    (let* ((s (llm-rewrite--session t--rw-buf))
           (span (llm-rewrite--range t--rw-buf s "block"))
           (text (plist-get s 'rendered))
           (head (car (string-split text "\n"))))
      (check-true! (string-index head "C-c p promote") "fence names promote")
      (check-true! (string-index head "C-c u original") "fence names restore")
      (check-false! (string-index text "Option 0") "the original is not a number")
      (check-false! (llm-rewrite--option-at t--rw-buf s (car span)) "the fence line is no option")
      (switch-to-buffer! t--rw-buf)
      (buffer-goto! t--rw-buf (+ (car span) (string-index text "Deux.")))
      (trace-key! '("C-c" "p"))
      (check-equal! (block-text-at t--rw-buf 6 11) "Deux." "C-c p promoted the draft at point")
      (let ((block (llm-rewrite--range t--rw-buf (llm-rewrite--session t--rw-buf) "block")))
        (check-true! (and (<= (car block) (buffer-point t--rw-buf)) (<= (buffer-point t--rw-buf) (cadr block)))
                     "the cursor stays in the options block"))
      (trace-key! '("C-c" "u"))
      (check-equal! (block-text-at t--rw-buf 6 10) "Two." "C-c u put the original back"))
    (t--rw-done!)))

(deftest 'rewrite-options-blocks-do-not-run
  "An options block holds saved text, not executable code."
  (lambda ()
    (check-false! (fence-kind-runnable? "options") "options are not executable")))
