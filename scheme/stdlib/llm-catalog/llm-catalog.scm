;;; llm-catalog.scm --- the model catalog: what every provider offers.
;;;
;;; Two sources, one place. The published catalog (llm_db, loaded by
;;; Elixir) gives each model its price, context limit and controls; only a
;;; person refreshes it. Each provider's own list (OpenRouter today) names
;;; what shipped after that snapshot; it is cached here and refreshes behind
;;; the model picker once a day. And every connector reports the models its
;;; agent runs (connector-models in agent-connectors.scm).
;;;
;;; M-x llm-catalog-refresh refreshes all three. M-x llm-catalog-status says
;;; what is loaded and how old it is.

(domain! 'llm)
(effects! '(write external))

;;; --- each provider's own list ---------------------------------------------
;;; LLMDB ships a snapshot of what each provider offers, and a snapshot
;;; ages: the day a provider ships a model, nothing in the picker can name
;;; it. So ask the provider. OpenRouter publishes its whole catalog with no
;;; key, and it is the provider with the most to miss: hundreds of models,
;;; new ones most weeks. The answer is cached in compos-cache-dir, so the list
;;; survives a restart and no menu ever waits on the network.

(define llm-catalog-file (string-append (compos-cache-dir) "/model-catalog.scm"))

;; PROVIDER -> ((ID NAME) ...), as the provider itself reports it
(define *llm-catalog* '())
;; when a provider last answered, and when one was last asked. The first
;; is cached with the catalog; the second only holds off a retry storm
;; while the network is down, so it starts fresh every session.
(define *llm-catalog-fetched* 0)
(define *llm-catalog-tried* 0)
(define llm-catalog-provider-max-age 86400)
(define llm-catalog-retry-after 300)

(define *llm-catalog-sources*
  '(("openrouter" "https://openrouter.ai/api/v1/models")))

(define (llm-catalog-models)
  (fold (lambda (acc entry)
          (append acc
            (map (lambda (m) (string-append (car entry) ":" (car m)))
                 (cadr entry))))
        '() *llm-catalog*))

;; A provider answers {"data": [{"id": ..., "name": ...}, ...]}. An id with
;; a colon in it is a billing variant (":batch", ":free"), and one that
;; begins with ~ is the provider's alias marker: neither is a model you
;; would choose by name, and a colon would break "provider:model" routing.
(define (llm-catalog-parse text)
  (let* ((doc (and text (not (equal? (string-trim text) "")) (json-parse text)))
         (data (plist-get doc 'data)))
    (if (not (pair? data))
        '()
        (fold (lambda (acc m)
                (let ((id (plist-get m 'id)))
                  (if (and (string? id)
                           (not (string-contains? id ":"))
                           (not (string-prefix? "~" id)))
                      (append acc (list (list id (or (plist-get m 'name) ""))))
                      acc)))
              '() data))))

(define (llm-catalog-put! provider models)
  (set! *llm-catalog* (alist-put *llm-catalog* provider models)))

(define (llm-catalog-save!)
  (write-file! llm-catalog-file
    (string-append "(set! *llm-catalog* '" (value->string *llm-catalog*) ")\n"
                   "(set! *llm-catalog-fetched* "
                   (number->string *llm-catalog-fetched*) ")\n")))

;; K hears how many models the provider named, or #f when it said nothing.
(define (llm-catalog-fetch! provider url k)
  (shell-command->string
    (string-append "curl -s --max-time 20 '" url "'")
    (lambda (out)
      (let ((models (llm-catalog-parse out)))
        (if (null? models)
            (k #f)
            (begin
              (llm-catalog-put! provider models)
              (set! *llm-catalog-fetched* (current-time))
              (llm-catalog-save!)
              (k (length models))))))))

(define (llm-provider-models-refresh! k)
  "Ask each provider in *llm-catalog-sources* for its model list. K gets N, or #f."
  (for-each (lambda (src) (llm-catalog-fetch! (car src) (cadr src) k))
            *llm-catalog-sources*))

;; Opening the model picker on a day-old catalog refreshes it behind the
;; picker: this list is what it knows now, and the next one is longer.
(define (llm-catalog-maybe-refresh!)
  (when (and (> (- (current-time) *llm-catalog-fetched*) llm-catalog-max-age)
             (> (- (current-time) *llm-catalog-tried*) llm-catalog-retry-after))
    (set! *llm-catalog-tried* (current-time))
    (llm-provider-models-refresh!
      (lambda (n)
        (when n (message (string-append "model catalog: "
                                        (number->string n) " models")))))))

;; every connector reports its own list (chat-mode.scm); K hears each one
(define (llm-catalog--ask-connectors!)
  (for-each
    (lambda (name)
      (llm-models-probe! name
        (lambda (connector n)
          (message (string-append connector ": "
                     (if n (string-append (number->string n) " models")
                         "no answer"))))))
    (llm-models-probe-connectors)))

(effects! '(read))

;; Every model the direct lane can be asked for: the favorites first, then
;; one of everything the snapshot and the providers know. sort is a
;; builtin, so uniqueness over ~800 ids costs n log n rather than the n^2 a
;; member-scan would cost, and the rest read in provider order because the
;; id starts with the provider.
(define (llm-models-unique lst)
  (let loop ((xs (sort lst)) (acc '()))
    (cond ((null? xs) (reverse acc))
          ((and (pair? acc) (equal? (car xs) (car acc))) (loop (cdr xs) acc))
          (else (loop (cdr xs) (cons (car xs) acc))))))

(define (llm-catalogued-models)
  (append *llm-models*
    (remove (lambda (m) (member m *llm-models*))
            (llm-models-unique (append (llm-available-models)
                                       (llm-catalog-models))))))

(define (llm-catalog--providers-describe)
  (if (= *llm-catalog-fetched* 0)
      "no provider list fetched yet"
      (string-append
        (number->string (length (llm-catalog-models)))
        " from the providers' own lists, fetched "
        (number->string (quotient (- (current-time) *llm-catalog-fetched*) 86400))
        " days ago")))

;;; --- the published catalog ------------------------------------------------
;;; llm_db packages a catalog inside deps/. It ages from the day the lock was
;;; written, and a model it does not carry has no price, no context limit and
;;; no capabilities: the ledger then records a cost of #f. A published
;;; snapshot is rebuilt every day. This keeps a copy outside the build, where
;;; a dependency update cannot remove it.

(domain! 'llm)
(effects! '(read))

(defcustom 'llm-catalog-max-age-days 7
  "Refresh the model catalog when the loaded snapshot is older than this many days."
  'group 'llm 'type 'number)

(define (llm-catalog-age)
  "The age of the loaded catalog in days, or #f when nothing records it."
  (plist-get (llm-catalog-info) 'stale-days))

;; the policy alone, so a test can state it without a catalog on disk. An
;; age of #f is the catalog packaged with the build: nothing records when it
;; was captured, so it counts as stale.
(define (llm-catalog-stale-age? age)
  (or (not age) (> age llm-catalog-max-age-days)))

(define (llm-catalog-stale?)
  "#t when the catalog is older than llm-catalog-max-age-days, or unrecorded."
  (llm-catalog-stale-age? (llm-catalog-age)))

(define (llm-catalog--describe info)
  (string-append
    (number->string (or (plist-get info 'models) 0)) " models from "
    (number->string (or (plist-get info 'providers) 0)) " providers, captured "
    (or (plist-get info 'captured-at) "at an unrecorded time")))

(domain! 'llm)
(effects! '(write external))

(define (llm-catalog-refresh! k)
  "Fetch the newest published catalog and load it. K gets (ok MESSAGE)."
  (message "fetching the model catalog…")
  ;; the lane hands a callback one value: here the list (OK INFO-OR-MESSAGE)
  (llm-catalog-install!
    (lambda (result)
      (let* ((ok (car result))
             (info (cadr result))
             (text (if ok
                       (string-append "catalog: " (llm-catalog--describe info))
                       (string-append "catalog refresh failed: " info))))
        (message text)
        (when k (k ok text))))))

(define-command "llm-catalog-refresh" "Refresh every model list: the published catalog, each provider's own, and each connector's"
  (lambda ()
    (llm-catalog-refresh! #f)
    (llm-provider-models-refresh!
      (lambda (n)
        (message (if n
                     (string-append "provider lists: " (number->string n) " models")
                     "provider lists: no answer"))))
    (llm-catalog--ask-connectors!))
  'public #t)

(effects! '(read))

(define-command "llm-catalog-status" "Say what the loaded model catalog is and how old it is"
  (lambda ()
    (let* ((info (llm-catalog-info))
           (age (plist-get info 'stale-days)))
      (message
        (string-append
          (llm-catalog--describe info)
          (if age
              (string-append " (" (number->string age) " days old)")
              " (age unrecorded: the catalog packaged with the build)")
          "; " (llm-catalog--providers-describe)))))
  'public #t)

;; No timer refreshes the published catalog. A fetch is several megabytes
;; over the GitHub API, which rate-limits an unauthenticated caller, and a
;; background fetch nobody asked for is not worth that. The provider lists
;; are small, so the model picker refreshes them (llm-catalog-maybe-refresh!).

(public! 'llm-catalog-stale?
  "(llm-catalog-stale?) — #t when the loaded model catalog is older than llm-catalog-max-age-days")
(public! 'llm-catalog-age
  "(llm-catalog-age) — the age of the loaded model catalog in days, or #f")
(public! 'llm-catalogued-models
  "(llm-catalogued-models) — every model id the direct lane can be asked for: favorites first, then the catalog and the providers' lists")
(effects! '(write external))
(public! 'llm-catalog-refresh!
  "(llm-catalog-refresh! K) — fetch the newest model catalog and load it; K gets (ok MESSAGE)")
(public! 'llm-provider-models-refresh!
  "(llm-provider-models-refresh! K) — ask each provider for its own model list; K gets N, or #f")

;; the lists the providers last reported, so a fresh session offers the
;; long list before anything is fetched
(when (file-exists? llm-catalog-file) (load llm-catalog-file))
