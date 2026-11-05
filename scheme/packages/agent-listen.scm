;;; agent-listen.scm --- an agent waits for an event: a WhatsApp reply, a mail.
;;;
;;; (agent-listen! SPEC [NOTE]) from a chat makes the chat's agent listen.
;;; When an event that SPEC names lands in the log, the agent gets it as a
;;; message and decides what it means: the answer it waited for, or not
;;; yet. A task that the agent parked with todo-wait wakes because its
;;; agent does; the task stays the record, and the agent moves it.
;;;
;;; SPEC is a plist:
;;;
;;;   topic "whatsapp:919902020677"   the topic, or a prefix ending in *
;;;   kind received                   only events of this kind
;;;   match "Vipul"                   only events whose data holds this text
;;;   task ID                         the task the agent waits on, for its brief
;;;   keep #t                         listen on after the first event
;;;   days 3 / due SECS               when it is due; past due, the daily sweep looks again
;;;   at "2026-10-27 10:00" / SECS     wake at this local time; no topic needed
;;;   chat CHAT                       a chat other than the one it runs in
;;;
;;; One workflow, agent-listen, carries every listener (workflows.scm). It
;;; listens to the listeners' topics and keeps its place in the log, so an
;;; event that came while the editor was down arrives after the restart. A
;;; listener takes only the events after it was made. A sleeping or killed
;;; chat is woken for its event. A wake that fails fails the batch, and the
;;; workflow runs it again with a backoff; after the last try the batch is
;;; parked on workflow:agent-listen. An at listener publishes its own event
;;; on time:ID when the time comes; its timer is armed again at boot, and
;;; fires at once when the time passed while the editor was down.
;;; agent-listen-file keeps the listeners.

