;;; orchestrate.scm --- orchestrate-mode: a chat runs a todo DAG.
;;;
;;; (orchestrate! ROOT) makes the calling chat the orchestrator of the
;;; todos under ROOT, the ones whose #+parent is ROOT. Scheme does the
;;; bookkeeping, not model turns: each time a child chat ends a turn, the
;;; tree is read again, and every todo whose depends are in review or done
;;; starts in its own chat. That chat wears the todo's title, gets the
;;; standard brief, and is linked to the orchestrator with notify.
;;;
;;; The orchestrator's model wakes only for judgment: a todo stuck in doing
;;; with its chat gone, a review whose log says tests fail, a todo held by
;;; a cancelled one, or the whole tree in review or done. Each judgment is
;;; sent once.
;;;
;;; The state is buffer-locals of the orchestrator chat, so it persists
;;; with the desktop: orchestrate-root, orchestrate-chats ((ID CHAT) ...),
;;; and orchestrate-woke, the judgments already sent.
;;;
;;; No new view: the todo list shows the tree, M-x subagents the chats.

(require 'todo)

(domain! 'chat)
(effects! '(read))

;; a depend in one of these states lets its dependents start
(define *orchestrate-passed* '("review" "done"))

(define (orchestrate-root chat)
  (and (string? chat) (buffer-exists? chat) (buffer-local chat 'orchestrate-root)))

(define (orchestrate-on? chat)
  (and (string? (orchestrate-root chat))
       (minor-mode-on? chat "orchestrate-mode")))

(define (orchestrate-children root)
  (todo-list (list 'parent root 'all #t)))

;; a depend that no longer exists holds nothing up
(define (orchestrate--dep-state dep)
  (let ((d (todo-get dep))) (if d (plist-get d 'state) "done")))

(define (orchestrate--ready? t)
  (null? (remove (lambda (dep) (member (orchestrate--dep-state dep) *orchestrate-passed*))
                 (or (plist-get t 'depends) '()))))

(define (orchestrate--blocked? t)
  (pair? (filter (lambda (dep) (equal? (orchestrate--dep-state dep) "cancelled"))
                 (or (plist-get t 'depends) '()))))

;; a triaged todo with no live chat and every depend passed
(define (orchestrate--startable? t)
  (and (equal? (plist-get t 'state) "todo")
       (not (todo--live-chat (plist-get t 'assignee)))
       (orchestrate--ready? t)))

(define (orchestrate--chat-gone? t)
  (let ((a (plist-get t 'assignee)))
    (and (equal? (plist-get t 'state) "doing")
         (string? a) (string-prefix? "chat:" a)
         (not (todo--live-chat a)))))

;; the log lines since the todo last went to review
(define (orchestrate--since-review t)
  (let loop ((ls (reverse (or (plist-get t 'log) '()))) (acc '()))
    (cond ((null? ls) acc)
          ((string-contains? (car ls) "-> review") (cons (car ls) acc))
          (else (loop (cdr ls) (cons (car ls) acc))))))

;; a word that starts with fail says tests fail, unless 0 or no is before it
(define (orchestrate--failing? t)
  (and (equal? (plist-get t 'state) "review")
       (let loop ((ws (string-split (string-downcase (string-join (orchestrate--since-review t) " ")) " "))
                  (prev ""))
         (cond ((null? ws) #f)
               ((and (string-prefix? "fail" (car ws)) (not (member prev '("0" "no")))) #t)
               (else (loop (cdr ws) (car ws)))))))

(define (orchestrate-status &optional chat)
  "(orchestrate-status [CHAT]) — the tree CHAT orchestrates, one todo a line: id, state, title, live chat"
  (let* ((chat (or chat (current-buffer)))
         (root (orchestrate-root chat)))
    (if (not root)
        "not orchestrating"
        (string-join
          (cons (string-append "root " root)
                (map (lambda (t)
                       (let ((c (todo--live-chat (plist-get t 'assignee))))
                         (string-append "- " (plist-get t 'id) " " (plist-get t 'state) " " (plist-get t 'title)
                                        (if c (string-append " · " c) ""))))
                     (orchestrate-children root)))
          "\n"))))

;; (KEY TEXT) for each thing only the model can decide. KEY names the
;; occasion, so the same one is sent once: a new chat or a new review is
;; a new occasion.
(define (orchestrate--judgments root ts)
  (let ((one (lambda (t)
               (let ((id (plist-get t 'id))
                     (title (plist-get t 'title)))
                 (cond ((orchestrate--chat-gone? t)
                        (list (string-append id " gone " (plist-get t 'assignee))
                              (string-append id " (" title ") is doing, but its chat is gone. Start it again with (todo-assign-chat! \"" id "\" GROUP), or decide.")))
                       ((orchestrate--failing? t)
                        (list (string-append id " failing " (number->string (length (plist-get t 'log))))
                              (string-append id " (" title ") is in review, and its log says tests fail. Read (todo-get \"" id "\"), then send its chat back to work or fix it.")))
                       ((and (equal? (plist-get t 'state) "todo") (orchestrate--blocked? t))
                        (list (string-append id " blocked")
                              (string-append id " (" title ") depends on a cancelled todo. Change its depends, or cancel it.")))
                       (else #f))))))
    (append (filter (lambda (j) j) (map one ts))
            (if (and (pair? ts)
                     (null? (remove (lambda (t) (member (plist-get t 'state) '("review" "done" "cancelled"))) ts)))
                (list (list "all" (string-append "Every todo under " root " is in review or done. Report to the user, then (orchestrate-stop!).")))
                '()))))

(effects! '(write))

;; start T in a new chat. From a turn end no spawner is in scope, so the
;; link to the orchestrator is made here; from the orchestrator's own eval
;; todo-assign-chat! made it already, and this one changes nothing.
(define (orchestrate--start! chat t)
  (let* ((id (plist-get t 'id))
         (me (chat-stable-id! chat))
         (c (todo-assign-chat! id (buffer-group chat) me)))
    (subagent-record! chat c)
    (buffer-set-local! c 'subagent-notify #t)
    (buffer-set-local! c 'inhibit-retitle #t)
    (buffer-set-local! chat 'orchestrate-chats
      (append (remove (lambda (e) (equal? (car e) id)) (or (buffer-local chat 'orchestrate-chats) '()))
              (list (list id (chat-stable-id! c)))))
    (todo-log id (string-append "orchestrate-mode started it in " c) me)
    c))

(define (orchestrate-step! &optional chat quiet)
  "(orchestrate-step! [CHAT] [QUIET]) — read CHAT's tree, start every todo whose depends passed, and wake CHAT's model for the judgments not yet sent; QUIET answers them instead of waking. Returns (started CHATS judgments TEXTS)"
  (let ((chat (or chat (current-buffer))))
    (when (orchestrate-on? chat)
      (let* ((root (orchestrate-root chat))
             (started (filter (lambda (c) c)
                              (map (lambda (t) (ignore-errors (lambda () (orchestrate--start! chat t))))
                                   (filter orchestrate--startable? (orchestrate-children root)))))
             (woke (or (buffer-local chat 'orchestrate-woke) '()))
             (new (remove (lambda (j) (member (car j) woke))
                          (orchestrate--judgments root (orchestrate-children root))))
             (texts (map cadr new)))
        (unless (null? new)
          (buffer-set-local! chat 'orchestrate-woke (append woke (map car new)))
          (unless quiet
            (agent-wake! chat 'orchestrator
              (string-append "orchestrate-mode needs your judgment:\n"
                             (string-join (map (lambda (s) (string-append "- " s)) texts) "\n")
                             "\n\n" (orchestrate-status chat)))))
        (list 'started started 'judgments texts)))))

(define (orchestrate! root &optional chat)
  "(orchestrate! ROOT [CHAT]) — CHAT, the calling chat by default, runs the todos under ROOT: each starts in its own linked chat when its depends are in review or done, and CHAT's model wakes only for judgment. Answers the step and the tree"
  (let ((chat (or chat (current-buffer))))
    (unless (chat-buffer? chat) (error (string-append "orchestrate!: not a chat: " chat)))
    (unless (todo-get root) (error (string-append "orchestrate!: no todo " root)))
    (buffer-set-local! chat 'orchestrate-root root)
    (buffer-set-local! chat 'orchestrate-woke '())
    (unless (minor-mode-on? chat "orchestrate-mode")
      (enable-minor-mode! chat "orchestrate-mode"))
    (list (orchestrate-step! chat #t) (orchestrate-status chat))))

(define (orchestrate-stop! &optional chat)
  "(orchestrate-stop! [CHAT]) — CHAT stops running its tree; its chats go on"
  (let ((chat (or chat (current-buffer))))
    (when (minor-mode-on? chat "orchestrate-mode")
      (disable-minor-mode! chat "orchestrate-mode"))
    (buffer-set-local! chat 'orchestrate-root #f)
    #t))

;; a child's turn end steps its orchestrator instead of waking it
(advice-add! 'subagent-notify-parent! 'around 'orchestrate
  (lambda (next slug ok? stop-reason)
    (let* ((parent (subagent-parent slug))
           (pbuf (and parent (subagent-live-buffer parent))))
      (if (orchestrate-on? pbuf)
          (orchestrate-step! pbuf)
          (next slug ok? stop-reason)))))

;; a child killed mid-task ends no turn: step once the kill is done
(advice-add! 'subagent-chat-killed! 'around 'orchestrate
  (lambda (next name)
    (let* ((slug (and (string? name) (buffer-exists? name) (agent-slug-of name)))
           (parent (and slug (subagent-parent slug)))
           (pbuf (and parent (subagent-live-buffer parent))))
      (next name)
      (when (orchestrate-on? pbuf)
        (task-run! (lambda () #t) (lambda (ok? v) (orchestrate-step! pbuf)))))))

(register-minor-mode!
  "orchestrate-mode"
  (lambda (buf) #t)
  (lambda (buf) (buffer-set-local! buf 'orchestrate-root #f)))

(define-command "orchestrate-mode" "Stop or resume running this chat's todo tree; (orchestrate! ROOT) starts one"
  (lambda ()
    (let ((buf (current-buffer)))
      (cond ((not (chat-buffer? buf)) (message "not a chat buffer"))
            ((minor-mode-on? buf "orchestrate-mode")
             (orchestrate-stop! buf)
             (message "orchestrate-mode disabled"))
            (else (message "start it from the chat: (orchestrate! ROOT-TODO)"))))))

(mode-doc! "orchestrate-mode"
  "The chat runs the todos under a root todo. A todo starts in its own linked chat when its depends are in review or done; the chat's model wakes only for judgment. The todo list shows the tree, M-x subagents the chats.")

(category! 'chat)
(public! 'orchestrate! "(orchestrate! ROOT [CHAT]) — CHAT runs the todos under ROOT: each starts in its own linked chat when its depends are in review or done; the model wakes only for judgment")
(public! 'orchestrate-step! "(orchestrate-step! [CHAT] [QUIET]) — read the tree, start what is ready, wake for new judgments")
(public! 'orchestrate-stop! "(orchestrate-stop! [CHAT]) — stop running the tree; its chats go on")
(public! 'orchestrate-status "(orchestrate-status [CHAT]) — the tree, one todo a line")
(public! 'orchestrate-on? "(orchestrate-on? CHAT) — #t when CHAT runs a tree")
(catalog-meta! 'function "orchestrate!" 'domain 'chat 'effects '(write))
(catalog-meta! 'function "orchestrate-step!" 'domain 'chat 'effects '(write))
(catalog-meta! 'function "orchestrate-stop!" 'domain 'chat 'effects '(write))
(catalog-meta! 'function "orchestrate-status" 'domain 'chat 'effects '(read))
(catalog-meta! 'function "orchestrate-on?" 'domain 'chat 'effects '(read))
