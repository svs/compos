;;; window-log.scm --- every change of the windows, as it happened.
;;;
;;; A command that changes the frame's windows leaves a record: the windows
;;; before, the action, the windows after. A change between commands (a kill
;;; from an agent, a display from another lane) is recorded too, as the
;;; command that found it. A door that knows what it did adds a note, so
;;; the record says "panes-visit b.scm -> w1" and not only
;;; "switch-to-buffer".
;;;
;;;   M-x debug-last-window-movement   the last change as a diff, in *window-log*
;;;   M-x debug-window-movements        the last ten
;;;   (window-log [N])                  the records, newest first, for an agent
;;;
;;; winner keeps arrangements to go back to; this keeps the story of how the
;;; screen got here.

(domain! 'windows)
(effects! '(write))

(define *window-log-depth* 50)

;; the frame's windows now, as one plain value
(define (window-log-snapshot)
  (list 'windows (window-list)
        'hidden (window-hidden-list)
        'active (active-window)
        'group (and (boundp 'frame-group) (frame-group))
        'layout (and (boundp 'panes-layout) (panes-layout))))

;; the parts of a snapshot that mean the windows changed
(define (window-log--shape snap)
  (list (plist-get snap 'windows) (plist-get snap 'hidden) (plist-get snap 'active)))

(define (window-log) (or (frame-local 'window-log) '()))

;; a door that knows what it did says so; the note joins the next record
(define (window-log-note! &rest parts)
  (set-frame-local! 'window-log-notes
    (append (or (frame-local 'window-log-notes) '())
            (list (string-join (map (lambda (p) (if (string? p) p (format "~s" p))) parts) " ")))))

(define (window-log--record! action before after)
  (let ((entry (list 'time (current-time) 'ms (monotonic-ms)
                     'action action
                     'notes (or (frame-local 'window-log-notes) '())
                     'before before 'after after)))
    (set-frame-local! 'window-log (take (cons entry (window-log)) *window-log-depth*))
    (set-frame-local! 'window-log-notes '())
    (run-hook-with-args 'window-log-hook entry)
    entry))

;; before a command: a change since the last command is recorded on its
;; own, with the notes left since then; a note with no change behind it
;; belongs to nothing and goes
(define (window-log--pre!)
  (let ((now (window-log-snapshot))
        (last (frame-local 'window-log-after)))
    (if (and last (not (equal? (window-log--shape last) (window-log--shape now))))
        (window-log--record! "(between commands)" last now)
        (set-frame-local! 'window-log-notes '()))
    (set-frame-local! 'window-log-before now)))

;; after a command: a change is recorded as that command
(define (window-log--post! &optional action)
  (let ((before (frame-local 'window-log-before))
        (now (window-log-snapshot)))
    (when (and before (not (equal? (window-log--shape before) (window-log--shape now))))
      (window-log--record! (or action (this-command) "?") before now))
    (set-frame-local! 'window-log-after now)
    (set-frame-local! 'window-log-before #f)))

(add-hook! 'pre-command-hook 'window-log--pre!)
(add-hook! 'post-command-hook 'window-log--post!)

;; the windows of a snapshot as text: [WIN BUFFER] rows, the active one starred
(define (window-log--row snap)
  (let ((active (plist-get snap 'active)))
    (string-join
      (map (lambda (r) (string-append "[" (if (equal? (car r) active) "*" "") (number->string (car r)) " " (cadr r) "]"))
           (plist-get snap 'windows))
      " ")))

(define (window-log--hidden snap)
  (let ((hs (plist-get snap 'hidden)))
    (if (null? hs) "none"
        (string-join (map (lambda (r) (string-append "[" (number->string (car r)) " " (cadr r) "]")) hs) " "))))

(define (window-log--layout snap)
  (let ((l (plist-get snap 'layout)))
    (if (not l) "none"
        (string-join
          (map (lambda (p)
                 (string-append (plist-get p 'id) "("
                                (string-join (map (lambda (k) (string-append k ":" (or (panes-window-buffer l k) "-")
                                                                            (let ((n (length (panes-window-buffers l k)))) (if (> n 1) (string-append "+" (number->string (- n 1))) ""))))
                                                  (or (plist-get p 'windows) '()))
                                             " ")
                                ")"))
               (panes-panes l))
          " "))))

;; the windows whose buffer changed, came or went, between two snapshots
(define (window-log--changes before after)
  (let* ((b (plist-get before 'windows)) (a (plist-get after 'windows))
         (ids (let loop ((rs (append b a)) (acc '()))
                (cond ((null? rs) (reverse acc))
                      ((member (car (car rs)) acc) (loop (cdr rs) acc))
                      (else (loop (cdr rs) (cons (car (car rs)) acc)))))))
    (filter (lambda (s) s)
      (map (lambda (id)
             (let ((was (assoc id b)) (is (assoc id a)))
               (cond ((and was is (equal? (cadr was) (cadr is))) #f)
                     ((and was is) (string-append "  window " (number->string id) ": " (cadr was) " -> " (cadr is)))
                     (was (string-append "  window " (number->string id) " left the screen (" (cadr was) ")"))
                     (else (string-append "  window " (number->string id) " came on screen (" (cadr is) ")")))))
           ids))))

;; one record as text
(define (window-log-report entry)
  (let ((before (plist-get entry 'before)) (after (plist-get entry 'after)))
    (string-join
      (append
        (list (string-append (format-time (plist-get entry 'time) "%H:%M:%S") "  " (plist-get entry 'action)
                             (let ((g (plist-get after 'group))) (if g (string-append "   group " (if (boundp 'group-name) (group-name g) g)) "")))
              (string-append "  active: " (number->string (or (plist-get before 'active) 0)) " -> " (number->string (or (plist-get after 'active) 0)))
              (string-append "  before: " (window-log--row before))
              (string-append "  after:  " (window-log--row after)))
        (window-log--changes before after)
        (map (lambda (n) (string-append "  note: " n)) (plist-get entry 'notes))
        (list (string-append "  hidden before: " (window-log--hidden before))
              (string-append "  hidden after:  " (window-log--hidden after))
              (string-append "  layout before: " (window-log--layout before))
              (string-append "  layout after:  " (window-log--layout after))))
      "\n")))

;; the records worth showing: not the ones this log's own display made
(define (window-log--shown)
  (filter (lambda (e) (not (string-prefix? "debug-" (plist-get e 'action)))) (window-log)))

(define *window-log-buffer* "*window-log*")

(define (window-log-show! n)
  (let* ((entries (take (window-log--shown) (min n (length (window-log--shown)))))
         (text (if (null? entries)
                   "No window change recorded yet in this frame."
                   (string-join (map window-log-report entries) "\n\n"))))
    (buffer-create *window-log-buffer*)
    (buffer-set-text! *window-log-buffer* text)
    (buffer-set-local! *window-log-buffer* 'read-only #t)
    (display-buffer-other-window! *window-log-buffer*)
    text))

(define-command "debug-last-window-movement"
  "Show the last change of this frame's windows: before, the action, after"
  (lambda () (window-log-show! 1)))

(define-command "debug-window-movements"
  "Show the last ten changes of this frame's windows, newest first"
  (lambda () (window-log-show! 10)))

(public! 'window-log "(window-log) -> this frame's window changes, newest first: (time action notes before after); before and after hold windows, hidden, active, group and layout")
(catalog-meta! 'function "window-log" 'effects '(read))
(public! 'window-log-report "(window-log-report ENTRY) -> one record of (window-log) as text")
(catalog-meta! 'function "window-log-report" 'effects '(pure))
(public! 'window-log-note! "(window-log-note! PART ...) -> add a note to the window change the current command is making")
