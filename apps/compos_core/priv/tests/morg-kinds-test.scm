;;; morg-kinds-test.scm --- the fence-kind registry, by what it answers.
;;;
;;; A kind is one registration: paint, runner, and help. These tests
;;; register throwaway kinds, read the paint through morg-refontify!, and
;;; run blocks through morg-babel-execute — the same doors the editor uses.

(domain! 'testing)
(effects! '(write))

(define t--kinds-buf "zz-fence-kinds.md")

(define (t--kinds! text point)
  (test-buffer! t--kinds-buf text)
  (with-current-buffer t--kinds-buf (lambda () (set-mode! "morg-mode")))
  (when (minor-mode-on? t--kinds-buf "preview-mode")
    (disable-minor-mode! t--kinds-buf "preview-mode"))
  (buffer-goto! t--kinds-buf point)
  t--kinds-buf)

(define (t--kinds-done!)
  (when (buffer-known? t--kinds-buf) (buffer-kill! t--kinds-buf)))

(define (t--kinds-faces)
  (map (lambda (o) (caddr o)) (buffer-overlays t--kinds-buf)))

;;; --- the registry ------------------------------------------------------------

(deftest 'a-kind-is-discoverable-in-the-catalog
  "apropos answers a fence-kind search the way it answers a component search"
  (lambda ()
    (check-true!
      (member "diff"
        (map (lambda (e) (plist-get e 'name))
             (apropos "unified diff" 'kind 'fence-kind)))
      "the diff kind answers an apropos search")))

(deftest 'a-kind-is-one-registration
  "define-fence-kind! stores the doc and the keys, and describe reads them back"
  (lambda ()
    (define-fence-kind! "zz-test-kind" "A throwaway kind."
      'body-face "morg-result" 'runnable #f)
    (let ((d (describe-fence-kind "zz-test-kind")))
      (check-equal! (plist-get d 'doc) "A throwaway kind." "the doc came back")
      (check-equal! (plist-get d 'runs) #f "runnable #f reads as runs #f"))
    (check-equal! (fence-kind-line-face "zz-test-kind" "any line") "morg-result"
                  "body-face answers for every line")))

(deftest 'registration-by-name-replaces
  "a package reload does not stack duplicate kinds"
  (lambda ()
    (define-fence-kind! "zz-twice" "First." 'body-face "morg-result")
    (define-fence-kind! "zz-twice" "Second.")
    (check-equal! (fence-kind-line-face "zz-twice" "x") #f
                  "the second registration replaced the first whole")))

(deftest 'merge-adds-keys-and-keeps-the-rest
  "two packages can own two aspects of one kind"
  (lambda ()
    (define-fence-kind! "zz-merged" "Paint." 'body-face "morg-result")
    (fence-kind-merge! "zz-merged" 'header-face "morg-bold")
    (check-equal! (fence-kind-line-face "zz-merged" "x") "morg-result"
                  "the paint survived the merge")
    (check-equal! (fence-kind-get "zz-merged" 'header-face #f) "morg-bold"
                  "the merged key answers")))

(deftest 'ts-lang-resolves-through-the-registry
  "an alias names its grammar; an unknown info string names its own"
  (lambda ()
    (check-equal! (fence-kind-get "exs" 'ts-lang #f) "elixir"
                  "the runner rows carry their grammar")
    (check-equal! (fence-kind-get "result-scheme" 'ts-lang #f) "scheme"
                  "a result-scheme body names the Scheme grammar")
    ;; resolution gates on the loaded grammars, which the test home does
    ;; not install; assert it only where the grammar is present
    (when (member "elixir" (ts-langs))
      (check-equal! (fence-kind-ts-lang "exs") "elixir"
                    "a loaded grammar resolves through the alias"))
    (check-equal! (fence-kind-ts-lang "diff") #f
                  "the diff kind declines tree-sitter")
    (check-equal! (fence-kind-ts-lang "zz-no-such-grammar") #f
                  "an unknown info string with no grammar paints nothing")))

(deftest 'a-chip-names-the-block-and-says-when-it-runs
  "the preview's fence chip comes from the registry, not a hand-kept list"
  (lambda ()
    (check-equal! (fence-kind-chip "diff") "diff" "a paint kind is its name")
    (check-equal! (fence-kind-chip "sh") "sh · run" "a runner kind offers run")
    (check-equal! (fence-kind-chip "") #f "a bare fence draws no chip")
    (define-fence-kind! "zz-chipped" "Chip test." 'chip "ZZ" 'runnable #f)
    (check-equal! (fence-kind-chip "zz-chipped") "ZZ"
                  "a declared chip overrides the name")))

;;; --- the paint ---------------------------------------------------------------

(deftest 'a-diff-fence-wears-the-diff-faces
  "added, removed, hunk, and file lines each take their face"
  (lambda ()
    (t--kinds! "```diff\n@@ -1 +1 @@\n-old line\n+new line\n context\n```\n" 0)
    (let ((faces (t--kinds-faces)))
      (check-true! (member "diff-hunk" faces) "the @@ line is a hunk")
      (check-true! (member "diff-del" faces) "the - line is a deletion")
      (check-true! (member "diff-add" faces) "the + line is an addition"))
    (t--kinds-done!)))

(deftest 'a-context-diff-line-takes-no-face
  "a plain context line inside a diff fence stays unpainted"
  (lambda ()
    (check-equal! (fence-kind-line-face "diff" " unchanged") #f
                  "a context line has no face")
    (check-equal! (fence-kind-line-face "diff" "+++ b/file") "diff-file"
                  "a file header outranks the + prefix")))

(deftest 'result-kinds-still-paint-as-results
  "the registry answers what the old tables answered"
  (lambda ()
    (t--kinds! "```result\nplain out\n```\n" 0)
    (check-true! (member "morg-result" (t--kinds-faces))
                 "a result body wears morg-result")
    (t--kinds-done!)))

;;; --- running -----------------------------------------------------------------

(deftest 'a-result-kind-refuses-to-run
  "the refusal comes from the registration, not a hard-coded list"
  (lambda ()
    (t--kinds! "```result\nout\n```\n" 10)
    (let ((r (morg-babel-execute t--kinds-buf 10)))
      (check-equal! (car r) 'error "a result block does not run"))
    (t--kinds-done!)))

(deftest 'an-unknown-kind-reports-no-runner
  "an unregistered language is an error, not a silent no-op"
  (lambda ()
    (t--kinds! "```zz-nolang\nbody\n```\n" 14)
    (let ((r (morg-babel-execute t--kinds-buf 14)))
      (check-equal! r (list 'error "No runner for zz-nolang")
                    "an unregistered language still names the gap"))
    (t--kinds-done!)))

(deftest 'a-new-kind-runs-in-one-form
  "one registration gives a fence its runner and its result landing"
  (lambda ()
    (define-fence-kind! "zz-shout" "Uppercases the body."
      'run (lambda (buf scan fstart e lang body)
             (morg-babel-insert-result! buf fstart (string-upcase body))
             (list 'ok lang)))
    (t--kinds! "```zz-shout\nquiet\n```\n" 14)
    (let ((r (morg-babel-execute t--kinds-buf 14)))
      (check-equal! r (list 'ok "zz-shout") "the kind ran"))
    (check-equal! (buffer-text t--kinds-buf)
                  "```zz-shout\nquiet\n```\n```result\nQUIET\n```\n"
                  "the output landed in a result fence below the block")
    (t--kinds-done!)))
