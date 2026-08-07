;;; ibuffer.scm --- the buffer list as a dired: filter, mark, act.
;;;
;;; C-x C-b (or M-x ibuffer) pops *ibuffer*: one line per buffer, MRU
;;; order — modified flag, size, mode, name. Same narrowing language as
;;; dired: / m major mode · / n name regex · / p pop · / / clear.
;;; d flags for killing, x executes, u unmarks, RET visits, g refreshes.
;;; Internals (space-prefixed) stay hidden.

(define *ibuffer-buffer* "*ibuffer*")
(add-display-rule! *ibuffer-buffer* 'popup)

(define (ibuffer-filters)
  (or (buffer-local *ibuffer-buffer* 'ibuffer-filters) '()))

(define (ibuffer-filter-match? b f)
  (let ((kind (car f)) (arg (car (cdr f))))
    (cond ((equal? kind "mode")
           (equal? (or (buffer-local b 'mode-name) "") arg))
          ((equal? kind "name") (re-match? arg b))
          (else #t))))

(define (ibuffer-visible)
  (filter (lambda (b)
            (and (not (equal? b *ibuffer-buffer*))
                 (not (string-prefix? " " b))
                 (let loop ((fs (ibuffer-filters)))
                   (cond ((null? fs) #t)
                         ((ibuffer-filter-match? b (car fs)) (loop (cdr fs)))
                         (else #f)))))
          (buffer-list-mru)))

(define (ibuffer-marks)
  (or (buffer-local *ibuffer-buffer* 'ibuffer-marks) '()))

(define (ibuffer-mark-of b)
  (let ((m (assoc b (ibuffer-marks))))
    (if m (car (cdr m)) " ")))

(define (ibuffer-set-mark! b ch)
  (buffer-set-local! *ibuffer-buffer* 'ibuffer-marks
    (let ((rest (filter (lambda (m) (not (equal? (car m) b))) (ibuffer-marks))))
      (if ch (cons (list b ch) rest) rest))))

(define (ibuffer-filters-label)
  (let ((fs (ibuffer-filters)))
    (if (null? fs)
        ""
        (fold (lambda (acc f) (string-append acc "  " (car f) ":" (car (cdr f))))
              "   ·" (reverse fs)))))

(define (ibuffer-line b)
  (string-append
    (ibuffer-mark-of b)
    (if (buffer-modified? b) "*" " ") " "
    (string-pad-left (number->string (buffer-size b)) 8) "  "
    (string-pad-right (or (buffer-local b 'mode-name) "-") 18)
    b "\n"))

(define (ibuffer-refresh!)
  (let* ((buf *ibuffer-buffer*)
         (bs (ibuffer-visible))
         (cur? (equal? (current-buffer) buf))
         (p (if cur? (point) 0)))
    (buffer-delete-range! buf 0 (buffer-size buf))
    (buffer-append! buf
      (string-append ";; buffers — RET visit · d flag · x kill flagged · "
                     "/ m mode · / n name · g refresh"
                     (ibuffer-filters-label) "\n"))
    (buffer-set-local! buf 'ibuffer-names bs)
    (for-each (lambda (b) (buffer-append! buf (ibuffer-line b))) bs)
    (when cur? (goto-char! (min p (buffer-size buf))))))

;; buffer named on the current line — header is line 0, entries follow
(define (ibuffer-current)
  (let* ((names (or (buffer-local *ibuffer-buffer* 'ibuffer-names) '()))
         (before (substring-bytes (buffer-text *ibuffer-buffer*) 0 (point)))
         (ln (- (length (string-split before "\n")) 2)))
    (if (and (>= ln 0) (< ln (length names))) (nth ln names) #f)))

(define (ibuffer-filter-push! f)
  (buffer-set-local! *ibuffer-buffer* 'ibuffer-filters
    (cons f (ibuffer-filters)))
  (ibuffer-refresh!))

(define-command "ibuffer" "List buffers dired-style: filter, mark, act"
  (lambda ()
    (let ((home (active-window)))
      (buffer-create *ibuffer-buffer*)
      ;; RET targets the window you came from — remember it
      (buffer-set-local! *ibuffer-buffer* 'ibuffer-home-window home)
      (display-buffer *ibuffer-buffer*)
      ;; select the popup window the display rule opened; switching the
      ;; current window would clobber the very window RET should target
      (let loop ((ws (window-list)))
        (cond ((null? ws) (switch-to-buffer! *ibuffer-buffer*))
              ((and (equal? (car (cdr (car ws))) *ibuffer-buffer*)
                    (not (equal? (car (car ws)) home)))
               (select-window! (car (car ws))))
              (else (loop (cdr ws)))))
      (set-mode! "ibuffer-mode")
      (ibuffer-refresh!)
      (goto-char! 0)
      (next-line!)
      (beginning-of-line!))))

(define-command "ibuffer-visit" "Show the selected buffer in the window ibuffer came from"
  (lambda ()
    (let ((b (ibuffer-current))
          (home (buffer-local *ibuffer-buffer* 'ibuffer-home-window)))
      (if (and b (buffer-exists? b))
          (begin
            (run-command "quit-window")
            (when (and home (window-exists? home))
              (select-window! home))
            (switch-to-buffer! b))
          (message "no buffer here")))))

(define-command "ibuffer-refresh" "Refresh the buffer list"
  (lambda () (ibuffer-refresh!)))

(define-command "ibuffer-flag" "Flag this buffer for killing"
  (lambda ()
    (let ((b (ibuffer-current)))
      (when b (ibuffer-set-mark! b "D") (ibuffer-refresh!) (next-line!)))))

(define-command "ibuffer-unmark" "Unmark this buffer"
  (lambda ()
    (let ((b (ibuffer-current)))
      (when b (ibuffer-set-mark! b #f) (ibuffer-refresh!) (next-line!)))))

(define-command "ibuffer-do-kill" "Kill every buffer flagged with D"
  (lambda ()
    (let ((doomed (filter (lambda (m) (equal? (car (cdr m)) "D")) (ibuffer-marks))))
      (for-each (lambda (m)
                  (when (buffer-exists? (car m)) (buffer-kill! (car m)))
                  (ibuffer-set-mark! (car m) #f))
                doomed)
      (ibuffer-refresh!)
      (message (string-append "killed " (number->string (length doomed)) " buffers")))))

(define-command "ibuffer-filter-mode" "Narrow to buffers in one major mode"
  (lambda ()
    (minibuffer-read "Mode: "
      (let loop ((bs (buffer-list)) (acc '()))
        (if (null? bs)
            (reverse acc)
            (loop (cdr bs)
                  (let ((m (buffer-local (car bs) 'mode-name)))
                    (if (and m (not (member m acc))) (cons m acc) acc)))))
      (lambda (m) (unless (equal? m "") (ibuffer-filter-push! (list "mode" m)))))))

(define-command "ibuffer-filter-name" "Narrow to buffer names matching a regex"
  (lambda ()
    (minibuffer-read "Filter names (regex): " '()
      (lambda (pat) (unless (equal? pat "") (ibuffer-filter-push! (list "name" pat)))))))

(define-command "ibuffer-filter-pop" "Drop the most recent filter"
  (lambda ()
    (buffer-set-local! *ibuffer-buffer* 'ibuffer-filters
      (let ((fs (ibuffer-filters))) (if (null? fs) '() (cdr fs))))
    (ibuffer-refresh!)))

(define-command "ibuffer-filter-clear" "Drop every filter"
  (lambda ()
    (buffer-set-local! *ibuffer-buffer* 'ibuffer-filters '())
    (ibuffer-refresh!)))

(define-mode "ibuffer-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-local! buf 'mode-name "ibuffer-mode")
      (local-set-key "n" "next-line")
      (local-set-key "p" "previous-line")
      (local-set-key "RET" "ibuffer-visit")
      (local-set-key "g" "ibuffer-refresh")
      (local-set-key "d" "ibuffer-flag")
      (local-set-key "u" "ibuffer-unmark")
      (local-set-key "x" "ibuffer-do-kill")
      (local-set-key "q" "quit-window")
      (local-set-key "/ m" "ibuffer-filter-mode")
      (local-set-key "/ n" "ibuffer-filter-name")
      (local-set-key "/ p" "ibuffer-filter-pop")
      (local-set-key "/ /" "ibuffer-filter-clear")
      (ibuffer-refresh!)
      (buffer-set-read-only! buf #t))))

(global-set-key "C-x C-b" "ibuffer")

(public! 'ibuffer-refresh! "(ibuffer-refresh!) — rebuild the *ibuffer* listing")
