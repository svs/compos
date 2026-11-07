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
(define llm-connectors--tests-file (string-append (compos-home) "/llm-connector-tests.scm"))

;; the tests kept from before, so a restart keeps each row's last result
(define (llm-connectors--load-tests)
  (let* ((src (and (file-exists? llm-connectors--tests-file) (read-file llm-connectors--tests-file)))
         (forms (and (string? src) (scheme-read src))))
    (if (and (pair? forms) (list? (car forms))) (car forms) '())))

(define *llm-connectors-tests* (llm-connectors--load-tests))

;;; A row of the list is a connector's name, or api:PROVIDER for one hosted
;;; provider of the api connector: OpenRouter, Anthropic, OpenAI, DeepSeek.
;;; A provider row is the api connector on that provider's models and key.

(define (llm-connectors--provider row)
  (and (string? row) (string-prefix? "api:" row) (substring row 4 (string-length row))))

(define (llm-connectors--connector row)
  (if (llm-connectors--provider row) "api" row))

;; the key setting of PROVIDER, or #f
(define (llm-connectors--provider-secret p)
  (find (lambda (s) (equal? (secret-prop s 'provider) p))
        (filter secret-setting? (setup--provider-secrets))))

;; the provider of a model id of the api connector: its prefix, else the
;; family its name says
(define (llm-connectors--model-provider id)
  (let ((parts (string-split id ":")))
    (cond ((pair? (cdr parts)) (car parts))
          ((string-prefix? "claude" id) "anthropic")
          ((or (string-prefix? "gpt" id) (string-prefix? "o1" id) (string-prefix? "o3" id) (string-prefix? "o4" id)) "openai")
          ((string-prefix? "deepseek" id) "deepseek")
          (else #f))))

(define (llm-connectors-providers)
  "(llm-connectors-providers) -- the hosted providers of the api connector: those with a key setting, and those whose models it lists"
  (let ((seen (append (filter string? (map (lambda (s) (secret-prop s 'provider)) (filter secret-setting? (setup--provider-secrets))))
                      (filter string? (map (lambda (m) (llm-connectors--model-provider (car m)))
                                           (llm-connectors--connector-models "api")))
                      (if (boundp 'llm-endpoints) (llm-endpoints) '()))))
    (reverse (fold (lambda (acc p) (if (member p acc) acc (cons p acc))) '() seen))))

;; the model a provider row tests: the one its key names, else its first
(define (llm-connectors--provider-model p)
  (let ((s (llm-connectors--provider-secret p))
        (ms (llm-connectors-models (string-append "api:" p))))
    (or (and s (secret-prop s 'model))
        (and (pair? ms) (car (car ms))))))

;; a test is keyed by the connector and the model it ran on; a provider
;; row's own test is the test of its model
(define (llm-connectors--test-key row &optional model)
  (let* ((p (llm-connectors--provider row))
         (m (or model (and p (llm-connectors--provider-model p)))))
    (if m (string-append (llm-connectors--connector row) " " m) (llm-connectors--connector row))))

(define (llm-connectors--result key)
  (let ((e (assoc key *llm-connectors-tests*))) (and e (cadr e))))

(define (llm-connectors-test-result name &optional model)
  "(llm-connectors-test-result NAME [MODEL]) -- the last test of connector NAME, or of its MODEL: status, reply, error, ms, at; or #f"
  (llm-connectors--result (llm-connectors--test-key name model)))

(define (llm-connectors--title name)
  (let ((p (llm-connectors--provider name)))
    (if p
        (let ((s (llm-connectors--provider-secret p)))
          (cond (s (car (string-split (setup-secret-label s) ":")))
                ((equal? p "deepseek") "DeepSeek")
                (else (string-append (string-upcase (substring p 0 1)) (substring p 1 (string-length p))))))
        (or (plist-get (connector-config name) 'title) name))))

(define (llm-connectors--about name)
  (let ((p (llm-connectors--provider name)))
    (if p
        (let ((s (llm-connectors--provider-secret p)))
          (string-append "hosted API" (if s (string-append " · " (setup-secret-label s)) "")))
        (connector-description name))))

(define (llm-connectors-kind name)
  "(llm-connectors-kind NAME) -- agent, API or browser"
  (let ((backend (plist-get (connector-config (llm-connectors--connector name)) 'backend)))
    (cond ((equal? backend "chrome-gemini-nano") "browser")
          ((equal? backend "req-llm") "API")
          (else "agent"))))

(define (llm-connectors-state name)
  "(llm-connectors-state NAME) -- what connector NAME, or provider row api:P, needs next: ready, not installed or needs a key"
  (let ((p (llm-connectors--provider name))
        (unmet (setup--unmet (setup-connector-requirements (llm-connectors--connector name)))))
    (cond (p (let ((s (llm-connectors--provider-secret p)))
               (if (if s (secret-set? s) (pair? (llm-connectors-models name))) "ready" "needs a key")))
          ((null? unmet) "ready")
          ((equal? (plist-get (car unmet) 'kind) 'program) "not installed")
          (else "needs a key"))))

;; the secret settings connector NAME declares; a provider row has its own
(define (llm-connectors--secrets name)
  (let ((p (llm-connectors--provider name)))
    (if p
        (let ((s (llm-connectors--provider-secret p))) (if s (list s) '()))
        (llm-connectors--connector-secrets name))))

(define (llm-connectors--connector-secrets name)
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

;; the result as a short word, for a column: ok and its time, or failed
(define (llm-connectors--result-short r)
  (let ((status (and r (plist-get r 'status))))
    (cond ((not r) "not tested")
          ((eq? status 'testing) "testing...")
          ((eq? status 'ok) (string-append "ok " (llm-connectors--secs (plist-get r 'ms))))
          (else "failed"))))

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

(define (llm-connectors--default? name)
  (and (equal? (llm-connectors--connector name) *default-connector*)
       (or (not (llm-connectors--provider name)) (llm-connectors--default-model name))
       #t))

;; the list: the agents, the hosted providers, then the browser, each under
;; its heading. A heading row is (section TITLE).
(define (llm-connectors-rows)
  "(llm-connectors-rows) -- the rows of the list: connector names and api:PROVIDER rows, under (section TITLE) headings"
  (let* ((names (connector-names))
         (of (lambda (kind) (filter (lambda (n) (equal? (llm-connectors-kind n) kind)) names)))
         (group (lambda (title rows) (if (null? rows) '() (cons (list 'section title) rows)))))
    (append (group "Agents (ACP)" (of "agent"))
            (group "Hosted APIs" (map (lambda (p) (string-append "api:" p)) (llm-connectors-providers)))
            (group "In the browser" (of "browser")))))

(define (llm-connectors--section? row) (and (pair? row) (eq? (car row) 'section)))

;;; --- the list ------------------------------------------------------------------

(define (llm-connectors--cells buf name)
  (if (llm-connectors--section? name)
      (list (list (cadr name) "list-section-name") "" "" "" "" "")
      (llm-connectors--row-cells buf name)))

(define (llm-connectors--row-cells buf name)
  (let ((state (llm-connectors-state name)))
    (list (list (string-append (llm-connectors--title name) (if (llm-connectors--default? name) " (default)" ""))
                "llm-connectors-name")
          (list (llm-connectors-kind name) "dim")
          (list state (if (equal? state "ready") "success" "warning"))
          (list (number->string (length (llm-connectors-models name))) "dim")
          (list (llm-connectors--test-text name) (llm-connectors--test-face name))
          (list (llm-connectors--about name) "dim"))))

(define (llm-connectors--meta buf)
  (let ((names (filter string? (llm-connectors-rows))))
    (string-append (number->string (length names)) " connectors and providers · "
                   (number->string (length (filter (lambda (n) (equal? (llm-connectors-state n) "ready")) names)))
                   " ready · new chats use " *default-connector*)))

;;; --- the page of one connector -------------------------------------------------

;; the models connector NAME offers, as (ID LABEL)
(define (llm-connectors--connector-models name)
  (or (ignore-errors (lambda () (chat-model-options *llm-connectors-buffer* name))) '()))

(define (llm-connectors-models name)
  "(llm-connectors-models NAME) -- every model connector NAME, or provider row api:P, offers, as (ID LABEL)"
  (let ((p (llm-connectors--provider name)))
    (if p
        (append
          (filter (lambda (m) (equal? (llm-connectors--model-provider (car m)) p))
                  (llm-connectors--connector-models "api"))
          ;; an endpoint of the user's own serves the models it was added with
          (map (lambda (id) (list (string-append p ":" id) ""))
               (if (boundp 'llm-endpoint-models) (llm-endpoint-models p) '())))
        (llm-connectors--connector-models name))))

;; the model new chats use on row NAME, or #f for its own default
(define (llm-connectors--default-model name)
  (let* ((b (llm-default-bundle-record))
         (m (and (equal? (plist-get b 'connector) (llm-connectors--connector name)) (plist-get b 'model)))
         (p (llm-connectors--provider name)))
    (if (and p m) (and (equal? (llm-connectors--model-provider m) p) m) m)))

;; a page row: (section TITLE), (fact ID LABEL VALUE) or (model ID LABEL)
(define (llm-connectors--page-rows buf)
  (let* ((name (buffer-local buf 'llm-connector))
         (c (and name (connector-config (llm-connectors--connector name))))
         (r (and name (llm-connectors-test-result name)))
         (fact (lambda (id label value) (list 'fact id label value))))
    (if (not name)
        '()
        (append
          (list (list 'section "Connector")
                (fact "about" "about" (llm-connectors--about name))
                (fact "kind" "kind" (llm-connectors-kind name))
                (fact "state" "state" (llm-connectors-state name))
                (fact "default" "default"
                      (if (llm-connectors--default? name)
                          (string-append "yes, new chats use it"
                                         (let ((m (llm-connectors--default-model name)))
                                           (if m (string-append " with " m) "")))
                          "no; d makes it the default")))
          (if (plist-get c 'cmd) (list (fact "command" "command" (plist-get c 'cmd))) '())
          (let ((pv (llm-connectors--provider name)))
            (if pv
                (append
                  (if (llm-base-url pv)
                      (list (fact "address" "address"
                                  (string-append (llm-base-url pv)
                                                 (let ((sh (llm-provider-shape pv)))
                                                   (if sh (string-append " · speaks " sh) "")))))
                      '())
                  (list (fact "model" "test model"
                            (string-append (or (llm-connectors--provider-model pv) "none") "; t tests it"))))
                '()))
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
                               (string-append (let ((l (setup-secret-label s))) (if (string-suffix? "." l) (substring l 0 (- (string-length l) 1)) l)) ": "
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
         (list (list (llm-connectors--result-short (llm-connectors-test-result name id))
                     (llm-connectors--test-face name id))
               (list (string-append id
                                    (let ((t (llm-connectors-test-result name id)))
                                      (if (and t (eq? (plist-get t 'status) 'failed))
                                          (string-append " · " (or (plist-get t 'error) "no reply"))
                                          ""))
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
  ;; list-refresh! reads the rows again; list-render! would draw the old ones
  (for-each (lambda (b) (when (buffer-local b 'llm-connector) (list-refresh! b)))
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
    (if (string? name) (fn name) (message "no connector on this line"))))

(define (llm-connectors-make-default! name &optional model)
  "(llm-connectors-make-default! NAME [MODEL]) -- new chats use connector NAME, on MODEL when it is given; a provider row api:P uses the api connector on its model"
  (let ((pv (llm-connectors--provider name)))
    (setup-use-connector! (llm-connectors--connector name)
                          (or model (and pv (llm-connectors--provider-model pv))))))

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
  (let ((buf (and (not (llm-connectors--provider name))
                  (setup-install-agent! name display-buffer-other-window!))))
    (cond (buf (llm-connectors--join! buf)
               (message (string-append name ": installing; t tests it when the terminal is done")))
          ((null? (or (plist-get (connector-config (llm-connectors--connector name)) 'install) '()))
           (message (string-append name " declares no install steps"))))))

(define (llm-connectors-sign-in! name)
  "(llm-connectors-sign-in! NAME) -- run the login command of connector NAME in a terminal beside the list"
  (let ((signin (plist-get (connector-config (llm-connectors--connector name)) 'signin)))
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
                              (if (plist-get (connector-config (llm-connectors--connector name)) 'signin) "; l signs in" "")))
      (if (llm-connectors--provider name)
          (setup-ask-secret! (car (llm-connectors--secrets name)) "api" llm-connectors-refresh!)
          (setup-wizard-add-key! #f name llm-connectors-refresh!))))

;; An endpoint of your own: (NAME URL SHAPE (MODEL ...)). URL #f is a
;; provider the model catalog knows (groq, mistral, ...), at its own address.
(defcustom 'llm-connectors-endpoints '()
  "The endpoints you added with a in M-x llm-connectors, as (NAME URL SHAPE (MODEL ...)). URL #f is a provider the model catalog knows, at its own address; else a server that speaks SHAPE, usually openai."
  'group 'llm 'type 'sexp)

(define (llm-connectors--endpoint name)
  (assoc name llm-connectors-endpoints))

;; the endpoint's address, its shape and its key setting; the row comes from the key setting
(define (llm-connectors--declare-endpoint! e)
  (let ((name (nth 0 e)) (url (nth 1 e)) (shape (nth 2 e)) (models (nth 3 e)))
    (when url (register-llm-endpoint! name url models shape))
    (unless (llm-connectors--provider-secret name)
      (defcustom (string->symbol (string-append name "-api-key")) #f
        (if url (string-append name ": your own server at " url ".")
            (string-append name ": its API key."))
        'type 'secret 'group 'llm 'provider name
        'env (string-upcase (string-append (string-replace name "-" "_") "_API_KEY"))
        'model (and (pair? models) (string-append name ":" (car models)))))))

(define (llm-connectors--save-endpoint! e)
  (customize-save! 'llm-connectors-endpoints
                   (append (filter (lambda (x) (not (equal? (car x) (car e)))) llm-connectors-endpoints)
                           (list e)))
  (llm-connectors--declare-endpoint! e))

;; the model ids an OpenAI-shaped server lists at URL/models; K gets them, or ()
(define (llm-connectors--fetch-models name url k)
  (let ((key (llm-key name)))
    (http-get (string-append (if (string-suffix? "/" url) (substring url 0 (- (string-length url) 1)) url) "/models")
              (if key (list 'headers (list 'authorization (string-append "Bearer " key))) '())
              (lambda (r)
                (let* ((j (or (plist-get r 'json) (json-parse (or (plist-get r 'body) ""))))
                       (data (and (pair? j) (plist-get j 'data))))
                  (k (if (list? data)
                         (filter string? (map (lambda (m) (and (pair? m) (plist-get m 'id))) data))
                         '())))))))

;; after the key: an own server with no models named lists its own, then the row is tested
(define (llm-connectors--endpoint-ready! name)
  (let* ((e (llm-connectors--endpoint name))
         (url (and e (nth 1 e)))
         (test (lambda () (llm-connectors-refresh!) (llm-connectors-test! (string-append "api:" name)))))
    (if (and url (null? (nth 3 e)))
        (llm-connectors--fetch-models name url
          (lambda (ids)
            (if (null? ids)
                (begin (message (string-append name ": the server listed no models; a on its row again names them"))
                       (llm-connectors-refresh!))
                (begin
                  ;; the row tests its first model when its key names none
                  (llm-connectors--save-endpoint! (list name url (nth 2 e) ids))
                  (test)))))
        (test))))

(define (llm-connectors-add-endpoint! name url &optional models shape)
  "(llm-connectors-add-endpoint! NAME URL [MODELS] [SHAPE]) -- add endpoint NAME: a server at URL that speaks SHAPE (default openai), or with URL #f a provider the catalog knows; save it, ask for its key, then test it"
  (let ((e (list name (and url (not (equal? (string-trim url) "")) (string-trim url))
                 (or shape "openai") (or models '()))))
    (llm-connectors--save-endpoint! e)
    (llm-connectors-refresh!)
    (let ((s (llm-connectors--provider-secret name)))
      (if s
          (setup-ask-secret! s "api" (lambda () (llm-connectors--endpoint-ready! name)))
          (llm-connectors--endpoint-ready! name)))))

(define (llm-connectors-add-endpoint-ask!)
  (read-string "Endpoint name (a provider such as groq, or a name of your own): "
    (lambda (name)
      (let ((name (string-downcase (string-trim (or name "")))))
        (if (or (equal? name "") (string-contains? name ":"))
            (message "Endpoint: give a name without a colon")
            (read-string (string-append "Address of " name " (empty for a known provider; e.g. http://localhost:8000/v1): ")
              (lambda (url)
                (let ((url (string-trim (or url ""))))
                  (if (equal? url "")
                      (llm-connectors-add-endpoint! name #f)
                      (read-string "Model ids it serves, separated by spaces (empty asks the server): "
                        (lambda (ids)
                          (llm-connectors-add-endpoint! name url
                            (filter (lambda (s) (not (equal? s ""))) (string-split (or ids "") " "))))))))))))))

(for-each llm-connectors--declare-endpoint! llm-connectors-endpoints)


(effects! '(write external spend))

(define (llm-connectors--set-test! key result)
  (set! *llm-connectors-tests*
        (cons (list key result)
              (filter (lambda (e) (not (equal? (car e) key))) *llm-connectors-tests*)))
  ;; a running test is not kept: after a restart it would never finish
  (unless (eq? (plist-get result 'status) 'testing)
    (write-file! llm-connectors--tests-file
                 (value->string (filter (lambda (e) (not (eq? (plist-get (cadr e) 'status) 'testing)))
                                        *llm-connectors-tests*)))))

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

;; the error a test chat shows, as (SUMMARY FULL), or #f. The chat writes
;; it as [error: ...]; the summary is its first sentence.
(define (llm-connectors--chat-error text)
  (let ((parts (string-split text "[error: ")))
    (and (pair? (cdr parts))
         (let* ((full (string-trim (car (string-split (car (reverse parts)) "]\n"))))
                (line (car (string-split full "\n")))
                (line (if (string-prefix? "session/prompt: " line) (substring line 16 (string-length line)) line))
                (summary (car (string-split line ". "))))
           (list summary full)))))

(define (llm-connectors-test! name &optional k model)
  "(llm-connectors-test! NAME [K] [MODEL]) -- a fresh chat on connector NAME, on MODEL when it is given, asks for one word; the reply and its time go on the row, and K gets the result plist"
  (let* ((t0 (monotonic-ms))
         (token t0)
         (key (llm-connectors--test-key name model))
         (pv (llm-connectors--provider name))
         (model (or model (and pv (llm-connectors--provider-model pv))))
         (connector (llm-connectors--connector name))
         (elapsed (lambda () (- (monotonic-ms) t0)))
         (fail (lambda (why) (list 'status 'failed 'error why 'ms (elapsed) 'at (current-time)))))
    (llm-connectors--set-test! key (list 'status 'testing 'token token 'at (current-time)))
    (llm-connectors-refresh!)
    (let ((slug (ignore-errors
                  (lambda ()
                    (execute* "This is a connection test. Reply with the one word: ready."
                              (append (list 'connector connector
                                            'title (string-append "Connector test: " key)
                                            'notify #f)
                                      (if model (list 'model model) '())))))))
      (if (not slug)
          (llm-connectors--finish! key token (fail "the chat did not start") k)
          (begin
            (debounce! (string->symbol (string-append "llm-connectors-deadline:" key))
                       (* 1000 llm-connectors-test-seconds)
                       (lambda (_)
                         ;; the chat may already show an error; read it, then close the chat
                         (let* ((buf (ignore-errors (lambda () (plist-get (subagent-result slug) 'buffer))))
                                (err (and buf (buffer-known? buf) (llm-connectors--chat-error (buffer-text buf))))
                                (late (fail (string-append "no reply in " (number->string llm-connectors-test-seconds) " s"))))
                           (when (and buf (buffer-known? buf)) (buffer-kill! buf))
                           (llm-connectors--finish! key token
                             (if err (append (fail (car err)) (list 'detail (cadr err))) late) k)))
                       #f)
            (subagent-wait (list slug)
              (lambda (results)
                (let* ((r (and (pair? results) (car results)))
                       (text (and r (plist-get r 'text)))
                       (said (and (string? text) (not (equal? (string-trim text) "")) (string-trim text)))
                       (reason (and r (plist-get r 'stop-reason))))
                  ;; the chat says what went wrong; read it before it goes
                  (let ((err (and r (buffer-known? (plist-get r 'buffer))
                                  (llm-connectors--chat-error (buffer-text (plist-get r 'buffer))))))
                    (when (and r (buffer-known? (plist-get r 'buffer)))
                      (buffer-kill! (plist-get r 'buffer)))
                    (llm-connectors--finish! key token
                      (cond ((and said (not err))
                             (list 'status 'ok 'reply said 'ms (elapsed) 'at (current-time)))
                            (err (append (fail (car err)) (list 'detail (cadr err))))
                            (else (fail (if reason (format "~a" reason) "no reply"))))
                      k))))))))))

(define (llm-connectors-test-all!)
  "(llm-connectors-test-all!) -- test every connector that is ready, at once"
  (let ((ready (filter (lambda (n) (equal? (llm-connectors-state n) "ready")) (filter string? (llm-connectors-rows)))))
    (for-each (lambda (n) (llm-connectors-test! n)) ready)
    (message (string-append "testing " (number->string (length ready)) " connectors"))))

(effects! '(write display))

;; the whole result of one test, in its own buffer beside the page
(define (llm-connectors-show-test! name &optional model)
  "(llm-connectors-show-test! NAME [MODEL]) -- show the whole last test of connector NAME, or of its MODEL, in the other window"
  (let* ((key (llm-connectors--test-key name model))
         (r (llm-connectors--result key))
         (buf (string-append "*llm-connector-test:" key "*")))
    (if (not r)
        (message (string-append key " is not tested yet; t tests it"))
        (begin
          (unless (buffer-known? buf) (buffer-create buf))
          (llm-connectors--join! buf)
          (buffer-set-read-only! buf #f)
          (buffer-set-text! buf
            (string-append "Test of " key "\n\n"
                           "result  " (llm-connectors--result-text r) "\n"
                           (if (plist-get r 'at) (string-append "at      " (format-time (plist-get r 'at) "%d %b %H:%M:%S") "\n") "")
                           (if (plist-get r 'ms) (string-append "time    " (llm-connectors--secs (plist-get r 'ms)) "\n") "")
                           (if (plist-get r 'reply) (string-append "\nReply\n\n" (plist-get r 'reply) "\n") "")
                           (if (plist-get r 'detail) (string-append "\nError\n\n" (plist-get r 'detail) "\n") "")
                           "\nt on the row tests it again.\n")
            #t)
          (buffer-set-read-only! buf #t)
          (with-current-buffer buf (lambda () (unless (equal? (buffer-local buf 'mode-name) "help-mode") (set-mode! "help-mode"))))
          (display-buffer-other-window! buf)
          buf))))

;;; --- commands ------------------------------------------------------------------

(effects! '(write))

(define-command "llm-connectors-show-test" "Show the whole last test of the model on this line, or else the connector"
  (lambda ()
    (let ((model (llm-connectors--model-at-point)))
      (llm-connectors--on-current (lambda (name) (llm-connectors-show-test! name model))))))

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

(define-command "llm-connectors-add-endpoint" "Add a hosted provider or a server of your own, give its key, and test it"
  (lambda () (llm-connectors-add-endpoint-ask!)))

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
           "new chats. a adds a hosted provider or a server of your own, asks for its key and tests it. RET shows the page, g checks again, / narrows, q quits.")
    'buffer *llm-connectors-buffer*
    'transient #f
    'rows (lambda (buf) (llm-connectors-rows))
    'key (lambda (buf name) (if (llm-connectors--section? name) (string-append "section:" (cadr name)) name))
    'preview (lambda (buf name) (when (string? name) (llm-connectors-show-detail! name)))
    'separator? (lambda (buf r) (llm-connectors--section? r))
    'section? (lambda (buf r) (llm-connectors--section? r))
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
                ("t" "test") ("T" "test all") ("d" "default") ("a" "add endpoint") ("g" "check") ("q" "quit")))
    'keys (append '(("RET" "llm-connectors-show") ("T" "llm-connectors-test-all") ("a" "llm-connectors-add-endpoint"))
                  *llm-connectors-keys*)))

(define-list-mode! "llm-connectors-detail-mode"
  (list
    'doc (string-append
           "One model connector: what it needs (its command, the install steps, the sign-in and "
           "the keys), its last test, and under Models every model it offers, each with its own "
           "last test. On a model, t tests that model and d makes it the model new chats use; "
           "elsewhere they act on the connector. RET shows the whole last test, with the error a failed test gave, in the other window. i installs, l signs in, k adds the key, "
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
              '(("RET" "result") ("t" "test") ("d" "default") ("i" "install") ("l" "sign in") ("k" "key")
                ("/" "filter") ("g" "check") ("q" "quit")))
    'keys (cons '("RET" "llm-connectors-show-test") *llm-connectors-keys*)))

(add-hook! 'setup-connector-chosen-hook 'llm-connectors-refresh!)

(define-command "llm-connectors" "Set up each model connector and test its connection"
  (lambda ()
    (let ((buf (list-mode-show! "llm-connectors-mode")))
      (with-current-buffer buf (lambda () (let ((r (list-current buf))) (when (string? r) (llm-connectors-show-detail! r)))))
      buf)))

(effects! '(read))
(public! 'llm-connectors-state "(llm-connectors-state NAME) -- what connector NAME needs next: ready, not installed or needs a key")
(public! 'llm-connectors-summary "(llm-connectors-summary) -- a sentence: the connector new chats use, and what its last test said")
(public! 'llm-connectors-providers "(llm-connectors-providers) -- the hosted providers of the api connector")
(public! 'llm-connectors-rows "(llm-connectors-rows) -- the rows of the list: connector names and api:PROVIDER rows, under (section TITLE) headings")
(public! 'llm-connectors-kind "(llm-connectors-kind NAME) -- agent, API or browser")
(public! 'llm-connectors-test-result "(llm-connectors-test-result NAME [MODEL]) -- the last test of connector NAME, or of its MODEL: status, reply, error, ms, at; or #f")
(effects! '(write external spend))
(public! 'llm-connectors-test! "(llm-connectors-test! NAME [K] [MODEL]) -- test connector NAME, or its MODEL, with a fresh chat; the reply and its time go on its row, K gets the result plist")
(public! 'llm-connectors-models "(llm-connectors-models NAME) -- every model connector NAME offers, as (ID LABEL)")
(effects! '(write execute external))
(public! 'llm-connectors-install! "(llm-connectors-install! NAME) -- install the agent program of connector NAME in a terminal")
(public! 'llm-connectors-add-endpoint! "(llm-connectors-add-endpoint! NAME URL [MODELS] [SHAPE]) -- add endpoint NAME, a server at URL or with URL #f a provider the catalog knows; save it, ask its key, test it")
(public! 'llm-connectors-sign-in! "(llm-connectors-sign-in! NAME) -- run the login command of connector NAME in a terminal")
