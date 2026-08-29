;;; apropos-test.scm --- the agent's first question has one good answer.
;;;
;;; "What can I call" was answered by four registries that nothing searched
;;; across, and by a name-only matcher that never read a doc. These hold
;;; the line on the search, on what an entry must carry, and on the
;;; cold-start path — an agent that has just connected and knows nothing.
;;;
;;; Two tests stay in ExUnit. Both read Elixir registration maps
;;; directly (Builtins.docs, SchemeAPI.docs), which have no Scheme surface.

(domain! 'testing)
(effects! '(read))

(define (t--ap-names entries) (map (lambda (e) (plist-get e 'name)) entries))
(define (t--ap-kinds entries) (map (lambda (e) (plist-get e 'kind)) entries))

;; This plain definition becomes a live global when this file loads. It does
;; not become public until a declaration registers it below.
(define (zz-progressive-catalog-global) #t)

(effects! '(write))

(define (t--ap-forget-public! name)
  (set! *public-api* (remove (lambda (e) (equal? (car e) name)) *public-api*))
  (set! *public-keys* (remove (lambda (k) (equal? k name)) *public-keys*))
  (test-forget-catalog! "function" name))

;;; --- the catalog --------------------------------------------------------------

(deftest 'read-file-option-controls-line-numbers
  "read-file returns raw text unless the caller requests stable line numbers"
  (lambda ()
    (let ((path "/tmp/aimax-read-file-option-test.txt"))
      (write-file! path "alpha\nbeta\n")
      (let* ((raw (read-file path))
             (numbered (read-file path #t)))
        (check-equal! raw "alpha\nbeta\n" "the default is raw text")
        (check-true! (string-prefix? "1\talpha" numbered) "true adds line numbers")
        (check-equal! (read-file-numbered path) numbered "the numbered helper delegates")
        (check-equal! (nth 2 (public-entry "read-file"))
                      "(read-file PATH [LINE-NUMBERS])"
                      "the public signature shows the optional argument"))
      (delete-file! path))))

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
    ;; the loader reads the file, so a declaration that moves house takes
    ;; its new package with it: this one lives in agent-permissions.scm
    (check-equal! (plist-get (catalog-entry 'setting "permission-timeout-ms") 'package)
                  "agent-permissions" "a setting")))

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

    (test-forget-catalog! "command" "zz-unstamped")
    (test-forget-catalog! "command" "zz-stamped")))

(deftest 'consequential-entries-declare-their-effects
  "the entries that spend, execute or destroy say so in their own source"
  (lambda ()
    (check-equal! (plist-get (catalog-entry 'function "llm") 'effects)
                  '("read" "external" "execute" "spend") "llm spends")
    (check-equal! (plist-get (catalog-entry 'command "eval-buffer") 'effects)
                  '("write" "execute") "eval-buffer executes")
    (check-equal! (plist-get (catalog-entry 'command "notmuch-trash") 'effects)
                  '("destroy") "notmuch-trash destroys")
    (check-equal! (plist-get (catalog-entry 'function "llm") 'metadata-source)
                  "declared" "declared in the source, never guessed")))

(deftest 'an-entry-declares-its-metadata-or-admits-it-does-not-know
  "the catalog has two answers; a guessed third one reaches the permission policy"
  (lambda ()
    (check-equal!
      (map (lambda (e) (plist-get e 'qualified-name))
           (filter (lambda (e)
                     (not (member (plist-get e 'metadata-source)
                                  '("declared" "unknown"))))
                   (catalog)))
      '() "every entry says declared or unknown")))

(deftest 'lexical-apropos-answers-from-the-catalog-alone
  "the semantic pass spends money, so a caller can ask for the catalog only"
  (lambda ()
    (let ((lexical (apropos "window" 'lexical #t)))
      (check-true! (pair? lexical) "the literal catalog still answers")
      (check-equal!
        (filter (lambda (h) (equal? (plist-get h 'note) "semantic match"))
                lexical)
        '() "and no hit came from the embedding service")
      ;; the flag is not a catalog field: it must not filter the hits away
      (check-true!
        (pair? (filter (lambda (h) (equal? (plist-get h 'kind) "function"))
                       lexical))
        "the functions are still there"))))

(deftest 'unstamped-bundled-declarations-do-not-multiply
  "an unstamped entry asks before it acts, which is correct and is also a debt"
  (lambda ()
    ;; A new declaration stamps itself. Lower this number, never raise it.
    (check-equal!
      (length (filter (lambda (e)
                        (and (equal? (plist-get e 'origin) "bundled")
                             (equal? (plist-get e 'metadata-source) "unknown")))
                      (catalog)))
      499 "the unstamped bundled entries")))

(deftest 'no-entry-carries-the-same-key-twice
  "one entry, one answer per key: a duplicate hides from plist-get and not from a walker"
  (lambda ()
    (let ((keys (lambda (pl)
                  (let loop ((xs pl) (ks '()))
                    (if (or (null? xs) (null? (cdr xs)))
                        (reverse ks)
                        (loop (cdr (cdr xs)) (cons (car xs) ks)))))))
      (check-equal!
        (map (lambda (e) (plist-get e 'qualified-name))
             (filter (lambda (e)
                       (let ((ks (keys e)))
                         (let dup ((xs ks))
                           (cond ((null? xs) #f)
                                 ((member (car xs) (cdr xs)) #t)
                                 (else (dup (cdr xs)))))))
                     (catalog)))
        '() "every entry has distinct keys"))))

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

(deftest 'apropos-keeps-its-public-call-shape
  "semantic search changes ranking, not the Scheme API"
  (lambda ()
    (check-equal! (nth 2 (public-entry "apropos"))
                  "(apropos QUERY &rest FILTERS)"
                  "the public signature is unchanged")))

(deftest 'doc-text-is-searched-not-only-names
  "the phrase is in the doc of a function whose name does not hold it"
  (lambda ()
    (check-true! (member "buffer-list-mru" (t--ap-names (apropos "most recently used")))
                 "the doc answered")))

(deftest 'semantic-results-join-the-catalog-and-keep-filters
  "embedding scores become labeled catalog hits and keep strict filters"
  (lambda ()
    (check-equal! (plist-get (catalog-entry 'function "apropos") 'effects)
                  '("read" "external" "spend") "the search declares its API cost")
    (let* ((rows (apropos--rows-cached))
           (sources (apropos--semantic-sources rows))
           (hit (filter (lambda (h) (equal? (plist-get h 'name) "buffer-kill!")) sources)))
      (check-true! (pair? hit) "the source holds buffer-kill!")
      (when (pair? hit)
        (let* ((semantic (append (car hit) (list 'note "semantic match" 'semantic-score 0.91)))
               (destroy (filter (lambda (h) (apropos--filter-match? h (list 'effect 'destroy)))
                                (list semantic))))
          (check-equal! (plist-get semantic 'note) "semantic match" "the label")
          (check-equal! (plist-get semantic 'semantic-score) 0.91 "the score")
          (check-true! (member "buffer-kill!" (t--ap-names destroy))
                       "the effect filter keeps the destructive hit"))))))

(deftest 'semantic-search-embeds-the-users-task-without-an-instruction-prefix
  "the query vector represents the task, because catalog vectors already describe editor APIs"
  (lambda ()
    (let ((old-search *apropos--embedding-search*)
          (old-key llm-key)
          (seen #f))
      (set! *apropos--embedding-search*
        (lambda (query texts key limit eligible)
          (set! seen query)
          '()))
      (set! llm-key (lambda (provider) "test-key"))
      (apropos--semantic-hits "read csv file" (apropos--rows-cached) '())
      (set! *apropos--embedding-search* old-search)
      (set! llm-key old-key)
      (check-equal! seen "read csv file"
                    "the embedding receives only the user's task"))))

(deftest 'embedding-rebuild-explains-a-missing-key
  "a manual rebuild clears the cache and reports why it cannot refill"
  (lambda ()
    (let ((old-key llm-key))
      (set! llm-key (lambda (provider) #f))
      (let ((result (apropos-rebuild-embeddings!)))
        (set! llm-key old-key)
        (check-contains! result "no OpenAI key" "the result explains the empty cache")))))

(deftest 'literal-results-rank-before-semantic-results
  "a direct vocabulary match stays ahead of a vector result"
  (lambda ()
    (let* ((literal (list 'kind "function" 'name "buffer-kill!"))
           (semantic (list 'kind "function" 'name "other" 'note "semantic match"
                           'semantic-score 0.95))
           (hits (apropos--rank (list semantic literal) "kill buffer")))
      (check-equal! (plist-get (car hits) 'name) "buffer-kill!"
                    "the literal hit is first"))))

(deftest 'semantic-ranking-weights-the-name-above-the-description
  "a task word in the API name beats the same word in prose"
  (lambda ()
    (let* ((named (list 'kind "function" 'name "read-csv-file"
                        'doc "load tabular data" 'semantic-score 0.40
                        'note "semantic match"))
           (described (list 'kind "function" 'name "other-operation"
                            'doc "read csv file" 'semantic-score 0.55
                            'note "semantic match"))
           (ranked (apropos--rank (list described named) "read csv file")))
      (check-equal! (plist-get (car ranked) 'name) "read-csv-file"
                    "the title match receives the larger field weight"))))

(deftest 'literal-ranking-weights-the-name-above-the-description
  "literal hits use the same field order as semantic hits"
  (lambda ()
    (let* ((named (list 'kind "function" 'name "read-csv-file"
                        'doc "load tabular data"))
           (described (list 'kind "function" 'name "other-operation"
                            'doc "read csv file"))
           (ranked (apropos--rank (list described named) "read csv file")))
      (check-equal! (plist-get (car ranked) 'name) "read-csv-file"
                    "the title match ranks first"))))

(deftest 'punctuation-and-filler-words-do-not-block-intent
  "natural phrasing and compound words keep their meaningful terms"
  (lambda ()
    (check-true! (member "split-window!" (t--ap-names (apropos "how do I split a window")))
                 "filler words do not block the splitter")))

(deftest 'responsive-list-layouts-are-publicly-discoverable
  "an agent creating a list finds the profile syntax before writing width branches"
  (lambda ()
    (let ((hits (apropos "responsive list layout")))
      (check-true! (member "define-list-mode!" (t--ap-names hits))
                   "the list constructor explains responsive profiles"))))

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

(deftest 'scope-all-asks-the-agent-to-catalog-a-useful-private-global
  "a loaded plain define is live, and discovery identifies its declaration debt"
  (lambda ()
    (let ((uncatalogued
            (llm-tool-call "apropos"
              (list 'query "zz-progressive-catalog-global" 'scope "all"))))
      (check-contains! uncatalogued "zz-progressive-catalog-global"
                       "the loaded definition is discoverable")
      (check-contains! uncatalogued "catalog-status \"uncatalogued\""
                       "the result identifies the missing declaration")
      (check-contains! uncatalogued "add a durable declaration"
                       "the result asks the agent to fix the source"))

    (domain! 'testing)
    (effects! '(pure))
    (public! 'zz-progressive-catalog-global
      "(zz-progressive-catalog-global) — return true for catalog registration tests"
      'testing)
    (domain! 'unknown)
    (effects! '(unknown))

    (let ((catalogued
            (llm-tool-call "apropos"
              (list 'query "zz-progressive-catalog-global" 'scope "all"))))
      (check-equal!
        (plist-get (catalog-entry 'function "zz-progressive-catalog-global")
                   'metadata-source)
        "declared" "the declaration registers during the same session")
      (check-false! (string-contains? catalogued "catalog-status \"uncatalogued\"")
                    "the discovery debt clears immediately"))
    (t--ap-forget-public! "zz-progressive-catalog-global")))

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


(deftest 'apropos-results-hide-ranking-metadata
  "ranking details stay private after apropos orders the hits"
  (lambda ()
    (let ((hit (apropos--public-hit
                 '(kind "function" name "read-csv"
                   note "semantic match" semantic-score 0.91))))
      (check-false! (plist-get hit 'note) "the note is not result data")
      (check-false! (plist-get hit 'semantic-score) "the score is not result data")
      (check-equal! (plist-get hit 'name) "read-csv" "public fields stay"))
    (let ((duplicate
            (apropos--public-hit
              '(kind "function" name "read-csv"
                sig "(read-csv PATH)" use "(read-csv PATH)")))
          (example
            (apropos--public-hit
              '(kind "function" name "read-csv"
                sig "(read-csv PATH)" use "(read-csv \"orders.csv\")"))))
      (check-false! (plist-get duplicate 'use) "an identical use is omitted")
      (check-equal! (plist-get example 'use) "(read-csv \"orders.csv\")"
                    "a distinct example stays"))))
