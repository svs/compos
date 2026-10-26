;;; messages.scm --- Structured *Messages* list and filters.

(domain! 'system)
(effects! '(write display))

(define *messages-buffer* "*Messages*")
(define *messages-limit* 2000)
(define messages--primitive message-emit)

(defgroup 'messages "The editor message log, its list, and its watches.")

(defcustom 'messages-text-scale -1
  "Text size of *Messages*, as a step on the 1.2 ladder; 0 is the normal size."
  'group 'messages 'type 'number)

(defcustom 'messages-wide-cols 92
  "From this width, *Messages* adds the mode and source columns."
  'group 'messages 'type 'number)

(defcustom 'messages-page-size 60
  "Rows of *Messages* that one draw writes. A message while the list is shown redraws the page and sends it to the browser."
  'group 'messages 'type 'number)

;; A log is read in bulk, so it wears a smaller face than a document. The
;; step is the one C-+ and C-_ move, and the buffer's own value wins once
;; it has one: a reader who resized this list keeps their size, including
;; the 0 that text-scale-reset writes.
(define (messages--scale! name)
  (when (not (number? (buffer-local name 'text-scale)))
    (buffer-set-local! name 'text-scale messages-text-scale)
    (text-scale-sync! name)))

;; Remove the pre-Emacs spelling when this package first loads.
(when (buffer-exists? "*messages*") (buffer-kill! "*messages*"))

;; *Messages* is the list, always. Emacs: *Messages* is never editable.
;; Session makes the buffer at boot as a plain buffer, and a kill can make
;; it go; this adoption puts messages-mode on the name at load and each
;; time the name is created again, so no path shows the raw buffer.
(define (messages--adopt! name)
  (when (equal? name *messages-buffer*)
    (unless (equal? (buffer-local name 'mode-name) "messages-mode")
      (buffer-set-local! name 'mode-name "messages-mode")
      (list-mode-init! name "messages-mode")
      (list-refresh! name))
    (messages--scale! name)))

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

;; --- Watches ---------------------------------------------------------
;;
;; A watch is a name, a grammar, and a reaction. Every message the log
;; records is offered to every watch; a watch whose grammar matches runs
;; its reaction on the event.
;;
;; The grammar is a plist over the event's own fields. 'level, 'source,
;; 'group and 'project match a field exactly. 'match is a regular
;; expression over the message text, and what it captures is handed to the
;; reaction as a second argument. An absent field matches anything, so the
;; empty grammar watches every message.
;;
;;   (messages-watch! "deploys" '(level "error" match "deploy ([a-z-]+)")
;;     (lambda (row caps) (chat-notify (nth 1 caps))))
;;
;; A reaction that logs its own message does not re-enter the watches: the
;; dispatch is closed while it runs. A reaction that raises is ignored, so
;; one bad watch cannot stop the log.
(define *messages-watches* '())
(define *messages-watching* #f)

(define (messages--watch-others name)
  (filter (lambda (w) (not (equal? (car w) name))) *messages-watches*))

(define (messages--field-match? row key wanted)
  (or (not wanted) (equal? (or (plist-get row key) "") wanted)))

;; #f when the grammar does not match. A grammar that matches answers its
;; regexp captures, or the empty list when it has no regexp.
(define (messages-watch-captures row grammar)
  (and (messages--field-match? row 'level (plist-get grammar 'level))
       (messages--field-match? row 'source (plist-get grammar 'source))
       (messages--field-match? row 'group (plist-get grammar 'group))
       (messages--field-match? row 'project (plist-get grammar 'project))
       (let ((re (plist-get grammar 'match)))
         (if re (re-match re (or (plist-get row 'text) "")) '()))))

(define (messages-watch! name grammar fn)
  (set! *messages-watches*
        (append (messages--watch-others name) (list (list name grammar fn))))
  name)

(define (messages-unwatch! name)
  (set! *messages-watches* (messages--watch-others name))
  name)

(define (messages-watches)
  (map (lambda (w) (list (car w) (nth 1 w))) *messages-watches*))

(define (messages-newest)
  (let ((rows (messages-snapshot 1)))
    (and (pair? rows) (car rows))))

(define (messages--notify! row)
  (when (and row (pair? *messages-watches*) (not *messages-watching*))
    (set! *messages-watching* #t)
    (for-each
      (lambda (w)
        (let ((caps (messages-watch-captures row (nth 1 w))))
          (when caps
            (ignore-errors (lambda () ((nth 2 w) row caps) #t)))))
      *messages-watches*)
    (set! *messages-watching* #f)))

;; The mode a buffer was in when it spoke. The list cannot ask each source
;; buffer for its mode while it draws: that is a call into every buffer's
;; process, once per row, which is the cost docs/LISTS.md rule 1 names —
;; and a buffer that has since changed mode, or been killed, could not
;; answer honestly anyway. So the mode is read once, on the message, and
;; kept here by name. The map is bounded: a long session names more
;; buffers than a log keeps rows.
(define *messages-modes* '())
(define *messages-modes-limit* 256)

(define (messages--first n xs)
  (if (or (= n 0) (null? xs)) '() (cons (car xs) (messages--first (- n 1) (cdr xs)))))

(define (messages--note-mode! source)
  (let ((mode (and (buffer-known? source) (buffer-local source 'mode-name))))
    (when mode
      (set! *messages-modes*
            (messages--first *messages-modes-limit*
              (cons (list source mode)
                    (filter (lambda (e) (not (equal? (car e) source)))
                            *messages-modes*)))))))

(define (messages--mode-of source)
  (let ((e (assoc source *messages-modes*)))
    (and e (nth 1 e))))

;; A column says "scheme", not "scheme-mode": every row would carry the
;; same five characters, and the icon already says it is a mode.
(define (messages--short-mode mode)
  (if (and mode (string-suffix? "-mode" mode))
      (substring mode 0 (- (string-length mode) 5))
      (or mode "")))

(define (messages--mode-label row)
  (let ((mode (messages--mode-of (or (plist-get row 'source) ""))))
    (if mode
        (string-append (mode-icon mode) " " (messages--short-mode mode))
        "")))

;; Keep the Emacs name. The wrapper adds editor context before the primitive
;; records the event and updates the echo area.
(define (message text &optional level)
  (let* ((source (current-buffer))
         (group-id (and (buffer-known? source) (buffer-group source)))
         (group (if (and group-id (boundp 'group-display-name))
                    (group-display-name group-id)
                    ""))
         (project (if (buffer-known? source)
                      (buffer-project-label source)
                      "")))
    (messages--note-mode! source)
    (messages--primitive text (or level 'info) source group project)
    (messages--sync!)
    (messages--notify! (messages-newest))))

(define (messages-events)
  (messages-snapshot *messages-limit*))

;; The colour code. A level is one colour, worn by the level chip and by
;; the message text alike: error red, warning amber, debug grey, info the
;; accent. Info is the ordinary case, so only its chip is coloured and its
;; text stays in the default face — the colours mean something because
;; most lines have none.
(define (messages--level-face level)
  (cond ((equal? level "error") "error")
        ((equal? level "warning") "warn")
        ((equal? level "debug") "dim")
        (else "accent")))

;; #f, not "default": the default face is the one the buffer's own font
;; size and background come from, so a span wearing it re-states both and
;; ignores the text scale. An ordinary message wants no face at all.
(define (messages--text-face level)
  (cond ((equal? level "error") "error")
        ((equal? level "warning") "warn")
        ((equal? level "debug") "dim")
        (else #f)))

(define (messages--level-label level)
  (cond ((equal? level "error") "error")
        ((equal? level "warning") "warn")
        ((equal? level "debug") "debug")
        (else "info")))

(define (messages--one-line text)
  (string-join (string-split text "\n") " ↵ "))

;; The buffer that spoke. The group and the project are one value for
;; almost every row of a session, so a column spent on them said nothing;
;; they are still on the event, and `G` and `P` still filter by them.
(define (messages--source row)
  (or (plist-get row 'source) ""))

(define (messages--time row)
  (let ((ms (plist-get row 'time-ms)))
    (if (number? ms) (format-time (quotient ms 1000) "%H:%M:%S") "")))

(define (messages--cells buf row)
  (let ((level (plist-get row 'level)))
    (list
      (list (messages--time row) "dim")
      (list (messages--level-label level) (messages--level-face level))
      (list (messages--mode-label row) "dim")
      (list (messages--source row) "dim")
      (list (messages--one-line (plist-get row 'text))
            (messages--text-face level)))))

;; Four columns of provenance in front of a message is three too many in a
;; narrow window: the message is what the reader came for, and it collapsed
;; to an ellipsis. Below messages-wide-cols the mode and the source go.
(define (messages--narrow-cells buf row)
  (let ((level (plist-get row 'level)))
    (list
      (list (messages--time row) "dim")
      (list (messages--level-label level) (messages--level-face level))
      (list (messages--one-line (plist-get row 'text))
            (messages--text-face level)))))

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

(define-command "messages-watch-list" "Say which message watches are in force"
  (lambda ()
    (let ((ws (messages-watches)))
      (message
        (if (null? ws)
            "no message watches"
            (string-append
              "watching: "
              (string-join (map (lambda (w) (car w)) ws) ", ")))))))

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
           "*Messages* is the editor message log, newest line first. Mode and source name "
           "the buffer that spoke, in the mode it was in then. The level column carries "
           "the colour code: "
           "error red, warning amber, debug grey, info accent. `l`, `G`, and `P` filter "
           "context. `/` filters all visible text. `\\` removes the newest filter. `w` "
           "says which watches are in force.")
    'buffer *messages-buffer*
    'rows (lambda (buf) (messages-events))
    ;; The log arrives oldest first. A reader opens this list to see what
    ;; just happened, so the order is turned over after the filters have
    ;; run and before the page is cut: the newest message is the top row.
    'order-filtered (lambda (buf rows) (reverse rows))
    'layouts
      (list
        (list 'name 'narrow
              'max-cols (lambda (buf) (- messages-wide-cols 1))
              'columns (lambda (buf)
                         (list (list "time" 8)
                               (list "level" 5)
                               (list "message" #f)))
              'cells messages--narrow-cells)
        (list 'name 'wide
              'default #t
              'columns (lambda (buf)
                         (list (list "time" 8)
                               (list "level" 5)
                               (list "mode" 11)
                               (list "source" 16 #f 'end)
                               (list "message" #f)))
              'cells messages--cells))
    'cells messages--cells
    'title (lambda (buf) "Messages")
    'meta messages--meta
    'total (lambda (buf) (length (messages-events)))
    'key (lambda (buf row) (number->string (plist-get row 'id)))
    'filter messages--filter
    'local-filter #t
    'stamp messages--stamp
    ;; A shown list redraws on every message. Without a page, each message
    ;; sends every row of the log to the browser.
    'page-size (lambda (buf) messages-page-size)
    'no-marks #t
    ;; The keys live in the shared ui/keymap component, pinned under the
    ;; rows: it wraps at the window width instead of dropping hints off
    ;; the end of a header line.
    'footer (lambda (buf)
              '(("l" "level") ("G" "group") ("P" "project")
                ("/" "filter") ("\\" "widen") ("g" "refresh")
                ("w" "watches") ("c" "clear") ("q" "quit")))
    'keys '(("l" "messages-filter-level")
            ("G" "messages-filter-group")
            ("P" "messages-filter-project")
            ("g" "messages-refresh")
            ("w" "messages-watch-list")
            ("c" "messages-clear")
            ("q" "quit-window"))))

(define-command "view-messages" "Display the structured *Messages* buffer"
  (lambda ()
    (let ((buf (list-mode-show! "messages-mode")))
      (when (buffer-exists? "*messages*") (buffer-kill! "*messages*"))
      buf)))

;; Emacs: C-h e is view-echo-area-messages
(define-key "help-map" "e" "view-messages")

;; The mode is defined above, so the adoption can run: on the buffer boot
;; made, and on every later creation of the name.
(add-hook! 'buffer-created-hook 'messages--adopt!)
(when (buffer-exists? *messages-buffer*) (messages--adopt! *messages-buffer*))

(effects! '(read))
(public! 'messages-events
  "(messages-events) — return structured editor messages, oldest first")
(public! 'messages-text
  "(messages-text) — the log as text, one line per message, oldest first; read this, not the paged *Messages* list")
(effects! '(write display))
(public! 'message
  "(message TEXT [LEVEL]) — log TEXT with source context and show it in the echo area")

(effects! '(read))
(public! 'messages-watches
  "(messages-watches) — every watch in force, as (NAME GRAMMAR) pairs")
(public! 'messages-newest
  "(messages-newest) — the newest logged message as an event plist, or #f")
(effects! '(write))
(public! 'messages-watch!
  "(messages-watch! NAME GRAMMAR FN) — run (FN EVENT CAPTURES) on every message GRAMMAR matches; GRAMMAR is a plist of 'level 'source 'group 'project and a 'match regexp, and an absent field matches anything")
(public! 'messages-unwatch!
  "(messages-unwatch! NAME) — drop the watch named NAME")
