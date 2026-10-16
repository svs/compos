;;; fast-code-test.scm --- prose to one call, and functions learned.
;;;
;;; The command palette and a ! at the chat prompt both arrive here. The model
;;; answers one call, or a function and one call to it; what it writes is
;;; refused unless it reads, names nothing unbound, and holds no value the
;;; request supplied. Nothing here reaches the network.

(domain! 'testing)
(effects! '(read write))

(define t--fast-good
  "(define (zz-fast-filtered! dir text) \"open DIR showing only the entries holding TEXT\" (list-filter-push! (dired-open dir) (list \"match\" text)))\n(zz-fast-filtered! \"~/src\" \".scm\")")

(define (t--fast-with-store! thunk)
  (with-stubs (list (list '*fast-learned-path* "/tmp/zz-fast-learned-test.scm")
                    (list '*fast-learned* '()))
    (lambda ()
      (thunk)
      (for-each (lambda (n) (fast-forget! n)) (fast-learned-names)))))

(deftest 'an-answer-must-read-and-name-nothing-unbound
  "an invented name is refused, not run"
  (lambda ()
    (check-equal! (fast-accept "(delete-other-windows!)") '(ok "(delete-other-windows!)")
                  "a bound call is accepted as written")
    (check-equal! (car (fast-accept "```scheme\n(buffer-list)\n```")) 'ok
                  "a code fence is stripped")
    (check-equal! (car (fast-accept "(frobnicate! 1)")) 'no "an unbound function is refused")
    (check-true! (string-contains? (cadr (fast-accept "(set-buffer-local! \"a\" 'x 1)")) "buffer-set-local!")
                 "and the refusal names the real one near it")
    (check-equal! (car (fast-accept "(run-command \"no-such-command-zz\")")) 'no
                  "a run-command must name a real command")
    (check-true! (string-prefix? "M-x dired stops to ask" (cadr (fast-accept "(run-command \"dired\")")))
                 "a command that asks for its value is refused: the request carries it")
    (check-equal! (car (fast-accept "(let ((b \"x\")) (message b))")) 'ok
                  "a let binding is not an unbound call")
    (check-equal! (car (fast-accept "(message \"a\")\n(message \"b\")")) 'ok
                  "several calls run in order")
    (check-equal! (car (fast-accept "Sure, (message \"a\")")) 'no "prose is refused")
    (check-equal! (fast-accept "(list-filter-push! \"Dired\" (list \"match\" \".md\"))")
                  '(no "no such buffer: Dired")
                  "a BUF slot must name a buffer that exists")
    (check-equal! (car (fast-accept "NONE")) 'no "NONE is a miss")))

(deftest 'a-function-takes-the-requests-values-as-parameters
  "a function written for one request is refused; one for any value is accepted"
  (lambda ()
    (let ((r (fast-accept t--fast-good "dired src with only scheme files")))
      (check-equal! (car r) 'ok "a parameterised function and its call")
      (check-equal! (cadr r) "(zz-fast-filtered! \"~/src\" \".scm\")" "the call is what runs"))
    (check-true! (string-contains?
                   (cadr (fast-accept "(define (zz-md-only! buf) \"show only md\" (list-filter-push! buf (list \"match\" \".md\")))\n(zz-md-only! (fast-this-buffer))" "filter it for md files"))
                   "the body holds \".md\"")
                 "a value the request spelled belongs in a parameter, not the body")
    (check-true! (string-contains?
                   (cadr (fast-accept "(define (zz-open-src-scm! dir text) \"open DIR showing entries holding TEXT\" (list-filter-push! (dired-open dir) (list \"match\" text)))\n(zz-open-src-scm! \"~/src\" \".scm\")" "dired src with scheme files"))
                   "the name holds")
                 "and a name speaks for every value, not this one")
    (check-true! (string-contains?
                   (cadr (fast-accept "(define (list-filter-push! b) \"x\" (message b))\n(list-filter-push! \"a\")"))
                   "already exists")
                 "an existing function is called, never redefined")
    (check-true! (string-contains? (cadr (fast-accept "(define (zz-f x) (message x))\n(zz-f \"a\")")) "docstring")
                 "a function says what it does")))

(deftest 'a-function-is-kept-once-its-call-runs-clean
  "accepted, it is defined; run clean, it is saved as Scheme and joins the catalog"
  (lambda ()
    (t--fast-with-store!
      (lambda ()
        (let* ((r (fast-accept t--fast-good "dired src with only scheme files"))
               (row (fast-block (car (cdr (cdr r))))))
          (set! *fast-pending* (list "zz intent" row))
          (fast-chat-ran! "!zz intent" "(zz)\nerror: boom")
          (check-equal! (fast-learned-names) '() "a run that errs keeps nothing")
          (set! *fast-pending* (list "zz intent" row))
          (fast-chat-ran! "!zz intent" "(zz)\nok")
          (check-equal! (fast-learned-names) '("zz-fast-filtered!") "a clean run keeps the function")
          (check-true! (string-contains? (read-file *fast-learned-path*) "(define (zz-fast-filtered! dir text)")
                       "as Scheme in the learned file")
          (check-equal! (plist-get (catalog-entry "function" "zz-fast-filtered!") 'signature)
                        "(zz-fast-filtered! DIR TEXT)" "with a signature from its parameters")
          (set! *fast-learned* '())
          (check-equal! (fast-learned-load!) 1 "the file reads back")
          (fast-forget! "zz-fast-filtered!")
          (check-equal! (fast-learned-names) '() "and a forgotten one is gone"))))))

(deftest 'a-bang-resolves-to-a-frame-call-or-an-error
  "what the chat runs is well-formed either way"
  (lambda ()
    (let ((src #f))
      (fast-chat-resolve "!one window again" (lambda (s) (set! src s)))
      (check-equal! src "(with-frame-windows (lambda () (delete-other-windows!)))"
                    "a recipe's title runs the recipe, against the frame")
      (check-true! (chat-scheme-well-formed? src) "and it reads"))))

(deftest 'the-palette-hands-a-sentence-to-fast-code
  "three words or more lead with your words; a short query keeps the palette's order"
  (lambda ()
    (let ((base '(("groups" "command") ("group-kill" "command"))))
      (check-equal! (car (car (fast-palette-rows "open the groups list" base))) "open the groups list"
                    "a sentence leads, so RET sends it to fast-code")
      (check-equal! (car (car (fast-palette-rows "groups list" base))) "groups"
                    "a short query keeps the palette's first hit")
      (check-equal! (car (list-ref (fast-palette-rows "groups list" base) 2)) "groups list"
                    "and your words close the list")
      (check-equal! (fast-palette-rows "groups" base) base
                    "words that are already a row are not added twice")
      (check-equal! (fast-palette-rows "  " base) base "nothing typed, nothing added"))))
