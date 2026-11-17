;;; llm-costs.scm --- What each LLM turn used and cost: the ledger and M-x llm-costs.
;;;
;;; Core reports every turn and every one-off call on the event log, topic
;;; "llm:usage", with the usage as the backend got it (LLM.report_usage).
;;; This package reads those reports. It turns each backend's usage into
;;; one shape, decides how the turn is paid, prices it from the catalog,
;;; and appends one row to llm-usage.jsonl in the state folder. M-x
;;; llm-costs shows the ledger by day and model.
;;;
;;; Usage formats and plans change often. Each step is a function or a
;;; setting here, so a fix is a reload, and a user can redefine one in
;;; their config: a team plan, a negotiated rate, a local model.
;;;
;;; A subscription turn has no one price: the same turn costs a different
;;; amount on a different plan. Its row holds no cost, only an estimate at
;;; the catalog price, and an estimate is never added to the spend.

(require 'workflows)

(domain! 'llm)
(effects! '(write))
(category! 'chat)

(defcustom 'llm-costs-ledger (string-append (compos-state-dir) "/llm-usage.jsonl")
  "The file that keeps one JSON row for each LLM turn and call."
  'group 'llm 'type 'string)

(defcustom 'llm-costs-subscriptions
  '(("claude-code" ".")
    ("codex-app-server" ".")
    ("codex" ".")
    ("opencode" "^opencode-go/")
    ("opencode-go" "^opencode-go/"))
  "The models a subscription pays for, as ((CONNECTOR REGEX) ...). A turn on such a model records an estimate, not a cost. Any other turn is billed per token."
  'group 'llm 'type 'list)

(defcustom 'llm-costs-price-providers
  '(("deepseek" "deepseek"))
  "The catalog provider of a connector that reports bare model ids, as ((CONNECTOR PROVIDER) ...). The harness of deepseek reports deepseek-v4-pro; the catalog has deepseek:deepseek-v4-pro."
  'group 'llm 'type 'list)

(effects! '(pure))

(define (llm-costs--n x) (if (number? x) x 0))

(define (llm-costs--tokens input output cache-read cache-write reasoning)
  (list 'input input 'output output 'cache-read cache-read
        'cache-write cache-write 'reasoning reasoning))

;; ACP: the PromptResponse usage of one turn. inputTokens counts the fresh
;; input, apart from the cached tokens.
(define (llm-costs-acp-tokens u)
  (llm-costs--tokens (llm-costs--n (plist-get u "inputTokens"))
                     (llm-costs--n (plist-get u "outputTokens"))
                     (llm-costs--n (plist-get u "cachedReadTokens"))
                     (llm-costs--n (plist-get u "cachedWriteTokens"))
                     (llm-costs--n (plist-get u "thoughtTokens"))))

;; Codex: one notification for each model request of the turn. Each one's
;; "last" is that request; inputTokens includes cachedInputTokens.
(define (llm-costs-codex-tokens notes)
  (let loop ((ns (if (pair? notes) notes '())) (i 0) (o 0) (r 0) (w 0) (x 0))
    (if (null? ns)
        (llm-costs--tokens i o r w x)
        (let* ((last (plist-get (plist-get (car ns) "tokenUsage") "last"))
               (in (llm-costs--n (plist-get last "inputTokens")))
               (cached (llm-costs--n (plist-get last "cachedInputTokens"))))
          (loop (cdr ns)
                (+ i (max 0 (- in cached)))
                (+ o (llm-costs--n (plist-get last "outputTokens")))
                (+ r cached)
                (+ w (llm-costs--n (plist-get last "cacheWriteInputTokens")))
                (+ x (llm-costs--n (plist-get last "reasoningOutputTokens"))))))))

;; The direct lane and the one-off calls: core already gives the fresh
;; input apart from the cached tokens (LLM.usage_strings).
(define (llm-costs-api-tokens u)
  (llm-costs--tokens (llm-costs--n (or (plist-get u "input_tokens") (plist-get u "prompt_tokens")))
                     (llm-costs--n (or (plist-get u "output_tokens") (plist-get u "completion_tokens")))
                     (llm-costs--n (plist-get u "cache_read_input_tokens"))
                     (llm-costs--n (plist-get u "cache_creation_input_tokens"))
                     0))

(define (llm-costs-tokens backend usage)
  "(llm-costs-tokens BACKEND USAGE) - the tokens of one report as (input N output N cache-read N cache-write N reasoning N); no usage is all zeros"
  (cond ((not usage) (llm-costs--tokens 0 0 0 0 0))
        ((equal? backend "codex-app-server") (llm-costs-codex-tokens usage))
        ((member backend '("req-llm" "llm" "llm-tools")) (llm-costs-api-tokens usage))
        (else (llm-costs-acp-tokens usage))))

(define (llm-costs-subscription? connector model)
  "(llm-costs-subscription? CONNECTOR MODEL) - #t when a subscription of CONNECTOR pays for MODEL (llm-costs-subscriptions)"
  (let ((e (and (string? connector) (assoc connector llm-costs-subscriptions))))
    (and e (string? model) (re-match? (cadr e) model) #t)))

(define (llm-costs-model connector model)
  "(llm-costs-model CONNECTOR MODEL) - MODEL as the catalog names it: a bare id of a connector in llm-costs-price-providers gets its provider"
  (let ((e (and (string? connector) (assoc connector llm-costs-price-providers))))
    (if (and e (string? model)
             (not (string-contains? model ":")) (not (string-contains? model "/")))
        (string-append (cadr e) ":" model)
        model)))

(define (llm-costs-catalog-price model tokens)
  "(llm-costs-catalog-price MODEL TOKENS) - the dollars of TOKENS at the catalog price of MODEL, or #f when the catalog has no price"
  (let ((p (and (string? model) (llm-price model))))
    (and p
         (/ (+ (* (plist-get tokens 'input) (llm-costs--n (plist-get p 'input)))
               (* (plist-get tokens 'output) (llm-costs--n (plist-get p 'output)))
               (* (plist-get tokens 'cache-read) (llm-costs--n (plist-get p 'cache-read)))
               (* (plist-get tokens 'cache-write) (llm-costs--n (plist-get p 'cache-write))))
            1000000.0))))

(define (llm-costs--put row key value)
  (if value (append row (list key value)) row))

;; one report as one ledger row: a plist with JSON-ready keys. A cost the
;; backend sends as a number wins over the catalog. A subscription turn
;; holds an estimate, not a cost. A value that is not there is left out.
(define (llm-costs-row event)
  "(llm-costs-row EVENT) - the ledger row of one llm:usage EVENT"
  (let* ((d (plist-get event 'data))
         (backend (plist-get d 'backend))
         (connector (plist-get d 'connector))
         (model (llm-costs-model connector (plist-get d 'model)))
         (tokens (llm-costs-tokens backend (plist-get d 'usage)))
         (own (and (number? (plist-get d 'cost)) (plist-get d 'cost)))
         (sub (and (not own) (llm-costs-subscription? connector model)))
         (price (and (not own) (llm-costs-catalog-price model tokens)))
         (at (plist-get event 'at)))
    (fold (lambda (row kv) (llm-costs--put row (car kv) (cadr kv)))
          (list 'seq (plist-get event 'seq) 'at at 'day (format-time at "%Y-%m-%d"))
          (list (list 'kind (format "~a" (plist-get event 'kind)))
                (list 'model model)
                (list 'connector connector)
                (list 'backend backend)
                (list 'slug (plist-get d 'slug))
                (list 'end (plist-get d 'end))
                (list 'input (plist-get tokens 'input))
                (list 'output (plist-get tokens 'output))
                (list 'cache_read (plist-get tokens 'cache-read))
                (list 'cache_write (plist-get tokens 'cache-write))
                (list 'reasoning (plist-get tokens 'reasoning))
                (list 'cost (or own (and (not sub) price)))
                (list 'estimate (and sub price))))))

;;; --- the ledger --------------------------------------------------------------

(effects! '(read))

(define (llm-costs-rows)
  "(llm-costs-rows) - every row of the ledger, oldest first, as plists; a line that does not read is skipped"
  (let ((text (read-file llm-costs-ledger)))
    (if (not text)
        '()
        (filter pair? (map (lambda (line) (and (not (equal? line "")) (json-parse line)))
                           (string-split text "\n"))))))

;; the newest seq in the ledger, read once. A workflow writes outside the
;; log at least once, so a batch that runs again skips what it wrote.
(define *llm-costs-last-seq* (if (boundp '*llm-costs-last-seq*) *llm-costs-last-seq* #f))

(define (llm-costs--last-seq)
  (or *llm-costs-last-seq*
      (let ((s (fold (lambda (m r) (max m (llm-costs--n (plist-get r 'seq)))) 0 (llm-costs-rows))))
        (set! *llm-costs-last-seq* s)
        s)))

(effects! '(write))

(define (llm-costs-record! events)
  "(llm-costs-record! EVENTS) - append a ledger row for each llm:usage event that the ledger does not have yet; answer how many"
  (let* ((last (llm-costs--last-seq))
         (new (filter (lambda (e) (> (llm-costs--n (plist-get e 'seq)) last)) events)))
    (when (pair? new)
      (let ((old (or (read-file llm-costs-ledger) ""))
            (lines (map (lambda (e) (json-encode (llm-costs-row e))) new)))
        (write-file! llm-costs-ledger
          (string-append old
                         (if (or (equal? old "") (string-suffix? "\n" old)) "" "\n")
                         (string-join lines "\n") "\n"))
        (set! *llm-costs-last-seq*
          (fold (lambda (m e) (max m (plist-get e 'seq))) last new))))
    (length new)))

(define (llm-costs--handle key events)
  (llm-costs-record! events))

(define-workflow! "llm-costs"
  'listen '("llm:usage")
  'handle 'llm-costs--handle)

;;; --- M-x llm-costs -----------------------------------------------------------

(effects! '(read))

;; a row's day: its own, or the date of the ts that core wrote before this
;; package kept the ledger
(define (llm-costs--day r)
  (or (plist-get r 'day)
      (let ((ts (plist-get r 'ts)))
        (if (and (string? ts) (>= (string-length ts) 10)) (substring ts 0 10) "?"))))

(define (llm-costs--add sums r)
  (list 'requests (+ 1 (plist-get sums 'requests))
        'input (+ (plist-get sums 'input) (llm-costs--n (plist-get r 'input)))
        'output (+ (plist-get sums 'output) (llm-costs--n (plist-get r 'output)))
        'cache-read (+ (plist-get sums 'cache-read) (llm-costs--n (plist-get r 'cache_read)))
        'cache-write (+ (plist-get sums 'cache-write) (llm-costs--n (plist-get r 'cache_write)))
        'cost (+ (plist-get sums 'cost) (llm-costs--n (plist-get r 'cost)))
        'estimate (+ (plist-get sums 'estimate) (llm-costs--n (plist-get r 'estimate)))))

(define (llm-costs-report)
  "(llm-costs-report) - the ledger summed by day and model, newest day first: ((DAY MODEL SUMS) ...), where SUMS has requests input output cache-read cache-write cost estimate"
  (let ((groups
          (fold (lambda (acc r)
                  (let* ((key (string-append (llm-costs--day r) "\t" (format "~a" (or (plist-get r 'model) "?"))))
                         (e (assoc key acc))
                         (zero '(requests 0 input 0 output 0 cache-read 0 cache-write 0 cost 0 estimate 0)))
                    (alist-put acc key (llm-costs--add (if e (cadr e) zero) r))))
                '() (llm-costs-rows))))
    (map (lambda (key)
           (let ((parts (string-split key "\t")))
             (list (car parts) (cadr parts) (cadr (assoc key groups)))))
         (reverse (sort (map car groups))))))

;; cached input over all input: low means the prefix is written again
;; every turn, at full price
(define (llm-costs--hit-rate s)
  (let ((total (+ (plist-get s 'input) (plist-get s 'cache-read))))
    (if (> total 0)
        (string-append (number->string (round (* 100.0 (/ (plist-get s 'cache-read) total)))) "% cached")
        "")))

(define-command "llm-costs" "Show LLM spend by day and model (the usage ledger)"
  (lambda ()
    (let ((buf "*llm-costs*"))
      (buffer-create buf)
      (buffer-delete-range! buf 0 (string-byte-length (buffer-text buf)))
      (buffer-append! buf
        (fold (lambda (acc row)
                (let ((s (caddr row)))
                  (string-append acc
                    (car row) "  "
                    (format-usd (plist-get s 'cost))
                    (if (> (plist-get s 'estimate) 0)
                        (string-append " (+ about " (format-usd (plist-get s 'estimate)) " on a subscription)")
                        "")
                    "  " (number->string (plist-get s 'requests)) " reqs  "
                    (number->string (plist-get s 'input)) "->"
                    (number->string (plist-get s 'output)) "  "
                    "cache " (number->string (plist-get s 'cache-read)) "r/"
                    (number->string (plist-get s 'cache-write)) "w  "
                    (string-pad-right (llm-costs--hit-rate s) 12)
                    "  " (cadr row) "\n")))
              (string-append
                "LLM spend - ledger " llm-costs-ledger " - per-chat: C-c $\n"
                "a subscription bills by its limits: its turns show an estimate at API prices, apart from the spend\n"
                "hit rate is cached input over all input: low means the prefix is written again every turn\n\n")
              (llm-costs-report)))
      (switch-to-buffer! buf))))

(public! 'llm-costs-tokens "(llm-costs-tokens BACKEND USAGE) - the tokens of one usage report as (input N output N cache-read N cache-write N reasoning N)")
(public! 'llm-costs-subscription? "(llm-costs-subscription? CONNECTOR MODEL) - #t when a subscription of CONNECTOR pays for MODEL")
(public! 'llm-costs-model "(llm-costs-model CONNECTOR MODEL) - MODEL as the catalog names it")
(public! 'llm-costs-catalog-price "(llm-costs-catalog-price MODEL TOKENS) - the dollars of TOKENS at the catalog price of MODEL, or #f")
(public! 'llm-costs-row "(llm-costs-row EVENT) - the ledger row of one llm:usage EVENT")
(public! 'llm-costs-rows "(llm-costs-rows) - every row of the ledger, oldest first")
(public! 'llm-costs-report "(llm-costs-report) - the ledger summed by day and model, newest day first")

(effects! '(write))
(public! 'llm-costs-record! "(llm-costs-record! EVENTS) - append a ledger row for each llm:usage event the ledger does not have yet; answer how many")
