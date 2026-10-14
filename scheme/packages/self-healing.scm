;;; self-healing.scm --- every error the daemon logs gets a chat that looks into it.
;;;
;;; Compos.Core.ErrorFeed writes each error the daemon logs to the topic
;;; compos:error, with its text and a signature: the text with what changes
;;; between occurrences blanked. The workflow "self-healing" takes the
;;; errors in bursts, one group per signature.
;;;
;;; A signature with no open task gets one in the compos project, and a new
;;; chat in the group self-healing-group gets the task as its brief. The chat
;;; finds the cause, fixes it, and puts the task in review. A repeat of an
;;; error under investigation only adds a line to its task's log. An error
;;; that comes back after its task closed gets a new task.
;;;
;;; At most self-healing-max-chats investigations run at once. Past that, a
;;; new error is filed in the inbox with no chat, so a chat that itself makes
;;; errors cannot start chats without end.

(require 'workflows)
(require 'todo)

(domain! 'system)
(effects! '(pure))

(defgroup 'self-healing "A chat for every error the daemon logs.")

(defcustom 'self-healing-enabled #t
  "Start a chat for every new error the daemon logs. Off, the errors stay in the event log only.")

(defcustom 'self-healing-group "self-healing"
  "The group the investigating chats start in.")

(defcustom 'self-healing-project "compos"
  "The todo project the error tasks are filed in.")

(defcustom 'self-healing-max-chats 3
  "How many investigations run at once. Past this, a new error goes to the inbox with no chat.")

(defcustom 'self-healing-brief
  "Find the cause of this error in the compos source. Fix it when the fix is clear and small, and check it with one focused test. Otherwise describe the cause and the fix you propose. Do not restart the daemon. Then put the task in review with what you found."
  "What the chat is asked to do with the error, ahead of the error itself.")

(define self-healing--source-prefix "compos:error ")

(define (self-healing--data e key)
  (let ((d (plist-get e 'data)))
    (or (and (pair? d) (plist-get d key)) "")))

(define (self-healing--signature e)
  ;; trimmed: the todo file drops the edge spaces of a source, and
  ;; self-healing--open-for compares sources by prefix
  (let ((sig (string-trim (self-healing--data e 'signature))))
    (if (equal? sig "") (first-line (self-healing--data e 'text)) sig)))

(define (self-healing--source sig)
  (string-append self-healing--source-prefix sig))

(effects! '(read))

(define (self-healing-open)
  "every open error task, most urgent first"
  (todo-list (list 'source self-healing--source-prefix)))

(define (self-healing--open-for sig)
  (let ((src (self-healing--source sig)))
    (let loop ((ts (self-healing-open)))
      (cond ((null? ts) #f)
            ((string-prefix? src (or (plist-get (car ts) 'source) "")) (car ts))
            (else (loop (cdr ts)))))))

(define (self-healing--running)
  (length (filter (lambda (t) (equal? (plist-get t 'state) "doing")) (self-healing-open))))

(effects! '(write external spend))

(define (self-healing--title sig)
  (let ((line (car (split-lines sig))))
    (string-append "Error: "
                   (if (> (string-length line) 100) (substring line 0 100) line))))

(define (self-healing--notes e n)
  (string-append self-healing-brief
                 "\n\nIt was logged " (number->string n)
                 (if (= n 1) " time" " times")
                 " in this burst. The first is event " (number->string (plist-get e 'seq))
                 " on compos:error, and the daemon log is ~/.compos/daemon.log.\n\n"
                 (self-healing--data e 'text)))

;; A source names one task for ever: todo-create gives back a closed task
;; with the same source. An error that returns after its task closed gets a
;; source of its own, the seq of the event that brought it back.
(define (self-healing--new-source sig e)
  (let ((src (self-healing--source sig)))
    (if (null? (todo-list (list 'all #t 'source src)))
        src
        (string-append src " #" (number->string (plist-get e 'seq))))))

(define (self-healing--file! sig events)
  (let* ((e (car events))
         (chat? (< (self-healing--running) self-healing-max-chats))
         (id (todo-create (self-healing--title sig)
                          (list 'project self-healing-project
                                'state (if chat? "todo" "inbox")
                                'tags "self-healing"
                                'group (group-ensure-record! self-healing-group)
                                'source (self-healing--new-source sig e)
                                'notes (self-healing--notes e (length events))))))
    (when chat? (todo-assign-chat! id self-healing-group))
    id))

(define (self-healing--handle sig events)
  (when (and self-healing-enabled (pair? events))
    (once! (string-append "self-healing:" (number->string (plist-get (car events) 'seq)))
           (lambda ()
             (let ((open (self-healing--open-for sig)))
               (if open
                   (todo-log (plist-get open 'id)
                             (string-append "logged again, " (number->string (length events))
                                            " times from event "
                                            (number->string (plist-get (car events) 'seq))))
                   (self-healing--file! sig events)))))))

(effects! '(write))

(define-workflow! "self-healing"
  'listen   '("compos:error")
  'group-by 'self-healing--signature
  'quiet    (seconds 5)
  'handle   'self-healing--handle)

(domain! 'system)
(effects! '(read))
(public! 'self-healing-open "(self-healing-open) — every open task for a logged error, most urgent first")

(provide 'self-healing)
