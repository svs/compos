;;; notifications.scm --- passing notices, and M-x notifications for the history.
;;;
;;; (notify! SOURCE TITLE [BODY] [PROPS]) puts a notice in the event log
;;; under notify:SOURCE, so the log is the history. A new notice shows in a
;;; small stack in the corner of every frame and leaves after
;;; notifications-seconds. It takes no focus and no key.
;;; This is only the pipe: each mode subscribes to its own events and
;;; decides what makes a notice.

(domain! 'interaction)
(effects! '(write))

(defcustom 'notifications-seconds 6
  "How many seconds a notice stays on screen.")

(defcustom 'notifications-max-shown 3
  "How many notices the corner shows at one time. The oldest leaves first.")

(defcustom 'notifications-history-limit 500
  "How many of the newest notices M-x notifications shows.")

(define *notifications-buffer* "*notifications*")

;; the notices on screen, newest first, as (SEQ SOURCE TITLE BODY); survives a reload
(define *notifications-shown* (if (boundp '*notifications-shown*) *notifications-shown* '()))

(effects! '(pure))

(define (notifications--data e k) (plist-get (plist-get e 'data) k))

(define (notifications--source e)
  "notify:whatsapp is whatsapp"
  (let ((topic (plist-get e 'topic)))
    (substring topic (string-length "notify:") (string-length topic))))

(define (notifications--chrome)
  (map (lambda (n) (list (number->string (car n)) (nth 1 n) (nth 2 n) (nth 3 n)))
       *notifications-shown*))

(effects! '(write display))

(define (notifications--publish!)
  (frame-chrome-set! "notifications" (notifications--chrome)))

(define (notifications-dismiss! seq)
  "take the notice SEQ off the screen; it stays in the history"
  (set! *notifications-shown*
        (filter (lambda (n) (not (equal? (car n) seq))) *notifications-shown*))
  (notifications--publish!))

(define (notifications--show! e)
  (let ((seq (plist-get e 'seq)))
    (set! *notifications-shown*
          (take (cons (list seq (notifications--source e)
                            (or (notifications--data e 'title) "")
                            (or (notifications--data e 'body) ""))
                      *notifications-shown*)
                (min notifications-max-shown (+ 1 (length *notifications-shown*)))))
    (notifications--publish!)
    (debounce! (string->symbol (string-append "notify-" (number->string seq)))
               (* 1000 notifications-seconds)
               (lambda (s) (notifications-dismiss! s))
               seq)))

(define (notifications--saw e)
  "a notice reached the log: show it, unless it is old, as when a restart replays the log"
  (when (< (- (current-time) (plist-get e 'at)) notifications-seconds)
    (notifications--show! e)))

(effects! '(write))

(define (notify! source title &optional body props)
  "(notify! SOURCE TITLE [BODY] [PROPS]) -- record a notice under notify:SOURCE and show it for a short time. PROPS is a plist kept with it, such as (topic \"whatsapp:9198...\"). Return its seq"
  (event-publish! (string-append "notify:" source) 'notice
                  (append (list 'title title 'body (or body "")) (or props '()))))

(event-subscribe! "notifications" "notify:*" 'notifications--saw)

;;; M-x notifications: the history

(effects! '(read))

(define (notifications--rows buf)
  (event-log-newest "notify:*" notifications-history-limit))

(define (notifications--cells buf e)
  (list (ibuffer-age-label (- (current-time) (plist-get e 'at)))
        (notifications--source e)
        (or (notifications--data e 'title) "")
        (first-line (or (notifications--data e 'body) ""))))

(effects! '(write))

(define-list-mode! "notifications-mode"
  (list
    'doc (string-append
           "The notices, newest first. Each one passed in the corner for a few seconds. "
           "/ narrows the rows drawn. The list follows new notices while it is on screen. "
           "g redraws, and q quits.")
    'buffer *notifications-buffer*
    'transient #f
    'rows notifications--rows
    'key (lambda (buf e) (number->string (plist-get e 'seq)))
    'follow-head #t
    'local-filter #t
    'no-marks #t
    'columns (lambda (buf) (list (list "age" 5) (list "from" 10) (list "title" 28) (list "notice" #f)))
    'cells notifications--cells
    'title (lambda (buf) "Notifications")
    'total (lambda (buf) (length (list-entries buf)))
    'noun "notice"
    'footer (lambda (buf) '(("/" "filter") ("g" "redraw") ("q" "quit")))
    'keys '(("g" "notifications-refresh") ("q" "quit-window"))))

(define-command "notifications" "Show the notices that passed, newest first"
  (lambda ()
    (buffer-create *notifications-buffer*)
    (unless (buffer-local *notifications-buffer* 'group)
      (buffer-set-local! *notifications-buffer* 'group (frame-group)))
    (list-mode-show! "notifications-mode")))

(define-command "notifications-refresh" "Redraw the notices"
  (lambda () (when (buffer-exists? *notifications-buffer*) (list-refresh! *notifications-buffer*))))

(define-command "notifications-clear" "Take every notice off the screen"
  (lambda () (set! *notifications-shown* '()) (notifications--publish!)))

(domain! 'interaction)
(effects! '(write display))
(public! 'notify! "(notify! SOURCE TITLE [BODY] [PROPS]) -- record a notice under notify:SOURCE and show it in the corner for notifications-seconds")
(public! 'notifications-dismiss! "(notifications-dismiss! SEQ) -- take the notice SEQ off the screen; it stays in the history")
