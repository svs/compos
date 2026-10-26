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
        'created (plist-get d 'created) 'pending (plist-get d 'pending)
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
    (let ((rows (map cdr table)))
      (append (filter (lambda (r) (equal? (plist-get r 'state) "listening")) rows)
              ;; sort has no comparator: the newest first, keyed on minus its last activity
              (map cadr (sort (map (lambda (r) (list (- 0 (or (plist-get r 'last) 0)) r))
                                   (filter (lambda (r) (not (equal? (plist-get r 'state) "listening"))) rows))))))))

;; the group the watcher's task shows in, by name
(define (watchers--task-group row)
  (let* ((id (plist-get row 'task)) (t (and (not (watchers--blank? id)) (todo-get id)))
         (g (and t (plist-get t 'group))))
    (and g (or (group-name g) g))))

(define (watchers--chat-buffer row)
  (let ((id (plist-get row 'chat)))
    (and id (find (lambda (b) (equal? (buffer-local b 'chat-id) id)) (buffer-list)))))

(define (watchers--task-title row)
  (let* ((id (plist-get row 'task)) (t (and (not (watchers--blank? id)) (todo-get id))))
    (and t (plist-get t 'title))))

(define (watchers--cells buf row)
  (list (watchers--state-label row)
        (number->string (length (plist-get row 'fired)))
        (watchers--age (plist-get row 'last))
        (or (plist-get row 'topic) "")
        (or (plist-get row 'match) "")
        (or (watchers--task-title row) (plist-get row 'note) "")))

;; one firing, as its page lists it: when, what, from whom, and the event's first line
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
      (line "created     " (and (plist-get row 'created) (string-append (watchers--age (plist-get row 'created)) " ago")))
      (line "waiting     " (and (pair? (plist-get row 'pending))
                              (string-append (number->string (length (plist-get row 'pending))) " event(s) for a chat that is not open")))
      (if (watchers--blank? (plist-get row 'note)) "" (string-append "\nNote\n" (plist-get row 'note) "\n"))
      "\nFired " (number->string (length (plist-get row 'fired))) " time(s)\n"
      (apply string-append (map watchers--firing-text (plist-get row 'fired)))
      "\n────\nend\n")))

(effects! '(write display))

(define (watchers--detail-buffer row) (string-append "*watcher:" (plist-get row 'id) "*"))

(define (watchers-show-detail! row)
  "show the page of the listener ROW beside the list"
  (when row
    (let ((buf (watchers--detail-buffer row)))
      (unless (buffer-known? buf)
        (buffer-create buf)
        (let ((g (buffer-local *watchers-buffer* 'group)))
          (when g (buffer-move-to-group! buf g)))
        (with-current-buffer buf (lambda () (set-mode! "watchers-detail-mode"))))
      (buffer-set-local! buf 'watcher row)
      (buffer-set-text! buf (watchers--detail-text row) #t)
      (display-buffer-detail! buf *watchers-buffer*))))

;; the listener at hand: the page's own, else the list's row
(define (watchers--at)
  (or (buffer-local (current-buffer) 'watcher)
      (and (buffer-exists? *watchers-buffer*) (list-current *watchers-buffer*))))

(define (watchers--redraw! _)
  (when (buffer-exists? *watchers-buffer*) (list-refresh! *watchers-buffer*)))

(define (watchers--saw e)
  (debounce! 'watchers-draw 500 watchers--redraw! #f))

(define-list-mode! "watchers-mode"
  (list
    'doc (string-append
           "The agents' watchers: every listener a chat set with agent-listen!, live first, then the ones "
           "that fired or were cancelled. Moving the point shows the watcher's page beside the list: what it "
           "waits for, its chat and task, and each time it fired. k cancels a live watcher, c shows its chat, "
           "t its task, RET its page, / narrows the rows, g redraws, q quits.")
    'buffer *watchers-buffer*
    'transient #f
    'rows watchers--rows
    'key (lambda (buf row) (plist-get row 'id))
    'local-filter #t
    'no-marks #t
    'columns (lambda (buf)
               (list (list "state" 10) (list "fired" 6) (list "last" 6) (list "listens to" 26)
                     (list "match" 20) (list "for" #f)))
    'cells watchers--cells
    'preview (lambda (buf row) (watchers-show-detail! row))
    'title (lambda (buf) "Watchers")
    'total (lambda (buf) (length (list-entries buf)))
    'noun "watcher"
    'footer (lambda (buf) '(("RET" "page") ("k" "cancel") ("c" "chat") ("t" "task") ("/" "filter") ("g" "redraw") ("q" "quit")))
    'keys '(("RET" "watchers-show") ("k" "watchers-cancel") ("c" "watchers-chat")
            ("t" "watchers-task") ("g" "watchers-refresh") ("q" "quit-window"))))

(define-mode "watchers-detail-mode" (lambda () (buffer-set-read-only! (current-buffer) #t)))
(mode-keys! "watchers-detail-mode"
            '(("k" "watchers-cancel") ("c" "watchers-chat") ("t" "watchers-task") ("g" "watchers-refresh")))
(mode-doc! "watchers-detail-mode" "One watcher: what it waits for, its chat and task, and each time it fired. k cancels it while it listens, c shows its chat, t its task, g reads it again.")

(define-command "watchers" "Open the agents' watchers: every listener, live or done, and its firings"
  (lambda ()
    (event-subscribe! "watchers" "agent-listen:*" 'watchers--saw)
    (buffer-create *watchers-buffer*)
    (unless (buffer-local *watchers-buffer* 'group)
      (buffer-set-local! *watchers-buffer* 'group (frame-group)))
    (list-mode-show! "watchers-mode")))

(define-command "watchers-show" "Show the watcher at point as its own page beside the list"
  (lambda () (watchers-show-detail! (watchers--at))))

(define-command "watchers-refresh" "Read the watchers again"
  (lambda ()
    (watchers--redraw! #f)
    (let ((row (buffer-local (current-buffer) 'watcher)))
      (when row
        (let ((now (find (lambda (r) (equal? (plist-get r 'id) (plist-get row 'id))) (watchers--rows *watchers-buffer*))))
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

(public! 'watchers-show-detail! "(watchers-show-detail! ROW) — show the page of the watcher ROW beside the watchers list")
