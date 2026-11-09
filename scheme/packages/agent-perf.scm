;;; agent-perf.scm --- the steps of an agent turn on any lane, for chat-perf.
;;;
;;; The direct lane stamps its own steps (round N model, tool NAME) into
;;; telemetry. An ACP or Codex thread runs its loop inside the adapter, so
;;; compos sees only its events: a prompt goes out, a tool call starts, a
;;; tool call ends, the turn ends. This package turns those events into the
;;; same steps. A model round runs from the prompt, or from the end of the
;;; last tool burst, to the next tool call or the turn end. chat-perf draws
;;; them beside the context row, so M-x chat-perf shows a flame graph of a
;;; claude-code turn as it does of a direct one.

(domain! 'diagnostics)
(effects! '(write))

;; slug -> (T0 MARK ROUND OPEN ROWS DONE). Times are monotonic ms. OPEN is
;; ((ID NAME START) ...), ROWS newest first, each (LABEL START END DETAIL).
(define *agent-perf* '())

(define (agent-perf--get slug)
  (let ((e (assoc slug *agent-perf*))) (and e (cadr e))))

(define (agent-perf--put! slug st)
  (set! *agent-perf* (alist-put *agent-perf* slug st)))

(define (agent-perf--name e fallback)
  (let ((n (or (plist-get e 'name) (plist-get e 'title))))
    (if (and (string? n) (not (equal? n ""))) n fallback)))

;; end the model round that runs now, and start the count of the next
(define (agent-perf--close-round st now)
  (let ((mark (list-ref st 1)) (n (list-ref st 2)))
    (list (list-ref st 0) now (+ n 1) (list-ref st 3)
          (cons (list (string-append "round " (number->string n) " model") mark now "")
                (list-ref st 4))
          (list-ref st 5))))

(define (agent-perf--event st e now)
  (let ((type (plist-get e 'type)))
    (cond
      ;; a prompt starts a turn; a steer inside a running turn does not
      ((eq? type 'user-msg)
       (if (and st (not (list-ref st 5))) st (list now now 1 '() '() #f)))
      ((or (not st) (list-ref st 5)) st)
      ((eq? type 'tool-call)
       (let ((id (plist-get e 'id)) (open (list-ref st 3)))
         (if (assoc id open)
             st
             (let ((st (if (null? open) (agent-perf--close-round st now) st)))
               (list (list-ref st 0) (list-ref st 1) (list-ref st 2)
                     (cons (list id (agent-perf--name e "tool") now) (list-ref st 3))
                     (list-ref st 4) #f)))))
      ((and (eq? type 'tool-update) (member (plist-get e 'status) '("completed" "failed")))
       (let* ((open (list-ref st 3)) (hit (assoc (plist-get e 'id) open)))
         (if (not hit)
             st
             (let ((left (filter (lambda (o) (not (equal? (car o) (car hit)))) open)))
               (list (list-ref st 0)
                     (if (null? left) now (list-ref st 1))
                     (list-ref st 2) left
                     (cons (list (string-append "tool " (agent-perf--name e (cadr hit)))
                                 (caddr hit) now (if (equal? (plist-get e 'status) "failed") "failed" ""))
                           (list-ref st 4))
                     #f)))))
      ((memq type '(turn-end turn-failed))
       (let* ((st (fold (lambda (st o)
                          (list (list-ref st 0) (list-ref st 1) (list-ref st 2) (list-ref st 3)
                                (cons (list (string-append "tool " (cadr o)) (caddr o) now "unfinished")
                                      (list-ref st 4))
                                #f))
                        st (list-ref st 3)))
              (st (if (null? (list-ref st 3)) (agent-perf--close-round st now) st)))
         (list (list-ref st 0) (list-ref st 1) (list-ref st 2) '() (list-ref st 4) #t)))
      (else st))))

;; the agent-events-hook: every event batch of every thread passes here
(define (agent-perf-note! slug events)
  (let ((now (monotonic-ms)))
    (let ((st (fold (lambda (st e) (agent-perf--event st e now)) (agent-perf--get slug) events)))
      (when st (agent-perf--put! slug st)))))

(add-hook! '(agent-events-hook agent-perf) agent-perf-note!)

(effects! '(read))

;; the last turn's steps of SLUG as chat-perf rows. ANCHOR is the epoch ms
;; the turn started at; #f takes it from the clock.
(define (agent-perf-rows slug &optional anchor)
  (let ((st (agent-perf--get slug)))
    (if (not st)
        '()
        (let* ((t0 (list-ref st 0))
               (base (or anchor (- (* 1000 (current-time)) (- (monotonic-ms) t0))))
               (at (lambda (m) (+ base (- m t0)))))
          (map (lambda (r)
                 (list 'layer "chat" 'kind "chat" 'owner slug 'label (car r)
                       'time-ms (at (caddr r)) 'duration-ms (- (caddr r) (cadr r))
                       'queue-ms 0 'detail (cadddr r)))
               (reverse (list-ref st 4)))))))

;; (LABEL MS) per step of SLUG's last turn, oldest first
(define (agent-perf-turn slug)
  (map (lambda (r) (list (plist-get r 'label) (plist-get r 'duration-ms)))
       (agent-perf-rows slug 0)))

(public! 'agent-perf-rows
  "(agent-perf-rows SLUG [ANCHOR]) -- the model rounds and tool calls of SLUG's last turn as chat-perf rows, on any lane; ANCHOR is the epoch ms of the turn start")
(public! 'agent-perf-turn
  "(agent-perf-turn SLUG) -- (LABEL MS) for each model round and tool call of SLUG's last turn, oldest first")
