;;; llm-gate.scm --- what the direct model lane may do, and when it tries again.
;;;
;;; The tool loop in llm.ex runs the rounds, the HTTP call and the waits.
;;; Every decision it makes on the way is here:
;;;
;;;   llm-tool-gate        may this tool call run? It is the permission
;;;                        chokepoint of the direct lane, and it answers the
;;;                        intrinsic ask tool.
;;;   llm-read-only-tools  which tools of a turn may run side by side.
;;;   llm-retry-delay      whether a failed model call tries again, and when.
;;;
;;; The gate fails closed. Elixir denies the call when this file gives no
;;; verdict: a policy that raises, a gate that raises, an answer it does not
;;; know. So a bug here stops tools; it never lets one through.

(domain! 'permissions)
(category! 'chat)

;; --- the gate --------------------------------------------------------------

;; the policy is the user's own function, so the gate can do what it does
(effects! '(unknown))

;; ask is the tool the model uses to ask the user a question. It is not
;; gated: the answer comes from the user, which is the gate. A bad call gets
;; an error result, and the model can try again.
(define (llm-gate--answers v)
  (if (list? v)
      (map (lambda (a)
             (cond ((string? a) a)
                   ((number? a) (number->string a))
                   ((eq? a #t) "true")
                   ((not a) "")
                   (else (value->string a))))
           v)
      '()))

(define (llm-gate--ask-user input)
  (let ((q (and (list? input) (plist-get input 'question))))
    (if (string? q)
        (list 'ask-user q (llm-gate--answers (plist-get input 'answers)))
        (list 'error "ask requires a question and an answers array"))))

;; POLICY is the chat's permission function (slug name kind raw), or #f for
;; a loop that has none. Only the symbols ask and reject stop a call: any
;; other answer allows it, as it always has. RAW is the text the policy
;; matches its patterns against; Elixir writes it, so it stays the text the
;; ACP lane and the always-rules have always seen.
(define (llm-tool-gate policy slug name raw input)
  (cond ((equal? name "ask") (llm-gate--ask-user input))
        ((not policy) 'allow)
        (else
         (let ((v (policy slug name "tool" raw)))
           (cond ((eq? v 'reject) (list 'deny "denied by policy"))
                 ((eq? v 'ask) (list 'ask-permission))
                 (else 'allow))))))

;; --- concurrency -------------------------------------------------------------

(effects! '(pure))

;; SPECS are the turn's tool specs: (name description params [effects]).
;; A tool whose first declared effect is pure or read may run beside other
;; reads; one without a declaration never does.
(define (llm-gate--name x) (if (symbol? x) (symbol->string x) x))

(define (llm-read-only-tools specs)
  (let loop ((ss specs) (acc '()))
    (if (null? ss)
        (reverse acc)
        (let* ((s (car ss))
               (effects (and (pair? s) (= (length s) 4) (list-ref s 3)))
               (effects (if (list? effects) effects (if effects (list effects) '())))
               (level (and (pair? effects) (llm-gate--name (car effects)))))
          (loop (cdr ss)
                (if (member level '("pure" "read"))
                    (cons (llm-gate--name (car s)) acc)
                    acc))))))

;; --- retry -------------------------------------------------------------------

;; 500 and 529 are the provider saying "not now". req_llm retries transport
;; errors and 429; it does not retry these, so the user did, by resending a
;; whole uncached transcript. Three tries, jittered, then the error stands.
(define llm-retry-max 3)
(define llm-retry-statuses '(500 502 503 529))

;; A Finch HTTP/2 pool takes requests only while its one connection is up.
;; After a start or a close it waits 500 ms or more before it connects
;; again, and every request in that gap fails at once: pool_not_available
;; while the pool is out of the registry, disconnected or read_only when the
;; request reaches it. deadline is our own: the pool that never answered.
(define llm-retry-transport
  '("pool_not_available" "disconnected" "read_only" "connection_closed" "closed" "deadline"))

(define (llm-gate--status-number s)
  (let ((m (re-match "^[+-]?[0-9]+" s)))
    (and m (string->number (car m)))))

;; E is a failed call as Elixir saw it: (STATUS REASON). STATUS is a
;; number, text, or #f. REASON is a symbol (an atom), text, a nested
;; (STATUS REASON), or #f. req_llm wraps a provider error inside a request
;; error and reports a status as a number on one and as text on the other,
;; so the whole chain is read. A status that is text decides alone; a
;; number not in the list leaves the reason to decide.
(define (llm-retryable? e)
  (and (pair? e)
       (let ((s (car e)) (r (cadr e)))
         (cond ((and (integer? s) (memv s llm-retry-statuses)) #t)
               ((string? s)
                (let ((n (llm-gate--status-number s)))
                  (and n (memv n llm-retry-statuses) #t)))
               ((symbol? r) (and (member (symbol->string r) llm-retry-transport) #t))
               ;; a request error carries the transport failure as text,
               ;; "http2 error: :connection_closed", not as the atom
               ((string? r)
                (let loop ((ts llm-retry-transport))
                  (cond ((null? ts) #f)
                        ((string-contains? r (string-append ":" (car ts))) #t)
                        (else (loop (cdr ts))))))
               ((pair? r) (llm-retryable? r))
               (else #f)))))

;; Milliseconds to wait before try ATTEMPT + 1, or #f to give up. BASE,
;; then twice BASE, each plus up to half its own width: two clients hitting
;; the same overloaded provider must not march in step.
(define (llm-retry-delay attempt e base)
  (and (< attempt llm-retry-max)
       (llm-retryable? e)
       (let ((b (* base (expt 2 (- attempt 1)))))
         (+ b 1 (random (max (quotient b 2) 1))))))

(public! 'llm-tool-gate
  "(llm-tool-gate POLICY SLUG NAME RAW INPUT) — the direct lane's verdict on one tool call: allow, (deny REASON), (ask-permission), (ask-user QUESTION ANSWERS) or (error TEXT)")
(public! 'llm-read-only-tools
  "(llm-read-only-tools SPECS) — the names of the tools in SPECS that may run side by side")
(public! 'llm-retryable?
  "(llm-retryable? E) — #t when the failed model call E, as (STATUS REASON), is worth another try")
(public! 'llm-retry-delay
  "(llm-retry-delay ATTEMPT E BASE) — milliseconds before the next try of a failed model call, or #f")
