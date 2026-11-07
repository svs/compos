;;; llm-loop.scm --- the model wire's rules, in Scheme.
;;;
;;; The HTTP call and the round loop stay in Elixir (Compos.Core.LLM): a
;;; streaming reply hands text to the renderer between two HTTP events, and
;;; that order belongs to the transport. The rules the loop applies are
;;; editor policy, and they live here: which provider answer is worth asking
;;; again, how long to wait, and which tools a round may run at once.
;;;
;;; Elixir asks these rules by name (Session.call_named), the same way it asks
;;; llm-key and llm-base-url. A rule it cannot get never retries and never
;;; runs tools at once: a slow round, not a wrong one.

(domain! 'chat)
(effects! '(pure))

;; 500 and 529 are the provider saying "not now". req_llm retries transport
;; errors and 429 by itself; these it does not, and a person then resends a
;; whole uncached transcript, which is the most expensive gesture here.
(define *llm-retry-statuses* '(500 502 503 529))

;; A Finch HTTP/2 pool takes requests only while its one connection is up.
;; The first ask after a quiet spell finds that gap and every request in it
;; fails at once: pool_not_available while the pool is out of the registry,
;; disconnected or read_only when the request reaches it.
(define *llm-retry-transport*
  '("pool_not_available" "disconnected" "read_only" "connection_closed" "closed" "deadline"))

(define (llm--effect-name e)
  (if (symbol? e) (symbol->string e) e))

;; EFFECTS is a tool's declared list: one level (pure, read, write, destroy)
;; plus modifiers. A round of pure or read tools may run at once.
(define (llm-effect-read-only? effects)
  "(llm-effect-read-only? EFFECTS) — #t when a tool's declared effects start pure or read, so its round may run at once"
  (and (pair? effects)
       (member (llm--effect-name (car effects)) '("pure" "read"))
       #t))

;; (llm-read-only-tools SPECS) — the names of the tools to run at once.
;; A spec is (NAME DESCRIPTION PARAMS EFFECTS); one with no effects entry is
;; not read-only.
(define (llm-read-only-tools specs)
  "(llm-read-only-tools SPECS) — the names of the tools in SPECS whose effects are pure or read; a round of them may run at once"
  (let loop ((ss specs) (out '()))
    (cond ((null? ss) (reverse out))
          ((not (pair? (car ss))) (loop (cdr ss) out))
          (else
           (let* ((s (car ss))
                  (name (llm--effect-name (car s)))
                  (effects (and (>= (length s) 4) (list-ref s 3))))
             (loop (cdr ss)
                   (if (and (string? name) (llm-effect-read-only? effects))
                       (cons name out)
                       out)))))))

;; STATUS is the provider's HTTP code as a number, or #f; REASON is the
;; transport failure as text, or #f. A status, when there is one, decides
;; alone.
(define (llm-retryable? status reason)
  "(llm-retryable? STATUS REASON) — #t when a failed model round is worth asking again; STATUS is the provider's HTTP code as a number or #f, REASON the transport failure as text or #f"
  (if status
      (and (number? status) (member status *llm-retry-statuses*) #t)
      (and (string? reason)
           (pair? (filter (lambda (word) (string-contains? reason word)) *llm-retry-transport*))
           #t)))

(public! 'llm-effect-read-only?
  "(llm-effect-read-only? EFFECTS) — #t when a tool's declared effects start pure or read, so its round may run at once")
(public! 'llm-read-only-tools
  "(llm-read-only-tools SPECS) — the names of the tools in SPECS whose effects are pure or read; a round of them may run at once")
(public! 'llm-retryable?
  "(llm-retryable? STATUS REASON) — #t when a failed model round is worth asking again; STATUS is the provider's HTTP code as a number or #f, REASON the transport failure as text or #f")

;; BASE doubled per attempt, plus up to half its width of jitter: two clients
;; hitting the same overloaded provider must not march in step.
(effects! '(read))

(define (llm-retry-delay attempt base)
  "(llm-retry-delay ATTEMPT BASE) — milliseconds to wait before retry ATTEMPT (1-based): BASE doubled per attempt, plus up to half its width of jitter"
  (let loop ((n (- attempt 1)) (wait base))
    (if (<= n 0)
        (+ wait (random (max (quotient wait 2) 1)))
        (loop (- n 1) (* wait 2)))))

(public! 'llm-retry-delay
  "(llm-retry-delay ATTEMPT BASE) — milliseconds to wait before retry ATTEMPT (1-based): BASE doubled per attempt, plus up to half its width of jitter")
