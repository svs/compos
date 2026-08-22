;;; apropos-test.scm --- the agent's first question has one good answer.
;;;
;;; "What can I call" was answered by four registries that nothing searched
;;; across, and by a name-only matcher that never read a doc. These hold
;;; the line on the search, on what an entry must carry, and on the
;;; cold-start path — an agent that has just connected and knows nothing.
;;;
;;; Four tests stay in ExUnit. Two read Elixir modules directly
;;; (Builtins.docs, SchemeAPI.docs). Two are red today, on the bundled
;;; backfill and the frozen Luna count, and a red test here would hide the
;;; next real failure.

(domain! 'testing)
(effects! '(read))

(define (t--ap-names entries) (map (lambda (e) (plist-get e 'name)) entries))
(define (t--ap-kinds entries) (map (lambda (e) (plist-get e 'kind)) entries))

(effects! '(write))

;; A test that registers a name must take it out again. This clears the
;; two Scheme registries. The M-x command table is Elixir and has no
;; removal, so a test command name stays until the next restart.
(define (t--ap-forget-catalog! kind name)
  (let ((e (catalog-entry (string->symbol kind) name)))
    (when e
      (set! *catalog-keys*
        (remove (lambda (k)
                  (equal? k (catalog--key kind name (plist-get e 'qualified-name))))
                *catalog-keys*))
      (set! *catalog*
        (remove (lambda (x) (and (equal? (plist-get x 'kind) kind)
                                 (equal? (plist-get x 'name) name)))
                *catalog*))))
  name)

(define (t--ap-forget-public! name)
  (set! *public-api* (remove (lambda (e) (equal? (car e) name)) *public-api*))
  (set! *public-keys* (remove (lambda (k) (equal? k name)) *public-keys*))
  (t--ap-forget-catalog! "function" name))

;;; --- the catalog --------------------------------------------------------------

(deftest 'entries-carry-package-namespace-domain-and-effects
  "one entry answers where a name lives and what calling it costs"
  (lambda ()
    (let ((entry (catalog-entry 'function "buffer-text")))
      (check-equal! (plist-get entry 'package) "editor" "the package")
      (check-equal! (plist-get entry 'namespace) "core" "the namespace")
      (check-equal! (plist-get entry 'domain) "buffers" "the domain")
      (check-equal! (plist-get entry 'effects) '("read") "the effects"))
    (check-equal! (plist-get (catalog-entry 'function "buffer-append!") 'effects)
                  '("write") "a write")
    (check-equal! (plist-get (catalog-entry 'function "buffer-kill!") 'effects)
                  '("destroy") "a destroy")))

(deftest 'load-units-stamp-their-registrations
  "the loader names the package, so no file has to"
  (lambda ()
    (check-equal! (plist-get (catalog-entry 'function "apropos-page") 'package)
                  "help" "a function")
    (check-equal! (plist-get (catalog-entry 'setting "permission-timeout-ms") 'package)
                  "agent" "a setting")))

(deftest 'new-scheme-must-stamp-metadata-instead-of-receiving-a-safe-guess
  "an unstamped declaration reads as unknown, and says so"
  (lambda ()
    (package! 'my-extension 'my-extension)
    (define-command "zz-unstamped" "Reads a harmless value" (lambda () #t))
    (package! 'user 'user)

    (let ((unstamped (catalog-entry 'command "zz-unstamped")))
      (check-equal! (plist-get unstamped 'package) "my-extension" "the package")
      (check-equal! (plist-get unstamped 'origin) "user" "the origin")
      (check-equal! (plist-get unstamped 'domain) "unknown" "the domain")
      (check-equal! (plist-get unstamped 'effects) '("unknown") "the effects")
      (check-equal! (plist-get unstamped 'metadata-source) "unknown" "the source"))

    (domain! 'files)
    (effects! '(destroy external))
    (define-command "zz-stamped" "Delete a remote test file" (lambda () #t))
    (domain! 'unknown)
    (effects! '(unknown))

    (let ((stamped (catalog-entry 'command "zz-stamped")))
      (check-equal! (plist-get stamped 'domain) "files" "the declared domain")
      (check-equal! (plist-get stamped 'effects) '("destroy" "external") "the declared effects")
      (check-equal! (plist-get stamped 'metadata-source) "declared" "declared, not guessed"))

    (t--ap-forget-catalog! "command" "zz-unstamped")
    (t--ap-forget-catalog! "command" "zz-stamped")))

(deftest 'luna-classified-consequential-entries-carry-metadata
  "the backfill names its model and its confidence"
  (lambda ()
    (check-equal! (plist-get (catalog-entry 'function "llm") 'effects)
                  '("read" "external" "execute" "spend") "llm spends")
    (check-equal! (plist-get (catalog-entry 'command "eval-buffer") 'effects)
                  '("write" "execute") "eval-buffer executes")
    (check-equal! (plist-get (catalog-entry 'command "notmuch-trash") 'effects)
                  '("destroy") "notmuch-trash destroys")
    (let ((llm (catalog-entry 'function "llm")))
      (check-equal! (plist-get llm 'metadata-source) "luna" "the source")
      (check-equal! (plist-get llm 'metadata-model) "openai:gpt-5.6-luna" "the model")
      (check-equal! (plist-get llm 'metadata-confidence) 0.98 "the confidence"))))

(deftest 'every-public-entry-carries-a-signature-and-a-category
  "the sig is parsed out of the doc, so the house way needs no extra work"
  (lambda ()
    (check-equal!
      (map car
           (filter (lambda (e) (or (not (nth 2 e)) (equal? (nth 2 e) "") (not (nth 3 e))))
                   (public-api)))
      '() "every entry has both")))

(deftest 'no-entry-is-left-in-the-default-category
  "misc is the category nobody chose"
  (lambda ()
    (check-equal! (map car (filter (lambda (e) (equal? (nth 3 e) 'misc)) (public-api)))
                  '() "no entry is misc")))

(deftest 'a-doc-written-the-house-way-splits-into-signature-and-prose
  "the leading form is the signature, and the rest is the sentence"
  (lambda ()
    (public! 'zz-split "(zz-split A B) — does a thing with A and B" 'testing)
    (let ((entry (public-entry "zz-split")))
      (check-equal! (nth 2 entry) "(zz-split A B)" "the signature")
      (check-equal! (nth 1 entry) "does a thing with A and B" "the prose")
      (check-equal! (nth 3 entry) 'testing "the category"))

    ;; a doc with no leading form still gets a usable signature
    (public! 'zz-plain "Just a description." 'testing)
    (check-equal! (nth 2 (public-entry "zz-plain")) "(zz-plain)" "a doc with no form")

    ;; a nested form is balanced, not cut at the first paren
    (public! 'zz-nest "(zz-nest '((a b) c)) — nested" 'testing)
    (check-equal! (nth 2 (public-entry "zz-nest")) "(zz-nest '((a b) c))" "a nested form")

    (t--ap-forget-public! "zz-split")
    (t--ap-forget-public! "zz-plain")
    (t--ap-forget-public! "zz-nest")))

(deftest 'categories-name-the-shape-of-the-surface
  "an agent asks for an area instead of guessing a name"
  (lambda ()
    (let ((cats (public-categories)))
      (for-each
        (lambda (c) (check-true! (member c cats) (string-append "a " (symbol->string c) " category")))
        '(buffers editing windows commands chat discovery)))
    (check-true! (> (length (apropos-category 'windows)) 0) "and one lists whole")))

;;; --- the search ---------------------------------------------------------------

(deftest 'doc-text-is-searched-not-only-names
  "the phrase is in the doc of a function whose name does not hold it"
  (lambda ()
    (check-true! (member "buffer-list-mru" (t--ap-names (apropos "most recently used")))
                 "the doc answered")))

(deftest 'every-word-must-appear
  "one word that matches nothing answers nothing"
  (lambda ()
    (check-equal! (apropos "buffer zzzznotaword") '() "no hits")))

(deftest 'commands-keys-and-settings-are-all-in-one-answer
  "four registries, one search"
  (lambda ()
    (check-true! (member "command" (t--ap-kinds (apropos "chat"))) "a command")
    (check-true! (member "key" (t--ap-kinds (apropos "find-file"))) "a key")
    (check-true! (member "variable" (t--ap-kinds (apropos "permission timeout"))) "a setting")))

(deftest 'a-near-miss-on-a-name-lands-anyway
  "a typo answers the name it meant, and says why"
  (lambda ()
    (let ((hits (apropos "buffer-tekst")))
      (check-true! (member "buffer-text" (t--ap-names hits)) "the name it meant")
      (check-true! (member "closest name" (map (lambda (e) (plist-get e 'note)) hits))
                   "and the reason"))))

(deftest 'kind-package-namespace-domain-and-effect-filters-compose
  "every filter narrows the same one answer"
  (lambda ()
    (let ((hits (apropos "card" 'kind 'component 'namespace 'ui 'effect 'pure)))
      (check-true! (member "ui/card" (map (lambda (e) (plist-get e 'qualified-name)) hits))
                   "the component")
      (check-false! (member "diff-card" (t--ap-names hits)) "and nothing else named card"))
    (check-true! (member "apropos-page" (t--ap-names (apropos "" 'package 'help 'kind 'function)))
                 "by package and kind")
    (check-true! (> (length (apropos "" 'domain 'windows 'effect 'read)) 0)
                 "by domain and effect")
    (check-true! (member "buffer-kill!" (t--ap-names (apropos "" 'effect 'destroy)))
                 "by effect alone")))

(deftest 'components-use-the-main-catalog-and-expose-a-runnable-contract
  "a component says its props and gives an example, then renders"
  (lambda ()
    (let ((hit (car (apropos-components "bordered container"))))
      (check-equal! (plist-get hit 'kind) "component" "the kind")
      (check-equal! (plist-get hit 'qualified-name) "ui/card" "the qualified name")
      (check-true! (plist-get hit 'props) "the props")
      (check-true! (plist-get hit 'example) "the example")
      (check-equal! (plist-get hit 'effects) '("pure") "the effects"))
    (let ((rendered (component 'ui/badge '(text "ready" class "success"))))
      (check-contains! (plist-get rendered 'class) "c-badge success" "the class")
      (check-equal! (plist-get rendered 'text) "ready" "the text"))))

;;; --- the cold start -----------------------------------------------------------

(deftest 'a-connecting-agent-is-told-what-it-is-holding-and-how-to-look
  "one message names the search, the areas, and the stopping rule"
  (lambda ()
    (let ((hello (hello)))
      ;; who it is talking to, and the one call that answers everything else
      (check-contains! hello "apropos" "the search")
      (check-contains! hello "eval" "the call")
      ;; the categories, so it can ask for an area rather than guess
      (check-contains! hello "buffers" "an area")
      (check-contains! hello "windows" "another area")
      ;; Discovery has a stopping rule: known recipes run directly and an
      ;; unfamiliar operation gets one search, not a synonym loop.
      (check-contains! hello "WORKFLOW — search once, then act" "the workflow")
      (check-contains! hello "do not rediscover them" "the recipes rule")
      (check-contains! hello "Never repeat an equivalent search" "the stopping rule")
      (check-contains! hello "read the affected state back" "the check rule"))))

(deftest 'the-done-when-one-hello-one-apropos-the-right-expression
  "a cold agent wants to split the window and open a file in it"
  (lambda ()
    (check-contains! (hello) "apropos" "hello names the search")
    (check-true! (member "split-window!" (t--ap-names (apropos "split window")))
                 "the split")
    (check-true! (member "visit" (t--ap-names (apropos "open a file")))
                 "the open")
    ;; and the recipe says it in one line, which is cheaper still: the
    ;; whole composition, not three names to assemble
    (let ((recipes (filter (lambda (e) (equal? (plist-get e 'kind) "recipe"))
                           (apropos "open a file in a split"))))
      (check-true! (> (length recipes) 0) "a recipe answers")
      (when (> (length recipes) 0)
        (check-contains! (plist-get (car recipes) 'run) "split-window!" "the split")
        (check-contains! (plist-get (car recipes) 'run) "visit" "the open")))))

(deftest 'the-primer-carries-recipes-so-a-cold-agent-has-working-lines
  "a name to assemble is not as good as a line to run"
  (lambda ()
    (let ((hello (hello)))
      (check-contains! hello "RECIPES" "the section")
      (check-contains! hello "(visit" "a working line"))))

;;; --- internal primitives ------------------------------------------------------
;;; R7's last gap: scope "all" listed names with no docs. The sweep gave
;;; every Elixir primitive a one-line doc; these hold that line.

(deftest 'every-builtin-bound-in-the-session-carries-a-doc
  "the interpreter is the registry of record"
  (lambda ()
    (check-equal!
      (filter (lambda (n)
                (and (string-prefix? "#<builtin"
                       (function-source (symbol-value (string->symbol n))))
                     (not (primitive-doc n))))
              (global-names))
      '() "every builtin has a doc")))

(deftest 'no-doc-names-a-primitive-that-does-not-exist
  "a doc for a name nobody bound is a doc nobody reads"
  (lambda ()
    (check-equal!
      (map car (filter (lambda (p) (not (boundp (string->symbol (car p)))))
                       (primitive-docs)))
      '() "every doc names a live primitive")))
