;;; ibuffer.scm --- the buffer list as a dired: filter, mark, act.
;;;
;;; C-x C-b and M-x ibuffer open *ibuffer*. The table shows one row per
;;; buffer, grouped and sorted by name. Compact rows combine size, mode, and group details.
;;; Wide rows also show file status. The keys follow traditional Emacs ibuffer:
;;; m marks, * marks all rows, d flags for killing, x executes, u and U
;;; unmark, RET visits, g refreshes, and q quits. / narrows the table.

(domain! 'buffers)
(effects! '(read))

(defgroup 'buffers "Buffer lists and buffer management.")

(defcustom 'ibuffer-compact-cols 100
  "Below this width, ibuffer combines size, mode, and group details."
  'group 'buffers 'type 'number)

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

(define (ibuffer-row? b)
  (and (buffer-known? b)
       (not (equal? b *ibuffer-buffer*))
       (not (string-prefix? " " b))
       (ibuffer-workspace-buffer? b)))

;; #f means the ordinary complete table. A list, including an empty list,
;; is the exact result set that a buffer prompt handed to ibuffer.
(define (ibuffer-sort-names rows)
  (map cadr
    (sort (map (lambda (row) (list (string-downcase row) row)) rows))))

(define (ibuffer-source)
  (let ((scope (buffer-local *ibuffer-buffer* 'ibuffer-scope)))
    (ibuffer-sort-names
      (filter ibuffer-row? (if (equal? scope #f) (buffer-list-mru) scope)))))

;; the members of the group the frame stands in come first, in their
;; order; the rest follow in theirs
(define (ibuffer-promote-group rows group)
  (if (not group)
      rows
      (append (filter (lambda (b) (buffer-in-group? b group)) rows)
              (filter (lambda (b) (not (buffer-in-group? b group))) rows))))

(define (ibuffer-separator label group) (list label "" "separator" group))

(define (ibuffer-separator? buf row)
  (and (pair? row) (> (length row) 2) (equal? (nth 2 row) "separator")))

;; A buffer can belong to many groups, but an ibuffer row appears once. The
;; current group wins. Otherwise, the first group by name owns the row.
(define (ibuffer-row-group row ordered-groups)
  (let ((memberships (group-buffer-memberships row)))
    (let loop ((groups ordered-groups))
      (cond ((null? groups) #f)
            ((member (car groups) memberships) (car groups))
            (else (loop (cdr groups)))))))

(define (ibuffer-group-section rows id label ordered-groups)
  (let ((members (filter (lambda (row)
                           (equal? (ibuffer-row-group row ordered-groups) id))
                         rows)))
    (if (pair? members)
        (cons (ibuffer-separator label id) members)
        '())))

;; Match C-x b for the current section, then continue group by group. Other
;; groups sort by name. Buffers with no matching membership come last.
(define (ibuffer-group-sections rows current)
  (let* ((named (sort (map (lambda (id)
                             (list (string-downcase (group-name id)) id))
                           (filter (lambda (id) (not (equal? id current)))
                                   (group-ids)))))
         (ordered (append (if current (list current) '()) (map cadr named)))
         (grouped
           (fold (lambda (out id)
                   (append out
                     (ibuffer-group-section
                       rows id
                       (if (equal? id current) "in this group" (group-name id))
                       ordered)))
                 '() ordered))
         (ungrouped
           (filter (lambda (row) (not (ibuffer-row-group row ordered))) rows)))
    (append grouped
            (if (pair? ungrouped)
                (cons (ibuffer-separator "ungrouped" #f) ungrouped)
                '()))))

;; The list fetches its name-sorted rows on open and on g. A mark or a
;; narrowing redraws the rows it already has, so the cursor stays stable.
(define (ibuffer-rows)
  (ibuffer-group-sections (ibuffer-source)
                          (and (boundp 'frame-group) (frame-group))))

(define (ibuffer-visible)
  (list-keep *ibuffer-buffer* (ibuffer-rows)))

(define (ibuffer-total) (length (ibuffer-source)))

(define (ibuffer-human n)
  (cond ((>= n 1048576)
         (string-append (number->string (quotient n 1048576)) "M"))
        ((>= n 1024)
         (string-append (number->string (quotient n 1024)) "k"))
        (else (number->string n))))

(define (ibuffer-short-mode b)
  (let* ((mode (or (buffer-local b 'mode-name) "Fundamental"))
         (n (string-length mode)))
    (if (and (> n 5) (string-suffix? "-mode" mode))
        (substring mode 0 (- n 5))
        mode)))

(define (ibuffer-details b)
  (string-join
    (filter (lambda (part) (not (equal? part "")))
      (list (ibuffer-human (buffer-size b))
            (ibuffer-short-mode b)
            (group-label (buffer-group b))))
    " · "))

(define (ibuffer-compact-columns buf)
  (let ((name-width (max 20 (min 32 (quotient (list-view-width buf) 2)))))
    (list (list "" 1)
          (list "" 1)
          (list "buffer" name-width)
          (list "details" #f))))

(define (ibuffer-wide-columns buf)
  (list (list "" 1)
        (list "" 1)
        (list "buffer" #f)
        (list "size" 7 'right)
        (list "mode" 16)
        (list "group" 18)
        (list "file" 4)))

(define (ibuffer-cell-head b)
  (list (if (buffer-modified? b) (list "●" "warn") "")
        (list (buffer-icon b) "faint")
        (list b (or (buffer-filename-face b)
                    (if (string-prefix? "*" b) "accent" #f)))))

(define (ibuffer-separator-cell row)
  (let ((group (and (> (length row) 3) (nth 3 row))))
    (list (string-append "── " (car row) " ")
          (or (and group (group-color-face group)) "accent"))))

(define (ibuffer-compact-cells buf b)
  (if (ibuffer-separator? buf b)
      (list "" "" (ibuffer-separator-cell b) "")
      (append (ibuffer-cell-head b)
              (list (list (ibuffer-details b) "faint")))))

(define (ibuffer-wide-cells buf b)
  (if (ibuffer-separator? buf b)
      (list "" "" (ibuffer-separator-cell b) "" "" "" "")
      (append (ibuffer-cell-head b)
        (list (list (ibuffer-human (buffer-size b)) "dim")
              (list (or (buffer-local b 'mode-name) "Fundamental") "faint")
              (list (group-label (buffer-group b))
                    (and (buffer-group b) (group-color-face (buffer-group b))))
              (list (if (buffer-path b) "✓" "") "ok")))))

(define (ibuffer-meta buf)
  (let* ((rows (filter (lambda (row) (not (ibuffer-separator? buf row)))
                       (list-entries buf)))
         (n (length rows))
         (dirty (length (filter buffer-modified? rows))))
    (string-append (number->string n) (if (= n 1) " buffer" " buffers")
                   " · " (number->string dirty) " modified"
                   " · grouped by group · name order")))

(define (ibuffer-compact-footer buf)
  '(("RET" "visit") ("m" "mark") ("k" "kill") ("G" "group")
    ("d" "flag") ("x" "execute") ("/" "filter") ("q" "quit")))

(define (ibuffer-wide-footer buf)
  '(("RET" "visit") ("m" "mark") ("*" "all") ("k" "kill")
    ("G" "group") ("d" "flag") ("x" "execute") ("/" "filter")
    ("\\" "widen") ("g" "refresh") ("q" "quit")))

(define (ibuffer-refresh!) (list-refresh! *ibuffer-buffer*))
(define (ibuffer-current) (list-current *ibuffer-buffer*))
(define (ibuffer-filter-push! f) (list-filter-push! *ibuffer-buffer* f))

(domain! 'buffers)
(effects! '(read))

(define (ibuffer-open! scope)
  (let ((from (active-window)))
    (buffer-create *ibuffer-buffer*)
    (buffer-set-local! *ibuffer-buffer* 'ibuffer-scope scope)
    ;; Typed narrowing is temporary. Keep any mode-specific filters.
    (list-clear-query! *ibuffer-buffer*)
    (display-buffer *ibuffer-buffer*)
    (let ((w (window-showing-other *ibuffer-buffer* from)))
      (if w (select-window! w) (switch-to-buffer! *ibuffer-buffer*)))
    (set-mode! "ibuffer-mode")
    (ibuffer-refresh!)
    (list-goto-first-entry *ibuffer-buffer*)))

(define (ibuffer-open-buffers! buffers)
  (ibuffer-open! (dedupe-names (filter buffer-known? buffers)))
  (list-preview! *ibuffer-buffer*))

(define-command "ibuffer" "List buffers in a traditional management table"
  (lambda () (ibuffer-open! #f)))

(define-command "ibuffer-visit" "Visit the selected buffer in another window"
  (lambda ()
    (let ((b (ibuffer-current)))
      (if (and b (buffer-known? b))
          (let ((w (display-buffer-other-window! b)))
            (run-command "quit-window")
            (when (and w (window-exists? w)) (select-window! w))
            (switch-to-buffer! b))
          (message "no buffer here")))))

(define-command "ibuffer-refresh" "Refresh the buffer table"
  (lambda () (ibuffer-refresh!)))

;; Keep the former public helper for callers and historical tests.
(define (ibuffer-preview!)
  (let ((b (ibuffer-current)))
    (when (and b (buffer-known? b))
      (display-buffer-other-window! b))))

(define-command "ibuffer-next" "Move down and preview the selected buffer"
  (lambda () (list-move! 1)))

(define-command "ibuffer-prev" "Move up and preview the selected buffer"
  (lambda () (list-move! -1)))

(effects! '(destroy))

(define-command "ibuffer-kill" "Kill the marked buffers, or the row at point"
  (lambda ()
    (let* ((buf (current-buffer))
           (targets (list-targets buf))
           (n 0))
      (when (buffer-known? "*scratch*")
        (display-buffer-other-window! "*scratch*"))
      (for-each (lambda (b)
                  (when (buffer-known? b)
                    (list-unmark-key! buf b)
                    (if (process-running? b) (process-kill! b))
                    (buffer-kill! b)
                    (set! n (+ n 1))))
                targets)
      (list-refresh! buf)
      (message (if (and (= n 0) (pair? targets))
                   "already gone"
                   (string-append "killed " (number->string n) " "
                                  (list-noun buf n)))))))


(effects! '(read))

(mode-icon! "ibuffer-mode" "")

(define-list-mode! "ibuffer-mode"
  (list
    'doc (string-append
           "A traditional buffer management table. Compact rows combine "
           "size, mode, and group details. Rows sort by group and buffer name. "
           "Wide rows also show file status. / narrows "
           "the table and \\ widens it. m marks one row, * marks all shown "
           "rows, u unmarks one row, and U clears all marks. k kills now. "
           "d flags rows for killing, and x executes the flags. G puts "
           "the targets in a group. RET visits, g refreshes, and q quits.")
    'buffer *ibuffer-buffer*
    'category 'buffer
    'rows (lambda (buf) (ibuffer-rows))
    'separator? ibuffer-separator?
    'local-filter #t
    'stamp (lambda (buf) (length (buffer-list-mru)))
    'layouts
      (list
        (list 'name 'compact
              'max-cols (lambda (buf) (- ibuffer-compact-cols 1))
              'columns ibuffer-compact-columns
              'cells ibuffer-compact-cells
              'footer ibuffer-compact-footer)
        (list 'name 'wide
              'default #t
              'columns ibuffer-wide-columns
              'cells ibuffer-wide-cells
              'footer ibuffer-wide-footer))
    'title (lambda (buf) "Buffers")
    'meta ibuffer-meta
    'total (lambda (buf) (ibuffer-total))
    'compact #t
    'flags (list (list "d" "D" "kill"
                       (lambda (buf b)
                         (and (buffer-known? b)
                              (begin (buffer-kill! b) #t)))))
    'noun "buffer"
    ;; the row under the highlight shows in the window this listing
    ;; covers, and leaves no trace: not a peek, which goes to the popup
    ;; this listing is in
    'preview (lambda (buf b)
               (let ((w (other-window-id (active-window))))
                 (when (and w (buffer-known? b))
                   (window-preview-buffer! b w))))
    'keys '(("RET" "ibuffer-visit") ("k" "ibuffer-kill")
            ("G" "group-add") ("g" "ibuffer-refresh")
            ("q" "quit-window"))))

(global-set-key "C-x C-b" "ibuffer")

(category! 'buffers)
(catalog-meta! 'command "ibuffer-kill" 'domain 'buffers 'effects '(destroy))
(public! 'ibuffer-refresh! "(ibuffer-refresh!) — rebuild the *ibuffer* table")
(public! 'ibuffer-open-buffers! "(ibuffer-open-buffers! BUFFERS) — open ibuffer on exactly these known buffers")
