;;; messages.scm --- Structured *Messages* list and filters.

(domain! 'system)
(effects! '(write display))

(define *messages-buffer* "*Messages*")
(define *messages-limit* 2000)
(define messages--primitive message-emit)

;; Remove the pre-Emacs spelling when this package first loads.
(when (buffer-exists? "*messages*") (buffer-kill! "*messages*"))

;; *Messages* is the list, always. Emacs: *Messages* is never editable.
;; Session makes the buffer at boot as a plain buffer, and a kill can make
;; it go; this adoption puts messages-mode on the name at load and each
;; time the name is created again, so no path shows the raw buffer.
(define (messages--adopt! name)
  (when (and (equal? name *messages-buffer*)
             (not (equal? (buffer-local name 'mode-name) "messages-mode")))
    (buffer-set-local! name 'mode-name "messages-mode")
    (list-mode-init! name "messages-mode")
    (list-refresh! name)))

(define (messages--shown? name)
  (let loop ((ws (window-list)))
    (cond ((null? ws) #f)
          ((equal? (car (cdr (car ws))) name) #t)
          (else (loop (cdr ws))))))

;; The list follows the log. A message while *Messages* is in a window
;; redraws it. A message while it is out of sight costs nothing: the list
;; restamps when a command runs in it. Code that wants the log as text
;; reads (messages-text), not the buffer: the list is paged, so its text
;; is one page, not the log.
(define (messages--sync!)
  (unless (buffer-exists? *messages-buffer*) (buffer-create *messages-buffer*))
  (messages--adopt! *messages-buffer*)
  (when (messages--shown? *messages-buffer*)
    (list-restamp! *messages-buffer*)))

;; The log as the Emacs text buffer had it: one line per message, oldest
;; first, newest last. A reader that remembers (string-length
;; (messages-text)) and reads the substring past it sees what was said
;; since.
(define (messages-text)
  (apply string-append
         (map (lambda (row) (string-append (plist-get row 'text) "\n"))
              (messages-events))))

;; Keep the Emacs name. The wrapper adds editor context before the primitive
;; records the event and updates the echo area.
(define (message text &optional level)
  (let* ((source (current-buffer))
         (group-id (and (boundp 'buffer-group)
                        (buffer-known? source)
                        (buffer-group source)))
         (group (if (and group-id (boundp 'group-display-name))
                    (group-display-name group-id)
                    ""))
         (project (if (and (boundp 'buffer-project-label)
                           (buffer-known? source))
                      (buffer-project-label source)
                      "")))
    (messages--primitive text (or level 'info) source group project)
    (messages--sync!)))

(define (messages-events)
  (messages-snapshot *messages-limit*))

(define (messages--level-face level)
  (cond ((equal? level "error") "alert")
        ((equal? level "warning") "warn")
        ((equal? level "debug") "dim")
        (else "accent")))

(define (messages--one-line text)
  (string-join (string-split text "\n") " ↵ "))

(define (messages--source row)
  (let ((group (or (plist-get row 'group) ""))
        (project (or (plist-get row 'project) "")))
    (cond ((not (equal? group "")) group)
          ((not (equal? project "")) project)
          (else (or (plist-get row 'source) "")))))

(define (messages--cells buf row)
  (let ((level (plist-get row 'level)))
    (list
      (list (messages--source row) "dim")
      (list (messages--one-line (plist-get row 'text))
            (messages--level-face level)))))

(define (messages--filter buf row filter-value)
  (let ((kind (car filter-value))
        (wanted (car (cdr filter-value))))
    (cond ((equal? kind "level")
           (equal? (plist-get row 'level) wanted))
          ((equal? kind "group")
           (equal? (plist-get row 'group) wanted))
          ((equal? kind "project")
           (equal? (plist-get row 'project) wanted))
          (else #t))))

(define (messages--filter-values key)
  (dedupe-names
    (filter (lambda (value) (and value (not (equal? value ""))))
            (map (lambda (row) (plist-get row key)) (messages-events)))))

(define (messages--prompt-filter prompt key candidates)
  (let ((buf (current-buffer)))
    (minibuffer-read prompt candidates
      (lambda (choice)
        (unless (equal? choice "")
          (list-filter-push! buf (list (symbol->string key) choice))
          (list-goto-first-entry buf))))))

(define-command "messages-filter-level" "Filter *Messages* by log level"
  (lambda ()
    (messages--prompt-filter "Log level: " 'level
                             '("debug" "info" "warning" "error"))))

(define-command "messages-filter-group" "Filter *Messages* by source group"
  (lambda ()
    (messages--prompt-filter "Message group: " 'group
                             (messages--filter-values 'group))))

(define-command "messages-filter-project" "Filter *Messages* by source project"
  (lambda ()
    (messages--prompt-filter "Message project: " 'project
                             (messages--filter-values 'project))))

(define-command "messages-refresh" "Refresh the structured *Messages* list"
  (lambda () (list-refresh! *messages-buffer*)))

(define-command "messages-clear" "Clear the *Messages* log"
  (lambda ()
    (messages-clear!)
    (list-refresh! *messages-buffer*)))

(define (messages--meta buf)
  (let ((rows (list-entries buf)))
    (string-append (number->string (length rows)) " messages")))

;; The stamp runs after every command in the list and after every message
;; while the list is shown, so it reads one row: the newest id moves on a
;; message, and a clear moves it back to 0.
(define (messages--stamp buf)
  (let ((last (messages-snapshot 1)))
    (if (null? last)
        '(0)
        (list (plist-get (car last) 'id)))))

(mode-icon! "messages-mode" "")

(define-list-mode! "messages-mode"
  (list
    'doc (string-append
           "*Messages* is the editor message log. Source prefers the group, then project, "
           "then buffer. Message color shows the level. `l`, `G`, and `P` filter context. "
           "`/` filters all visible text. `\\` removes the newest filter.")
    'buffer *messages-buffer*
    'rows (lambda (buf) (messages-events))
    'columns (lambda (buf)
               (list (list "source" 16 #f 'end)
                     (list "message" #f)))
    'cells messages--cells
    'title (lambda (buf) "Messages")
    'meta messages--meta
    'total (lambda (buf) (length (messages-events)))
    'key (lambda (buf row) (number->string (plist-get row 'id)))
    'filter messages--filter
    'local-filter #t
    'stamp messages--stamp
    'no-marks #t
    'footer (lambda (buf)
              '(("l" "level") ("G" "group") ("P" "project")
                ("/" "filter") ("\\" "widen") ("g" "refresh")
                ("c" "clear") ("q" "quit")))
    'keys '(("l" "messages-filter-level")
            ("G" "messages-filter-group")
            ("P" "messages-filter-project")
            ("g" "messages-refresh")
            ("c" "messages-clear")
            ("q" "quit-window"))))

(define-command "view-messages" "Display the structured *Messages* buffer"
  (lambda ()
    (let ((buf (list-mode-show! "messages-mode")))
      (when (buffer-exists? "*messages*") (buffer-kill! "*messages*"))
      buf)))

;; Emacs: C-h e is view-echo-area-messages
(global-set-key "C-h e" "view-messages")

;; The mode is defined above, so the adoption can run: on the buffer boot
;; made, and on every later creation of the name.
(on-buffer-created! messages--adopt!)
(when (buffer-exists? *messages-buffer*) (messages--adopt! *messages-buffer*))

(effects! '(read))
(public! 'messages-events
  "(messages-events) — return structured editor messages, oldest first")
(public! 'messages-text
  "(messages-text) — the log as text, one line per message, oldest first; read this, not the paged *Messages* list")
(effects! '(write display))
(public! 'message
  "(message TEXT [LEVEL]) — log TEXT with source context and show it in the echo area")
