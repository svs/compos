;;; llm-connectors.scm --- M-x llm-connectors: set up each model connector and test it.
;;;
;;; One row per connector: its kind, what it still needs, and what its last
;;; test said. Moving the point shows the connector's page beside the list:
;;; its command, its install steps, its sign-in, its keys and its last reply.
;;; The same keys work on the list and on the page:
;;;
;;;   i  install the agent program, in a terminal beside the list
;;;   l  sign in: run the connector's own login command in a terminal
;;;   k  add or change the connector's API key
;;;   t  test: a fresh chat on the connector asks for one word, timed
;;;   T  test every connector at once (on the list)
;;;   d  make it the default for new chats
;;;
;;; The needs come from the connectors' own declarations (setup.scm), so a
;;; new connector shows up here with nothing added.

(require 'setup)

(domain! 'setup)
(effects! '(read))

(define *llm-connectors-buffer* "*llm-connectors*")

;; how long a test waits for its reply before it says failed
(defcustom 'llm-connectors-test-seconds 120
  "How many seconds a connector test waits for the reply before it fails."
  'group 'setup 'type 'integer)

;; (NAME PLIST): the last test of each connector. PLIST holds status
;; (testing, ok or failed), reply, error, ms and at.
(define *llm-connectors-tests* '())

;; a test of the connector alone is keyed by its name; a test of one of
;; its models by the name and the model
(define (llm-connectors--test-key name &optional model)
  (if model (string-append name " " model) name))

(define (llm-connectors--result key)
  (let ((e (assoc key *llm-connectors-tests*))) (and e (cadr e))))

(define (llm-connectors-test-result name &optional model)
  "(llm-connectors-test-result NAME [MODEL]) -- the last test of connector NAME, or of its MODEL: status, reply, error, ms, at; or #f"
  (llm-connectors--result (llm-connectors--test-key name model)))

(define (llm-connectors--title name)
  (or (plist-get (connector-config name) 'title) name))

(define (llm-connectors-kind name)
  "(llm-connectors-kind NAME) -- agent, API or browser"
  (let ((backend (plist-get (connector-config name) 'backend)))
    (cond ((equal? backend "chrome-gemini-nano") "browser")
          ((equal? backend "req-llm") "API")
          (else "agent"))))

(define (llm-connectors-state name)
  "(llm-connectors-state NAME) -- what connector NAME needs next: ready, not installed or needs a key"
  (let ((unmet (setup--unmet (setup-connector-requirements name))))
    (cond ((null? unmet) "ready")
          ((equal? (plist-get (car unmet) 'kind) 'program) "not installed")
          (else "needs a key"))))

;; the secret settings connector NAME declares
(define (llm-connectors--secrets name)
  (apply append
         (map (lambda (r) (cond ((plist-get r 'secret) (list (plist-get r 'secret)))
                                ((plist-get r 'secrets) (plist-get r 'secrets))
                                (else '())))
              (filter (lambda (r) (memq (plist-get r 'kind) '(secret one-secret)))
                      (setup-connector-requirements name)))))

(define (llm-connectors--secs ms)
  (let ((tenths (round (/ ms 100))))
    (string-append (number->string (quotient tenths 10)) "."
                   (number->string (remainder tenths 10)) " s")))

;; the end of a reply, where the answer is: an agent may put a notice first
(define (llm-connectors--reply-end text)
  (let* ((s (string-trim (string-replace text "\n" " ")))
         (n (string-length s)))
    (if (> n 80) (string-append "..." (substring s (- n 80) n)) s)))

(define (llm-connectors--result-text r)
  (let ((status (and r (plist-get r 'status))))
    (cond ((not r) "not tested")
          ((eq? status 'testing) "testing...")
          ((eq? status 'ok) (string-append "replied in " (llm-connectors--secs (plist-get r 'ms))))
          (else (string-append "failed: " (or (plist-get r 'error) "no reply"))))))

(define (llm-connectors--test-text name &optional model)
  (llm-connectors--result-text (llm-connectors-test-result name model)))

(define (llm-connectors--result-face r)
  (let ((status (and r (plist-get r 'status))))
    (cond ((not r) "faint") ((eq? status 'ok) "success") ((eq? status 'failed) "error") (else "dim"))))

(define (llm-connectors--test-face name &optional model)
  (llm-connectors--result-face (llm-connectors-test-result name model)))

;; one sentence on the default connector and its last test, for a page that
;; sends the reader here: the setup wizard and the tutorial
(define (llm-connectors-summary)
  "(llm-connectors-summary) -- a sentence: the connector new chats use, and what its last test said"
  (let* ((name *default-connector*)
         (r (llm-connectors-test-result name)))
    (string-append "New chats use " (llm-connectors--title name) ". "
                   (cond ((not r) "It is not tested yet.")
                         ((eq? (plist-get r 'status) 'testing) "Its test is running.")
                         ((eq? (plist-get r 'status) 'ok)
                          (string-append "It " (llm-connectors--test-text name) "."))
                         (else (string-append "Its test " (llm-connectors--test-text name) "."))))))

(define (llm-connectors--default? name) (equal? name *default-connector*))

;;; --- the list ------------------------------------------------------------------

(define (llm-connectors--cells buf name)
  (let ((state (llm-connectors-state name)))
    (list (list (string-append (llm-connectors--title name) (if (llm-connectors--default? name) " (default)" ""))
                "llm-connectors-name")
          (list (llm-connectors-kind name) "dim")
          (list state (if (equal? state "ready") "success" "warning"))
          (list (number->string (length (llm-connectors-models name))) "dim")
          (list (llm-connectors--test-text name) (llm-connectors--test-face name))
          (list (connector-description name) "dim"))))

(define (llm-connectors--meta buf)
  (let ((names (connector-names)))
    (string-append (number->string (length names)) " connectors · "
                   (number->string (length (filter (lambda (n) (equal? (llm-connectors-state n) "ready")) names)))
                   " ready · new chats use " *default-connector*)))

;;; --- the page of one connector -------------------------------------------------

;; a page row is (ID LABEL VALUE)
;; the models connector NAME offers, as (ID LABEL)
(define (llm-connectors-models name)
  "(llm-connectors-models NAME) -- every model connector NAME offers, as (ID LABEL)"
  (or (ignore-errors (lambda () (chat-model-options *llm-connectors-buffer* name))) '()))

;; the model new chats use on connector NAME, or #f for its own default
(define (llm-connectors--default-model name)
  (let ((b (llm-default-bundle-record)))
    (and (equal? (plist-get b 'connector) name) (plist-get b 'model))))

;; a page row: (section TITLE), (fact ID LABEL VALUE) or (model ID LABEL)
(define (llm-connectors--page-rows buf)
  (let* ((name (buffer-local buf 'llm-connector))
         (c (and name (connector-config name)))
         (r (and name (llm-connectors-test-result name)))
         (fact (lambda (id label value) (list 'fact id label value))))
    (if (not name)
        '()
        (append
          (list (list 'section "Connector")
                (fact "about" "about" (connector-description name))
                (fact "kind" "kind" (llm-connectors-kind name))
                (fact "state" "state" (llm-connectors-state name))
                (fact "default" "default"
                      (if (llm-connectors--default? name)
                          (string-append "yes, new chats use it"
                                         (let ((m (llm-connectors--default-model name)))
                                           (if m (string-append " with " m) "")))
                          "no; d makes it the default")))
          (if (plist-get c 'cmd) (list (fact "command" "command" (plist-get c 'cmd))) '())
          (let ((steps (or (plist-get c 'install) '())))
            (if (null? steps)
                '()
                (cons (list 'section "Install")
                      (map (lambda (step)
                             (fact (string-append "install:" (car step)) (car step)
                                   (string-append (if (setup--program-present? (car step)) "present" "missing; i installs it")
                                                  " · " (cadr step))))
                           steps))))
          (let ((ss (llm-connectors--secrets name)))
            (if (and (null? ss) (not (plist-get c 'signin)))
                '()
                (append
                  (list (list 'section "Sign in and keys"))
                  (if (plist-get c 'signin)
                      (list (fact "signin" "sign in" (string-append (plist-get c 'signin) "; l runs it")))
                      '())
                  (map (lambda (s)
                         (fact (string-append "key:" (symbol->string s)) "key"
                               (string-append (setup-secret-label s) ": "
                                              (if (secret-set? s) "set; k changes it" "missing; k adds it"))))
                       ss))))
          (append
            (list (list 'section "Last test")
                  (fact "test" "result" (llm-connectors--test-text name)))
            (if (and r (string? (plist-get r 'reply)) (not (equal? (plist-get r 'reply) "")))
                (list (fact "reply" "reply" (llm-connectors--reply-end (plist-get r 'reply))))
                '())
            (if (and r (plist-get r 'at))
                (list (fact "at" "at" (format-time (plist-get r 'at) "%d %b %H:%M:%S")))
                '()))
          (cons (list 'section "Models")
                (map (lambda (m) (list 'model (car m) (if (and (pair? (cdr m)) (string? (cadr m))) (cadr m) "")))
                     (llm-connectors-models name)))))))

(define (llm-connectors--page-columns buf)
  (list (list "" 18) (list "" #f)))

(define (llm-connectors--row-key r)
  (cond ((eq? (car r) 'model) (string-append "model:" (cadr r)))
        ((eq? (car r) 'section) (string-append "section:" (cadr r)))
        (else (cadr r))))

(define (llm-connectors--page-cells buf r)
  (let ((name (buffer-local buf 'llm-connector)))
    (cond
      ((eq? (car r) 'section) (list (list (cadr r) "list-section-name") ""))
      ((eq? (car r) 'model)
       (let* ((id (cadr r))
              (default? (equal? id (llm-connectors--default-model name))))
         ;; the result first, as a checklist reads: it fits a narrow pane
         (list (list (llm-connectors--test-text name id) (llm-connectors--test-face name id))
               (list (string-append id
                                    ;; a short id is an alias, and its name says which model it is
                                    (if (or (equal? (caddr r) "") (> (string-length id) 12)) ""
                                        (string-append " · " (caddr r)))
                                    (if default? " (default)" ""))
                     (if default? "llm-connectors-name" "default")))))
      (else
       (let ((id (cadr r)) (value (cadddr r)))
         (list (list (caddr r) "dim")
               (cond ((equal? id "state") (list value (if (equal? value "ready") "success" "warning")))
                     ((equal? id "test") (list value (llm-connectors--test-face name)))
                     (else value))))))))

(define (llm-connectors--page-meta buf)
  (let ((name (buffer-local buf 'llm-connector)))
    (if name
        (string-append (llm-connectors-kind name) " · " (llm-connectors-state name)
                       " · " (number->string (length (llm-connectors-models name))) " models"
                       " · " (llm-connectors--test-text name))
        "")))

;;; --- actions -------------------------------------------------------------------

(effects! '(write))

(defface! 'llm-connectors-name 'fg "var(--default-fg)" 'weight "600")

(define (llm-connectors-refresh!)
  "(llm-connectors-refresh!) -- redraw the connector list and every connector page"
  (when (buffer-exists? *llm-connectors-buffer*) (list-refresh! *llm-connectors-buffer*))
  (for-each (lambda (b) (when (buffer-local b 'llm-connector) (list-render! b #t)))
            (mode-group-buffers "llm-connectors-detail-mode")))

(define (llm-connectors--list)
  (if (equal? (buffer-local (current-buffer) 'mode-name) "llm-connectors-mode")
      (current-buffer)
      (or (buffer-local (current-buffer) 'llm-connectors-list) *llm-connectors-buffer*)))

(define (llm-connectors--join! buf)
  (let ((g (buffer-group (llm-connectors--list))))
    (when (and g (not (equal? (buffer-group buf) g))) (buffer-move-to-group! buf g))))

(define (llm-connectors-show-detail! name)
  "(llm-connectors-show-detail! NAME) -- show the page of connector NAME beside the list"
  (when name
    (let* ((list-buf (llm-connectors--list))
           (buf (string-append "*llm-connector:" name "*")))
      (unless (buffer-known? buf) (buffer-create buf))
      (llm-connectors--join! buf)
      (buffer-set-local! buf 'llm-connectors-list list-buf)
      (buffer-set-local! buf 'llm-connector name)
      (if (equal? (list-mode-of buf) "llm-connectors-detail-mode")
          (list-render! buf #t)
          (with-current-buffer buf (lambda () (set-mode! "llm-connectors-detail-mode"))))
      (display-buffer-detail! buf list-buf))))

(define (llm-connectors--on-current fn)
  (let ((name (or (buffer-local (current-buffer) 'llm-connector)
                  (let ((l (llm-connectors--list))) (and (buffer-exists? l) (list-current l))))))
    (if name (fn name) (message "no connector on this line"))))

(define (llm-connectors-make-default! name &optional model)
  "(llm-connectors-make-default! NAME [MODEL]) -- new chats use connector NAME, on MODEL when it is given"
  (setup-use-connector! name model))

;; the model of the row at point on a connector page, or #f
(define (llm-connectors--model-at-point)
  (let ((r (and (buffer-local (current-buffer) 'llm-connector) (list-current (current-buffer)))))
    (and (pair? r) (eq? (car r) 'model) (cadr r))))

;; a terminal beside the list that runs SCRIPT, then stays as a login shell
(define (llm-connectors--terminal! buf script)
  (when (buffer-known? buf) (buffer-kill! buf))
  (buffer-create buf)
  (llm-connectors--join! buf)
  (buffer-set-local! buf 'mode-name "term-mode")
  (buffer-set-local! buf 'terminal-command script)
  (with-current-buffer buf (lambda () (terminal-mode-init! buf)))
  ;; a restore must not run the script again
  (buffer-set-local! buf 'terminal-command #f)
  (display-buffer-other-window! buf)
  buf)

(effects! '(write execute external))

(define (llm-connectors-install! name)
  "(llm-connectors-install! NAME) -- install the agent program of connector NAME in a terminal beside the list"
  (let ((buf (setup-install-agent! name display-buffer-other-window!)))
    (cond (buf (llm-connectors--join! buf)
               (message (string-append name ": installing; t tests it when the terminal is done")))
          ((null? (or (plist-get (connector-config name) 'install) '()))
           (message (string-append name " declares no install steps"))))))

(define (llm-connectors-sign-in! name)
  "(llm-connectors-sign-in! NAME) -- run the login command of connector NAME in a terminal beside the list"
  (let ((signin (plist-get (connector-config name) 'signin)))
    (if (not signin)
        (message (string-append name " has no sign-in; k adds its key"))
        (begin
          (llm-connectors--terminal!
            (string-append "*llm-connector-signin:" name "*")
            (string-append signin
                           "; printf '\\nWhen you are signed in, press t on " name " to test it.\\n'"
                           "; exec \"${SHELL:-/bin/sh}\" -l"))
          (message (string-append name ": sign in in the terminal, then press t to test"))))))

(define (llm-connectors-add-key! name)
  "(llm-connectors-add-key! NAME) -- ask for the API key connector NAME declares"
  (if (null? (llm-connectors--secrets name))
      (message (string-append name " takes no key"
                              (if (plist-get (connector-config name) 'signin) "; l signs in" "")))
      (setup-wizard-add-key! #f name llm-connectors-refresh!)))

(effects! '(write external spend))

(define (llm-connectors--set-test! key result)
  (set! *llm-connectors-tests*
        (cons (list key result)
              (filter (lambda (e) (not (equal? (car e) key))) *llm-connectors-tests*))))

(define (llm-connectors--finish! key token result k)
  ;; a late reply after the deadline, or a test started again, changes nothing
  (let ((now (llm-connectors--result key)))
    (when (and now (eq? (plist-get now 'status) 'testing) (equal? (plist-get now 'token) token))
      (llm-connectors--set-test! key result)
      (llm-connectors-refresh!)
      ;; the pages that show a test, the wizard's and the tutorial's, draw it
      (run-hooks 'llm-connectors-tested-hook)
      (message (string-append key ": " (llm-connectors--result-text result)))
      (when k (k result)))))

(define (llm-connectors-test! name &optional k model)
  "(llm-connectors-test! NAME [K] [MODEL]) -- a fresh chat on connector NAME, on MODEL when it is given, asks for one word; the reply and its time go on the row, and K gets the result plist"
  (let* ((t0 (monotonic-ms))
         (token t0)
         (key (llm-connectors--test-key name model))
         (elapsed (lambda () (- (monotonic-ms) t0)))
         (fail (lambda (why) (list 'status 'failed 'error why 'ms (elapsed) 'at (current-time)))))
    (llm-connectors--set-test! key (list 'status 'testing 'token token 'at (current-time)))
    (llm-connectors-refresh!)
    (let ((slug (ignore-errors
                  (lambda ()
                    (execute* "This is a connection test. Reply with the one word: ready."
                              (append (list 'connector name
                                            'title (string-append "Connector test: " key)
                                            'notify #f)
                                      (if model (list 'model model) '())))))))
      (if (not slug)
          (llm-connectors--finish! key token (fail "the chat did not start") k)
          (begin
            (debounce! (string->symbol (string-append "llm-connectors-deadline:" key))
                       (* 1000 llm-connectors-test-seconds)
                       (lambda (_)
                         (llm-connectors--finish! key token
                           (fail (string-append "no reply in " (number->string llm-connectors-test-seconds) " s")) k))
                       #f)
            (subagent-wait (list slug)
              (lambda (results)
                (let* ((r (and (pair? results) (car results)))
                       (text (and r (plist-get r 'text)))
                       (said (and (string? text) (not (equal? (string-trim text) "")) (string-trim text)))
                       (reason (and r (plist-get r 'stop-reason))))
                  (when (and r (buffer-known? (plist-get r 'buffer)))
                    (buffer-kill! (plist-get r 'buffer)))
                  (llm-connectors--finish! key token
                    (if said
                        (list 'status 'ok 'reply said 'ms (elapsed) 'at (current-time))
                        (fail (if reason (format "~a" reason) "no reply")))
                    k)))))))))

(define (llm-connectors-test-all!)
  "(llm-connectors-test-all!) -- test every connector that is ready, at once"
  (let ((ready (filter (lambda (n) (equal? (llm-connectors-state n) "ready")) (connector-names))))
    (for-each (lambda (n) (llm-connectors-test! n)) ready)
    (message (string-append "testing " (number->string (length ready)) " connectors"))))

;;; --- commands ------------------------------------------------------------------

(effects! '(write))

(define-command "llm-connectors-show" "Show the page of the connector on this line beside the list"
  (lambda () (llm-connectors--on-current llm-connectors-show-detail!)))

(define-command "llm-connectors-refresh" "Check every connector again and redraw"
  (lambda () (llm-connectors-refresh!) (message "connectors checked again")))

(define-command "llm-connectors-make-default" "Make the model on this line, or else the connector, the one new chats use"
  (lambda ()
    (let ((model (llm-connectors--model-at-point)))
      (llm-connectors--on-current (lambda (name) (llm-connectors-make-default! name model))))))

(effects! '(write execute external))

(define-command "llm-connectors-install" "Install the agent program of the connector on this line"
  (lambda () (llm-connectors--on-current llm-connectors-install!)))

(define-command "llm-connectors-sign-in" "Sign in to the connector on this line in a terminal"
  (lambda () (llm-connectors--on-current llm-connectors-sign-in!)))

(define-command "llm-connectors-add-key" "Add or change the API key of the connector on this line"
  (lambda () (llm-connectors--on-current llm-connectors-add-key!)))

(effects! '(write external spend))

(define-command "llm-connectors-test" "Test the model on this line, or else the connector, and time the reply"
  (lambda ()
    (let ((model (llm-connectors--model-at-point)))
      (llm-connectors--on-current (lambda (name) (llm-connectors-test! name #f model))))))

(define-command "llm-connectors-test-all" "Test every ready connector at once"
  (lambda () (llm-connectors-test-all!)))

;;; --- modes ---------------------------------------------------------------------

(effects! '(write))

(define *llm-connectors-keys*
  '(("i" "llm-connectors-install") ("l" "llm-connectors-sign-in")
    ("k" "llm-connectors-add-key") ("t" "llm-connectors-test")
    ("d" "llm-connectors-make-default") ("g" "llm-connectors-refresh")
    ("q" "quit-window")))

(define-list-mode! "llm-connectors-mode"
  (list
    'doc (string-append
           "The model connectors: their kind (an agent program, a direct API, or the browser), "
           "what each still needs, and what its last test said. Moving the point shows the "
           "connector's page beside the list. i installs the agent program, l signs in, "
           "k adds or changes the API key, t sends a test message and times the reply, "
           "T tests every ready connector at once, d makes the connector the default for "
           "new chats. RET shows the page, g checks again, / narrows, q quits.")
    'buffer *llm-connectors-buffer*
    'transient #f
    'rows (lambda (buf) (connector-names))
    'key (lambda (buf name) name)
    'preview (lambda (buf name) (llm-connectors-show-detail! name))
    'columns (lambda (buf)
               (list (list "connector" 30) (list "kind" 8) (list "needs" 14)
                     (list "models" 7) (list "last test" 28) (list "about" #f)))
    'cells (lambda (buf name) (llm-connectors--cells buf name))
    ;; narrow: the test result matters more than the description
    'layouts (list (list 'name 'narrow 'max-cols (lambda (buf) 120)
                         'columns (lambda (buf)
                                    (list (list "connector" 30) (list "kind" 8)
                                          (list "needs" 14) (list "models" 7) (list "last test" #f)))
                         'cells (lambda (buf name)
                                  (let ((cs (llm-connectors--cells buf name)))
                                    (list (nth 0 cs) (nth 1 cs) (nth 2 cs) (nth 3 cs) (nth 4 cs)))))
                   (list 'name 'wide 'default #t))
    'title (lambda (buf) "LLM connectors")
    'meta (lambda (buf) (llm-connectors--meta buf))
    'noun "connector"
    'no-marks #t
    'local-filter #t
    'footer (lambda (buf)
              '(("RET" "page") ("i" "install") ("l" "sign in") ("k" "key")
                ("t" "test") ("T" "test all") ("d" "default") ("g" "check") ("q" "quit")))
    'keys (append '(("RET" "llm-connectors-show") ("T" "llm-connectors-test-all"))
                  *llm-connectors-keys*)))

(define-list-mode! "llm-connectors-detail-mode"
  (list
    'doc (string-append
           "One model connector: what it needs (its command, the install steps, the sign-in and "
           "the keys), its last test, and under Models every model it offers, each with its own "
           "last test. On a model, t tests that model and d makes it the model new chats use; "
           "elsewhere they act on the connector. i installs, l signs in, k adds the key, "
           "/ narrows, g checks again, q quits.")
    'transient #f
    'rows (lambda (buf) (llm-connectors--page-rows buf))
    'key (lambda (buf r) (llm-connectors--row-key r))
    'separator? (lambda (buf r) (eq? (car r) 'section))
    'section? (lambda (buf r) (eq? (car r) 'section))
    'columns (lambda (buf) (llm-connectors--page-columns buf))
    'cells (lambda (buf r) (llm-connectors--page-cells buf r))
    'title (lambda (buf) (llm-connectors--title (or (buffer-local buf 'llm-connector) "")))
    'meta (lambda (buf) (llm-connectors--page-meta buf))
    'noun "model"
    'no-marks #t
    'local-filter #t
    'footer (lambda (buf)
              '(("t" "test") ("d" "default") ("i" "install") ("l" "sign in") ("k" "key")
                ("/" "filter") ("g" "check") ("q" "quit")))
    'keys *llm-connectors-keys*))

(add-hook! 'setup-connector-chosen-hook 'llm-connectors-refresh!)

(define-command "llm-connectors" "Set up each model connector and test its connection"
  (lambda ()
    (let ((buf (list-mode-show! "llm-connectors-mode")))
      (with-current-buffer buf (lambda () (llm-connectors-show-detail! (list-current buf))))
      buf)))

(effects! '(read))
(public! 'llm-connectors-state "(llm-connectors-state NAME) -- what connector NAME needs next: ready, not installed or needs a key")
(public! 'llm-connectors-summary "(llm-connectors-summary) -- a sentence: the connector new chats use, and what its last test said")
(public! 'llm-connectors-kind "(llm-connectors-kind NAME) -- agent, API or browser")
(public! 'llm-connectors-test-result "(llm-connectors-test-result NAME [MODEL]) -- the last test of connector NAME, or of its MODEL: status, reply, error, ms, at; or #f")
(effects! '(write external spend))
(public! 'llm-connectors-test! "(llm-connectors-test! NAME [K] [MODEL]) -- test connector NAME, or its MODEL, with a fresh chat; the reply and its time go on its row, K gets the result plist")
(public! 'llm-connectors-models "(llm-connectors-models NAME) -- every model connector NAME offers, as (ID LABEL)")
(effects! '(write execute external))
(public! 'llm-connectors-install! "(llm-connectors-install! NAME) -- install the agent program of connector NAME in a terminal")
(public! 'llm-connectors-sign-in! "(llm-connectors-sign-in! NAME) -- run the login command of connector NAME in a terminal")
