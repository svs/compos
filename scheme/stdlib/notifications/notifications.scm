;;; notifications.scm --- passing notices, and M-x notifications for the ones that need you.
;;;
;;; (notify! SOURCE TITLE [BODY] [PROPS]) puts a notice in the event log
;;; under notify:SOURCE, so the log is the history. A new notice shows in a
;;; small stack in the corner of every frame and leaves after
;;; notifications-seconds. It takes no focus and no key. A click on it
;;; goes where it points (notifications-visit!) and takes it away.
;;; A notice with (sticky #t) stays until you act on it: a click, or a visit
;;; to its buffer. Agent attention is sticky; status updates pass.
;;; This is only the pipe: each mode subscribes to its own events and
;;; decides what makes a notice.

(require 'events)
(require 'tabulated-list)

(domain! 'interaction)
(effects! '(write))

(defcustom 'notifications-seconds 6
  "How many seconds a notice stays on screen.")

(defcustom 'notifications-max-shown 3
  "How many notices the corner shows at one time. The oldest leaves first.")

(defcustom 'notifications-history-limit 500
  "How many of the newest notices M-x notifications shows.")

(define *notifications-buffer* "*notifications*")

;; the notices on screen, newest first, as (SEQ SOURCE TITLE BODY BUFFER EVENT),
;; BUFFER the one the notice is about or #f, EVENT the notice itself; survives a reload
(define *notifications-shown* (if (boundp '*notifications-shown*) *notifications-shown* '()))

;; the open notices: what still needs the user, as (SEQ BUFFER), newest
;; first. The bell counts them and M-x notifications lists them. A notice
;; closes when it is dealt with: its BUFFER resolves (notifications-resolve!),
;; you go to it, or you mark it done (notifications-done!)
(define *notifications-open*
  (if (and (boundp '*notifications-open*) (list? *notifications-open*)) *notifications-open* '()))

(effects! '(pure))

(define (notifications--data e k) (plist-get (plist-get e 'data) k))

(define (notifications--source e)
  "notify:whatsapp is whatsapp"
  (let ((topic (plist-get e 'topic)))
    (substring topic (string-length "notify:") (string-length topic))))

(define (notifications--chrome)
  (map (lambda (n) (list (number->string (car n)) (nth 1 n) (nth 2 n) (nth 3 n)))
       *notifications-shown*))

(define (notifications--sticky? n)
  (and (> (length n) 5) (notifications--data (nth 5 n) 'sticky) #t))

(define (notifications--trim shown)
  "SHOWN cut to notifications-max-shown: the oldest passing notice leaves
first, so a notice that waits for you is not pushed off by status updates"
  (if (<= (length shown) notifications-max-shown)
      shown
      (let* ((old (reverse shown))
             (drop (or (find (lambda (n) (not (notifications--sticky? n))) old)
                       (car old))))
        (notifications--trim (filter (lambda (n) (not (eq? n drop))) shown)))))

(effects! '(write display))

(define (notifications--publish!)
  (frame-chrome-set! "notifications" (notifications--chrome)))

(define (notifications--publish-unread!)
  (frame-chrome-set! "notifications-unread"
                     (if (pair? *notifications-open*) (number->string (length *notifications-open*)) "")))

(define (notifications--open-changed!)
  "the open notices changed: the bell and the list follow"
  (notifications--publish-unread!)
  (for-each list-refresh! (notifications--lists)))

(define (notifications--lists)
  "every notifications list, one per group"
  (filter (lambda (n) (equal? (buffer-local-value 'mode-name n) "notifications-mode")) (buffer-list)))

(define (notifications-done! seq)
  "the notice SEQ is dealt with: off the screen, out of the bell and the list"
  (let ((s (if (string? seq) (string->number seq) seq)))
    (notifications-dismiss! s)
    (when (assoc s *notifications-open*)
      (set! *notifications-open* (filter (lambda (u) (not (equal? (car u) s))) *notifications-open*))
      (notifications--open-changed!))))

(define (notifications-resolve! buf)
  "what the notices about BUF asked is done or seen: take them off the screen and out of the bell's count"
  (for-each (lambda (n) (when (and (> (length n) 4) (equal? (nth 4 n) buf)) (notifications-dismiss! (car n))))
            *notifications-shown*)
  (let ((left (filter (lambda (u) (not (equal? (cadr u) buf))) *notifications-open*)))
    (unless (= (length left) (length *notifications-open*))
      (set! *notifications-open* left)
      (notifications--open-changed!))))

(define (notifications--show! e)
  (let ((seq (plist-get e 'seq))
        (sticky? (notifications--data e 'sticky)))
    (set! *notifications-shown*
          (notifications--trim
            (cons (list seq (notifications--source e)
                        (or (notifications--data e 'title) "")
                        (or (notifications--data e 'body) "")
                        (or (notifications--data e 'buffer) #f)
                        e)
                  *notifications-shown*)))
    (notifications--publish!)
    (unless sticky?
      (debounce! (string->symbol (string-append "notify-" (number->string seq)))
                 (* 1000 notifications-seconds)
                 (lambda (s) (notifications-dismiss! s))
                 seq))))

(define (notifications-dismiss! seq)
  "take the notice SEQ off the screen; it stays in the history"
  (set! *notifications-shown*
        (filter (lambda (n) (not (equal? (car n) seq))) *notifications-shown*))
  (notifications--publish!))

;; a notice about a buffer has done its job once you are in that buffer:
;; its 'buffer prop names it
(define (notifications--dismiss-here!)
  (when (or (pair? *notifications-shown*) (pair? *notifications-open*))
    (let ((here (window-buffer (active-window))))
      (when here (notifications-resolve! here)))))

(add-hook! 'post-command-hook 'notifications--dismiss-here!)

(define (notifications--saw e)
  "a notice reached the log: show it, unless it is old, as when a restart replays the log"
  (when (< (- (current-time) (plist-get e 'at)) notifications-seconds)
    (set! *notifications-open* (cons (list (plist-get e 'seq) (notifications--data e 'buffer)) *notifications-open*))
    (notifications--open-changed!)
    (notifications--show! e)))

(effects! '(write))

(define (notify! source title &optional body props)
  "(notify! SOURCE TITLE [BODY] [PROPS]) -- record a notice under notify:SOURCE and show it for a short time. PROPS is a plist kept with it, such as (topic \"whatsapp:9198...\"); (buffer BUF) takes the notice off the screen when you go to BUF, and a click goes there; (jid J) opens that WhatsApp chat, (command NAME) runs it; (sticky #t) keeps it on screen until you act on it. Return its seq"
  (event-publish! (string-append "notify:" source) 'notice
                  (append (list 'title title 'body (or body "")) (or props '()))))

(event-subscribe! "notifications" "notify:*" 'notifications--saw)

(effects! '(write display))

(define (notifications-visit! e)
  "go where the notice E points: its buffer, its WhatsApp chat, its mailbox,
or its command; #t when it went somewhere"
  (let ((buf (notifications--data e 'buffer))
        (jid (notifications--data e 'jid))
        (cmd (notifications--data e 'command)))
    (cond ((and (string? buf) (buffer-known? buf))
           (switch-to-buffer-in-group! buf) #t)
          ((and (string? jid) (boundp 'whatsapp--open-chat!))
           (whatsapp--open-chat! (list 'jid jid 'name (or (notifications--data e 'title) jid)) #t) #t)
          ((and (equal? (notifications--source e) "mail") (boundp 'mail-open!))
           (mail-open! (notifications--data e 'mailbox)) #t)
          ((string? cmd) (run-command cmd) #t)
          (else (message "This notice points nowhere") #f))))

(define (notifications-click! seq)
  "a click on the notice SEQ in the corner: take it away and go where it points"
  (let* ((s (if (string? seq) (string->number seq) seq))
         (n (find (lambda (n) (equal? (car n) s)) *notifications-shown*)))
    (notifications-done! s)
    (when (and n (> (length n) 5)) (notifications-visit! (nth 5 n)))))

;;; M-x notifications: the history

(effects! '(read))

(define (notifications--rows buf)
  "the open notices; with 'notifications-all on, the whole history"
  (let ((es (event-log-newest "notify:*" notifications-history-limit)))
    (if (buffer-local-value 'notifications-all buf)
        es
        (filter (lambda (e) (assoc (plist-get e 'seq) *notifications-open*)) es))))

(define (notifications--cells buf e)
  (list (ibuffer-age-label (- (current-time) (plist-get e 'at)))
        (notifications--source e)
        (or (notifications--data e 'title) "")
        (first-line (or (notifications--data e 'body) ""))))

(effects! '(write))

(define-list-mode! "notifications-mode"
  (list
    'doc (string-append
           "The notices that need you, newest first. A notice leaves when it is dealt with: "
           "the chat no longer waits on you, you go where it points, or you mark it done. "
           "RET or a click goes there, d marks it done, a shows every notice that passed or only the open ones. "
           "/ narrows the rows drawn. g redraws, and q quits.")
    'buffer *notifications-buffer*
    'transient #f
    'rows notifications--rows
    'key (lambda (buf e) (number->string (plist-get e 'seq)))
    'follow-head #t
    'local-filter #t
    'no-marks #t
    'columns (lambda (buf) (list (list "age" 5) (list "from" 10) (list "title" 28) (list "notice" #f)))
    'cells notifications--cells
    'title (lambda (buf) (if (buffer-local-value 'notifications-all buf) "Notifications: all" "Notifications"))
    'total (lambda (buf) (length (list-entries buf)))
    'noun "notice"
    'footer (lambda (buf) '(("RET" "go") ("d" "done") ("a" "all/open") ("/" "filter") ("g" "redraw") ("q" "quit")))
    'keys '(("RET" "notifications-visit") ("d" "notifications-done") ("a" "notifications-toggle-all")
            ("g" "notifications-refresh") ("q" "quit-window"))))

(define-command "notifications" "Show the notices that need you, newest first"
  (lambda ()
    (buffer-create *notifications-buffer*)
    (unless (buffer-local-value 'group *notifications-buffer*)
      (buffer-set-local! *notifications-buffer* 'group (frame-group)))
    (list-mode-show! "notifications-mode")))

(define-command "notifications-refresh" "Redraw the notices"
  (lambda () (when (buffer-exists? *notifications-buffer*) (list-refresh! *notifications-buffer*)))
  'modes '(notifications-mode))

(define-command "notifications-clear" "Take every notice off the screen"
  (lambda () (set! *notifications-shown* '()) (notifications--publish!)))

(define-command "notifications-visit" "Go where the notice at point points"
  (lambda ()
    (let ((e (list-current (current-buffer))))
      (if e
          (begin (notifications-done! (plist-get e 'seq)) (notifications-visit! e))
          (message "No notice on this line"))))
  'modes '(notifications-mode))

(define-command "notifications-done" "Mark the notice at point done: it leaves the list and the bell"
  (lambda ()
    (let ((e (list-current (current-buffer))))
      (if e (notifications-done! (plist-get e 'seq)) (message "No notice on this line"))))
  'modes '(notifications-mode))

(define-command "notifications-toggle-all" "Show every notice that passed, or only the open ones"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-local! buf 'notifications-all (not (buffer-local-value 'notifications-all buf)))
      (list-refresh! buf)))
  'modes '(notifications-mode))

(domain! 'interaction)
(effects! '(write display))
(public! 'notify! "(notify! SOURCE TITLE [BODY] [PROPS]) -- record a notice under notify:SOURCE and show it in the corner for notifications-seconds")
(public! 'notifications-dismiss! "(notifications-dismiss! SEQ) -- take the notice SEQ off the screen; it stays in the history")
(public! 'notifications-done! "(notifications-done! SEQ) -- the notice SEQ is dealt with: off the screen, out of the bell and the list")
(public! 'notifications-resolve! "(notifications-resolve! BUF) -- the notices about BUF are done or seen: off the screen and out of the bell's count")
(public! 'notifications-visit! "(notifications-visit! NOTICE) -- go where NOTICE points: its buffer, WhatsApp chat, mailbox or command")
(public! 'notifications-click! "(notifications-click! SEQ) -- what a click on the notice SEQ in the corner does: take it away and go where it points")