(require 'workflows)

(domain! 'chat)
(effects! '(pure))

(defcustom 'agent-listen-file (string-append (compos-home) "/agent-listeners.scd")
  "The file that keeps the agents' event listeners, one form each. Not .scm: hotload evaluates a .scm saved under ~/.compos.")

(defcustom 'agent-listen-default-days 3
  "How long a listener waits before it is due, when its SPEC names no due or days. M-x watchers-sweep looks again at the ones past due.")

;; (id ID chat CHAT-ID topic T kind K match M note N task ID keep B since SEQ created SECS due SECS)
(defvar '*agent-listeners* '())

(define (agent-listen--name id) (string-append "agent-listen:" id))

(define (agent-listen--blank? s) (or (not s) (and (string? s) (equal? (string-trim s) ""))))

(define (agent-listen--find id)
  (let ((hit (filter (lambda (l) (equal? (plist-get l 'id) id)) *agent-listeners*)))
    (and (pair? hit) (car hit))))

;; the open chat whose stable id is ID, or #f
(define (agent-listen--chat id)
  ;; asleep ones too: an event must wake its chat
  (let ((hit (chat-list (list 'chat-ids (list id)))))
    (and (pair? hit) (car hit))))

;; a chat buffer, a chat id or an agent id, as the chat's stable id
(define (agent-listen--chat-id who)
  (cond ((not who) (buffer-local (current-buffer) 'chat-id))
        ((string-prefix? "chat:" who) who)
        ((string-prefix? "agent:chat-" who)
         (let ((parts (string-split (substring who 11 (string-length who)) "-")))
           (and (= (length parts) 2) (string-append "chat:" (car parts) ":" (cadr parts)))))
        ((buffer-exists? who) (buffer-local who 'chat-id))
        (else #f)))

(define (agent-listen--wants? l e)
  (let ((kind (plist-get l 'kind)) (match (plist-get l 'match)))
    (and (or (not kind) (equal? kind (format "~a" (plist-get e 'kind))))
         (or (agent-listen--blank? match)
             (string-contains? (string-downcase (format "~s" (plist-get e 'data)))
                               (string-downcase match))))))

(define (agent-listen--who e)
  (let ((d (plist-get e 'data)))
    (and (pair? d)
         (let ((names (filter (lambda (s) (not (agent-listen--blank? s)))
                              (map (lambda (k) (let ((v (plist-get d k))) (and (string? v) v)))
                                   '(chat-name from sender-name phone)))))
           (and (pair? names) (car names))))))

;; what the agent reads when its event lands
(define (agent-listen--brief l e)
  (let ((id (plist-get l 'id)) (who (agent-listen--who e)))
    (string-append
      "[event] What you were listening for arrived: "
      (if (agent-listen--blank? (plist-get l 'note)) (plist-get l 'topic) (plist-get l 'note))
      (if (agent-listen--blank? (plist-get l 'task)) "" (string-append " (task " (plist-get l 'task) ")"))
      "\n" (plist-get e 'topic) " " (format "~a" (plist-get e 'kind))
      (if who (string-append " from " who) "")
      "\n\n" (event-text e) "\n\n"
      (if (plist-get l 'keep)
          (string-append "Listener " id " listens on; (agent-unlisten! \"" id "\") stops it.")
          "That listener is closed. Decide whether this is the answer: carry on with the task, or (agent-listen! SPEC NOTE) again."))))

(effects! '(write))

(define (agent-listen--save!)
  (write-file! agent-listen-file
    (string-append ";; agent listeners: agent-listen! keeps this file. One listener a form.\n"
                   (apply string-append
                          (map (lambda (l) (string-append (format "~s" l) "\n")) *agent-listeners*))))
  ;; a task's page lists what its agent listens for
  (for-each (lambda (b) (when (equal? (buffer-local b 'mode-name) "todo-detail-mode")
                          (todo--detail-render! b)))
            (buffer-list)))

(define (agent-listen--load!)
  (set! *agent-listeners*
        (if (file-exists? agent-listen-file)
            (filter (lambda (l) (and (pair? l) (string? (plist-get l 'id))))
                    (or (scheme-read (read-file agent-listen-file)) '()))
            '())))

(define (agent-listen--put! l)
  (set! *agent-listeners*
        (append (filter (lambda (x) (not (equal? (plist-get x 'id) (plist-get l 'id)))) *agent-listeners*)
                (list l)))
  (agent-listen--save!))

;; what happened to a listener goes in the log as agent-listen:ID, so M-x
;; watchers can show every listener and its firings after it is gone. The
;; publish waits for the delivery in hand to end
(define (agent-listen--record! l what &optional e)
  (let ((id (plist-get l 'id))
        (data (list 'id (plist-get l 'id) 'chat (plist-get l 'chat) 'topic (plist-get l 'topic)
                    'only-kind (plist-get l 'kind) 'match (plist-get l 'match) 'note (plist-get l 'note)
                    'task (plist-get l 'task) 'keep (plist-get l 'keep) 'created (plist-get l 'created)
                    'due (plist-get l 'due)
                    'event-seq (and e (plist-get e 'seq)) 'event-topic (and e (plist-get e 'topic))
                    'from (and e (agent-listen--who e)))))
    (debounce! (string->symbol (string-append "agent-listen-record:" id ":" (symbol->string what) ":"
                                              (number->string (if e (plist-get e 'seq) 0))))
               0
               (lambda (_)
                 (event-publish! (agent-listen--name id) what data)
                 (let ((task (plist-get l 'task)))
                   (when (and e (not (agent-listen--blank? task)) (todo-get task))
                     (todo-log task (string-append "watcher " id " fired: " (plist-get e 'topic)
                                                   (let ((who (agent-listen--who e))) (if who (string-append " from " who) "")))
                               "watcher"))))
               #f)))

;; "YYYY-MM-DD HH:MM" in local time, or unix seconds, as unix seconds
(define (agent-listen--at at)
  (cond ((not at) #f)
        ((number? at) at)
        (else
         (let* ((dt (string-split (string-trim at) " "))
                (d (map string->number (string-split (car dt) "-")))
                (t (if (pair? (cdr dt)) (map string->number (string-split (cadr dt) ":")) '(0 0))))
           (unless (and (= (length d) 3) (= (length t) 2) (not (memv #f (append d t))))
             (error "agent-listen!: at wants \"YYYY-MM-DD HH:MM\" or unix seconds"))
           (parts->time (car d) (cadr d) (caddr d) (car t) (cadr t))))))

;; an at listener's timer publishes on its topic when the time comes; a
;; long wait sleeps in steps a timer can hold
(define (agent-listen--arm! l)
  (let ((at (plist-get l 'at)))
    (when at
      (debounce! (string->symbol (string-append "agent-listen-at:" (plist-get l 'id)))
                 (* 1000 (min 86400 (max 0 (- at (current-time)))))
                 (lambda (id)
                   (let ((l (agent-listen--find id)))
                     (when l
                       (if (< (current-time) (plist-get l 'at))
                           (agent-listen--arm! l)
                           (event-publish! (plist-get l 'topic) 'due
                                           (list 'at (format-time (plist-get l 'at) "%Y-%m-%d %H:%M")
                                                 'task (plist-get l 'task)))))))
                 (plist-get l 'id)))))

;; the brief goes before the listener closes: an agent that cannot start
;; (a spawn that fails, a dead backend) raises, and the event then waits in
;; the listener for a retry instead of being lost

(define (agent-listen--archive-group path)
  ;; .../groups/grp-SECS-N/chats/X.chat names its group grp:SECS:N
  (let ((tail (member "groups" (string-split path "/"))))
    (and tail (pair? (cdr tail))
         (string-join (string-split (cadr tail) "-") ":"))))

(define (agent-listen--wake-chat l)
  ;; the listener's chat; a killed one is read back from its archive in its
  ;; own group, shown nowhere, so the event wakes it and it is in the chat list
  (let ((chat (plist-get l 'chat)))
    (or (agent-listen--chat chat)
        (and (boundp 'todo--archived-chat)
             (report-errors "agent-listen: reopen the archived chat"
               (lambda ()
                 (let ((path (todo--archived-chat chat)))
                   (and path (todo--open-chat chat (agent-listen--archive-group path))))))))))

(define agent-listen--workflow "agent-listen")

;; the listener id and event seq of each wake this session made: a batch
;; that runs again must not wake a chat twice for one event
(defvar '*agent-listen-sent* '())

(define (agent-listen--sent-key l e)
  (string-append (plist-get l 'id) ":" (number->string (plist-get e 'seq))))

;; one group a batch, so the events go to the chats in the order they came
(define (agent-listen--batch-key e) 'all)

;; #t when L takes E: its topic, after L was made, its kind and its match
(define (agent-listen--takes? l e)
  (and (event-topic-match? (plist-get l 'topic) (plist-get e 'topic))
       (> (plist-get e 'seq) (or (plist-get l 'since) 0))
       (agent-listen--wants? l e)
       (not (member (agent-listen--sent-key l e) *agent-listen-sent*))))

;; wake L's chat with E; #f when the chat is there and could not take it,
;; so the batch runs again
(define (agent-listen--sent! l e)
  (set! *agent-listen-sent* (take (cons (agent-listen--sent-key l e) *agent-listen-sent*) 500)))

(define (agent-listen--deliver! l e)
  (let ((buf (agent-listen--wake-chat l)))
    (cond ((not buf)
           ;; no chat and no archive: a retry finds nothing either
           (agent-listen--sent! l e)
           (agent-listen--record! l 'undelivered e)
           #t)
          ((report-errors "agent-listen: wake the chat" (lambda () (agent-wake! buf 'event (agent-listen--brief l e)) #t))
           (agent-listen--sent! l e)
           (agent-listen--record! l 'fired e)
           (unless (plist-get l 'keep) (agent-listen--drop! (plist-get l 'id)))
           #t)
          (else #f))))

;; the workflow's handler: every event of the batch to every listener that
;; takes it. A wake that failed fails the batch, and the workflow runs it
;; again after a backoff; the wakes that landed are not made again
(define (agent-listen--handle key events)
  (let ((failed 0))
    (for-each
      (lambda (e)
        (for-each (lambda (l)
                    ;; a listener that fired and closed earlier in the batch is gone
                    (when (and (agent-listen--find (plist-get l 'id)) (agent-listen--takes? l e))
                      (unless (agent-listen--deliver! l e) (set! failed (+ failed 1)))))
                  *agent-listeners*))
      events)
    (when (> failed 0)
      (error (string-append "agent-listen: " (number->string failed) " wake(s) failed; the batch runs again")))))

;; every listener's topic, once each; none when no one listens
(define (agent-listen--topics)
  (let loop ((ls *agent-listeners*) (acc '()))
    (cond ((null? ls) (reverse acc))
          ((member (plist-get (car ls) 'topic) acc) (loop (cdr ls) acc))
          (else (loop (cdr ls) (cons (plist-get (car ls) 'topic) acc))))))

;; one workflow carries every listener; FROM is where a new one starts
(define (agent-listen--define! &optional from)
  (define-workflow! agent-listen--workflow
    'listen (agent-listen--topics)
    'handle 'agent-listen--handle
    'group-by 'agent-listen--batch-key
    'quiet 50 'max-wait 500 'max-attempts 8
    'from from))

(define (agent-listen! spec &optional note)
  "(agent-listen! SPEC [NOTE]) — make this chat's agent listen for an event; answer the listener's id. SPEC is a plist: topic (required unless at; a trailing * matches a prefix), kind, match (text the event's data must hold), task, keep, chat, at (\"YYYY-MM-DD HH:MM\" local, or unix seconds: wake then)"
  (let ((at (agent-listen--at (plist-get spec 'at)))
        (chat (agent-listen--chat-id (plist-get spec 'chat))))
    (when (and (not at) (agent-listen--blank? (plist-get spec 'topic)))
      (error "agent-listen!: SPEC needs a topic, such as \"whatsapp:919902020677\", or an at"))
    (unless chat
      (error "agent-listen!: run it from a chat, or name one with 'chat"))
    (let* ((id (string-append "l" (number->string (current-time)) "-" (number->string (random 10000))))
           (topic (if at (string-append "time:" id) (plist-get spec 'topic)))
           (kind (plist-get spec 'kind))
           (l (list 'id id 'chat chat 'topic topic
                    'kind (and kind (format "~a" kind))
                    'match (plist-get spec 'match) 'note note 'task (plist-get spec 'task)
                    'keep (and (not at) (plist-get spec 'keep) #t) 'since (event-log-seq) 'created (current-time)
                    'at at
                    'due (or at (plist-get spec 'due)
                             (+ (current-time) (* 86400 (or (plist-get spec 'days) agent-listen-default-days)))))))
      (agent-listen--put! l)
      (agent-listen--define!)
      (agent-listen--arm! l)
      (agent-listen--record! l 'created)
      id)))

(define (agent-listen-extend! id days)
  "(agent-listen-extend! ID DAYS) — the listener ID is due DAYS from now; it listens on as it did"
  (let ((l (agent-listen--find id)))
    (when l
      (let ((l (plist-put l 'due (+ (current-time) (* 86400 days)))))
        (agent-listen--put! l)
        (agent-listen--record! l 'extended)))
    id))

(define (agent-listen-cancel! id)
  "(agent-listen-cancel! ID) — stop the listener ID by hand, and say so in the log"
  (agent-unlisten! id))

;; every stop but a firing says so in the log, so M-x watchers shows why a
;; listener went
(define (agent-unlisten! id)
  "(agent-unlisten! ID) — stop the listener ID, and say so in the log"
  (let ((l (agent-listen--find id)))
    (when l (agent-listen--record! l 'cancelled))
    (agent-listen--drop! id)))

(define (agent-listen--drop! id)
  (set! *agent-listeners* (filter (lambda (l) (not (equal? (plist-get l 'id) id))) *agent-listeners*))
  (agent-listen--save!)
  (debounce-cancel! (string->symbol (string-append "agent-listen-at:" id)))
  ;; the workflow stops listening to a topic no listener names
  (agent-listen--define!)
  id)

(effects! '(read))

(define (agent-listen-due l)
  "(agent-listen-due L) — when the listener L is due, in unix seconds; one made before due times counts from its creation"
  (or (plist-get l 'due) (+ (or (plist-get l 'created) 0) (* 86400 agent-listen-default-days))))

(define (agent-listeners &optional chat)
  "(agent-listeners [CHAT]) — the listeners, each a plist; only CHAT's when given"
  (let ((id (and chat (agent-listen--chat-id chat))))
    (filter (lambda (l) (or (not id) (equal? (plist-get l 'chat) id))) *agent-listeners*)))

(public! 'agent-listen! "(agent-listen! SPEC [NOTE]) — make this chat's agent listen for an event, such as a WhatsApp reply, or wake at a time; it gets the event as a message. SPEC: topic, kind, match, task, keep, chat, at (\"YYYY-MM-DD HH:MM\" local)")
(public! 'agent-unlisten! "(agent-unlisten! ID) — stop the listener ID, and say so in the log")
(public! 'agent-listen-extend! "(agent-listen-extend! ID DAYS) — the listener ID is due DAYS from now")
(public! 'agent-listen-due "(agent-listen-due L) — when the listener L is due, in unix seconds")
(public! 'agent-listen-cancel! "(agent-listen-cancel! ID) — stop the listener ID by hand, and say so in the log")
(public! 'agent-listeners "(agent-listeners [CHAT]) — the listeners, each a plist; only CHAT's when given")

(effects! '(write))

;; listeners made before the workflow carried them were subscribers of
;; their own, agent-listen:ID, with a list of pending seqs: each takes the
;; events after the oldest of those, and its subscriber goes
(define (agent-listen--migrate!)
  (let ((old (filter (lambda (l) (not (plist-get l 'since))) *agent-listeners*)))
    (for-each
      (lambda (l)
        (let* ((name (agent-listen--name (plist-get l 'id)))
               (pending (or (plist-get l 'pending) '()))
               (since (if (pair? pending)
                          (- (apply min pending) 1)
                          (or (event-position name) (event-log-seq)))))
          (event-unsubscribe! name)
          (set! *agent-listeners*
                (map (lambda (x) (if (equal? (plist-get x 'id) (plist-get l 'id))
                                     (plist-put (plist-put x 'since since) 'pending '())
                                     x))
                     *agent-listeners*))))
      old)
    (when (pair? old) (agent-listen--save!))))

;; where a new workflow starts: before the oldest listener, so none misses
;; what came while the editor was down
(define (agent-listen--oldest-since)
  (let ((seqs (filter number? (map (lambda (l) (plist-get l 'since)) *agent-listeners*))))
    (and (pair? seqs) (apply min seqs))))

;; the workflow starts once the boot ends, as todo.scm's first scan does
(debounce! 'agent-listen-boot 0
           (lambda (_)
             ;; each step on its own: a step that fails must not leave the
             ;; listeners deaf, as a failed subscribe once did
             (agent-listen--load!)
             (report-errors "agent-listen: the old listeners did not migrate"
               (lambda () (agent-listen--migrate!)))
             (agent-listen--define! (agent-listen--oldest-since))
             (for-each (lambda (l) (report-errors "agent-listen: arm a listener" (lambda () (agent-listen--arm! l))))
                       *agent-listeners*))
           #f)
