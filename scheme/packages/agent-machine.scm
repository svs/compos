;;; agent-machine.scm --- one agent thread's turn machine, as pure data.
;;;
;;; Every live chat runs through Compos.Core.Agent, a GenServer that owns
;;; the backend adapter, the timers and the event pipe. What the thread
;;; DOES with a message is decided here: the prompt queue, steering and
;;; its settlement, a turn end held back behind a steer, the idle park and
;;; the revive, permission and question bookkeeping, and the recovery nets
;;; for a turn that never ends.
;;;
;;; (agent-step STATE MSG) answers (STATE REPLY EFFECTS). It reads nothing
;;; and writes nothing: the GenServer calls it in its own process, then
;;; runs EFFECTS in order. STATE is an alist of (KEY VALUE) rows.
;;;
;;; MSG, from the GenServer:
;;;   (prompt TEXT DISPLAY IMAGES)       -> sent | queued | answered | (error dead)
;;;   (take-steering)                    -> ((TEXT DISPLAY) ...)
;;;   (steer-next)                       -> (steer TOKEN TEXT DISPLAY EPOCH) | (error WHY) | sent
;;;   (steered TOKEN RESULT)             -> sent | (error WHY); RESULT is ok or (error WHY)
;;;   (dequeue TEXT) (promote TEXT)      -> ok | (error not_found)
;;;   (cancel)                           -> ok
;;;   (ask-permission TITLE KIND RAW MS) -> (defer ID)
;;;   (respond-permission ID OPTION)     -> ok
;;;   (permission-deadline MS)           -> ok
;;;   (permission-timeout ID)
;;;   (ask-user QUESTION ANSWERS)        -> (defer ID) | (error question_already_pending)
;;;   (respond-question ID ANSWER)       -> ok
;;;   (backend-event EVENT)
;;;   (context EPOCH ok SETTLE-S SILENT-S) | (context EPOCH error WHY)
;;;   (settle-grace EPOCH) (silent-turn EPOCH) (steer-settle EPOCH) (idle-park)
;;;   (terminate)
;;;
;;; EFFECTS, run by the GenServer in order:
;;;   (emit EVENT)                       the event goes to the chat
;;;   (arm NAME MS MSG) (disarm NAME)    a timer that steps MSG; a re-arm replaces it
;;;   (after MS MSG)                     a timer nobody cancels
;;;   (fetch-context EPOCH TEXT DISPLAY IMAGES)
;;;   (prompt)                           send the turn the context came back for
;;;   (cancel) (park) (revive RESUME)
;;;   (respond-permission ID OPTION) (respond-question ID ANSWER)   to the backend
;;;   (reply ID VALUE)                   to the caller that waits on ID

