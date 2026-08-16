;;; ibuffer.scm --- the buffer list as a dired: filter, mark, act.
;;;
;;; C-x C-b (or M-x ibuffer) pops *ibuffer*: one row per buffer, MRU
;;; order — modified flag, name, size, mode, group, and whether it has a
;;; file. Same table and same narrowing as dired, because both are lists:
;;; `/` narrows as you type and `\` widens. A row matches on its columns
;;; and on the annotation C-x b shows beside the same buffer.
;;; m marks, `*` marks every row, d flags for killing, x executes, u and
;;; U unmark, RET visits, g refreshes.
;;; Internals (space-prefixed) stay hidden.

(define *ibuffer-buffer* "*ibuffer*")
(add-display-rule! *ibuffer-buffer* 'popup)

;; the rows: every buffer that is not this list, not an internal, and not
;; filtered out
(define (ibuffer-visible)
  (list-keep *ibuffer-buffer*
    (filter (lambda (b)
              (and (not (equal? b *ibuffer-buffer*))
                   (not (string-prefix? " " b))))
            (buffer-list-mru))))

;; every buffer, before the filters — the header counts what a narrowing hid
(define (ibuffer-total)
  (length (filter (lambda (b)
                    (and (not (equal? b *ibuffer-buffer*))
                         (not (string-prefix? " " b))))
                  (buffer-list-mru))))

(define (ibuffer-human n)
  (cond ((>= n 1048576) (string-append (number->string (quotient n 1048576)) "M"))
        ((>= n 1024) (string-append (number->string (quotient n 1024)) "k"))
        (else (number->string n))))

;; the columns say the same things the annotation beside a buffer name
;; says, because `/` narrows on both
(define (ibuffer-cells buf b)
  (list (if (buffer-modified? b) (list "●" "warn") "")
        ;; a name in stars is a buffer the editor made, not a file
        (list b (if (string-prefix? "*" b) "accent" #f))
        (list (ibuffer-human (buffer-size b)) "dim")
        (list (or (buffer-local b 'mode-name) "Fundamental") "faint")
        (list (group-label (buffer-group b)) "accent")
        ;; the name already says which file; this column says whether
        ;; there is one
        (list (if (buffer-path b) "✓" "") "ok")))

(define (ibuffer-meta buf)
  (let* ((rows (list-entries buf))
         (n (length rows))
         (dirty (length (filter buffer-modified? rows))))
    (string-append (number->string n) (if (= n 1) " buffer" " buffers")
                   " · " (number->string dirty) " modified"
                   " · most recent first")))

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
      ;; the header is several lines: the list knows where its rows start
      (list-goto-first-entry *ibuffer-buffer*))))

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
;; moving in the list previews without leaving it. list-mode moves and
;; calls the mode's 'preview; these names stay for the tests that call them.
(define (ibuffer-preview!)
  (let ((b (ibuffer-current)))
    (when (and b (buffer-exists? b))
      (display-buffer-other-window! b))))

(define-command "ibuffer-next" "Move down and preview in the home window"
  (lambda () (list-move! 1)))

(define-command "ibuffer-prev" "Move up and preview in the home window"
  (lambda () (list-move! -1)))

(define-list-mode! "ibuffer-mode"
  (list
    'doc (string-append
           "The buffer list as a dired: one row per buffer in most-recently-used "
           "order, with its modified flag, size, mode, group and file. `/` "
           "narrows as you type — it matches the row and the annotation C-x b "
           "shows, so a group or a project name finds every member — and `\\` "
           "widens by one. Flag buffers with `d`, then kill the flagged ones "
           "with `x`. `m` marks, `*` marks every row, `u` unmarks and `U` "
           "drops every mark. "
           "Moving the highlight previews the buffer in the other window.")
    'buffer *ibuffer-buffer*
    ;; a buffer name is a buffer name: `/` matches the same annotation
    ;; C-x b shows beside one
    'category 'buffer
    'rows (lambda (buf) (ibuffer-visible))
    'columns (lambda (buf)
               (list (list "" 1)
                     (list "buffer" #f)
                     (list "size" 7 'right)
                     (list "mode" 16)
                     (list "group" 18)
                     (list "file" 4)))
    'cells ibuffer-cells
    'title (lambda (buf) "Buffers")
    'meta ibuffer-meta
    'total (lambda (buf) (ibuffer-total))
    'footer (lambda (buf)
              '(("RET" "visit") ("m" "mark") ("*" "all") ("d" "flag")
                ("x" "kill") ("/" "filter") ("\\" "widen")
                ("g" "refresh") ("q" "quit")))
    ;; the flag says what it does; list-mode supplies m/u/U/*/x and the column
    'flags (list (list "d" "D" "kill"
                       (lambda (buf b)
                         (and (buffer-exists? b) (begin (buffer-kill! b) #t)))))
    'noun "buffer"
    ;; the other window follows the highlight: list-mode moves, this shows
    'preview (lambda (buf b)
               (when (buffer-exists? b) (display-buffer-other-window! b)))
    'keys '(("RET" "ibuffer-visit") ("g" "ibuffer-refresh") ("q" "quit-window"))))

(global-set-key "C-x C-b" "ibuffer")

(category! 'buffers)
(public! 'ibuffer-refresh! "(ibuffer-refresh!) — rebuild the *ibuffer* listing")
