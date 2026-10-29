;;; watchers.scm --- M-x watchers: every agent listener, live or done, and its firings.
;;;
;;; A listener (agent-listen!) wakes a chat when an event it names lands.
;;; agent-listen.scm writes what happens to each one into the log as
;;; agent-listen:ID: created, fired, cancelled. This list reads the live
;;; listeners and that history, one row a listener. Moving the point shows
;;; its page beside the list: what it waits for, for which chat and task,
;;; and every time it fired. k cancels a live one, c shows its chat, t its
;;; task.

(domain! 'chat)
(effects! '(write))
(category! 'chat)

(define *watchers-buffer* "*watchers*")

(defcustom 'watchers-history-limit 2000
  "How many agent-listen events M-x watchers reads back for listeners that are gone.")

(effects! '(pure))

(define (watchers--blank? s) (or (not s) (and (string? s) (equal? (string-trim s) ""))))

(define (watchers--age at) (if (number? at) (ibuffer-age-label (- (current-time) at)) ""))

(define (watchers--state-label row)
  (let ((s (plist-get row 'state)))
    (cond ((and (equal? s "listening") (pair? (plist-get row 'pending))) "queued")
          (else s))))

(effects! '(read))

;; a row from a listener spec or an event's data: the parts both share
(define (watchers--row-of d state)
  (list 'id (plist-get d 'id) 'chat (plist-get d 'chat) 'topic (plist-get d 'topic)
        'only-kind (or (plist-get d 'only-kind) (plist-get d 'kind)) 'match (plist-get d 'match)
        'note (plist-get d 'note) 'task (plist-get d 'task) 'keep (plist-get d 'keep)
        'created (plist-get d 'created) 'pending (plist-get d 'pending) 'due (plist-get d 'due)
        'state state 'fired '() 'last (plist-get d 'created)))

;; every listener: the live ones, then the ones the log remembers
(define (watchers--rows buf)
  (let ((table '()))
    (define (get id) (let ((hit (assoc id table))) (and hit (cdr hit))))
    (define (set id row) (set! table (cons (cons id row) (filter (lambda (p) (not (equal? (car p) id))) table))))
    (for-each (lambda (l) (set (plist-get l 'id) (watchers--row-of l "listening"))) (agent-listeners))
    (for-each
      (lambda (e)
        (let* ((d (plist-get e 'data)) (id (and (pair? d) (plist-get d 'id))))
          (when id
            (let* ((live (let ((r (get id))) (and r (equal? (plist-get r 'state) "listening"))))
                   (row (or (get id) (watchers--row-of d "gone")))
                   (kind (format "~a" (plist-get e 'kind)))
                   (row (plist-put row 'last (plist-get e 'at))))
              (set id
                   (cond ((equal? kind "fired")
                          (let ((row (plist-put row 'fired (cons e (plist-get row 'fired)))))
                            (if live row (plist-put row 'state "fired"))))
                         ((and (equal? kind "cancelled") (not live)) (plist-put row 'state "cancelled"))
                         (else row)))))))
      (reverse (event-log-newest "agent-listen:*" watchers-history-limit)))
    ;; the task titles in one read: todo-get reads every todo file per call
    (let* ((titles (let ((ts (if (boundp 'todo--all) (todo--all) '())))
                     (map (lambda (t) (list (plist-get t 'id) (plist-get t 'title))) ts)))
           (rows (map (lambda (p)
                        (let* ((r (cdr p)) (hit (assoc (plist-get r 'task) titles)))
                          (plist-put (plist-put r 'task-read #t) 'task-title (and hit (cadr hit)))))
                      table)))
      (append (filter (lambda (r) (equal? (plist-get r 'state) "listening")) rows)
              ;; sort has no comparator: the newest first, keyed on minus its last activity
              (map cadr (sort (map (lambda (r) (list (- 0 (or (plist-get r 'last) 0)) r))
                                   (filter (lambda (r) (not (equal? (plist-get r 'state) "listening"))) rows))))))))

;; the group the watcher's task shows in, by name
(define (watchers--task-group row)
  (let* ((id (plist-get row 'task)) (t (and (not (watchers--blank? id)) (todo-get id)))
         (g (and t (plist-get t 'group))))
    (and g (or (group-name g) g))))

;; how long until a live watcher is due, or how late it is
(define (watchers--due-label row)
  (if (not (equal? (plist-get row 'state) "listening"))
      ""
      (let ((left (- (agent-listen-due row) (current-time))))
        (if (< left 0) (string-append "late " (ibuffer-age-label (- 0 left))) (ibuffer-age-label left)))))

(define (watchers--chat-buffer row)
  (let ((id (plist-get row 'chat)))
    (and id (find (lambda (b) (equal? (buffer-local b 'chat-id) id)) (buffer-list)))))

(define (watchers--task-title row)
  (if (plist-get row 'task-read)
      (plist-get row 'task-title)
      (let* ((id (plist-get row 'task)) (t (and (not (watchers--blank? id)) (todo-get id))))
        (and t (plist-get t 'title)))))

;;; `<` cycles what a section is, as in ibuffer; a heading is a row of kind sep
(define *watchers-groupings* '("state" "chat" "group" "topic" "none"))
(define *watchers-state-order* '("listening" "queued" "fired" "cancelled" "gone"))

(define (watchers--grouping buf) (or (buffer-local buf 'watchers-grouping) "state"))

(define (watchers--sep? row) (equal? (plist-get row 'kind) "sep"))

(define (watchers--section-of buf row &optional chats)
  ;; CHATS maps a chat id to its buffer, read once per draw
  (let* ((g (watchers--grouping buf))
         (chat (lambda () (if chats
                              (let ((hit (assoc (plist-get row 'chat) chats))) (and hit (cadr hit)))
                              (watchers--chat-buffer row)))))
    (cond ((equal? g "chat") (let ((c (chat))) (or (and c (buffer-short-label c)) (plist-get row 'chat) "no chat")))
          ((equal? g "group") (let ((c (chat))) (or (and c (buffer-group c) (group-name (buffer-group c)))
                                                      (watchers--task-group row) "no group")))
          ((equal? g "topic") (or (plist-get row 'topic) "no topic"))
          (else (watchers--state-label row)))))

(define (watchers--sections buf rows)
  ;; a state keeps its fixed order; any other section comes in the order of its first watcher.
  ;; Each row's section is worked out once.
  (if (equal? (watchers--grouping buf) "none")
      rows
      (let* ((chats (if (member (watchers--grouping buf) '("chat" "group"))
                        (filter (lambda (p) p) (map (lambda (b) (let ((id (buffer-local b 'chat-id))) (and id (list id b))))
                                                         (buffer-list)))
                        '()))
             (tagged (map (lambda (r) (cons (watchers--section-of buf r chats) r)) rows))
             (seen (fold (lambda (acc p) (if (member (car p) acc) acc (cons (car p) acc))) '() tagged))
             (seen (reverse seen))
             (names (if (equal? (watchers--grouping buf) "state")
                        (append (filter (lambda (s) (member s seen)) *watchers-state-order*)
                                (filter (lambda (s) (not (member s *watchers-state-order*))) seen))
                        seen)))
        (apply append
          (map (lambda (n)
                 (cons (list 'kind "sep" 'id (string-append "sep:" n) 'title n)
                       (map cdr (filter (lambda (p) (equal? (car p) n)) tagged))))
               names)))))

(define (watchers--list-rows buf) (watchers--sections buf (watchers--rows buf)))

(define (watchers--cells buf row)
  (if (watchers--sep? row)
      (list (list (plist-get row 'title) "list-section-name") "" "" "" "" "" "")
  (list (watchers--state-label row)
        (number->string (length (plist-get row 'fired)))
        (watchers--age (plist-get row 'last))
        (watchers--due-label row)
        (or (plist-get row 'topic) "")
        (or (plist-get row 'match) "")
        (or (watchers--task-title row) (plist-get row 'note) ""))))

;; one firing, as its page lists it: when, what, from whom, and the event's first line
;; a pane narrower than the full table keeps what tells watchers apart:
;; when it is due, what it listens to, and what it is for
(define (watchers--narrow-cells buf row)
  (if (watchers--sep? row)
      (list (list (plist-get row 'title) "list-section-name") "" "" "")
      (let ((c (watchers--cells buf row)))
        (list (nth 0 c) (nth 3 c) (nth 4 c) (nth 6 c)))))

(define (watchers--firing-text e)
  (let* ((d (plist-get e 'data))
         (seq (plist-get d 'event-seq)) (topic (plist-get d 'event-topic))
         (orig (and seq topic (let ((r (event-log-read (- seq 1) topic 1)))
                                (and (pair? r) (equal? (plist-get (car r) 'seq) seq) (car r)))))
         (text (if orig (first-line (event-text orig)) "")))
    (string-append "\n" (watchers--age (plist-get e 'at)) " ago  " (or topic "")
                   (if (watchers--blank? (plist-get d 'from)) "" (string-append " from " (plist-get d 'from)))
                   (if (watchers--blank? text) "" (string-append "\n  " text))
                   "\n")))

;; the page of one listener
(define (watchers--detail-text row)
  (let ((line (lambda (k v) (if (watchers--blank? v) "" (string-append k (format "~a" v) "\n"))))
        (task-title (watchers--task-title row)))
    (string-append
      "Watcher " (plist-get row 'id) "  ·  " (watchers--state-label row) "\n\n"
      (line "listens to  " (plist-get row 'topic))
      (line "kind        " (plist-get row 'only-kind))
      (line "match       " (plist-get row 'match))
      (line "keeps on    " (if (plist-get row 'keep) "yes, every event" "no, the first event ends it"))
      (line "chat        " (or (watchers--chat-buffer row) (plist-get row 'chat)))
      (line "task        " (and (plist-get row 'task)
                              (string-append (plist-get row 'task) (if task-title (string-append "  " task-title) ""))))
      (line "task group  " (watchers--task-group row))
      (line "due         " (let ((d (watchers--due-label row))) (and (not (equal? d "")) (if (string-prefix? "late" d) d (string-append "in " d)))))
      (line "created     " (and (plist-get row 'created) (string-append (watchers--age (plist-get row 'created)) " ago")))
      (line "waiting     " (and (pair? (plist-get row 'pending))
                              (string-append (number->string (length (plist-get row 'pending))) " event(s) for a chat that is not open")))
      (if (watchers--blank? (plist-get row 'note)) "" (string-append "\nNote\n" (plist-get row 'note) "\n"))
      "\nFired " (number->string (length (plist-get row 'fired))) " time(s)\n"
      (apply string-append (map watchers--firing-text (plist-get row 'fired)))
      "\n────\nend\n")))

(effects! '(write display))

(define (watchers--detail-buffer row) (string-append "*watcher:" (plist-get row 'id) "*"))

(define (watchers--list)
  "the list at hand: this one, the one this page belongs to, else the first"
  (if (equal? (buffer-local (current-buffer) 'mode-name) "watchers-mode")
      (current-buffer)
      (or (buffer-local (current-buffer) 'watchers-list) *watchers-buffer*)))

(define (watchers-show-detail! row)
  "show the page of the listener ROW beside the list; each group's list keeps its own pages"
  (when row
    (let* ((list-buf (watchers--list))
           (buf (string-append (watchers--detail-buffer row)
                               (substring list-buf (string-length *watchers-buffer*) (string-length list-buf)))))
      (unless (buffer-known? buf)
        (buffer-create buf)
        (let ((g (buffer-group list-buf)))
          (when g (buffer-move-to-group! buf g)))
        (with-current-buffer buf (lambda () (set-mode! "watchers-detail-mode"))))
      (buffer-set-local! buf 'watcher row)
      (buffer-set-local! buf 'watchers-list list-buf)
      (buffer-set-text! buf (watchers--detail-text row) #t)
      (display-buffer-detail! buf list-buf))))

;; the listener at hand: the page's own, else the list's row
(define (watchers--at)
  (or (buffer-local (current-buffer) 'watcher)
      (let* ((l (watchers--list)) (row (and (buffer-exists? l) (list-current l))))
        (and row (not (watchers--sep? row)) row))))

(define (watchers--regroup! buf)
  (let* ((g (watchers--grouping buf))
         (i (length (member g (reverse *watchers-groupings*))))
         (next (nth (modulo i (length *watchers-groupings*)) *watchers-groupings*)))
    (buffer-set-local! buf 'watchers-grouping next)
    (list-refresh! buf)
    (message (string-append "Watchers grouped by " next))))

;; x on the rows flagged with d: each live one stops listening
(define (watchers--cancel-key! buf id)
  (let ((row (find (lambda (r) (equal? (plist-get r 'id) id)) (watchers--rows buf))))
    (and row (equal? (plist-get row 'state) "listening")
         (begin (agent-listen-cancel! id) #t))))

(define (watchers--redraw! _)
  (for-each (lambda (b) (list-render! b #t)) (mode-group-buffers "watchers-mode")))

(define (watchers--saw e)
  (debounce! 'watchers-draw 500 watchers--redraw! #f))

(define-list-mode! "watchers-mode"
  (list
    'doc (string-append
           "The agents' watchers: every listener a chat set with agent-listen!, in sections as ibuffer has them. "
           "The tabs across the top keep the live ones, the ones that fired, the done ones, or all; "
           "left and right step them, and a click takes one. / searches the whole page of each watcher. "
           "< cycles the sections: state, chat, group, topic, none. Moving the point shows the watcher's page "
           "beside the list: what it waits for, its chat and task, and each time it fired. d flags a live "
           "watcher for cancel and x cancels the flagged ones; SPC marks, u unmarks, U drops every mark. "
           "k cancels the watcher at point at once, c shows its chat, t its task, RET its page, / narrows "
           "the rows, g redraws, q quits.")
    'buffer *watchers-buffer*
    'transient #f
    'rows watchers--list-rows
    'key (lambda (buf row) (plist-get row 'id))
    'local-filter #t
    ;; tabs across the top: the live ones first, as todo opens on the open ones
    'tabs (list (list "live" (lambda (buf r) (equal? (plist-get r 'state) "listening")))
                (list "fired" (lambda (buf r) (pair? (plist-get r 'fired))))
                (list "done" (lambda (buf r) (member (plist-get r 'state) '("fired" "cancelled" "gone"))))
                (list "all" (lambda (buf r) #t)))
    ;; / searches the whole page: the note, the task, and every firing
    'body (lambda (buf r) (if (watchers--sep? r) "" (watchers--detail-text r)))
    'separator? (lambda (buf row) (watchers--sep? row))
    'section? (lambda (buf row) (watchers--sep? row))
    'regroup watchers--regroup!
    'markable? (lambda (buf row) (equal? (plist-get row 'state) "listening"))
    'flags (list (list "d" "D" "cancel" watchers--cancel-key! #f))
    'columns (lambda (buf)
               (list (list "state" 10) (list "fired" 6) (list "last" 6) (list "due" 9) (list "listens to" 26)
                     (list "match" 20) (list "for" #f)))
    'cells watchers--cells
    'layouts (list (list 'name 'narrow
                         'max-cols (lambda (buf) 119)
                         'columns (lambda (buf) (list (list "state" 10) (list "due" 9) (list "listens to" 24) (list "for" #f)))
                         'cells watchers--narrow-cells)
                   (list 'name 'wide 'default #t))
    'preview (lambda (buf row) (unless (watchers--sep? row) (watchers-show-detail! row)))
    'title (lambda (buf) "Watchers")
    'total (lambda (buf) (length (filter (lambda (r) (not (watchers--sep? r))) (list-entries buf))))
    'noun "watcher"
    'footer (lambda (buf) '(("RET" "page") ("d" "flag") ("x" "cancel flagged") ("k" "cancel") ("c" "chat") ("t" "task") ("<" "group") ("/" "filter") ("g" "redraw") ("q" "quit")))
    'keys '(("RET" "watchers-show") ("k" "watchers-cancel") ("c" "watchers-chat")
            ("t" "watchers-task") ("g" "watchers-refresh") ("q" "quit-window"))))

(define-mode "watchers-detail-mode" (lambda () (buffer-set-read-only! (current-buffer) #t)))
(mode-keys! "watchers-detail-mode"
            '(("k" "watchers-cancel") ("c" "watchers-chat") ("t" "watchers-task") ("g" "watchers-refresh")))
(mode-doc! "watchers-detail-mode" "One watcher: what it waits for, its chat and task, and each time it fired. k cancels it while it listens, c shows its chat, t its task, g reads it again.")

(define-command "watchers" "Open the agents' watchers: every listener, live or done, and its firings"
  (lambda ()
    (event-subscribe! "watchers" "agent-listen:*" 'watchers--saw)
    (list-mode-show! "watchers-mode")))

(define-command "watchers-show" "Show the watcher at point as its own page beside the list"
  (lambda () (watchers-show-detail! (watchers--at))))

(define-command "watchers-refresh" "Read the watchers again"
  (lambda ()
    (watchers--redraw! #f)
    (let ((row (buffer-local (current-buffer) 'watcher)))
      (when row
        (let ((now (find (lambda (r) (equal? (plist-get r 'id) (plist-get row 'id))) (watchers--rows (watchers--list)))))
          (when now (watchers-show-detail! now)))))))

(define-command "watchers-cancel" "Cancel the watcher at point; it wakes its chat no more"
  (lambda ()
    (let ((row (watchers--at)))
      (cond ((not row) (message "no watcher here"))
            ((not (equal? (plist-get row 'state) "listening"))
             (message (string-append (plist-get row 'id) " is not listening")))
            (else (agent-listen-cancel! (plist-get row 'id))
                  (message (string-append "cancelled " (plist-get row 'id)))
                  (watchers--redraw! #f))))))

(define-command "watchers-chat" "Show the chat the watcher at point wakes"
  (lambda ()
    (let* ((row (watchers--at)) (buf (and row (watchers--chat-buffer row))))
      (if buf (display-buffer-other-window! buf) (message "its chat is not open")))))

(define-command "watchers-task" "Show the task the watcher at point waits on"
  (lambda ()
    (let* ((row (watchers--at)) (id (and row (plist-get row 'task))))
      (if (and (not (watchers--blank? id)) (todo-get id))
          (todo-show-detail! id)
          (message "no task for this watcher")))))

;; ---- the daily sweep ------------------------------------------------------
;; Once a day the live watchers past due go to one agent. It reads each
;; source itself, to tell a reply that never came from a pipe that broke:
;; a feed that stopped, a mailbox not indexed, a match that cannot hit.
;; No watcher past due, no agent.

(defcustom 'watchers-sweep-spec "0 9 * * *"
  "When the daily sweep of watchers past due runs, as a cron time in the local zone.")

(defcustom 'watchers-sweep-days 3
  "How many days the sweep gives a watcher it found still waiting on a working pipe.")

(effects! '(read))

(define (watchers-overdue)
  "the live watchers past due, as listener plists"
  (filter (lambda (l) (< (agent-listen-due l) (current-time))) (agent-listeners)))

;; the group the sweep runs in: the first late watcher's task's, else its chat's, else the frame's
(define (watchers--sweep-group late)
  (let loop ((ls late))
    (if (null? ls)
        (frame-group)
        (let* ((l (car ls))
               (t (and (not (watchers--blank? (plist-get l 'task))) (todo-get (plist-get l 'task))))
               (chat (watchers--chat-buffer l)))
          (or (and t (plist-get t 'group)) (and chat (buffer-group chat)) (loop (cdr ls)))))))

(define (watchers--sweep-prompt late)
  (string-append
    "Daily watcher sweep. These " (number->string (length late))
    " watchers (agent-listen!) are past due: what each waits for has not reached its chat. "
    "For each one, find out why and fix what you can.\n\n"
    (apply string-append
           (map (lambda (l)
                  (string-append
                    "- " (plist-get l 'id) ": topic " (plist-get l 'topic)
                    (if (watchers--blank? (plist-get l 'kind)) "" (string-append ", kind " (plist-get l 'kind)))
                    (if (watchers--blank? (plist-get l 'match)) "" (string-append ", match \"" (plist-get l 'match) "\""))
                    ", chat " (plist-get l 'chat)
                    (if (watchers--blank? (plist-get l 'task)) "" (string-append ", task " (plist-get l 'task)))
                    ", made " (watchers--age (plist-get l 'created)) " ago"
                    (if (watchers--blank? (plist-get l 'note)) "" (string-append "\n  note: " (plist-get l 'note)))
                    "\n"))
                late))
    "\nFor each watcher:\n"
    "1. Read the source itself, not the event log: mail-search for mail, the WhatsApp MCP for WhatsApp, the ATS for candidate messages. Did what it waits for happen?\n"
    "2. If it happened and the watcher missed it, find out why: the feed stopped, the mailbox was not indexed, the topic or match text is wrong. Fix the pipe if you can (restart a feed, reconnect a server). Then hand what happened to the watcher's chat with (agent-continue! CHAT TEXT), and (agent-listen-cancel! ID).\n"
    "3. If it did not happen, check the pipe is alive: (event-log-newest TOPIC-PREFIX 3) should show recent events. Fix it if not. A wrong topic or match: make a new watcher with the same task and note, and cancel the old one. Then (agent-listen-extend! ID " (number->string watchers-sweep-days) ").\n"
    "4. Write one line of what you found on the watcher's task with (todo-log TASK TEXT WHO).\n\n"
    "Do not message any person and do not move any application. If a watcher waits on something only svs can decide, say so. "
    "End with a short table: watcher, what you found, what you did."))

(effects! '(write external spend))

(define (watchers-sweep! &optional _event)
  "hand the watchers past due to one agent chat; answer its slug, or #f when none is past due"
  (let ((late (watchers-overdue)))
    (if (null? late)
        (begin (message "watchers: none past due") #f)
        (let ((chat (group-chat (watchers--sweep-group late))))
          (with-current-buffer chat
            (lambda ()
              (execute* (watchers--sweep-prompt late)
                        (list 'title (string-append "Watcher sweep " (format-time (current-time) "%Y-%m-%d"))))))))))

(define-command "watchers-sweep" "Hand the watchers past due to an agent, which looks again and fixes broken pipes"
  (lambda () (watchers-sweep!)))

(when (boundp 'cron-define!)
  (cron-define! "watchers-sweep" watchers-sweep-spec 'call 'watchers-sweep! 'save #f))

(public! 'watchers-overdue "(watchers-overdue) — the live watchers past due")
(public! 'watchers-sweep! "(watchers-sweep!) — hand the watchers past due to one agent chat, which looks again and fixes broken pipes")

(public! 'watchers-show-detail! "(watchers-show-detail! ROW) — show the page of the watcher ROW beside the watchers list")
