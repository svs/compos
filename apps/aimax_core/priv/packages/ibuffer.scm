;;; ibuffer.scm --- the buffer list as a dired: filter, mark, act.
;;;
;;; C-x C-b (or M-x ibuffer) pops *ibuffer*: one line per buffer, MRU
;;; order — modified flag, size, mode, name. Same narrowing language as
;;; dired: / m major mode · / n name regex · / p pop · / / clear.
;;; d flags for killing, x executes, u unmarks, RET visits, g refreshes.
;;; Internals (space-prefixed) stay hidden.

(define *ibuffer-buffer* "*ibuffer*")
(add-display-rule! *ibuffer-buffer* 'popup)

(define (ibuffer-filter-match? b f)
  (let ((kind (car f)) (arg (car (cdr f))))
    (cond ((equal? kind "mode")
           (equal? (or (buffer-local b 'mode-name) "") arg))
          ((equal? kind "name") (re-match? arg b))
          (else #t))))

;; the rows: every buffer that is not this list, not an internal, and not
;; filtered out
(define (ibuffer-visible)
  (filter (lambda (b)
            (and (not (equal? b *ibuffer-buffer*))
                 (not (string-prefix? " " b))
                 (let loop ((fs (list-filters *ibuffer-buffer*)))
                   (cond ((null? fs) #t)
                         ((ibuffer-filter-match? b (car fs)) (loop (cdr fs)))
                         (else #f)))))
          (buffer-list-mru)))

(define (ibuffer-line b)
  (string-append
    (list-mark-of *ibuffer-buffer* b)
    (if (buffer-modified? b) "*" " ") " "
    (string-pad-left (number->string (buffer-size b)) 8) "  "
    (string-pad-right (or (buffer-local b 'mode-name) "-") 18)
    b))

(define (ibuffer-refresh!) (list-refresh! *ibuffer-buffer*))
(define (ibuffer-current) (list-current *ibuffer-buffer*))
(define (ibuffer-filter-push! f) (list-filter-push! *ibuffer-buffer* f))

;; No window bookkeeping: like Emacs, RET/preview never remember where
;; they came from — the target window is chosen at display time by
;; display-buffer-other-window! (reuse → other → split), so stale window
;; ids simply cannot exist.

(define-command "ibuffer" "List buffers dired-style: filter, mark, act"
  (lambda ()
    (let ((from (active-window)))
      (buffer-create *ibuffer-buffer*)
      (display-buffer *ibuffer-buffer*)
      ;; select the popup window the display rule opened; switching the
      ;; current window would clobber the window previews should target
      (let ((w (window-showing-other *ibuffer-buffer* from)))
        (if w (select-window! w) (switch-to-buffer! *ibuffer-buffer*)))
      (set-mode! "ibuffer-mode")
      (ibuffer-refresh!)
      (goto-char! 0)
      (next-line!)
      (beginning-of-line!))))

(define-command "ibuffer-visit" "Show the selected buffer in another window and go there"
  (lambda ()
    (let ((b (ibuffer-current)))
      (if (and b (buffer-exists? b))
          (let ((w (display-buffer-other-window! b)))
            (run-command "quit-window")
            (when (and w (window-exists? w))
              (select-window! w))
            (switch-to-buffer! b))
          (message "no buffer here")))))

(define-command "ibuffer-refresh" "Refresh the buffer list"
  (lambda () (ibuffer-refresh!)))

;; the other window follows the highlight (the occur/consult pattern):
;; moving in the list previews without leaving it
(define (ibuffer-preview!)
  (let ((b (ibuffer-current)))
    (when (and b (buffer-exists? b))
      (display-buffer-other-window! b))))

(define-command "ibuffer-next" "Move down and preview in the home window"
  (lambda () (next-line!) (ibuffer-preview!)))

(define-command "ibuffer-prev" "Move up and preview in the home window"
  (lambda () (previous-line!) (ibuffer-preview!)))

(define-command "ibuffer-flag" "Flag this buffer for killing"
  (lambda ()
    (let ((b (ibuffer-current)))
      (when b (list-mark! *ibuffer-buffer* b "D") (ibuffer-refresh!) (next-line!)))))

(define-command "ibuffer-unmark" "Unmark this buffer"
  (lambda ()
    (let ((b (ibuffer-current)))
      (when b (list-mark! *ibuffer-buffer* b #f) (ibuffer-refresh!) (next-line!)))))

(define-command "ibuffer-do-kill" "Kill every buffer flagged with D"
  (lambda ()
    (let ((doomed (list-marked *ibuffer-buffer* "D")))
      (for-each (lambda (b)
                  (when (buffer-exists? b) (buffer-kill! b))
                  (list-mark! *ibuffer-buffer* b #f))
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
  (lambda () (list-filter-pop! *ibuffer-buffer*)))

(define-command "ibuffer-filter-clear" "Drop every filter"
  (lambda () (list-filter-clear! *ibuffer-buffer*)))

(define-list-mode! "ibuffer-mode"
  (list
    'doc (string-append
           "The buffer list as a dired: one line per buffer in most-recently-used "
           "order, with its modified flag, size and mode. Narrow it with the "
           "filters, flag buffers with `d`, then kill the flagged ones with `x`. "
           "Moving the highlight previews the buffer in the other window.")
    'buffer *ibuffer-buffer*
    'rows ibuffer-visible
    'render ibuffer-line
    'header (lambda ()
              (string-append
                ";; buffers — RET visit · d flag · x kill flagged · "
                "/ m mode · / n name · g refresh"
                (list-filters-label *ibuffer-buffer*)))
    'keys '(("RET" "ibuffer-visit") ("g" "ibuffer-refresh") ("d" "ibuffer-flag")
            ("u" "ibuffer-unmark") ("x" "ibuffer-do-kill") ("q" "quit-window")
            ("n" "ibuffer-next") ("p" "ibuffer-prev")
            ("/ m" "ibuffer-filter-mode") ("/ n" "ibuffer-filter-name")
            ("/ p" "ibuffer-filter-pop") ("/ /" "ibuffer-filter-clear"))
    ;; the standard: line movement REMAPS, so arrows, C-n/C-p, and any
    ;; user binding of next-line all move-and-preview identically
    'remap '(("next-line" "ibuffer-next") ("previous-line" "ibuffer-prev"))))

(global-set-key "C-x C-b" "ibuffer")

(category! 'buffers)
(public! 'ibuffer-refresh! "(ibuffer-refresh!) — rebuild the *ibuffer* listing")
