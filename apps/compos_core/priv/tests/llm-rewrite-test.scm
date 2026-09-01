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
    (llm-rewrite--release! t--rw-buf)
    (buffer-kill! t--rw-buf)))

;; the document every verb below works on, with the rewrite of "Two."
;; already waiting under it
(define (t--rw-proposed!)
  (t--rw! "One.\n\nTwo.\n")
  (llm-rewrite--propose! t--rw-buf 6 10 "Two." "Deux." t--rw-what)
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

(deftest 'every-block-says-what-it-was-asked-and-what-you-can-do
  "the fence line names the kind and the instruction, in bare text"
  (lambda ()
    (check-equal! (llm-rewrite-theirs-block "new text" "make it X")
                  "```rewrite make it X\nnew text\n```"
                  "the block is a fence whose info string explains it")
    (check-equal! (llm-rewrite--body
                    (llm-rewrite-theirs-block "new text" "make it X"))
                  "new text"
                  "and the fences come off by structure")
    (check-equal! (llm-rewrite--body "no fences here")
                  "no fences here"
                  "a block whose fences were edited away stays whole")))

(deftest 'the-all-view-is-a-diff-fence
  "old lines over new, with the shared ends as context, in a ```diff block"
  (lambda ()
    (check-equal! (llm-rewrite-diff-block "a\nb\nc" "a\nX\nc" "make it X")
                  "```diff make it X\n a\n-b\n+X\n c\n```"
                  "one hunk between the shared ends, and the kind says diff")))

(deftest 'the-ours-view-is-the-passage-alone
  "a one-sided view is prose in a rewrite fence, never diff paint"
  (lambda ()
    (check-equal! (llm-rewrite-ours-block "Two." "make it X")
                  "```rewrite make it X · ours\nTwo.\n```"
                  "the fence args say which side this is")))

(deftest 'the-block-faces-follow-the-view
  "the all view reads by prefix; a one-sided view must not"
  (lambda ()
    (check-equal! (llm-rewrite--block-faces 0 "-b\n+X" 'all)
                  '((0 2 diff-del) (3 5 diff-add))
                  "the old line and the new one")
    (check-equal! (llm-rewrite--block-faces 0 "- a bullet" 'theirs)
                  '()
                  "a dash in prose is not a deleted line")))

(deftest 'a-rewrite-lands-below-the-passage
  "theirs by default, with the passage untouched above it"
  (lambda ()
    (t--rw-proposed!)
    (check-equal! (buffer-text t--rw-buf)
                  (t--rw-doc (llm-rewrite-theirs-block "Deux." t--rw-what))
                  "the block sits under the passage, one blank line down")
    (check-equal! (llm-rewrite--view (llm-rewrite-pending t--rw-buf)) 'theirs
                  "and it reads as theirs: the new text, not a diff")
    (check-equal! (llm-rewrite--old (llm-rewrite-pending t--rw-buf)) "Two."
                  "the passage is remembered as it was asked about")
    (t--rw-done!)))

(deftest 'the-key-cycles-theirs-all-ours
  "the diff is a key away, and every view comes from the same two strings"
  (lambda ()
    (t--rw-proposed!)
    (llm-rewrite-cycle-view! t--rw-buf)
    (check-equal! (buffer-text t--rw-buf)
                  (t--rw-doc (llm-rewrite-diff-block "Two." "Deux." t--rw-what))
                  "first all: the unified diff")
    (llm-rewrite-cycle-view! t--rw-buf)
    (check-equal! (buffer-text t--rw-buf)
                  (t--rw-doc (llm-rewrite-ours-block "Two." t--rw-what))
                  "then ours: the passage alone")
    (llm-rewrite-cycle-view! t--rw-buf)
    (check-equal! (buffer-text t--rw-buf)
                  (t--rw-doc (llm-rewrite-theirs-block "Deux." t--rw-what))
                  "and back to theirs")
    (t--rw-done!)))

(deftest 'keeping-a-rewrite-puts-it-in-the-passages-place
  "the passage, the block and the break between them become one text"
  (lambda ()
    (t--rw-proposed!)
    (llm-rewrite-accept! t--rw-buf)
    (check-equal! (buffer-text t--rw-buf) "One.\n\nDeux.\n"
                  "the rewrite stands where the passage did, header and all gone")
    (check-false! (llm-rewrite-pending t--rw-buf) "and nothing waits")
    (t--rw-done!)))

(deftest 'keeping-a-diff-block-lands-the-rewrite-it-describes
  "a diff is a view of two strings, not text to paste"
  (lambda ()
    (t--rw-proposed!)
    (llm-rewrite-cycle-view! t--rw-buf)
    (llm-rewrite-accept! t--rw-buf)
    (check-equal! (buffer-text t--rw-buf) "One.\n\nDeux.\n"
                  "no markers, no header")
    (t--rw-done!)))

(deftest 'keeping-a-block-you-edited-keeps-your-edit
  "a whole block is your text, not a view"
  (lambda ()
    (t--rw-proposed!)
    (buffer-replace! t--rw-buf "Deux." "Deux!")
    (llm-rewrite-accept! t--rw-buf)
    (check-equal! (buffer-text t--rw-buf) "One.\n\nDeux!\n"
                  "what you saw is what landed")
    (t--rw-done!)))

(deftest 'putting-it-back-removes-only-the-block
  "the passage was never touched, so there is nothing to restore"
  (lambda ()
    (t--rw-proposed!)
    (llm-rewrite-reject! t--rw-buf)
    (check-equal! (buffer-text t--rw-buf) "One.\n\nTwo.\n"
                  "the document is as it was")
    (check-false! (llm-rewrite-pending t--rw-buf) "and nothing waits")
    (t--rw-done!)))

(deftest 'asking-again-rewrites-the-block-not-the-passage
  "so a reject after any number of rounds still has the original"
  (lambda ()
    (t--rw-proposed!)
    (llm-rewrite--refine! t--rw-buf "Zwei." "now in German")
    (check-equal! (buffer-text t--rw-buf)
                  (t--rw-doc (llm-rewrite-theirs-block "Zwei." "now in German"))
                  "the second round replaced the first, and says so")
    (llm-rewrite-reject! t--rw-buf)
    (check-equal! (buffer-text t--rw-buf) "One.\n\nTwo.\n"
                  "and the passage is still the passage")
    (t--rw-done!)))

(deftest 'a-rewrite-never-lands-on-changed-text
  "the reply is about a passage that is no longer there"
  (lambda ()
    (t--rw! "One.\n\nTwo.\n")
    (llm-rewrite--propose! t--rw-buf 6 10 "Zero." "Nul." "in French")
    (check-equal! (buffer-text t--rw-buf) "One.\n\nTwo.\n"
                  "the buffer is untouched")
    (check-false! (llm-rewrite-pending t--rw-buf) "and nothing waits")
    (t--rw-done!)))

(deftest 'an-edited-block-stays
  "a rewrite you have since edited is your text"
  (lambda ()
    (t--rw-proposed!)
    (buffer-replace! t--rw-buf "Deux." "Deux!")
    (llm-rewrite-reject! t--rw-buf)
    (check-equal! (buffer-text t--rw-buf)
                  (t--rw-doc (llm-rewrite-theirs-block "Deux!" t--rw-what))
                  "a reject takes back nothing you wrote")
    (check-true! (llm-rewrite-pending t--rw-buf) "and it still waits")
    (t--rw-done!)))

(deftest 'a-record-from-an-older-build-is-no-record
  "a hot reload can land between the proposal and the decision"
  (lambda ()
    (t--rw! "One.\n\nTwo.\n")
    (buffer-set-local! t--rw-buf 'llm-rewrite '(6 10 "Two." "Deux." "in French"))
    (check-false! (llm-rewrite-pending t--rw-buf)
                  "the old five-field shape is not read")
    (llm-rewrite-accept! t--rw-buf)
    (check-equal! (buffer-text t--rw-buf) "One.\n\nTwo.\n"
                  "and no verb edits the document by arithmetic")
    (t--rw-done!)))

;;; The review prompt is the same key that made the rewrite, so the decision
;;; is reachable from the only window that can hold it.

(define (t--rw-review! answer)
  (llm-rewrite--review! t--rw-buf (llm-rewrite-pending t--rw-buf)
                        (llm-rewrite--spans t--rw-buf) answer))

(deftest 'the-review-prompt-keeps-a-rewrite
  "the keep answer is the accept verb"
  (lambda ()
    (t--rw-proposed!)
    (t--rw-review! *llm-rewrite-keep-answer*)
    (check-equal! (buffer-text t--rw-buf) "One.\n\nDeux.\n" "kept")
    (t--rw-done!)))

(deftest 'the-review-prompt-puts-a-rewrite-back
  "the back answer is the reject verb"
  (lambda ()
    (t--rw-proposed!)
    (t--rw-review! *llm-rewrite-back-answer*)
    (check-equal! (buffer-text t--rw-buf) "One.\n\nTwo.\n" "put back")
    (t--rw-done!)))

(deftest 'the-review-prompt-offers-the-views-you-are-not-in
  "two answers, and each says which view it gives"
  (lambda ()
    (t--rw-proposed!)
    (check-equal! (llm-rewrite--view-answers 'theirs)
                  '("show all" "show ours")
                  "a theirs block offers the diff and the passage")
    (t--rw-review! "show all")
    (check-equal! (buffer-text t--rw-buf)
                  (t--rw-doc (llm-rewrite-diff-block "Two." "Deux." t--rw-what))
                  "and the answer is the view")
    (t--rw-done!)))

(deftest 'an-empty-answer-decides-nothing
  "leaving the prompt is not a decision"
  (lambda ()
    (t--rw-proposed!)
    (t--rw-review! "")
    (check-equal! (buffer-text t--rw-buf)
                  (t--rw-doc (llm-rewrite-theirs-block "Deux." t--rw-what))
                  "the document stands")
    (check-true! (llm-rewrite-pending t--rw-buf) "and the rewrite still waits")
    (t--rw-done!)))
