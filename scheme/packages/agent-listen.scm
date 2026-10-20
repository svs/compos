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
;;;   chat CHAT                       a chat other than the one it runs in
;;;
;;; Each listener is a subscriber of its own, agent-listen:ID, so it keeps
;;; its place in the log: an event that came while the editor was down
;;; arrives after the restart. agent-listen-file keeps the listeners. An
;;; event for a chat that is not open waits in its listener until the chat
;;; opens.

(domain! 'chat)
(effects! '(pure))

(defcustom 'agent-listen-file (string-append (compos-home) "/agent-listeners.scm")
  "The file that keeps the agents' event listeners, one form each.")

;; (id ID chat CHAT-ID topic T kind K match M note N task ID keep B pending SEQS created SECS)
(defvar '*agent-listeners* '())

(define (agent-listen--name id) (string-append "agent-listen:" id))

(define (agent-listen--blank? s) (or (not s) (and (string? s) (equal? (string-trim s) ""))))

(define (agent-listen--find id)
  (let ((hit (filter (lambda (l) (equal? (plist-get l 'id) id)) *agent-listeners*)))
    (and (pair? hit) (car hit))))

;; the open chat whose stable id is ID, or #f
(define (agent-listen--chat id)
  (let ((hit (filter (lambda (b) (equal? (buffer-local b 'chat-id) id)) (buffer-list))))
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

;; the event SEQ, read back from the log for a chat that was not open
(define (agent-listen--event l seq)
  (let ((r (event-log-read (- seq 1) (plist-get l 'topic) 1)))
    (and (pair? r) (equal? (plist-get (car r) 'seq) seq) (car r))))

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
                          (map (lambda (l) (string-append (format "~s" l) "\n")) *agent-listeners*)))))

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

(define (agent-listen--deliver! l buf e)
  (unless (plist-get l 'keep) (agent-unlisten! (plist-get l 'id)))
  (agent-continue! buf (agent-listen--brief l e)))

(define (agent-listen--heard id e)
  (let ((l (agent-listen--find id)))
    (when (and l (agent-listen--wants? l e))
      (let ((buf (agent-listen--chat (plist-get l 'chat))))
        (if buf
            (agent-listen--deliver! l buf e)
            (agent-listen--put! (plist-put l 'pending (append (or (plist-get l 'pending) '())
                                                              (list (plist-get e 'seq))))))))))

(define (agent-listen--subscribe! l)
  (let ((id (plist-get l 'id)))
    (event-subscribe! (agent-listen--name id) (plist-get l 'topic)
                      (lambda (e) (agent-listen--heard id e)))))

;; hand each open chat the events that came while it was not
(define (agent-listen--flush! _)
  (for-each
    (lambda (l)
      (let ((buf (and (pair? (plist-get l 'pending)) (agent-listen--chat (plist-get l 'chat)))))
        (when buf
          (let ((events (filter (lambda (x) x)
                                (map (lambda (seq) (agent-listen--event l seq)) (plist-get l 'pending)))))
            (agent-listen--put! (plist-put l 'pending '()))
            (for-each (lambda (e) (agent-listen--deliver! l buf e))
                      (if (or (plist-get l 'keep) (null? events)) events (list (car events))))))))
    *agent-listeners*))

(define (agent-listen! spec &optional note)
  "(agent-listen! SPEC [NOTE]) — make this chat's agent listen for an event; answer the listener's id. SPEC is a plist: topic (required; a trailing * matches a prefix), kind, match (text the event's data must hold), task, keep, chat"
  (let ((topic (plist-get spec 'topic))
        (chat (agent-listen--chat-id (plist-get spec 'chat))))
    (when (agent-listen--blank? topic)
      (error "agent-listen!: SPEC needs a topic, such as \"whatsapp:919902020677\""))
    (unless chat
      (error "agent-listen!: run it from a chat, or name one with 'chat"))
    (let* ((id (string-append "l" (number->string (current-time)) "-" (number->string (random 10000))))
           (kind (plist-get spec 'kind))
           (l (list 'id id 'chat chat 'topic topic
                    'kind (and kind (format "~a" kind))
                    'match (plist-get spec 'match) 'note note 'task (plist-get spec 'task)
                    'keep (and (plist-get spec 'keep) #t) 'pending '() 'created (current-time))))
      (agent-listen--put! l)
      (agent-listen--subscribe! l)
      id)))

(define (agent-unlisten! id)
  "(agent-unlisten! ID) — stop the listener ID"
  (set! *agent-listeners* (filter (lambda (l) (not (equal? (plist-get l 'id) id))) *agent-listeners*))
  (agent-listen--save!)
  ;; a delivery sets the subscriber's position after its handler returns,
  ;; so the subscriber goes once that is done
  (debounce! (string->symbol (agent-listen--name id)) 0
             (lambda (name) (event-unsubscribe! name)) (agent-listen--name id))
  id)

(effects! '(read))

(define (agent-listeners &optional chat)
  "(agent-listeners [CHAT]) — the listeners, each a plist; only CHAT's when given"
  (let ((id (and chat (agent-listen--chat-id chat))))
    (filter (lambda (l) (or (not id) (equal? (plist-get l 'chat) id))) *agent-listeners*)))

(public! 'agent-listen! "(agent-listen! SPEC [NOTE]) — make this chat's agent listen for an event, such as a WhatsApp reply; it gets the event as a message. SPEC: topic, kind, match, task, keep, chat")
(public! 'agent-unlisten! "(agent-unlisten! ID) — stop the listener ID")
(public! 'agent-listeners "(agent-listeners [CHAT]) — the listeners, each a plist; only CHAT's when given")

(effects! '(write))

;; a chat opens after its event came: it gets the event now
(define (agent-listen--chat-mode-hook!)
  (debounce! 'agent-listen-flush 0 agent-listen--flush! #f))
(add-hook! 'chat-mode-hook 'agent-listen--chat-mode-hook!)

;; the subscribers start once the boot ends, as todo.scm's first scan does
(debounce! 'agent-listen-boot 0
           (lambda (_)
             (agent-listen--load!)
             (for-each agent-listen--subscribe! *agent-listeners*)
             (agent-listen--flush! #f))
           #f)