(domain! 'chat)
(effects! '(pure))

;; --- state rows -------------------------------------------------------------

(define (am-get s k)
  (let ((row (assq k s))) (if row (cadr row) #f)))

(define (am-set s k v)
  (cons (list k v) (am-drop s k)))

(define (am-drop s k)
  (cond ((null? s) '())
        ((eq? (car (car s)) k) (cdr s))
        (else (cons (car s) (am-drop (cdr s) k)))))

(define (am-push s k v) (am-set s k (append (am-get s k) (list v))))

(define (am-pget plist key)
  (cond ((or (not (pair? plist)) (not (pair? (cdr plist)))) #f)
        ((eq? (car plist) key) (cadr plist))
        (else (am-pget (cddr plist) key))))

(define (am-type event)
  (let ((t (am-pget event 'type)))
    (cond ((symbol? t) (symbol->string t)) ((string? t) t) (else #f))))

(define (am-fold f acc items)
  (if (null? items) acc (am-fold f (f acc (car items)) (cdr items))))

;; --- effects ----------------------------------------------------------------

(define (am-fx s effect) (am-set s 'fx (cons effect (am-get s 'fx))))
(define (am-emit s event) (am-fx s (list 'emit event)))
(define (am-reply s value) (am-set s 'reply value))

(define (am-armed? s name) (memq name (am-get s 'armed)))

(define (am-arm s name ms msg)
  (am-fx (am-set s 'armed (cons name (am-get (am-disarm s name) 'armed)))
         (list 'arm name ms msg)))

(define (am-disarm s name)
  (if (am-armed? s name)
      (am-fx (am-set s 'armed (filter (lambda (n) (not (eq? n name))) (am-get s 'armed)))
             (list 'disarm name))
      s))

;; a timer that fired is no longer armed
(define (am-fired s name)
  (am-set s 'armed (filter (lambda (n) (not (eq? n name))) (am-get s 'armed))))

;; --- a new thread -------------------------------------------------------------

(define (agent-machine-new steering idle-ms stateless)
  (list (list 'status 'starting) (list 'parked #f) (list 'resume #f)
        (list 'queue '()) (list 'steering-queue '()) (list 'steers '())
        (list 'steer-order '()) (list 'fallbacks '()) (list 'turn-end #f)
        (list 'steered #f) (list 'settle-ms 180000) (list 'silent-ms 180000)
        (list 'stale-ends 0) (list 'next-steer 1) (list 'steering steering)
        (list 'permission #f) (list 'waiting '()) (list 'question #f)
        (list 'epoch 0) (list 'context-pending #f) (list 'next-rpc 1)
        (list 'idle-ms idle-ms) (list 'stateless stateless) (list 'armed '())
        (list 'fx '()) (list 'reply 'ok)))

;; --- status -----------------------------------------------------------------

(define (am-status s status)
  (if (eq? (am-get s 'status) status)
      s
      (am-idle-clock (am-emit (am-set s 'status status) (list 'type 'status 'status status))
                     status)))

(define (am-idle-clock s status)
  (if (eq? status 'idle) (am-arm-idle s) (am-disarm s 'idle)))

;; A thread idle this long closes its adapter and keeps its session id;
;; the next prompt opens a new adapter on the same session. A thread with
;; no session to come back to never parks.
(define (am-parkable? s)
  (and (eq? (am-get s 'status) 'idle) (string? (am-get s 'resume))
       (not (am-get s 'parked)) (null? (am-get s 'queue))
       (null? (am-get s 'steering-queue)) (not (am-get s 'permission))
       (not (am-get s 'question)) (not (am-get s 'context-pending))
       (not (am-get s 'stateless))))

(define (am-arm-idle s)
  (let ((s (am-disarm s 'idle)) (ms (am-get s 'idle-ms)))
    (if (and (integer? ms) (> ms 0) (am-parkable? s))
        (am-arm s 'idle ms (list 'idle-park))
        s)))

(define (am-attention-resolved s)
  (am-status s (if (or (am-get s 'permission) (am-get s 'question)) 'needs_attention 'running)))

;; --- permissions --------------------------------------------------------------
;; A pending request is (ID TITLE KIND OPTIONS OURS). OURS: the editor
;; asked, and the verdict goes back to the caller that waits, not out to
;; the backend.

(define (am-perm-id p) (car p))
(define (am-perm-title p) (cadr p))

(define (am-verdict p option)
  (let ((hit (and option (assoc option (cadddr p)))))
    (if (not hit)
        'deny
        (let* ((kind (caddr hit))
               (kind (if (symbol? kind) (symbol->string kind) kind)))
          (cond ((equal? kind "allow_always") 'always)
                ((equal? kind "allow_once") 'allow)
                ((and (string? kind) (string-prefix? "allow" kind)) 'allow)
                (else 'deny))))))

(define (am-answer-permission s p option)
  (if (list-ref p 4)
      (am-fx s (list 'reply (am-perm-id p) (am-verdict p option)))
      (am-fx s (list 'respond-permission (am-perm-id p) option))))

;; An adapter asks about parallel tool calls at the same time. The second
;; request waits behind the first and never replaces it.
(define (am-add-permission s p)
  (if (am-get s 'permission) (am-push s 'waiting p) (am-set s 'permission p)))

(define (am-next-permission s)
  (let ((waiting (am-get s 'waiting)))
    (if (null? waiting)
        (am-set s 'permission #f)
        (am-set (am-set s 'permission (car waiting)) 'waiting (cdr waiting)))))

(define (am-resolve-pending s option)
  (am-attention-resolved
   (am-next-permission (am-answer-permission s (am-get s 'permission) option))))

;; An answer names its request. The request that waits behind the first
;; one resolves alone and leaves the first one pending.
(define (am-resolve-permission s id option)
  (let ((p (am-get s 'permission)))
    (if (and p (equal? (am-perm-id p) id))
        (am-resolve-pending s option)
        (let ((hit (filter (lambda (w) (equal? (am-perm-id w) id)) (am-get s 'waiting))))
          (if (null? hit)
              s
              (am-set (am-answer-permission s (car hit) option) 'waiting
                      (filter (lambda (w) (not (eq? w (car hit)))) (am-get s 'waiting))))))))

(define (am-resolve-all-permissions s)
  (if (am-get s 'permission)
      (am-resolve-all-permissions (am-resolve-pending s #f))
      s))

(define (am-permissions s)
  (let ((p (am-get s 'permission)))
    (if p (cons p (am-get s 'waiting)) (am-get s 'waiting))))

;; --- questions ----------------------------------------------------------------
;; A pending question is (ID QUESTION ANSWERS OURS).

(define (am-resolve-question s id answer)
  (let ((q (am-get s 'question)))
    (if (not (and q (equal? (car q) id)))
        s
        (let ((s (if (cadddr q)
                     (am-fx s (list 'reply id (if answer (list 'ok answer) (list 'error 'cancelled))))
                     (am-fx s (list 'respond-question id answer)))))
          (am-attention-resolved
           (am-emit (am-set s 'question #f)
                    (list 'type 'question-answer 'id id 'answer (or answer "cancelled"))))))))

(define (am-cancel-question s)
  (let ((q (am-get s 'question)))
    (if q (am-resolve-question s (car q) #f) s)))

;; --- turns --------------------------------------------------------------------

(define (am-entry-wire e) (car e))
(define (am-entry-shown e) (or (cadr e) (car e)))

(define (am-send s text display images)
  (let* ((s (am-emit s (list 'type 'user-msg 'text (or display text))))
         ;; a backend that never answered the last cancel never will: drop
         ;; the debt, or the swallow would eat THIS turn's end instead
         (s (am-set s 'stale-ends 0))
         (s (am-disarm s 'settle))
         (s (am-disarm s 'silent))
         (s (am-set s 'steered #f))
         (s (am-disarm s 'idle))
         (s (am-emit (am-set s 'status 'running) (list 'type 'status 'status 'running)))
         (epoch (+ (am-get s 'epoch) 1)))
    (am-fx (am-set (am-set s 'epoch epoch) 'context-pending #t)
           (list 'fetch-context epoch text (or display text) images))))

(define (am-pop-queue s)
  (let ((queue (am-get s 'queue)))
    (if (and (pair? queue) (eq? (am-get s 'status) 'idle))
        (let ((next (car queue)))
          (am-send (am-set s 'queue (cdr queue)) (car next) (cadr next) (caddr next)))
        s)))

(define (am-finish-turn s event)
  ;; a turn that ends with a request still open (the agent gave up, the
  ;; wire died) resolves it cancelled: never a stuck banner
  (let* ((s (am-disarm s 'settle))
         (s (am-disarm s 'silent))
         (s (am-set s 'steered #f))
         (s (am-disarm s 'steer-settle))
         (s (am-set s 'queue (append (am-get s 'steering-queue) (am-get s 'queue))))
         (s (am-set s 'steering-queue '()))
         (s (am-set s 'queue (append (am-get s 'fallbacks) (am-get s 'queue))))
         (s (am-set s 'fallbacks '()))
         (s (am-resolve-all-permissions s))
         (s (am-cancel-question s))
         (s (am-emit s event))
         (s (am-status s 'idle)))
    (am-pop-queue s)))

(define (am-turn-end reason) (list 'type 'turn-end 'stop-reason reason))

;; A steered turn only. An ordinary ACP turn answers session/prompt at its
;; result, so it needs no net.
(define (am-arm-settle s)
  (let ((ms (am-get s 'settle-ms)))
    (if (and (am-get s 'steered) (eq? (am-get s 'status) 'running) (integer? ms) (> ms 0))
        (am-arm s 'settle ms (list 'settle-grace (am-get s 'epoch)))
        s)))

;; Every turn, every connector: the prompt is on the wire and the first
;; event has not come back yet.
(define (am-arm-silent s)
  (let ((ms (am-get s 'silent-ms)))
    (if (and (eq? (am-get s 'status) 'running) (integer? ms) (> ms 0))
        (am-arm s 'silent ms (list 'silent-turn (am-get s 'epoch)))
        s)))

;; --- steering -----------------------------------------------------------------
;; A committed push steer is (TOKEN TEXT DISPLAY EPOCH OUTCOME), OUTCOME
;; pending, accepted or fallback. The turn end waits until every one of
;; them is accepted or put back.

(define (am-settle-steering s event outcome)
  (let* ((token (am-pget event 'token))
         (epoch (am-pget event 'epoch))
         (entry (assoc token (am-get s 'steers)))
         (s (if (and entry (eq? (list-ref entry 4) 'pending)
                     (equal? (list-ref entry 3) epoch) (equal? epoch (am-get s 'epoch)))
                (am-set s 'steers (am-steer-outcome (am-get s 'steers) token outcome))
                s)))
    (am-finish-deferred (am-drain-steering s))))

(define (am-steer-outcome steers token outcome)
  (map (lambda (e) (if (equal? (car e) token)
                       (list (car e) (cadr e) (caddr e) (cadddr e) outcome)
                       e))
       steers))

(define (am-drain-steering s)
  (let ((order (am-get s 'steer-order)))
    (if (null? order)
        s
        (let* ((token (car order))
               (entry (assoc token (am-get s 'steers)))
               (rest (lambda (s)
                       (am-set (am-set s 'steer-order (cdr order)) 'steers
                               (filter (lambda (e) (not (equal? (car e) token))) (am-get s 'steers))))))
          (cond ((not entry) (am-drain-steering (am-set s 'steer-order (cdr order))))
                ((eq? (list-ref entry 4) 'pending) s)
                ((eq? (list-ref entry 4) 'accepted)
                 (am-drain-steering
                  (am-emit (rest s) (list 'type 'user-msg 'text (or (caddr entry) (cadr entry))))))
                (else
                 (am-drain-steering
                  (am-push (rest s) 'fallbacks (list (cadr entry) (caddr entry) '())))))))))

(define (am-finish-deferred s)
  (let ((event (am-get s 'turn-end)))
    (if (and event (null? (am-get s 'steer-order)))
        (am-finish-turn (am-set s 'turn-end #f) event)
        s)))

;; --- backend events -----------------------------------------------------------

;; Bookkeeping events say nothing about whether the turn still produces.
;; Every other event is output, so the adapter has not reached the result
;; a steered turn settles on, and the settle grace disarms.
(define am-settle-quiet
  '("context" "usage" "model-state" "mode-state" "status" "cycle-result"
    "steering-ready" "steering-disabled" "steering-accepted" "steering-fallback"))

(define (am-backend-event s event)
  (let* ((type (am-type event))
         (s (if (member type am-settle-quiet) s (am-disarm s 'settle)))
         ;; every event counts here: the silence watchdog asks only whether
         ;; the connector speaks at all
         (s (am-disarm s 'silent)))
    (am-apply-event s event type)))

(define (am-apply-event s event type)
  (cond
   ;; the terminal event of a turn this side already ended: swallowed once
   ((and (member type '("turn-end" "turn-failed")) (> (am-get s 'stale-ends) 0))
    (am-set s 'stale-ends (- (am-get s 'stale-ends) 1)))
   ((equal? type "cycle-result") (am-arm-settle s))
   ((equal? type "steering-ready") (am-set s 'steering 'push))
   ((equal? type "steering-disabled") (am-set s 'steering 'none))
   ((equal? type "steering-accepted") (am-settle-steering (am-set s 'steered #t) event 'accepted))
   ((equal? type "steering-fallback") (am-settle-steering s event 'fallback))
   ((equal? type "ready") (am-pop-queue (am-status s 'idle)))
   ((equal? type "turn-failed") (am-apply-event s (am-turn-end "error") "turn-end"))
   ((equal? type "turn-end")
    ;; A transport may report completion before its steering reply. Keep
    ;; the turn open until every committed steer is accepted or put back,
    ;; under a fresh timer stamped with the current epoch.
    (if (null? (am-get s 'steer-order))
        (am-finish-turn s event)
        (am-set (am-arm (am-disarm s 'steer-settle) 'steer-settle 2000
                        (list 'steer-settle (am-get s 'epoch)))
                'turn-end event)))
   ((equal? type "permission")
    (let ((options (am-pget event 'options)))
      (am-emit (am-status (am-add-permission
                           s (list (am-pget event 'rpc-id) (am-pget event 'title)
                                   (am-pget event 'kind) (if (list? options) options '()) #f))
                          'needs_attention)
               event)))
   ((equal? type "question")
    (let ((answers (am-pget event 'answers)))
      (am-emit (am-status (am-set s 'question
                                  (list (am-pget event 'id) (am-pget event 'question)
                                        (if (list? answers) answers '()) #f))
                          'needs_attention)
               event)))
   ;; the backend named its session: kept for the next adapter
   ((equal? type "session") (am-emit (am-set s 'resume (am-pget event 'id)) event))
   ;; the thread stays registered so the transcript keeps working
   ((equal? type "dead") (am-emit (am-set (am-disarm s 'idle) 'status 'dead) event))
   (else (am-emit s event))))

;; --- calls --------------------------------------------------------------------

(define (am-running? s) (memq (am-get s 'status) '(running needs_attention)))

(define (am-prompt s text display images)
  (let ((q (am-get s 'question)) (status (am-get s 'status)))
    (cond (q (am-reply (am-resolve-question s (car q) (or display text)) 'answered))
          ;; parked: open a new adapter on the old session; the prompt
          ;; waits in the queue until it is ready
          ((and (am-get s 'parked) (eq? status 'idle))
           (am-reply (am-push (am-status (am-fx (am-set s 'parked #f) (list 'revive (am-get s 'resume)))
                                         'starting)
                              'queue (list text display images))
                     'queued))
          ((eq? status 'idle) (am-reply (am-send s text display images) 'sent))
          ((eq? status 'dead) (am-reply s '(error dead)))
          (else (am-reply (am-push s 'queue (list text display images)) 'queued)))))

;; steering joins a turn already in flight, where only text can land
(define (am-take-steering s)
  (let ((queue (am-get s 'steering-queue)))
    (if (and (pair? queue) (am-running? s))
        (am-reply (am-set (am-fold (lambda (s e) (am-emit s (list 'type 'user-msg 'text (am-entry-shown e))))
                                     s queue)
                          'steering-queue '())
                  (map (lambda (e) (list (car e) (cadr e))) queue))
        (am-reply s '()))))

;; A turn whose end already arrived takes no steer: the message stays in
;; the queue and runs as its own turn.
(define (am-steer-next s)
  (let ((queue (am-get s 'queue)) (mode (am-get s 'steering)))
    (cond ((am-get s 'turn-end) (am-reply s '(error turn_ending)))
          ((and (am-running? s) (eq? mode 'push) (pair? queue))
           (am-reply s (list 'steer (am-get s 'next-steer) (car (car queue)) (cadr (car queue))
                             (am-get s 'epoch))))
          ((and (am-running? s) (eq? mode 'boundary) (pair? queue))
           (am-reply (am-push (am-set s 'queue (cdr queue)) 'steering-queue (car queue)) 'sent))
          ((eq? mode 'none) (am-reply s '(error unsupported)))
          ((null? queue) (am-reply s '(error empty)))
          (else (am-reply s '(error not_running))))))

(define (am-steered s token result)
  (if (not (eq? result 'ok))
      (am-reply s result)
      (let ((head (car (am-get s 'queue))))
        (am-reply (am-push (am-push (am-set (am-set s 'queue (cdr (am-get s 'queue))) 'next-steer (+ token 1))
                                    'steers (list token (car head) (cadr head) (am-get s 'epoch) 'pending))
                           'steer-order token)
                  'sent))))

(define (am-queue-split queue text)
  (let loop ((before '()) (rest queue))
    (cond ((null? rest) #f)
          ((equal? (am-entry-shown (car rest)) text) (list (reverse before) (car rest) (cdr rest)))
          (else (loop (cons (car rest) before) (cdr rest))))))

(define (am-dequeue s text)
  (let ((hit (am-queue-split (am-get s 'queue) text)))
    (if hit
        (am-reply (am-set s 'queue (append (car hit) (caddr hit))) 'ok)
        (am-reply s '(error not_found)))))

(define (am-promote s text)
  (let ((hit (am-queue-split (am-get s 'queue) text)))
    (if hit
        (am-reply (am-set s 'queue (cons (cadr hit) (append (car hit) (caddr hit)))) 'ok)
        (am-reply s '(error not_found)))))

;; Abort means the whole pending run list. Advancing the epoch discards a
;; context fetch for the cancelled turn. The turn ends HERE: a cancel that
;; only asks is one a wedged adapter can ignore.
(define (am-cancel s)
  (if (am-get s 'parked)
      (am-reply s 'ok)
      (let* ((pending (am-get s 'context-pending))
             (deferred (am-get s 'turn-end))
             (s (am-disarm s 'steer-settle))
             (s (am-fold (lambda (s kv) (am-set s (car kv) (cadr kv))) s
                           (list (list 'queue '()) (list 'steering-queue '()) (list 'steers '())
                                 (list 'steer-order '()) (list 'fallbacks '()) (list 'turn-end #f)
                                 (list 'epoch (+ (am-get s 'epoch) 1)) (list 'context-pending #f))))
             (s (am-cancel-question s)))
        (am-reply
         (cond (deferred (am-finish-turn s deferred))
               (pending (am-status (am-emit s (am-turn-end "cancelled")) 'idle))
               ((am-running? s)
                (am-finish-turn (am-set (am-fx s '(cancel)) 'stale-ends (+ (am-get s 'stale-ends) 1))
                                (am-turn-end "cancelled")))
               (else s))
         'ok))))

(define am-editor-options
  '(("allow" "Allow" "allow_once") ("always" "Always" "allow_always") ("deny" "Deny" "reject_once")))

;; a backend that runs its own turns asks US; the verdict comes when the
;; banner, a deadline or a close resolves the slot
(define (am-ask-permission s title kind raw ms)
  (let* ((id (am-get s 'next-rpc))
         (s (am-set s 'next-rpc (+ id 1)))
         (s (if (integer? ms) (am-fx s (list 'after ms (list 'permission-timeout id))) s)))
    (am-reply
     (am-emit (am-status (am-add-permission s (list id title kind am-editor-options #t)) 'needs_attention)
              ;; editor: the card shows, and no chat policy answers it
              (list 'type 'permission 'rpc-id id 'title title 'kind kind 'raw raw
                    'options am-editor-options 'editor #t))
     (list 'defer id))))

(define (am-ask-user s question answers)
  (if (am-get s 'question)
      (am-reply s '(error question_already_pending))
      (let ((id (am-get s 'next-rpc)))
        (am-reply
         (am-emit (am-status (am-set (am-set s 'next-rpc (+ id 1)) 'question (list id question answers #t))
                             'needs_attention)
                  (list 'type 'question 'id id 'question question 'answers answers))
         (list 'defer id)))))

(define (am-permission-timeout s id)
  (let ((hit (filter (lambda (p) (equal? (am-perm-id p) id)) (am-permissions s))))
    (if (null? hit)
        s
        (am-resolve-permission
         (am-emit s (list 'type 'permission-timeout 'title (am-perm-title (car hit))))
         id #f))))

(define (am-context s epoch outcome a b)
  (cond ((not (equal? epoch (am-get s 'epoch))) s)
        ((eq? outcome 'ok)
         (let* ((s (am-fx (am-set s 'context-pending #f) '(prompt)))
                (s (if (and (integer? a) (>= a 0)) (am-set s 'settle-ms (* a 1000)) s))
                (s (if (and (integer? b) (>= b 0)) (am-set s 'silent-ms (* b 1000)) s)))
           (am-arm-silent s)))
        (else
         (am-pop-queue (am-status (am-emit (am-set s 'context-pending #f) (list 'type 'error 'text a))
                                  'idle)))))

;; The steered turn produced its result and then said nothing, or the
;; connector took the prompt and said nothing at all. Either turn never
;; closes itself: end it HERE and tell the adapter to drop it.
(define (am-recover s epoch timer kind ms-key reason)
  (let ((s (am-fired s timer)))
    (if (and (equal? epoch (am-get s 'epoch)) (eq? (am-get s 'status) 'running))
        (am-finish-turn
         (am-set (am-emit (am-fx s '(cancel)) (list 'type kind 'seconds (quotient (am-get s ms-key) 1000)))
                 'stale-ends (+ (am-get s 'stale-ends) 1))
         (am-turn-end reason))
        s)))

;; The turn is confirmed complete, so an unacknowledged steer can no
;; longer be trusted as delivered: every unresolved one goes back.
(define (am-steer-settle s epoch)
  (let ((s (am-fired s 'steer-settle)))
    (if (and (equal? epoch (am-get s 'epoch)) (am-get s 'turn-end))
        (am-finish-deferred
         (am-drain-steering
          (am-set s 'steers (map (lambda (e) (if (eq? (list-ref e 4) 'pending)
                                                 (list (car e) (cadr e) (caddr e) (cadddr e) 'fallback)
                                                 e))
                                 (am-get s 'steers)))))
        s)))

(define (am-idle-park s)
  (let ((s (am-fired s 'idle)))
    (if (am-parkable? s) (am-fx (am-set s 'parked #t) '(park)) s)))

(define (am-dispatch s msg)
  (let ((kind (car msg)) (args (cdr msg)))
    (cond
     ((eq? kind 'backend-event) (am-backend-event s (car args)))
     ((eq? kind 'prompt) (am-prompt s (car args) (cadr args) (caddr args)))
     ((eq? kind 'take-steering) (am-take-steering s))
     ((eq? kind 'steer-next) (am-steer-next s))
     ((eq? kind 'steered) (am-steered s (car args) (cadr args)))
     ((eq? kind 'dequeue) (am-dequeue s (car args)))
     ((eq? kind 'promote) (am-promote s (car args)))
     ((eq? kind 'cancel) (am-cancel s))
     ((eq? kind 'ask-permission) (am-ask-permission s (car args) (cadr args) (caddr args) (cadddr args)))
     ((eq? kind 'respond-permission) (am-reply (am-resolve-permission s (car args) (cadr args)) 'ok))
     ((eq? kind 'permission-deadline)
      (let ((p (am-get s 'permission)))
        (am-reply (if p (am-fx s (list 'after (car args) (list 'permission-timeout (am-perm-id p)))) s) 'ok)))
     ((eq? kind 'permission-timeout) (am-permission-timeout s (car args)))
     ((eq? kind 'ask-user) (am-ask-user s (car args) (cadr args)))
     ((eq? kind 'respond-question) (am-reply (am-resolve-question s (car args) (cadr args)) 'ok))
     ((eq? kind 'context) (am-context s (car args) (cadr args) (caddr args)
                                      (if (pair? (cdddr args)) (cadddr args) #f)))
     ((eq? kind 'settle-grace) (am-recover s (car args) 'settle 'turn-settled 'settle-ms "end_turn"))
     ((eq? kind 'silent-turn) (am-recover s (car args) 'silent 'turn-silent 'silent-ms "error"))
     ((eq? kind 'steer-settle) (am-steer-settle s (car args)))
     ((eq? kind 'idle-park) (am-idle-park s))
     ((eq? kind 'terminate) (am-cancel-question (am-resolve-all-permissions s)))
     (else s))))

(define (agent-step s msg)
  "one message in: (STATE REPLY EFFECTS)"
  (let ((s (am-dispatch (am-set (am-set s 'fx '()) 'reply 'ok) msg)))
    (list (am-set (am-set s 'fx '()) 'reply 'ok) (am-get s 'reply) (reverse (am-get s 'fx)))))

;; --- what the thread reports ------------------------------------------------

(define (agent-machine-info s)
  "the thread's state as a plist, for agent-info"
  (let ((p (am-get s 'permission)) (q (am-get s 'question)))
    (list 'status (am-get s 'status)
          'parked (am-get s 'parked)
          'session (am-get s 'resume)
          'queued (+ (length (am-get s 'queue)) (length (am-get s 'steering-queue))
                     (length (am-get s 'steers)) (length (am-get s 'fallbacks)))
          'steering (not (eq? (am-get s 'steering) 'none))
          'ending (if (am-get s 'turn-end) #t #f)
          'settling (if (am-armed? s 'settle) #t #f)
          'silent (if (am-armed? s 'silent) #t #f)
          'steers (length (am-get s 'steer-order))
          'permission (if p (list (car p) (cadr p) (cadddr p)) #f)
          'question (if q (list (car q) (cadr q) (caddr q)) #f))))

;; adjacent chunks melt into one append; a Codex tool item gets its card fields
(define (agent-coalesce events)
  "EVENTS with each run of adjacent text chunks joined into one"
  (reverse
   (am-fold (lambda (acc e)
              (if (and (pair? acc) (am-chunk? e) (am-chunk? (car acc)))
                  (cons (list 'type 'chunk 'text (string-append (cadddr (car acc)) (cadddr e))) (cdr acc))
                  (cons (am-codex-item e) acc)))
            '() events)))

(define (am-str v dflt) (if (string? v) v dflt))

;; Codex sends a tool item raw (codex_app_server.ex); its card's title, kind
;; and bare tool name are made here, as an ACP adapter names its own. A name
;; only where the title IS the tool name: command and file items already
;; title with their argument.
(define (codex-item-fields item-json)
  "(codex-item-fields ITEM-JSON) - a Codex tool item's card fields: (title T kind K [name N])"
  (let* ((item (or (ignore-errors (lambda () (json-parse item-json))) '()))
         (type (am-str (plist-get item 'type) ""))
         (tool (plist-get item 'tool))
         (mcp (string-append (am-str (plist-get item 'server) "mcp") "/" (am-str tool "tool")))
         (paths (filter (lambda (p) (not (equal? p "")))
                        (map (lambda (c) (am-str (plist-get c 'path) ""))
                             (or (plist-get item 'changes) '()))))
         (title (cond ((equal? type "commandExecution") (am-str (plist-get item 'command) "command"))
                      ((equal? type "fileChange")
                       (if (null? paths) "Edit files" (string-append "Edit " (string-join paths ", "))))
                      ((equal? type "mcpToolCall") mcp)
                      ((equal? type "dynamicToolCall") (am-str tool "tool"))
                      ((equal? type "webSearch") (string-append "Search: " (am-str (plist-get item 'query) "")))
                      ((equal? type "imageView") (string-append "View " (am-str (plist-get item 'path) "image")))
                      ((equal? type "collabAgentToolCall") (am-str tool "agent"))
                      (else "tool")))
         (kind (cond ((equal? type "commandExecution") "execute")
                     ((equal? type "fileChange") "edit")
                     ((equal? type "mcpToolCall") "mcp")
                     ((equal? type "webSearch") "search")
                     (else type)))
         (name (cond ((equal? type "mcpToolCall") mcp)
                     ((member type '("dynamicToolCall" "collabAgentToolCall")) tool)
                     (else #f))))
    (append (list 'title title 'kind kind) (if (string? name) (list 'name name) '()))))

;; a tool-call takes every field; a tool-update only the name that
;; agent-tool-refine! retitles from
(define (am-codex-item e)
  (let ((item (and (list? e) (plist-get e 'item))))
    (if (not (string? item))
        e
        (let ((f (codex-item-fields item))
              (rest (let loop ((ps e) (acc '()))
                      (cond ((or (null? ps) (null? (cdr ps))) (reverse acc))
                            ((eq? (car ps) 'item) (loop (cddr ps) acc))
                            (else (loop (cddr ps) (cons (cadr ps) (cons (car ps) acc))))))))
          (cond ((eq? (plist-get e 'type) 'tool-call) (append rest f))
                ((plist-get f 'name) (append rest (list 'name (plist-get f 'name))))
                (else rest))))))

(define (am-chunk? e)
  (and (list? e) (= (length e) 4) (eq? (car e) 'type) (eq? (cadr e) 'chunk)
       (eq? (caddr e) 'text) (string? (cadddr e))))

(public! 'agent-step "(agent-step STATE MSG) - one message to an agent thread: (STATE REPLY EFFECTS)")
(public! 'agent-machine-new "(agent-machine-new STEERING IDLE-MS STATELESS) - a new thread's state")
(public! 'agent-machine-info "(agent-machine-info STATE) - the thread's state as a plist")
(public! 'agent-coalesce "(agent-coalesce EVENTS) - adjacent text chunks joined into one")
(public! 'codex-item-fields "(codex-item-fields ITEM-JSON) - a Codex tool item's card fields: (title T kind K [name N])")
