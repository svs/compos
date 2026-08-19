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

(define (ibuffer-workspace-buffer? b)
  (let* ((root (and (boundp (quote daemon-workspace-root))
                    (daemon-workspace-root)))
         (path (or (buffer-path b)
                   (and (string-prefix? "/" b) b))))
    (or (not (string? root))
        (not path)
        (equal? path root)
        (string-prefix? (string-append root "/") path))))

;; the rows: every buffer that is not this list, not an internal, and not
;; filtered out
(define (ibuffer-visible)
  (list-keep *ibuffer-buffer*
    (filter (lambda (b)
              (and (not (equal? b *ibuffer-buffer*))
                   (not (string-prefix? " " b))
                   (ibuffer-workspace-buffer? b)))
            (buffer-list-mru))))

;; every buffer, before the filters — the header counts what a narrowing hid
(define (ibuffer-total)
  (length (filter (lambda (b)
                    (and (not (equal? b *ibuffer-buffer*))
                         (not (string-prefix? " " b))
                         (ibuffer-workspace-buffer? b)))
                  (buffer-list-mru))))

(define (ibuffer-human n)
  (cond ((>= n 1048576) (string-append (number->string (quotient n 1048576)) "M"))
        ((>= n 1024) (string-append (number->string (quotient n 1024)) "k"))
        (else (number->string n))))

;; the columns say the same things the annotation beside a buffer name
;; says, because `/` narrows on both
(define (ibuffer-cells buf b)
  (list (if (buffer-modified? b) (list "●" "warn") "")
        ;; the icon reads before the name: the mode is what the buffer IS
        (list (buffer-icon b) "faint")
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
      ;; a dormant buffer is a buffer: it holds a checkpoint and no
      ;; process, and it wakes when this window shows it. Asking
      ;; buffer-exists? here made RET answer "no buffer here" on every
      ;; row the editor had put to sleep.
      (if (and b (buffer-known? b))
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
    (when (and b (buffer-known? b))
      (display-buffer-other-window! b))))

;; `k` kills NOW — the marked buffers, or the row at point. `d`+`x` stays
;; for the flag-then-execute habit; `k` is the direct verb. The other
;; window moves to *scratch* first so no dying buffer is on screen while
;; dormancy wake-on-write is still open.
(define-command "ibuffer-kill" "Kill the marked buffers, or the one at point"
  (lambda ()
    (let* ((buf (current-buffer))
           (targets (list-targets buf))
           (n 0))
      (when (buffer-known? "*scratch*")
        (display-buffer-other-window! "*scratch*"))
      (for-each (lambda (b)
                  ;; dormant or live, the row names a buffer this editor
                  ;; keeps — buffer-kill! drops the checkpoint either way
                  (when (buffer-known? b)
                    (list-unmark-key! buf b)
                    (if (process-running? b) (process-kill! b))
                    (buffer-kill! b)
                    (set! n (+ n 1))))
                targets)
      (list-refresh! buf)
      ;; a row can name a buffer that something else killed. Say that,
      ;; rather than report a kill of nothing — the refresh above drops
      ;; the row the reader was looking at.
      (message (if (and (= n 0) (pair? targets))
                   "already gone"
                   (string-append "killed " (number->string n) " "
                                  (list-noun buf n)))))))

;; `G` groups a SET. C-c g joins the buffer you are in; here the marked
;; buffers join one group in one act. The prompt offers the groups that
;; exist, a name it does not know founds that group — the same rule C-c
;; g follows — and "(none)" takes them out of theirs. "(none)" leads the
;; list, so RET on an empty prompt removes rather than joins a group you
;; did not name.
(define *ibuffer-no-group* "(none)")

(define (ibuffer-group! buf targets g)
  (let ((n (length targets))
        (out? (equal? g *ibuffer-no-group*)))
    (for-each (lambda (b)
                (buffer-set-local! b 'group (if out? #f g))
                (when out? (buffer-set-local! b 'companion-of #f))
                (list-unmark-key! buf b))
              targets)
    (list-refresh! buf)
    (message (string-append (number->string n) " " (list-noun buf n)
                            (if out? " left their group"
                                (string-append " joined " g))))))

(define-command "ibuffer-group"
  "Put the marked buffers in a group, or take them out of one"
  (lambda ()
    (let* ((buf (current-buffer))
           (targets (filter buffer-known? (list-targets buf)))
           (n (length targets)))
      (if (null? targets)
          (message "no buffer here")
          (minibuffer-read
            (string-append "Group for " (number->string n) " "
                           (list-noun buf n) ": ")
            (cons (list *ibuffer-no-group* "remove from the group")
                  (group-names))
            (lambda (input)
              (let ((g (string-trim input)))
                (ibuffer-group! buf targets
                  (if (equal? g "") *ibuffer-no-group* g)))))))))

(define-command "ibuffer-next" "Move down and preview in the home window"
  (lambda () (list-move! 1)))

(define-command "ibuffer-prev" "Move up and preview in the home window"
  (lambda () (list-move! -1)))

(mode-icon! "ibuffer-mode" "")

(define-list-mode! "ibuffer-mode"
  (list
    'doc (string-append
           "The buffer list as a dired: one row per buffer in most-recently-used "
           "order, with its modified flag, size, mode, group and file. `/` "
           "narrows as you type — it matches the row and the annotation C-x b "
           "shows, so a group or a project name finds every member — and `\\` "
           "widens by one. `m` marks a buffer, `*` marks every row, `u` "
           "unmarks and `U` drops every mark; `k` kills the marked "
           "buffers, or the row at point, and `G` puts them in a group. "
           "`d` flags for `x` to run. "
           "Moving the highlight previews the buffer in the other window.")
    'buffer *ibuffer-buffer*
    ;; a buffer name is a buffer name: `/` matches the same annotation
    ;; C-x b shows beside one
    'category 'buffer
    'rows (lambda (buf) (ibuffer-visible))
    ;; C-x k kills a buffer from anywhere, and a chat or a shell can end
    ;; on its own. The stamp counts the buffers — one cheap call, and a
    ;; count does not move when the MRU order does, so previewing with n
    ;; and p never reorders the rows under the reader.
    'stamp (lambda (buf) (length (buffer-list-mru)))
    'columns (lambda (buf)
               (list (list "" 1)
                     (list "" 1)
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
              '(("RET" "visit") ("m" "mark") ("*" "all") ("k" "kill")
                ("G" "group") ("d" "flag") ("x" "execute") ("/" "filter")
                ("\\" "widen") ("g" "refresh") ("q" "quit")))
    ;; the flag says what it does; list-mode supplies m/u/U/*/x and the column
    'flags (list (list "d" "D" "kill"
                       (lambda (buf b)
                         (and (buffer-known? b) (begin (buffer-kill! b) #t)))))
    'noun "buffer"
    ;; the other window follows the highlight: list-mode moves, this shows
    'preview (lambda (buf b)
               (when (buffer-known? b) (display-buffer-other-window! b)))
    'keys '(("RET" "ibuffer-visit") ("k" "ibuffer-kill")
            ("G" "ibuffer-group")
            ("g" "ibuffer-refresh") ("q" "quit-window"))))

(global-set-key "C-x C-b" "ibuffer")

(category! 'buffers)
(catalog-meta! 'command "ibuffer-group" 'domain 'buffers 'effects '(write))
(public! 'ibuffer-refresh! "(ibuffer-refresh!) — rebuild the *ibuffer* listing")
