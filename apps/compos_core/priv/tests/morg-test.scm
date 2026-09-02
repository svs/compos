;;; morg-test.scm --- morg-mode, by the commands that do the work.
;;;
;;; TAB is morg-cycle, S-TAB is morg-global-cycle, C-c C-t is morg-todo.
;;; A test sets a buffer and a point, runs the command, and reads the
;;; folds, the overlays and the text.
;;;
;;; The Markdown structural API is here too: markdown-outline, find, read,
;;; replace! and insert-after! address a section by the LINE its heading
;;; is on, so an agent edits one section and never a whole file.
;;;
;;; Two stay in ExUnit, both about a markdown-mode that is not built:
;;; one is a skipped design contract, and the other passes there but not
;;; here — set-mode! has no teardown hook, so morg's org faces survive the
;;; switch, which is the very gap the skipped test describes.

(domain! 'testing)
(effects! '(write))

(define t--morg-buf "zz-morg-mode.md")

;; "# a\nbody\n## child\ncbody\n# b\ntail\n"
;;  0123 4..8 9......17 ...   24.. 28..
(define t--morg-fixture "# a\nbody\n## child\ncbody\n# b\ntail\n")

(define (t--morg! text point)
  (test-buffer! t--morg-buf text)
  (with-current-buffer t--morg-buf (lambda () (set-mode! "morg-mode")))
  ;; these tests read morg's plain faces; preview-mode's painter would
  ;; replace them, so the page it draws stays off here
  (when (minor-mode-on? t--morg-buf "preview-mode")
    (disable-minor-mode! t--morg-buf "preview-mode"))
  (buffer-goto! t--morg-buf point)
  t--morg-buf)

(define (t--morg-run! cmd)
  (with-current-buffer t--morg-buf (lambda () (run-command cmd))))

(define (t--morg-faces)
  (map (lambda (o) (caddr o)) (buffer-overlays t--morg-buf)))

(define (t--morg-ts-face?)
  (fold (lambda (acc f) (or acc (string-prefix? "ts-" f))) #f (t--morg-faces)))

(define (t--morg-done!) (when (buffer-known? t--morg-buf) (buffer-kill! t--morg-buf)))

;; the structural API needs no point, so it takes the text alone
(define (t--morg-md! text) (t--morg! text 0))

;;; --- the mode -----------------------------------------------------------------

(deftest 'morg-mode-enables-writing-mode
  "prose wants visual lines, so morg turns them on"
  (lambda ()
    (t--morg! t--morg-fixture 0)
    (check-true! (buffer-local t--morg-buf 'visual-line-mode) "visual lines are on")
    (check-true! (member "writing-mode" (buffer-local t--morg-buf 'minor-modes))
                 "writing-mode came with it")
    (t--morg-done!)))

(deftest 'morg-mode-fontifies-headings-with-the-org-level-faces
  "the level is the depth of the hash marks"
  (lambda ()
    (t--morg! t--morg-fixture 0)
    (check-equal! (buffer-local t--morg-buf 'mode-name) "morg-mode" "the mode is set")
    (let ((ovs (buffer-overlays t--morg-buf)))
      (check-true! (member '(0 3 "org-level-1") ovs) "the top heading")
      (check-true! (member '(9 17 "org-level-2") ovs) "and the child"))
    (t--morg-done!)))

(deftest 'morg-scans-a-standalone-embed-directive
  "a complete #+embed line is a directive with one value"
  (lambda ()
    (t--morg! "before\n#+embed: https://youtu.be/dQw4w9WgXcQ\nafter\n" 0)
    (let ((entry (cadr (morg-scan t--morg-buf))))
      (check-equal! (morg-kind entry) 'directive "the line is a directive")
      (check-equal! (morg-info entry)
                    '("embed" "https://youtu.be/dQw4w9WgXcQ")
                    "the directive keeps its name and value")
      (check-true! (member '(7 44 "org-meta") (buffer-overlays t--morg-buf))
                   "plain Morg shows directive metadata"))
    (t--morg-done!)))

(deftest 'morg-does-not-scan-an-inline-embed-word-as-a-directive
  "directive syntax must occupy the complete line"
  (lambda ()
    (t--morg! "text #+embed: https://youtu.be/dQw4w9WgXcQ\n" 0)
    (check-equal! (morg-kind (car (morg-scan t--morg-buf))) 'text
                  "inline syntax remains paragraph text")
    (t--morg-done!)))

;;; --- folding ------------------------------------------------------------------

(deftest 'morg-cycle-folds-and-unfolds-the-heading-subtree-at-point
  "the subtree is the body and every child under it"
  (lambda ()
    (t--morg! t--morg-fixture 0)
    (t--morg-run! "morg-cycle")
    ;; "# a" subtree = body + child + cbody (bytes 3..23)
    (check-equal! (buffer-hidden t--morg-buf) '((3 23)) "the subtree folded")
    (t--morg-run! "morg-cycle")
    (check-equal! (buffer-hidden t--morg-buf) '() "and unfolded")
    (t--morg-done!)))

(deftest 'morg-global-cycle-cycles-overview-and-show-all
  "one command for the whole document"
  (lambda ()
    (t--morg! t--morg-fixture 0)
    (t--morg-run! "morg-global-cycle")
    (check-false! (equal? (buffer-hidden t--morg-buf) '()) "overview hides the bodies")
    (t--morg-run! "morg-global-cycle")
    (check-equal! (buffer-hidden t--morg-buf) '() "show-all brings them back")
    (t--morg-done!)))

(deftest 'morg-narrow-shows-one-heading-and-supplies-a-retrieval-hint
  "narrowing hides other sections without attaching document text"
  (lambda ()
    (t--morg! t--morg-fixture 12)
    (t--morg-run! "morg-narrow")
    (let* ((anchor (buffer-local t--morg-buf 'morg-narrow-anchor))
           (scan (morg-scan t--morg-buf))
           (entry (morg-entry-at scan anchor))
           (end (markdown--section-end scan t--morg-buf entry)))
      (check-equal! (buffer-narrow-range t--morg-buf)
                    (list anchor end)
                    "only the selected section remains visible")
      (check-contains! (buffer-context t--morg-buf) "markdown-outline"
                       "the hint starts with the outline")
      (check-contains! (buffer-context t--morg-buf) "markdown-read"
                       "the hint directs section reads"))
    ;; A daemon hot-loaded from the short-lived fold implementation may
    ;; still carry these ranges. Widening must migrate them away.
    (fold-set! t--morg-buf 'morg-narrow '((0 3)))
    (t--morg-run! "morg-widen")
    (check-false! (buffer-narrow-range t--morg-buf)
                  "widening clears the cosmetic restriction")
    (check-equal! (fold-get t--morg-buf 'morg-narrow) '()
                  "widening clears the legacy fold tag")
    (t--morg-done!)))

(deftest 'morg-narrow-rebuilds-after-an-edit-and-mode-setup
  "the durable anchor follows edits and setup restores its display range"
  (lambda ()
    (t--morg! t--morg-fixture 12)
    (t--morg-run! "morg-narrow")
    (let ((before (buffer-local t--morg-buf 'morg-narrow-anchor)))
      (buffer-insert! t--morg-buf 0 "intro\n")
      (check-true!
        (wait-until
          (lambda ()
            (equal? (buffer-local t--morg-buf 'morg-narrow-anchor)
                    (+ before 6)))
          3000 20)
        "the change hook completes")
      (check-equal! (buffer-local t--morg-buf 'morg-narrow-anchor)
                    (+ before 6) "the anchor follows an earlier edit")
      (buffer-widen! t--morg-buf)
      (with-current-buffer t--morg-buf (lambda () (set-mode! "morg-mode")))
      (check-true! (pair? (buffer-narrow-range t--morg-buf))
                   "mode setup rebuilds the display range"))
    (t--morg-done!)))

(deftest 'morg-outline-folds-every-heading-body
  "and running it again changes nothing"
  (lambda ()
    (t--morg! t--morg-fixture 9)
    (t--morg-run! "morg-cycle")
    (buffer-goto! t--morg-buf 5)

    (t--morg-run! "morg-outline")
    (check-equal! (buffer-local t--morg-buf 'morg-folds) '(0 9 24) "every heading folded")
    (check-equal! (buffer-hidden t--morg-buf) '((3 8) (17 23) (27 33)) "the hidden ranges")
    (check-equal! (buffer-point t--morg-buf) 0 "point moved to the first heading")

    (t--morg-run! "morg-outline")
    (check-equal! (buffer-local t--morg-buf 'morg-folds) '(0 9 24) "a second run is a no-op")
    (t--morg-done!)))

(deftest 'morg-cycle-toggles-one-heading-without-leaving-outline-mode
  "outline is a state, and one heading opening does not end it"
  (lambda ()
    (t--morg! t--morg-fixture 0)
    (t--morg-run! "morg-outline")
    (buffer-goto! t--morg-buf 9)
    (t--morg-run! "morg-cycle")

    (check-true! (buffer-local t--morg-buf 'morg-outline) "still in outline mode")
    (check-equal! (buffer-local t--morg-buf 'morg-folds) '(0 24) "that heading is open")
    (check-equal! (buffer-hidden t--morg-buf) '((3 8) (27 33)) "and the others are not")

    (t--morg-run! "morg-cycle")
    (check-equal! (buffer-hidden t--morg-buf) '((3 8) (17 23) (27 33)) "closing it restores them")
    (t--morg-done!)))

(deftest 'morg-cycle-on-a-fence-folds-the-code-block
  "a block is a foldable thing like a heading"
  (lambda ()
    (t--morg! "```elixir\n1 + 1\n```\n# next\n" 0)
    (t--morg-run! "morg-cycle")
    ;; open fence eol (9) .. end of the close fence line (19)
    (check-equal! (buffer-hidden t--morg-buf) '((9 19)) "the block folded")
    (t--morg-run! "morg-cycle")
    (check-equal! (buffer-hidden t--morg-buf) '() "and unfolded")
    (t--morg-done!)))

(deftest 'morg-cycle-inside-a-block-body-folds-the-enclosing-block
  "point in the code means the block, not the heading above it"
  (lambda ()
    (t--morg! "```elixir\n1 + 1\n```\n" 12)
    (t--morg-run! "morg-cycle")
    (check-equal! (buffer-hidden t--morg-buf) '((9 19)) "the enclosing block folded")
    (t--morg-done!)))

(deftest 'a-hash-line-inside-a-fenced-block-is-not-a-heading
  "it is a shell comment, and the fold swallows the whole block"
  (lambda ()
    (t--morg! "# real\n```sh\n# comment\n```\n" 0)
    (let ((ovs (buffer-overlays t--morg-buf)))
      (check-true! (member '(0 6 "org-level-1") ovs) "the real heading")
      (check-false! (fold (lambda (acc o)
                            (or acc (and (equal? (car o) 13)
                                         (string-prefix? "org-level" (caddr o)))))
                          #f ovs)
                    "and nothing at the comment"))
    (t--morg-run! "morg-cycle")
    (check-equal! (buffer-hidden t--morg-buf) '((6 27)) "one fold over the whole block")
    (t--morg-done!)))

(deftest 'folds-re-anchor-through-edits-above-them
  "an insert before a fold pushes the hidden range down"
  (lambda ()
    (t--morg! t--morg-fixture 0)
    (t--morg-run! "morg-cycle")
    (check-equal! (buffer-hidden t--morg-buf) '((3 23)) "the fold")
    (buffer-insert! t--morg-buf 0 "x")
    (check-equal! (buffer-hidden t--morg-buf) '((4 24)) "moved by one byte")
    (t--morg-done!)))

(deftest 'the-mode-setup-re-derives-folds-from-the-surviving-local
  "a restart drops hidden ranges and keeps locals"
  (lambda ()
    (t--morg! t--morg-fixture 0)
    (t--morg-run! "morg-cycle")
    (check-equal! (buffer-hidden t--morg-buf) '((3 23)) "the fold")

    ;; simulate the restart: the ranges go, the local stays
    (fold-set! t--morg-buf 'morg '())
    (check-equal! (buffer-hidden t--morg-buf) '() "the ranges are gone")
    (with-current-buffer t--morg-buf (lambda () (set-mode! "morg-mode")))
    (check-equal! (buffer-hidden t--morg-buf) '((3 23)) "and the setup rebuilt them")
    (t--morg-done!)))

(deftest 'copying-a-selected-folded-heading-lifts-the-whole-subtree
  "the visible heading represents its hidden body and child"
  (lambda ()
    (t--morg! t--morg-fixture 0)
    (t--morg-run! "morg-cycle")
    (with-current-buffer t--morg-buf
      (lambda ()
        (set-mark! 0)
        (goto-char! 3)))

    (t--morg-run! "copy-region-as-kill")
    (check-equal! (kill-top) "# a\nbody\n## child\ncbody\n"
                  "the hidden subtree is copied")
    (check-equal! (buffer-text t--morg-buf) t--morg-fixture
                  "copy does not edit the buffer")
    (t--morg-done!)))

(deftest 'copying-and-pasting-a-folded-heading-reproduces-the-whole-subtree
  "the hidden body and child survive the complete copy-paste path"
  (lambda ()
    (t--morg! t--morg-fixture 0)
    (t--morg-run! "morg-cycle")
    (with-current-buffer t--morg-buf
      (lambda ()
        (set-mark! 0)
        (goto-char! 3)))

    (t--morg-run! "copy-region-as-kill")
    (with-current-buffer t--morg-buf
      (lambda () (end-of-buffer!)))
    (t--morg-run! "yank")

    (check-equal! (buffer-text t--morg-buf)
                  (string-append t--morg-fixture
                                 "# a\nbody\n## child\ncbody\n")
                  "paste reproduces the complete folded subtree")
    (t--morg-done!)))

(deftest 'cutting-a-selected-folded-heading-lifts-the-whole-subtree
  "one cut removes the heading, body, and child"
  (lambda ()
    (t--morg! t--morg-fixture 0)
    (t--morg-run! "morg-cycle")
    (with-current-buffer t--morg-buf
      (lambda ()
        (set-mark! 0)
        (goto-char! 3)))

    (t--morg-run! "kill-region")
    (check-equal! (kill-top) "# a\nbody\n## child\ncbody\n"
                  "the hidden subtree is on the kill ring")
    (check-equal! (buffer-text t--morg-buf) "# b\ntail\n"
                  "the complete subtree is gone")
    (check-equal! (buffer-hidden t--morg-buf) '() "its stale fold is gone")
    (t--morg-done!)))

(deftest 'copying-part-of-a-folded-line-keeps-the-literal-region
  "selecting words in a folded title must not copy its body"
  (lambda ()
    (t--morg! t--morg-fixture 0)
    (t--morg-run! "morg-cycle")
    (with-current-buffer t--morg-buf
      (lambda ()
        (set-mark! 2)
        (goto-char! 3)))

    (t--morg-run! "copy-region-as-kill")
    (check-equal! (kill-top) "a" "only the selected title text is copied")
    (t--morg-done!)))

(deftest 'copying-a-selected-folded-fence-lifts-the-whole-block
  "a folded code opener represents the body and closing fence"
  (lambda ()
    (t--morg! "```elixir\n1 + 1\n```\n# next\n" 0)
    (t--morg-run! "morg-cycle")
    (with-current-buffer t--morg-buf
      (lambda ()
        (set-mark! 0)
        (goto-char! 9)))

    (t--morg-run! "copy-region-as-kill")
    (check-equal! (kill-top) "```elixir\n1 + 1\n```\n"
                  "the complete fenced block is copied")
    (t--morg-done!)))

(deftest 'system-copy-lifts-a-selected-folded-heading
  "the OS clipboard path uses the same structural region"
  (lambda ()
    (t--morg! t--morg-fixture 0)
    (t--morg-run! "morg-cycle")
    (with-current-buffer t--morg-buf
      (lambda ()
        (set-mark! 0)
        (goto-char! 3)
        (check-equal! (clipboard-copy) "# a\nbody\n## child\ncbody\n"
                      "system copy receives the hidden subtree")))
    (t--morg-done!)))

;;; --- TODO state ---------------------------------------------------------------

(deftest 'morg-todo-cycles-todo-done-and-no-state
  "three states, and the face follows each one"
  (lambda ()
    (t--morg! "# task\n" 0)
    (t--morg-run! "morg-todo")
    (check-equal! (buffer-text t--morg-buf) "# TODO task\n" "TODO")
    (check-true! (member '(2 6 "org-todo") (buffer-overlays t--morg-buf)) "with its face")

    (t--morg-run! "morg-todo")
    (check-equal! (buffer-text t--morg-buf) "# DONE task\n" "DONE")
    (check-true! (member '(2 6 "org-done") (buffer-overlays t--morg-buf)) "with its face")

    (t--morg-run! "morg-todo")
    (check-equal! (buffer-text t--morg-buf) "# task\n" "and back to none")
    (check-false! (or (member "org-todo" (t--morg-faces)) (member "org-done" (t--morg-faces)))
                  "with no state face left")
    (t--morg-done!)))

(deftest 'morg-todo-does-not-change-a-body-line
  "a TODO belongs to a heading"
  (lambda ()
    (t--morg! "# task\nbody\n" 8)
    (t--morg-run! "morg-todo")
    (check-equal! (buffer-text t--morg-buf) "# task\nbody\n" "the body is untouched")
    (t--morg-done!)))

(deftest 'todo-cycling-keeps-a-folded-task-folded-and-undoes-in-one-step
  "the fold moves with the text the keyword pushed down"
  (lambda ()
    (t--morg! "# task\nbody\n" 0)
    (t--morg-run! "morg-cycle")
    (check-equal! (buffer-hidden t--morg-buf) '((6 12)) "the task is folded")

    (t--morg-run! "morg-todo")
    (check-equal! (buffer-text t--morg-buf) "# TODO task\nbody\n" "the keyword went in")
    (check-equal! (buffer-hidden t--morg-buf) '((11 17)) "and the fold moved with it")

    (with-current-buffer t--morg-buf (lambda () (undo!)))
    (check-equal! (buffer-text t--morg-buf) "# task\nbody\n" "one undo took the keyword back")
    (t--morg-done!)))

;;; --- fenced code --------------------------------------------------------------

(deftest 'fenced-code-renders-with-the-themes-ts-faces
  "a block resolves its own grammar; the buffer carries none"
  (lambda ()
    (t--morg! "```elixir\ndef foo do\n  :ok\nend\n```\n" 0)
    (check-true! (t--morg-ts-face?) "the block is highlighted")
    (t--morg-done!)))

(deftest 'an-unknown-language-renders-plain-without-error
  "no grammar is not an error, it is plain text"
  (lambda ()
    (t--morg! "```brainfuck\n+++\n```\n" 0)
    (check-false! (t--morg-ts-face?) "nothing is highlighted")
    (t--morg-done!)))

;;; --- the structural API -------------------------------------------------------

(deftest 'md-files-open-in-morg-mode
  "the extension decides, like every other mode"
  (lambda ()
    (check-equal! (auto-mode-for "notes.md") "morg-mode" "a .md file")))

(deftest 'the-markdown-api-outlines-and-finds-headings-outside-fences
  "a # inside a fenced block is code, not a heading"
  (lambda ()
    (t--morg-md! "# One\nbody\n## Child\ntext\n```sh\n# not a heading\n```\n# Two\n")
    (check-equal! (markdown-outline t--morg-buf)
                  '((1 1 "One") (3 2 "Child") (8 1 "Two")) "the outline")
    (check-equal! (markdown-find t--morg-buf "Child")
                  '((3 2 "Child")) "the search")
    (check-contains!
      (llm-tool-call "markdown-outline" (list 'buffer t--morg-buf))
      "(3 2 \"Child\")" "the agent can outline without prompt instructions")
    (check-equal!
      (llm-tool-call "markdown-read" (list 'buffer t--morg-buf 'line 3))
      "## Child\ntext\n```sh\n# not a heading\n```\n"
      "the agent reads one relevant section")
    (t--morg-done!)))

(deftest 'the-markdown-api-reads-the-section-that-holds-a-body-line
  "a read is shallow unless the caller asks for the subtree"
  (lambda ()
    (t--morg-md! "# One\nbody\n## Child\ntext\n# Two\ntail\n")
    (check-equal! (markdown-read t--morg-buf 4) "## Child\ntext\n" "the child section")
    (check-equal! (markdown-read t--morg-buf 1) "# One\nbody\n"
                  "the parent excludes its child by default")
    (check-equal! (markdown-read t--morg-buf 1 #t)
                  "# One\nbody\n## Child\ntext\n"
                  "an explicit subtree includes the child")
    (check-equal!
      (llm-tool-call "markdown-read" (list 'buffer t--morg-buf 'line 1))
      "# One\nbody\n" "the tool also defaults to the shallow section")
    (check-equal!
      (llm-tool-call "markdown-read"
                     (list 'buffer t--morg-buf 'line 1 'subtree #t))
      "# One\nbody\n## Child\ntext\n"
      "the tool requires an explicit subtree request")
    (t--morg-done!)))

(deftest 'the-markdown-api-replaces-one-duplicate-section-by-line
  "two headings share a name, and the line says which one"
  (lambda ()
    (t--morg-md! "# Same\nfirst\n# Same\nsecond\n# Last\ntail\n")
    (check-contains! (markdown-replace! t--morg-buf 3 "# Same\nchanged")
                     "replaced the Markdown section" "the report")
    (check-equal! (buffer-text t--morg-buf)
                  "# Same\nfirst\n# Same\nchanged\n# Last\ntail\n"
                  "only the second one changed")
    (t--morg-done!)))

(deftest 'the-markdown-api-inserts-a-peer-after-a-section
  "after the section and its children, not after its heading"
  (lambda ()
    (t--morg-md! "# One\nbody\n# Three\ntail\n")
    (check-contains! (markdown-insert-after! t--morg-buf 1 "# Two\nnew")
                     "inserted Markdown" "the report")
    (check-equal! (buffer-text t--morg-buf) "# One\nbody\n# Two\nnew\n# Three\ntail\n"
                  "the peer landed between them")
    (t--morg-done!)))

(deftest 'the-markdown-api-reports-preamble-and-invalid-lines
  "a line no section holds is an answer, not a guess"
  (lambda ()
    (t--morg-md! "preamble\n\n# One\nbody\n")
    (check-contains! (markdown-read t--morg-buf 1)
                     "no Markdown section holds line 1" "the preamble")
    (check-contains! (markdown-read t--morg-buf 99) "outside the buffer" "a line past the end")
    (t--morg-done!)))

(deftest 'the-markdown-editing-skill-exposes-the-section-api
  "an agent reads the skill and finds the calls"
  (lambda ()
    (let ((body (skill "markdown-editing")))
      (check-contains! body "markdown-outline" "the read call")
      (check-contains! body "markdown-replace!" "and the write one"))
    (let ((entry (catalog-entry 'function "markdown-replace!")))
      (check-equal! (plist-get entry 'package) "morg" "the package")
      (check-equal! (plist-get entry 'domain) "writing" "the domain")
      (check-equal! (plist-get entry 'effects) '("write") "the effects"))))

(deftest 'morg-babel-and-morg-tangle-load-as-package-extensions
  "each is its own package, stamped by the loader"
  (lambda ()
    (check-true! (member "morg-babel" (command-names)) "morg-babel is a command")
    (check-true! (member "morg-tangle" (command-names)) "and so is morg-tangle")
    (check-equal! (plist-get (catalog-entry 'command "morg-babel") 'package)
                  "morg-babel" "babel names its own package")
    (check-equal! (plist-get (catalog-entry 'command "morg-tangle") 'package)
                  "morg-tangle" "and so does tangle")))


;;; --- babel and tangle ------------------------------------------------------------


;;; A shell block runs off the editor lane, so a test drives the seam
;;; instead of a shell: t--babel-now! answers at once, and t--babel-later!
;;; holds the answer until the test asks for it.

(define t--babel-real-shell *morg-babel-shell*)
(define t--babel-pending #f)
(define t--babel-real-scheme *morg-babel-scheme*)
(define t--babel-scheme-pending #f)

(define (t--babel-now! out)
  (set! *morg-babel-shell*
    (lambda (runner body k) (k out))))

(define (t--babel-later!)
  (set! t--babel-pending #f)
  (set! *morg-babel-shell*
    (lambda (runner body k) (set! t--babel-pending k))))

(define (t--babel-answer! out)
  (let ((k t--babel-pending))
    (set! t--babel-pending #f)
    (k out)))

(define (t--babel-scheme-now!)
  (set! *morg-babel-scheme*
    (lambda (body k) (k #t (eval-string-safe body)))))

(define (t--babel-scheme-later!)
  (set! t--babel-scheme-pending #f)
  (set! *morg-babel-scheme*
    (lambda (body k) (set! t--babel-scheme-pending (list body k)))))

(define (t--babel-scheme-answer!)
  (let ((pending t--babel-scheme-pending))
    (set! t--babel-scheme-pending #f)
    ((cadr pending) #t (eval-string-safe (car pending)))))

(define (t--babel-restore!)
  (set! *morg-babel-shell* t--babel-real-shell)
  (set! t--babel-pending #f)
  (set! *morg-babel-scheme* t--babel-real-scheme)
  (set! t--babel-scheme-pending #f))

(deftest 'a-shell-block-runs-into-a-result-block
  "the result is a block, so a second run can replace it"
  (lambda ()
    (t--babel-now! "hi\n")
    (t--morg! "```sh\necho hi\n```\n" 7)
    (t--morg-run! "morg-babel")
    (check-equal! (buffer-text t--morg-buf) "```sh\necho hi\n```\n```result\nhi\n```\n"
                  "the output landed in a result block")
    (t--babel-restore!)
    (t--morg-done!)))

(deftest 'a-second-run-replaces-the-result-block
  "not a second one appended"
  (lambda ()
    (t--babel-now! "hi\n")
    (t--morg! "```sh\necho hi\n```\n" 7)
    (t--morg-run! "morg-babel")
    (t--morg-run! "morg-babel")
    (check-equal! (buffer-text t--morg-buf) "```sh\necho hi\n```\n```result\nhi\n```\n"
                  "still one result block")
    (t--babel-restore!)
    (t--morg-done!)))

(deftest 'a-running-block-says-so-until-its-output-arrives
  "the editor is free while the command works"
  (lambda ()
    (t--babel-later!)
    (t--morg! "```sh\nsleep 1\n```\n" 7)
    (t--morg-run! "morg-babel")
    (check-equal! (buffer-text t--morg-buf)
                  "```sh\nsleep 1\n```\n```result\nrunning\n```\n"
                  "the result block reports the run")
    (t--babel-answer! "done\n")
    (check-equal! (buffer-text t--morg-buf)
                  "```sh\nsleep 1\n```\n```result\ndone\n```\n"
                  "and the output replaced it")
    (t--babel-restore!)
    (t--morg-done!)))

(deftest 'the-output-finds-the-block-after-the-document-moves-it
  "the block's identity is its language and its body, not a byte offset"
  (lambda ()
    (t--babel-later!)
    (t--morg! "```sh\necho hi\n```\n" 7)
    (t--morg-run! "morg-babel")
    (buffer-insert! t--morg-buf 0 "# Title\n\n")
    (t--babel-answer! "hi\n")
    (check-equal! (buffer-text t--morg-buf)
                  "# Title\n\n```sh\necho hi\n```\n```result\nhi\n```\n"
                  "the output landed in the block that ran")
    (t--babel-restore!)
    (t--morg-done!)))

(deftest 'one-block-runs-once-at-a-time
  "a second start while the first still runs is refused"
  (lambda ()
    (t--babel-later!)
    (t--morg! "```sh\necho hi\n```\n" 7)
    (t--morg-run! "morg-babel")
    (check-equal! (car (morg-babel-execute t--morg-buf 7)) 'error
                  "the second start is an error")
    (t--babel-answer! "hi\n")
    (check-equal! (car (morg-babel-execute t--morg-buf 7)) 'pending
                  "and the block runs again once the first run ends")
    (t--babel-restore!)
    (t--morg-done!)))

(deftest 'a-sync-block-answers-before-the-command-returns
  "`:sync` holds the editor, so the result is there when the command ends"
  (lambda ()
    (t--morg! "```sh :sync\necho hi\n```\n" 13)
    (t--morg-run! "morg-babel")
    (check-equal! (buffer-text t--morg-buf)
                  "```sh :sync\necho hi\n```\n```result\nhi\n```\n"
                  "the real shell ran on the lane")
    (t--morg-done!)))

(deftest 'a-scheme-block-evaluates-in-the-editors-interpreter
  "the same interpreter the editor is written in"
  (lambda ()
    (t--babel-scheme-now!)
    (t--morg! "```scheme\n(+ 1 2)\n```\n" 11)
    (t--morg-run! "morg-babel")
    (check-equal! (buffer-text t--morg-buf) "```scheme\n(+ 1 2)\n```\n```result-scheme\n3\n```\n"
                  "the value came back")
    (t--babel-restore!)
    (t--morg-done!)))

(deftest 'a-scheme-block-runs-off-the-editor-lane
  "the result says running until the Scheme task answers"
  (lambda ()
    (t--babel-scheme-later!)
    (t--morg! "```scheme\n(+ 1 2)\n```\n" 11)
    (t--morg-run! "morg-babel")
    (check-equal! (buffer-text t--morg-buf)
                  "```scheme\n(+ 1 2)\n```\n```result\nrunning\n```\n"
                  "the result reports the pending Scheme work")
    (t--babel-scheme-answer!)
    (check-equal! (buffer-text t--morg-buf)
                  "```scheme\n(+ 1 2)\n```\n```result-scheme\n3\n```\n"
                  "the task result replaced running")
    (t--babel-restore!)
    (t--morg-done!)))

(deftest 'a-scheme-block-runs-once-at-a-time
  "the second run cannot start while the Scheme task runs"
  (lambda ()
    (t--babel-scheme-later!)
    (t--morg! "```scheme\n(+ 1 2)\n```\n" 11)
    (check-equal! (car (morg-babel-execute t--morg-buf 11)) 'pending
                  "the first run starts")
    (check-equal! (car (morg-babel-execute t--morg-buf 11)) 'error
                  "the second run is refused")
    (t--babel-scheme-answer!)
    (t--babel-restore!)
    (t--morg-done!)))

(deftest 'a-sync-scheme-block-runs-on-the-calling-lane
  "the sync marker keeps the old immediate Scheme behavior"
  (lambda ()
    (t--morg! "```scheme :sync\n(+ 1 2)\n```\n" 17)
    (t--morg-run! "morg-babel")
    (check-equal! (buffer-text t--morg-buf)
                  "```scheme :sync\n(+ 1 2)\n```\n```result-scheme\n3\n```\n"
                  "the result is present when the command returns")
    (t--morg-done!)))

(deftest 'a-scheme-result-pretty-prints-nested-property-lists
  "long Scheme data stays readable in its Morg result block"
  (lambda ()
    (t--morg!
      (string-append
        "```scheme :sync\n"
        "(list (list 'kind \"function\" 'name \"read-file-numbered\" "
        "'doc \"read source text files with stable line numbers for exact citations\") "
        "(list 'kind \"function\" 'name \"spreadsheet-read\" "
        "'doc \"read a workbook by buffer name without displaying it\"))\n"
        "```\n")
      20)
    (t--morg-run! "morg-babel")
    (check-contains!
      (buffer-text t--morg-buf)
      (string-append
        "```result-scheme\n"
        "((kind \"function\"\n"
        "  name \"read-file-numbered\"\n"
        "  doc \"read source text files with stable line numbers for exact citations\")\n"
        " (kind \"function\"\n"
        "  name \"spreadsheet-read\"\n"
        "  doc \"read a workbook by buffer name without displaying it\"))\n"
        "```\n")
      "property keys stay beside their values and rows start on separate lines")
    (check-equal! (morg-ts-lang "result-scheme") "scheme"
                  "the Scheme result uses the Scheme highlighter")
    (t--morg-done!)))

(deftest 'running-outside-a-block-does-not-edit-the-buffer
  "there is nothing to run, so nothing happens"
  (lambda ()
    (t--morg! t--morg-fixture 5)
    (t--morg-run! "morg-babel")
    (check-equal! (buffer-text t--morg-buf) t--morg-fixture "the document is untouched")
    (t--morg-done!)))

(deftest 'a-result-block-is-not-runnable
  "output is not source"
  (lambda ()
    (t--morg! "```result\nold\n```\n" 11)
    (t--morg-run! "morg-babel")
    (check-equal! (buffer-text t--morg-buf) "```result\nold\n```\n" "nothing ran")
    (t--morg-done!)))

(deftest 'a-csv-block-previews-its-existing-tangle-file
  "CSV is data, so Babel reads its file instead of asking for a runner"
  (lambda ()
    (let ((path (string-append (compos-home) "/zz-morg-preview.csv")))
      (write-file! path
        "disk_header,value\ndisk_one,1\ndisk_two,2\ndisk_three,3\ndisk_four,4\ndisk_five,5\n")
      (t--morg!
        (string-append "```csv :tangle " path "\n"
                       "stale_header,value\nstale_row,9\n```\n")
        20)
      (check-equal! (morg-babel-execute t--morg-buf 20) '(ok "csv")
                    "CSV uses its preview handler")
      (check-equal!
        (buffer-text t--morg-buf)
        (string-append
          "```csv :tangle " path "\n"
          "stale_header,value\nstale_row,9\n```\n"
          "```result-csv\n"
          "disk_header,value\ndisk_one,1\ndisk_two,2\ndisk_three,3\ndisk_four,4\n"
          "```\n")
        "the default preview contains five file lines")
      (morg-refontify! t--morg-buf)
      (check-true! (member "morg-bold" (t--morg-faces))
                   "the CSV result header is bold in morg-mode")
      (delete-file! path)
      (t--morg-done!))))

(deftest 'a-csv-block-falls-back-to-its-body-and-honors-lines
  "a missing tangle file leaves the block useful"
  (lambda ()
    (let ((path (string-append (compos-home) "/zz-morg-missing.csv")))
      (when (file-exists? path) (delete-file! path))
      (t--morg!
        (string-append "```csv :tangle " path " :lines 2\n"
                       "name,value\none,1\ntwo,2\n```\n")
        20)
      (check-equal! (morg-babel-execute t--morg-buf 20) '(ok "csv")
                    "a missing file is not a runner error")
      (check-contains! (buffer-text t--morg-buf)
                       "```result-csv\nname,value\none,1\n```\n"
                       "the preview uses two body lines")
      (t--morg-done!))))

(deftest 'a-csv-result-block-is-not-runnable
  "a preview is output, not another CSV source block"
  (lambda ()
    (t--morg! "```result-csv\nname,value\n```\n" 18)
    (check-equal! (car (morg-babel-execute t--morg-buf 18)) 'error
                  "the result does not ask for a runner")
    (t--morg-done!)))

(deftest 'tangle-writes-marked-blocks-relative-to-the-morg-file
  "one file from two blocks, and a block marked no is skipped"
  (lambda ()
    (let ((dir (string-append (compos-home) "/zz-morg-tangle")))
      (shell-command->string (string-append "rm -rf " dir))
      (make-directory! dir)
      (t--morg!
        (string-append
          "# Program\n"
          "```elixir :tangle lib/demo.ex\n"
          "defmodule Demo do\n"
          "```\n"
          "```elixir :tangle lib/demo.ex\n"
          "end\n"
          "```\n"
          "```sh :tangle no\n"
          "echo skip\n"
          "```\n")
        0)
      (buffer-set-local! t--morg-buf 'default-directory (string-append dir "/"))
      (t--morg-run! "morg-tangle")

      (check-equal! (read-file (string-append dir "/lib/demo.ex")) "defmodule Demo do\nend\n"
                    "both blocks landed in one file, in order")
      (check-false! (file-exists? (string-append dir "/no")) "and the skipped block wrote nothing")
      (shell-command->string (string-append "rm -rf " dir))
      (t--morg-done!))))

;;; --- show-source ----------------------------------------------------------------
;;; A :show-source block is a view of a snippet. The fill reads the file;
;;; the file is never written.

(define t--show-source-dir (string-append (compos-home) "/zz-morg-show-source"))
(define t--show-source-lib (string-append t--show-source-dir "/lib.scm"))

(define (t--show-source-make!)
  (shell-command->string (string-append "rm -rf " (sh-quote t--show-source-dir)))
  (make-directory! t--show-source-dir)
  (write-file! t--show-source-lib
    ";; lib\n(define (alpha x)\n  (+ x 1))\n\n(define (beta y)\n  (* y 2))\n"))

(define (t--show-source-remove!)
  (shell-command->string (string-append "rm -rf " (sh-quote t--show-source-dir))))

(define (t--show-source-doc! text)
  (t--morg! text 0)
  (buffer-set-local! t--morg-buf 'default-directory (string-append t--show-source-dir "/")))

(deftest 'show-source-snippet-names-a-definition-a-line-or-a-range
  "WHAT after :: picks the snippet; a missing file is an error, not text"
  (lambda ()
    (t--show-source-make!)
    (t--show-source-doc! "# Doc\n")
    (check-equal! (show-source-snippet t--morg-buf "lib.scm::beta")
                  "(define (beta y)\n  (* y 2))\n" "a definition by name")
    (check-equal! (show-source-snippet t--morg-buf "lib.scm::5")
                  "(define (beta y)\n  (* y 2))\n" "the definition that holds a line")
    (check-equal! (show-source-snippet t--morg-buf "lib.scm::2-3")
                  "(define (alpha x)\n  (+ x 1))\n" "a line range")
    (check-equal! (car (show-source-snippet t--morg-buf "nope.scm::beta")) 'error
                  "a missing file answers an error")
    (check-equal! (car (show-source-snippet t--morg-buf "lib.scm::gamma")) 'error
                  "and so does a missing definition")
    (check-false! (buffer-known? t--show-source-lib)
                  "the read leaves no buffer behind")
    (t--show-source-remove!)
    (t--morg-done!)))

(deftest 'show-source-takes-many-definitions-from-one-file-or-several
  "a comma list names definitions in order; a second target adds another file"
  (lambda ()
    (t--show-source-make!)
    ;; two definitions: the outline reads a file with one as that one's parts
    (write-file! (string-append t--show-source-dir "/other.scm")
                 "(define (gamma z)\n  z)\n\n(define (delta w)\n  w)\n")
    (t--show-source-doc! "# Doc\n")
    (check-equal! (show-source-snippet t--morg-buf "lib.scm::beta,alpha")
                  "(define (beta y)\n  (* y 2))\n\n(define (alpha x)\n  (+ x 1))\n"
                  "two definitions, in the order named, a blank line between")
    (check-equal! (show-source-text t--morg-buf '("lib.scm::alpha" "other.scm::gamma"))
                  "(define (alpha x)\n  (+ x 1))\n\n(define (gamma z)\n  z)\n"
                  "two files, one body")
    (check-equal! (car (show-source-snippet t--morg-buf "lib.scm::alpha,nope")) 'error
                  "one missing name fails the whole list")
    (check-equal! (morg-show-source-targets "scheme :show-source a.scm::x b.scm::y :tangle out")
                  '("a.scm::x" "b.scm::y")
                  "targets stop at the next argument")
    (t--show-source-remove!)
    (t--morg-done!)))

(deftest 'show-source-fill-replaces-the-body-and-runs-from-babel
  "C-c C-c on the block fills it; a stale body is replaced, the file is untouched"
  (lambda ()
    (t--show-source-make!)
    (t--show-source-doc!
      (string-append "# Doc\n"
                     "```scheme :show-source lib.scm::beta\n"
                     "stale\n"
                     "```\n"))
    (buffer-goto! t--morg-buf 12)
    (check-equal! (morg-babel-execute t--morg-buf 12) '(ok "scheme")
                  "the argument owns the run")
    (check-equal! (buffer-text t--morg-buf)
                  (string-append "# Doc\n"
                                 "```scheme :show-source lib.scm::beta\n"
                                 "(define (beta y)\n  (* y 2))\n"
                                 "```\n")
                  "the body is the snippet")
    (check-equal! (read-file t--show-source-lib)
                  ";; lib\n(define (alpha x)\n  (+ x 1))\n\n(define (beta y)\n  (* y 2))\n"
                  "the file is untouched")
    (t--show-source-remove!)
    (t--morg-done!)))

(deftest 'morg-show-source-fills-every-block-and-an-empty-one
  "the command fills all blocks, last first, so earlier fills move nothing"
  (lambda ()
    (t--show-source-make!)
    (t--show-source-doc!
      (string-append "```scheme :show-source lib.scm::beta\n"
                     "```\n\n"
                     "```scheme :show-source lib.scm::2-3\n"
                     "old\n"
                     "```\n"))
    (t--morg-run! "morg-show-source")
    (let ((filled (string-append "```scheme :show-source lib.scm::beta\n"
                                 "(define (beta y)\n  (* y 2))\n"
                                 "```\n\n"
                                 "```scheme :show-source lib.scm::2-3\n"
                                 "(define (alpha x)\n  (+ x 1))\n"
                                 "```\n")))
      (check-equal! (buffer-text t--morg-buf) filled "both bodies are their snippets")
      (t--morg-run! "morg-show-source")
      (check-equal! (buffer-text t--morg-buf) filled "a second fill changes nothing"))
    (t--show-source-remove!)
    (t--morg-done!)))

;;; --- motion -------------------------------------------------------------------
;;; A note is read by jumping. Each motion command answers with the position
;;; it landed on, and leaves point alone when there is nowhere to go.

(define (t--morg-point) (buffer-point t--morg-buf))
(define (t--morg-line)
  (with-current-buffer t--morg-buf (lambda () (line-number-at-pos (point)))))

(deftest 'morg-next-heading-walks-every-heading
  "C-c C-n takes the next heading whatever its depth"
  (lambda ()
    (t--morg! t--morg-fixture 0)
    (t--morg-run! "morg-next-heading")
    (check-equal! (t--morg-point) 9 "the child heading")
    (t--morg-run! "morg-next-heading")
    (check-equal! (t--morg-point) 24 "then the next top heading")
    (t--morg-run! "morg-next-heading")
    (check-equal! (t--morg-point) 24 "and the last heading stays put")
    (t--morg-done!)))

(deftest 'morg-previous-heading-walks-back
  "C-c C-p takes the heading above point"
  (lambda ()
    (t--morg! t--morg-fixture 20)
    (t--morg-run! "morg-previous-heading")
    (check-equal! (t--morg-point) 9 "the heading this body belongs to")
    (t--morg-done!)))

(deftest 'morg-same-level-motion-stays-inside-its-parent
  "a sibling motion gives up at a shallower heading rather than leaving"
  (lambda ()
    (t--morg! t--morg-fixture 0)
    (t--morg-run! "morg-forward-same-level")
    (check-equal! (t--morg-point) 24 "# a to # b, one level")
    (t--morg! t--morg-fixture 9)
    (t--morg-run! "morg-forward-same-level")
    (check-equal! (t--morg-point) 9 "## child has no sibling, so point stays")
    (t--morg-done!)))

(deftest 'morg-link-motion-walks-the-links
  "M-n and M-p take the next and previous markdown link"
  (lambda ()
    (t--morg! "see [one](http://a) and [two](http://b)\n" 0)
    (t--morg-run! "morg-next-link")
    (check-equal! (t--morg-point) 4 "the first link")
    (t--morg-run! "morg-next-link")
    (check-equal! (t--morg-point) 24 "the second")
    (t--morg-run! "morg-previous-link")
    (check-equal! (t--morg-point) 4 "and back again")
    (t--morg-done!)))

(deftest 'morg-landmarks-are-headings-paragraphs-blocks-and-links
  "M-<down> and M-<up> walk the anchors: headings, paragraphs, fences, links"
  (lambda ()
    (t--morg! t--morg-fixture 0)
    (check-equal! (morg--landmarks t--morg-buf) '(0 4 9 18 24 28)
                  "three headings and three paragraphs")
    (t--morg! "para [l](http://a)\n\n```sh\necho hi\n```\n" 0)
    (check-equal! (morg--landmarks t--morg-buf) '(0 5 20)
                  "the paragraph, its link, and the fence")
    (t--morg! "# a\n\ntext\n\n## b\n\n```sh\nx\n```\n\n### c\n" 30)
    (t--morg-run! "morg-previous-landmark")
    (check-equal! (t--morg-point) 17 "M-<up> from the end lands on the fence")
    (t--morg-run! "morg-previous-landmark")
    (check-equal! (t--morg-point) 11 "then on the second-level heading")
    (t--morg-run! "morg-previous-landmark")
    (check-equal! (t--morg-point) 5 "then on the paragraph")
    (t--morg-run! "morg-previous-landmark")
    (check-equal! (t--morg-point) 0 "then on the top heading")
    (t--morg-done!)))

(deftest 'a-landmark-farther-than-a-page-away-is-a-page
  "when no anchor lies within one page, M-<up> and M-<down> page instead"
  (lambda ()
    ;; one paragraph of PAGE+8 lines: its first line is the only anchor
    ;; between the two headings
    (let* ((page (morg--page-lines))
           (n (+ page 8))
           (body (string-join (map (lambda (i) "l") (iota n)) "\n"))
           (text (string-append "# a\n\n" body "\n\n# b\n"))
           (b-pos (string-index text "# b")))
      (t--morg! text b-pos)
      (check-equal! (t--morg-line) (+ 4 n) "the fixture: the heading is the last line")
      (t--morg-run! "morg-previous-landmark")
      (check-equal! (t--morg-line) (- (+ 4 n) page)
                    "the paragraph start is farther than a page: one page up")
      (t--morg-run! "morg-previous-landmark")
      (check-equal! (t--morg-point) 5
                    "from there the paragraph start is near: it lands")
      (t--morg! text 5)
      (t--morg-run! "morg-next-landmark")
      (check-equal! (t--morg-line) (+ 3 page)
                    "downward the heading is a page and more away: one page down")
      (t--morg! text 0)
      (t--morg-run! "morg-next-landmark")
      (check-equal! (t--morg-point) 5 "a near anchor still lands")
      (t--morg-done!))))

;;; --- selection ----------------------------------------------------------------

(deftest 'morg-select-block-takes-the-code-between-the-fences
  "the region is the code itself, so the fences stay out of it"
  (lambda ()
    (t--morg! "# h\n\n```sh\necho hi\n```\n" 15)
    (t--morg-run! "morg-select-block")
    (check-equal! (with-current-buffer t--morg-buf (lambda () (mark))) 11
                  "the mark sits after the open fence")
    (check-equal! (t--morg-point) 19 "and point before the close fence")
    (t--morg-done!)))

(deftest 'morg-select-block-outside-a-block-takes-the-section
  "prose has no fences, so the heading and its body are the unit"
  (lambda ()
    (t--morg! t--morg-fixture 5)
    (t--morg-run! "morg-select-block")
    (check-equal! (with-current-buffer t--morg-buf (lambda () (mark))) 0
                  "the section starts at its heading")
    (check-true! (> (t--morg-point) 5) "and runs past the point that asked")
    (t--morg-done!)))

;;; --- the llm block ------------------------------------------------------------
;;; An llm block is a code block whose interpreter is the model. The seam
;;; answers here, so the test needs no network.

(deftest 'an-llm-block-asks-the-buffers-model-and-writes-the-answer
  "the prompt is the body, and the result block holds the reply"
  (lambda ()
    (let ((seen #f) (saved *morg-babel-llm*))
      (t--morg! "```llm\nwhat is 2 + 2?\n```\n" 8)
      (buffer-set-local! t--morg-buf 'llm-model "test-model")
      (set! *morg-babel-llm*
        (lambda (prompt model k) (set! seen (list prompt model)) (k "four")))
      (t--morg-run! "morg-babel")
      (set! *morg-babel-llm* saved)
      (check-equal! seen '("what is 2 + 2?\n" "test-model")
                    "the body went to the buffer's own model")
      (check-contains! (buffer-text t--morg-buf) "```result\nfour\n```"
                       "the answer")
      (t--morg-done!))))

(deftest 'an-llm-block-shows-that-the-model-is-thinking
  "the result block holds the status until the answer replaces it"
  (lambda ()
    (let ((k #f) (saved *morg-babel-llm*))
      (t--morg! "```llm\nhello?\n```\n" 8)
      (buffer-set-local! t--morg-buf 'llm-model "test-model")
      (set! *morg-babel-llm* (lambda (prompt model cb) (set! k cb)))
      (t--morg-run! "morg-babel")
      (set! *morg-babel-llm* saved)
      (check-contains! (buffer-text t--morg-buf) "thinking: test-model"
                       "the wait names the model")
      (k "the answer")
      (check-contains! (buffer-text t--morg-buf) "```result\nthe answer\n```"
                       "and the answer replaces the status")
      (t--morg-done!))))
