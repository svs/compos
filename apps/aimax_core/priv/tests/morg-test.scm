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
    (t--morg-done!)))

(deftest 'the-markdown-api-reads-the-section-that-holds-a-body-line
  "a body line belongs to the nearest heading above it"
  (lambda ()
    (t--morg-md! "# One\nbody\n## Child\ntext\n# Two\ntail\n")
    (check-equal! (markdown-read t--morg-buf 4) "## Child\ntext\n" "the child section")
    (check-equal! (markdown-read t--morg-buf 1) "# One\nbody\n## Child\ntext\n"
                  "the parent takes its children with it")
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

(define (t--babel-restore!)
  (set! *morg-babel-shell* t--babel-real-shell)
  (set! t--babel-pending #f))

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
    (t--morg! "```scheme\n(+ 1 2)\n```\n" 11)
    (t--morg-run! "morg-babel")
    (check-equal! (buffer-text t--morg-buf) "```scheme\n(+ 1 2)\n```\n```result\n3\n```\n"
                  "the value came back")
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

(deftest 'tangle-writes-marked-blocks-relative-to-the-morg-file
  "one file from two blocks, and a block marked no is skipped"
  (lambda ()
    (let ((dir (string-append (aimax-home) "/zz-morg-tangle")))
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
