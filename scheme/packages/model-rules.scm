;;; model-rules.scm --- the model catalog's policy, as pure rules.
;;;
;;; The catalog itself is Elixir's (LLMDB): it fetches, caches and installs
;;; snapshots. What a raw catalog entry MEANS is editor policy, and it lives
;;; here: which reasoning controls a model has, which live-backend effort
;;; list to offer, and how old a snapshot is. Each rule reads the raw entry
;;; as JSON text, because the catalog is JSON on the wire and one encoding
;;; keeps atom keys and string keys from reading apart.

(domain! 'chat)
(effects! '(pure))

;;; --- reading the raw entry ---------------------------------------------------

;; a JSON object is a flat plist; an absent key and an empty object both read
;; as #f, and plist-get errors on the empty list, so every read guards here.
(define (model--get m k)
  (if (pair? m) (plist-get m k) #f))

;; a catalog value as text: a string stands, an atom is its name (models.dev
;; spells a few knobs as words), and anything else names nothing.
(define (model--string v)
  (cond ((string? v) v)
        ((symbol? v) (symbol->string v))
        (else #f)))

(define (model--strings vs)
  (if (list? vs)
      (apply append
             (map (lambda (v)
                    (let ((s (model--string v)))
                      (if s (list s) '())))
                  vs))
      '()))

;;; --- reasoning controls ------------------------------------------------------

;; The typed shape is preferred; the older models.dev reasoning_options list
;; is the fallback until the snapshot is fully curated.
(define (model--typed-effort reasoning)
  (let* ((effort (model--get reasoning 'effort))
         (values (if (pair? effort)
                     (model--strings (or (model--get effort 'values) '()))
                     '())))
    (if (and (pair? effort) (eq? (model--get effort 'supported) #t) (pair? values))
        (list 'values values 'default (model--string (model--get effort 'default)))
        #f)))

(define (model--raw-effort options)
  (let ((option (find (lambda (o) (equal? (model--get o 'type) "effort")) options)))
    (if option
        (let ((values (model--strings (or (model--get option 'values) '()))))
          (if (pair? values)
              (list 'values values 'default (model--string (model--get option 'default)))
              #f))
        #f)))

(define (model--typed-thinking reasoning)
  (let* ((thinking (model--get reasoning 'thinking))
         (types (if (pair? thinking)
                    (model--strings (or (model--get thinking 'types) '()))
                    '())))
    (if (and (pair? thinking) (eq? (model--get thinking 'supported) #t))
        (list 'types types
              'default (model--string (model--get thinking 'default_type))
              'disable_supported (or (model--get thinking 'disable_supported) #f))
        #f)))

(define (model--raw-toggle options)
  (if (find (lambda (o) (equal? (model--get o 'type) "toggle")) options)
      (list 'types '("enabled") 'default #f 'disable_supported #t)
      #f))

(define (model--budget-map value)
  (let* ((min (model--get value 'min))
         (max (model--get value 'max))
         (default (model--get value 'default)))
    (if (or (integer? min) (integer? max) (integer? default))
        (list 'min (or min #f) 'max (or max #f) 'default (or default #f))
        #f)))

(define (model--typed-budget reasoning)
  (let ((value (model--get reasoning 'token_budget)))
    (cond ((integer? value) (list 'min 0 'max value 'default value))
          ((pair? value) (model--budget-map value))
          (else #f))))

(define (model--raw-budget options)
  (let ((option (find (lambda (o) (equal? (model--get o 'type) "budget_tokens")) options)))
    (and option (model--budget-map option))))

;; (model-reasoning-normalize RAW-JSON) -> the controls, or #f when the
;; model has none. RAW-JSON is the catalog entry's capabilities and extra.
(define (model-reasoning-normalize raw-json)
  "(model-reasoning-normalize RAW-JSON) — the normalized reasoning controls of a catalog entry, or #f; RAW-JSON holds its capabilities and extra"
  (let* ((raw (json-parse raw-json))
         (caps (or (model--get raw 'capabilities) '()))
         (extra (or (model--get raw 'extra) '()))
         (reasoning (or (model--get caps 'reasoning) '()))
         (options (or (model--get extra 'reasoning_options) '()))
         (effort (or (model--typed-effort reasoning) (model--raw-effort options)))
         (thinking (or (model--typed-thinking reasoning) (model--raw-toggle options)))
         (budget (or (model--typed-budget reasoning) (model--raw-budget options)))
         (enabled (or (eq? (model--get reasoning 'enabled) #t) effort thinking budget)))
    (if enabled
        (list 'enabled #t
              'effort (or effort #f)
              'thinking (or thinking #f)
              'token_budget (or budget #f)
              'source "llmdb")
        #f)))

;;; --- a live backend's model list ---------------------------------------------

(define (model--codex-effort v)
  (cond ((string? v) v)
        ((pair? v) (or (model--string (model--get v 'reasoningEffort))
                       (model--string (model--get v 'effort))
                       (model--string (model--get v 'value))))
        (else #f)))

(define (model--uniq xs)
  (let loop ((in xs) (out '()))
    (cond ((null? in) (reverse out))
          ((member (car in) out) (loop (cdr in) out))
          (else (loop (cdr in) (cons (car in) out))))))

;; (model-codex-entry MODEL-JSON) -> (ID NAME VALUES DEFAULT), the picker row
;; for one model a live Codex backend listed. Its effort list is authoritative
;; for that session, so it is read as offered and never invented.
(define (model-codex-row model)
  (let* ((efforts (model--uniq
                    (filter (lambda (e) e)
                            (map model--codex-effort
                                 (or (model--get model 'supportedReasoningEfforts) '())))))
         (default (model--string (model--get model 'defaultReasoningEffort)))
         (id (or (model--string (model--get model 'model))
                 (model--string (model--get model 'id))
                 ""))
         (name (or (model--string (model--get model 'displayName)) "")))
    (list id name efforts (or default ""))))

(define (model-codex-entry model-json)
  "(model-codex-entry MODEL-JSON) — the picker row (ID NAME EFFORTS DEFAULT) for one model a live backend listed"
  (model-codex-row (json-parse model-json)))

(define (model-codex-entries models-json)
  "(model-codex-entries MODELS-JSON) — the picker rows of every model a live backend listed"
  (map model-codex-row (json-parse models-json)))

;;; --- how old a snapshot is ---------------------------------------------------

;; days since 1970-01-01 for a proleptic Gregorian civil date (Hinnant's
;; algorithm); the catalog stamps its snapshot in UTC ISO-8601.
(define (model--days-from-civil y m d)
  (let* ((y (if (<= m 2) (- y 1) y))
         (era (quotient (if (>= y 0) y (- y 399)) 400))
         (yoe (- y (* era 400)))
         (mp (if (> m 2) (- m 3) (+ m 9)))
         (doy (+ (quotient (+ (* 153 mp) 2) 5) (- d 1)))
         (doe (+ (* yoe 365) (quotient yoe 4) (- (quotient yoe 100)) doy)))
    (- (+ (* era 146097) doe) 719468)))

(define (model--whole s)
  (string->number (car (string-split (if (string? s) s "") "."))))

(define (model--iso-seconds s)
  (if (not (string? s))
      #f
      (let* ((z? (string-suffix? "Z" s))
             (tz (and (not z?) (re-match "([+-])([0-9][0-9]):([0-9][0-9])$" s)))
             (off (cond (z? 0)
                        (tz (let* ((sign (if (equal? (cadr tz) "-") -1 1))
                                   (hh (string->number (caddr tz)))
                                   (mm (string->number (cadddr tz))))
                              (* sign (+ (* hh 3600) (* mm 60)))))
                        (else 0)))
             (core (cond (z? (substring s 0 (- (string-length s) 1)))
                         (tz (substring s 0 (- (string-length s) 6)))
                         (else s)))
             (parts (string-split core "T"))
             (d (if (pair? parts) (string-split (car parts) "-") '()))
             (t (if (and (pair? parts) (pair? (cdr parts)))
                    (string-split (cadr parts) ":")
                    '("0" "0" "0"))))
        (if (= (length d) 3)
            (let* ((y (string->number (car d)))
                   (mo (string->number (cadr d)))
                   (da (string->number (caddr d)))
                   (h (string->number (car t)))
                   (mi (if (pair? (cdr t)) (string->number (cadr t)) 0))
                   (sec (if (and (pair? (cdr t)) (pair? (cddr t)))
                            (model--whole (caddr t))
                            0)))
              (and y mo da h mi sec
                   (- (+ (* (model--days-from-civil y mo da) 86400)
                         (* h 3600) (* mi 60) sec)
                      off)))
            #f))))

;; (model-stale-days CAPTURED NOW) -> whole days since CAPTURED, or #f when
;; it does not read as an instant. NOW is unix seconds.
(define (model-stale-days captured now)
  "(model-stale-days CAPTURED NOW) — whole days since the ISO-8601 instant CAPTURED, or #f; NOW is unix seconds"
  (let ((secs (model--iso-seconds captured)))
    (and secs (quotient (- now secs) 86400))))

(public! 'model-reasoning-normalize
  "(model-reasoning-normalize RAW-JSON) — the normalized reasoning controls of a catalog entry, or #f; RAW-JSON holds its capabilities and extra")
(public! 'model-codex-entry
  "(model-codex-entry MODEL-JSON) — the picker row (ID NAME EFFORTS DEFAULT) for one model a live backend listed")
(public! 'model-codex-entries
  "(model-codex-entries MODELS-JSON) — the picker rows of every model a live backend listed")
(public! 'model-stale-days
  "(model-stale-days CAPTURED NOW) — whole days since the ISO-8601 instant CAPTURED, or #f; NOW is unix seconds")

;;; --- the shared snapshot ------------------------------------------------------

;; The lookup Elixir does must not ask Scheme: it reads this snapshot. Scheme
;; builds it once at boot and again when the catalog changes, so a picker that
;; names a hundred models pays nothing per row.
(effects! '(write))

(define (model-rules-build!)
  "(model-rules-build!) — rebuild the shared catalog snapshot from the loaded catalog; answers the number of models"
  (with-scheme-lock 'model-rules
    (lambda ()
      (let* ((entries (llm-catalog-entries))
             (answers (map (lambda (e) (list (car e) (model-reasoning-normalize (cadr e)))) entries))
             (info (llm-catalog-info))
             (captured (plist-get info 'captured-at))
             (secs (model--iso-seconds captured)))
        (model-rules-install! answers (or captured #f) (or secs #f))
        (length answers)))))

(public! 'model-rules-build!
  "(model-rules-build!) — rebuild the shared catalog snapshot from the loaded catalog; answers the number of models")
