;;; modeline-test.scm — buffer modelines keep compact names.

(domain! 'testing)
(effects! '(write execute))

(define t--modeline-root
  (string-append (compos-home) "/zz-modeline-project"))

(define (t--modeline-reset!)
  (shell-command->string (string-append "rm -rf " t--modeline-root)))

(deftest 'a-project-file-keeps-a-project-relative-buffer-modeline-name
  "the buffer modeline stays compact while the frame bar owns the full path"
  (lambda ()
    (t--modeline-reset!)
    (make-directory! (string-append t--modeline-root "/.git"))
    (let ((path (string-append t--modeline-root "/lib/example.scm")))
      (make-directory! (string-append t--modeline-root "/lib"))
      (write-file! path "(display \"example\")\n")
      (visit path)
      (dashboard--sync! path)
      (check-equal! (buffer-modeline-name path) "lib/example.scm"
                    "the buffer modeline policy returns project coordinates")
      (check-equal! (buffer-local path 'modeline-name) "lib/example.scm"
                    "the rendered buffer modeline stores the compact name")
      (buffer-kill! path))
    (t--modeline-reset!)))

(deftest 'a-non-file-buffer-keeps-its-buffer-name-in-the-modeline
  "the file path policy does not rename a non-file buffer"
  (lambda ()
    (let ((buf "*zz-modeline-non-file*"))
      (test-buffer! buf "")
      (check-equal! (buffer-modeline-name buf) buf
                    "the non-file buffer keeps its name")
      (buffer-kill! buf))))

;; the dashboard line pulls the summary and the jj line from state, so a
;; buffer with no file shows both when it has them
(define (t--dseg-value blocks key)
  (let loop ((bs blocks))
    (cond ((null? bs) #f)
          ((and (pair? (car bs))
                (equal? (plist-get (car bs) 'tag) "div")
                (let ((kids (plist-get (car bs) 'children)))
                  (and (pair? kids)
                       (equal? (plist-get (car kids) 'text) key))))
           (cadr (car (plist-get (cadr (plist-get (car bs) 'children)) 'segs))))
          (else (loop (cdr bs))))))

(deftest 'a-chat-shows-its-running-summary-in-the-dashboard-line
  "the summary segment carries the chat-summary local; a chat without one shows no segment"
  (lambda ()
    (let ((buf "*chat:zz-modeline-summary*"))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "chat-mode")
      (check-equal! (t--dseg-value (dashboard-line-blocks buf) "summary") #f
                    "no summary yet, no segment")
      (buffer-set-local! buf 'chat-summary "The user is testing the bar.")
      (check-equal! (t--dseg-value (dashboard-line-blocks buf) "summary")
                    "The user is testing the bar."
                    "the segment shows the paragraph")
      ;; the summary takes the one wide slot; the jj line steps back
      (let ((dir "/zz-modeline-sum-repo/") (root "/zz-modeline-sum-repo")
            (lines *jj-lines*) (roots *jj-dir-roots*))
        (buffer-set-local! buf 'default-directory dir)
        (set! *jj-dir-roots* (cons (list dir root) *jj-dir-roots*))
        (set! *jj-lines* (cons (list root "jj: open") *jj-lines*))
        (check-equal! (t--dseg-value (dashboard-line-blocks buf) "jj") #f
                      "no jj segment beside a summary")
        (set! *jj-lines* lines)
        (set! *jj-dir-roots* roots))
      (buffer-kill! buf))))

(deftest 'a-buffer-without-a-file-shows-the-jj-line-of-its-directory
  "the jj segment comes from the per-root cache through the buffer's directory"
  (lambda ()
    (let ((buf "*zz-modeline-jj*")
          (dir "/zz-modeline-jj-repo/sub/")
          (root "/zz-modeline-jj-repo")
          (lines *jj-lines*)
          (roots *jj-dir-roots*))
      (test-buffer! buf "")
      (buffer-set-local! buf 'default-directory dir)
      (set! *jj-dir-roots* (cons (list dir root) *jj-dir-roots*))
      (set! *jj-lines* (cons (list root "jj: the open change") *jj-lines*))
      (check-equal! (jj-modeline-line buf) "jj: the open change"
                    "the line comes from the cache, not from a shell call")
      (check-equal! (t--dseg-value (dashboard-line-blocks buf) "jj") "jj: the open change"
                    "the dashboard line shows it")
      (set! *jj-lines* lines)
      (set! *jj-dir-roots* roots)
      (buffer-kill! buf))))

(deftest 'the-summary-log-interleaves-summaries-and-jj-lines-by-time
  "every paragraph lands in chat-summary-log; the entries merge with the repo's line history in time order"
  (lambda ()
    (let ((buf "*chat:zz-modeline-log*")
          (dir "/zz-modeline-log-repo/") (root "/zz-modeline-log-repo")
          (lines *jj-lines*) (roots *jj-dir-roots*) (hist *jj-history*))
      (test-buffer! buf "")
      (buffer-set-local! buf 'mode-name "chat-mode")
      (buffer-set-local! buf 'chat-turn-active #t)   ; no archive write here
      (buffer-set-local! buf 'default-directory dir)
      (set! *jj-dir-roots* (cons (list dir root) *jj-dir-roots*))
      (set! *jj-lines* (cons (list root "jj: second") *jj-lines*))
      (set! *jj-history* (list (list root 2000 "jj: second") (list root 1000 "jj: first")))
      (buffer-set-local! buf 'chat-summary "from before the log")
      (check-equal! (map caddr (buffer-summary-log-entries buf))
                    '("from before the log" "jj: first" "jj: second")
                    "a chat from before the log shows its one paragraph, undated")
      (chat-summary-land! buf "first paragraph")
      (chat-summary-land! buf "second paragraph")
      (check-equal! (buffer-local buf 'chat-summary) "second paragraph"
                    "the bar's local is the latest")
      (check-equal! (map cadr (buffer-local buf 'chat-summary-log))
                    '("second paragraph" "first paragraph")
                    "the log keeps every paragraph, newest first")
      (let ((entries (buffer-summary-log-entries buf)))
        (check-equal! (map cadr entries) '(jj jj summary summary)
                      "old jj lines come first, today's summaries after")
        (check-equal! (caddr (car entries)) "jj: first" "oldest first"))
      (check-equal! (plist-get (car (reverse (dashboard-line-blocks buf))) 'click)
                    "summary-log"
                    "the wide segment opens the log")
      (set! *jj-lines* lines)
      (set! *jj-dir-roots* roots)
      (set! *jj-history* hist)
      (buffer-kill! buf))))
