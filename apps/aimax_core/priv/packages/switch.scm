;;; switch.scm --- ONE buffer switcher: C-x b, C-x C-b, and ibuffer merged.
;;;
;;; A modal list buffer with its own keymap. Typing narrows — the filter
;;; is the default act, as in every list. Control chords act on rows:
;;; RET visits, C-RET enters the row's context, C-SPC marks, C-k kills,
;;; C-t sets the group, C-g shows groups and projects, TAB locks to a
;;; group, ESC quits. DEL widens the narrowing by one character.
;;;
;;; The rows are the C-x b pool: buffers and group cards woven by
;;; recency, plus whatever the switch-buffer-source seam adds (chrome
;;; adds browser tabs). Moving the highlight previews the row in the
;;; window you came from. A preview can wake a dormant buffer; closing
;;; the switcher puts every buffer nobody picked back to sleep.

(define *switch-buffer* "*switch*")
(add-display-rule! *switch-buffer* 'popup)

;; the seam's pick fn from the last rows fetch — a closure, so it lives
;; here and not in a buffer-local
(define *switch-pick* (lambda (picked) #f))

;;; --- rows ---------------------------------------------------------------------

(define (switch-container? e)
  (and (> (length e) 2) (equal? (nth 2 e) "container")))

;; group ids whose card can appear: every group, except the one you are in
(define (switch-groups buf)
  (filter (lambda (g) (not (equal? g (buffer-local buf 'switch-group))))
          (group-names)))

;; project roots that are not groups yet — a switch founds their group
(define (switch-project-roots)
  (let loop ((bs (buffer-list)) (out '()))
    (if (null? bs)
        (reverse out)
        (let ((root (buffer-project-root (car bs))))
          (loop (cdr bs)
                (if (and (string? root)
                         (not (equal? root ""))
                         (not (member root (group-names)))
                         (not (member root out)))
                    (cons root out)
                    out))))))

(define (switch-project-candidate root)
  (list (string-append "[" root "]") "project — RET founds its group"
        "container" '()))

;; the groups view: every other group's card, then the projects
(define (switch-group-rows buf)
  (append (map group-container-candidate (switch-groups buf))
          (map switch-project-candidate (switch-project-roots))))

;; the buffers view: the C-x b pool — MRU-woven buffers and group cards,
;; plus the seam's rows (chrome tabs). The place you stand is not an
;; offer, and neither is this list itself.
(define (switch-buffer-rows buf)
  (let* ((here (buffer-local buf 'switch-here))
         (source (switch-buffer-source
                   (switch-history-pool (buffer-local buf 'switch-group))))
         (pool (car source)))
    (set! *switch-pick* (nth 2 source))
    (filter (lambda (c) (and (not (equal? (car c) here))
                             (not (equal? (car c) *switch-buffer*))))
            pool)))

;; one group's members, most recent first — the locked view TAB opens
(define (switch-locked-rows g)
  (annotate 'buffer
    (filter (lambda (b) (not (string-prefix? " " b)))
            (group-buffers-mru g))))

(define (switch-rows buf)
  (let ((view (or (buffer-local buf 'switch-view) 'buffers)))
    (cond ((equal? view 'groups) (switch-group-rows buf))
          ((and (pair? view) (equal? (car view) 'locked))
           (switch-locked-rows (nth 1 view)))
          (else (switch-buffer-rows buf)))))

;;; --- cells --------------------------------------------------------------------

(define (switch-ann e)
  (if (and (> (length e) 1) (string? (nth 1 e))) (nth 1 e) ""))

(define (switch-chips e)
  (if (> (length e) 3) (nth 3 e) '()))

(define (switch-cells buf e)
  (let ((name (car e))
        (ann (switch-ann e)))
    (cond
      ((switch-container? e)
       (list ""
             (list name "accent")
             (list (let ((chips (switch-chips e)))
                     (if (pair? chips)
                         (string-append ann "  ·  " (string-join chips "  "))
                         ann))
                   "dim")))
      ((buffer-known? name)
       (list (if (and (buffer-exists? name) (buffer-modified? name))
                 (list "●" "warn") "")
             (list name (if (string-prefix? "*" name) "accent" #f))
             (list ann "faint")))
      ;; a seam row — a browser tab
      (else (list "" (list name "accent") (list ann "dim"))))))

;; a row matches on everything it says, untruncated — the name, the
;; annotation, and a card's member chips
(define (switch-match? buf e input)
  (re-match? input
    (string-join (cons (car e) (cons (switch-ann e) (switch-chips e))) " ")))

(define (switch-meta buf)
  (let* ((view (or (buffer-local buf 'switch-view) 'buffers))
         (n (length (list-entries buf))))
    (cond ((equal? view 'groups)
           (string-append (number->string n) " contexts · RET switches"))
          ((pair? view)
           (string-append "in " (group-label (nth 1 view))
                          " · " (number->string n) " buffers"))
          (else (string-append (number->string n)
                               " candidates · most recent first · type to narrow")))))

;;; --- the home window: preview and dormancy --------------------------------------

(define (switch-home-window buf)
  (let ((w (buffer-local buf 'switch-home-window)))
    (and w (window-exists? w) w)))

(define (switch-note-woken! buf b)
  (buffer-set-local! buf 'switch-woken
    (cons b (or (buffer-local buf 'switch-woken) '()))))

;; the other side of the wake: closing sleeps every woken buffer nobody
;; picked (the consult contract)
(define (switch-sleep-woken! buf keep)
  (for-each (lambda (b) (unless (equal? b keep) (buffer-sleep! b)))
            (or (buffer-local buf 'switch-woken) '()))
  (buffer-set-local! buf 'switch-woken '()))

(define (switch-preview! buf e)
  (let ((b (car e))
        (w (switch-home-window buf)))
    (when (and w (not (switch-container? e)) (buffer-known? b))
      (let ((sleeping (not (buffer-exists? b))))
        (window-preview-buffer! b w)
        ;; the primitive wakes a sleeper; the mode setup must follow, or
        ;; switch-to-buffer! later sees the buffer live and skips it
        (when (and sleeping (buffer-exists? b))
          (restore-buffer-runtime! b)
          (switch-note-woken! buf b))))))

;; put HOME back to what it showed at open — the cancel path, and the
;; guard before a kill takes the previewed buffer off screen
(define (switch-restore-home! buf)
  (let ((w (switch-home-window buf))
        (here (buffer-local buf 'switch-here)))
    (when w
      (cond ((and here (buffer-known? here)) (window-preview-buffer! here w))
            ((buffer-known? "*scratch*") (window-preview-buffer! "*scratch*" w))))))

;; close the popup and settle dormancy; KEEP stays awake (#f keeps none)
(define (switch-close! buf keep)
  (switch-sleep-woken! buf keep)
  (run-command "quit-window"))

;;; --- typing is the filter -------------------------------------------------------

(domain! 'buffers)
(effects! '(read))

(define-command "switch-self-insert"
  "Append the typed character to the narrowing"
  (lambda ()
    (let* ((buf (current-buffer))
           (ks (last-keys))
           (k (if (pair? ks) (car (reverse ks)) #f))
           (ch (cond ((equal? k "SPC") " ")
                     ((and (string? k) (= (string-length k) 1)) k)
                     (else #f))))
      (when ch
        (list-set-query! buf (string-append (list-query buf) ch))
        (list-goto-first-entry buf)
        (list-preview! buf)))))

(define-command "switch-del"
  "Widen the narrowing by one character"
  (lambda ()
    (let* ((buf (current-buffer))
           (q (list-query buf)))
      (unless (equal? q "")
        (list-set-query! buf (substring q 0 (- (string-length q) 1)))
        (list-goto-first-entry buf)
        (list-preview! buf)))))

;;; --- the verbs -------------------------------------------------------------------

(effects! '(write))

;; a container card names a group by its label, or a project by its root
(define (switch-card-target label)
  (let loop ((gs (group-names)))
    (cond ((null? gs)
           (list 'project (substring label 1 (- (string-length label) 1))))
          ((equal? (group-container-label (car gs)) label)
           (list 'group (car gs)))
          (else (loop (cdr gs))))))

;; a project is also a group: tag its open buffers and found it
(define (switch-found-project! root)
  (for-each (lambda (x)
              (when (and (not (buffer-group x))
                         (equal? (buffer-project-root x) root))
                (buffer-set-local! x 'group root)))
            (buffer-list))
  (switch-to-group! root))

;; the C-x G contract: after the group comes up, ask which buffer in it
(define (switch-then-pick! buf g)
  (when (and (buffer-known? buf) (buffer-local buf 'switch-then-pick))
    (buffer-set-local! buf 'switch-then-pick #f)
    (switch-open! (list 'locked g))))

(define (switch-pick! buf e context?)
  (let ((name (car e)))
    (cond
      ((switch-container? e)
       (let ((target (switch-card-target name)))
         (switch-close! buf #f)
         (if (equal? (car target) 'group)
             (switch-to-group! (nth 1 target))
             (switch-found-project! (nth 1 target)))
         (switch-then-pick! buf (nth 1 target))))
      ((buffer-known? name)
       (switch-close! buf name)
       (if context?
           (buffer-context-switch! name)
           (begin
             ;; the preview already put it in the home window — go there
             (let ((w (window-showing name)))
               (if w (select-window! w) (switch-to-buffer! name)))
             ;; a plain switch moves no windows, but the frame's standing
             ;; follows where you are
             (let ((bg (buffer-group name)))
               (when bg (set-frame-local! 'current-group bg)))
             (windows-shown-catchup!))))
      ((*switch-pick* name)
       (switch-close! buf #f))
      (else (message "no buffer here")))))

(define-command "switch-visit"
  "Visit the selected row; with no match, found a group named the narrowing"
  (lambda ()
    (let* ((buf (current-buffer))
           (e (list-current buf))
           (q (list-query buf)))
      (cond (e (switch-pick! buf e #f))
            ((equal? q "") (message "no buffer here"))
            (else
              ;; nothing matches: RET founds a group named Q from the
              ;; current windows — put the home window back first
              (switch-restore-home! buf)
              (switch-close! buf #f)
              (group-found-from-windows! q))))))

(define-command "switch-visit-context"
  "Enter the selected buffer's group, or found one from its project"
  (lambda ()
    (let* ((buf (current-buffer))
           (e (list-current buf)))
      (if e (switch-pick! buf e #t) (message "no buffer here")))))

(define-command "switch-mark"
  "Mark the row at point, or unmark a marked one"
  (lambda ()
    (let* ((buf (current-buffer))
           (e (list-current buf)))
      (cond ((not (and e (list-markable? buf e))) (message "no buffer here"))
            ((equal? (list-mark-of buf e) "*") (run-command "list-unmark"))
            (else (run-command "list-mark"))))))

;; C-k kills NOW — the marked buffers, or the row at point. The home
;; window leaves a dying buffer before it dies.
(define-command "switch-kill" "Kill the marked buffers, or the one at point"
  (lambda ()
    (let* ((buf (current-buffer))
           (names (filter buffer-known? (map car (list-targets buf))))
           (n 0))
      (if (null? names)
          (message "no buffer here")
          (begin
            (switch-restore-home! buf)
            (for-each (lambda (b)
                        (when (buffer-known? b)
                          (list-unmark-key! buf b)
                          (buffer-set-local! buf 'switch-woken
                            (remove (lambda (x) (equal? x b))
                                    (or (buffer-local buf 'switch-woken) '())))
                          (if (process-running? b) (process-kill! b))
                          (buffer-kill! b)
                          (set! n (+ n 1))))
                      names)
            (list-refresh! buf)
            (message (if (= n 0)
                         "already gone"
                         (string-append "killed " (number->string n) " "
                                        (list-noun buf n)))))))))

;; C-t puts a SET in a group. The prompt offers the groups that exist; a
;; name it does not know founds that group; "(none)" takes them out.
(define *switch-no-group* "(none)")

(define (switch-set-group! buf names g)
  (let ((n (length names))
        (out? (equal? g *switch-no-group*)))
    (for-each (lambda (b)
                (buffer-set-local! b 'group (if out? #f g))
                (when out? (buffer-set-local! b 'companion-of #f))
                (list-unmark-key! buf b))
              names)
    (list-refresh! buf)
    (message (string-append (number->string n) " " (list-noun buf n)
                            (if out? " left their group"
                                (string-append " joined " g))))))

(define-command "switch-group"
  "Put the marked buffers in a group, or take them out of one"
  (lambda ()
    (let* ((buf (current-buffer))
           (names (filter buffer-known? (map car (list-targets buf))))
           (n (length names)))
      (if (null? names)
          (message "no buffer here")
          (minibuffer-read
            (string-append "Group for " (number->string n) " "
                           (list-noun buf n) ": ")
            (cons (list *switch-no-group* "remove from the group")
                  (group-names))
            (lambda (input)
              (let ((g (string-trim input)))
                (switch-set-group! buf names
                  (if (equal? g "") *switch-no-group* g)))))))))

(effects! '(read))

;; C-g flips between the buffers and the contexts. Quitting is ESC: in
;; this one buffer the filter, not the quit, is what C-g's reflex serves.
(define-command "switch-toggle-groups" "Show groups and projects; again shows buffers"
  (lambda ()
    (let* ((buf (current-buffer))
           (groups? (equal? (buffer-local buf 'switch-view) 'groups)))
      (buffer-set-local! buf 'switch-view (if groups? 'buffers 'groups))
      (list-set-query! buf "")
      (list-refresh! buf)
      (list-goto-first-entry buf)
      (message (if groups? "buffers" "groups — RET switches, C-g goes back")))))

;; TAB locks to one group's buffers: the highlighted card's, or the
;; highlighted buffer's own
(define-command "switch-lock" "Narrow to the selected group's buffers"
  (lambda ()
    (let* ((buf (current-buffer))
           (e (list-current buf))
           (g (cond ((not e) #f)
                    ((switch-container? e)
                     (let ((t (switch-card-target (car e))))
                       (and (equal? (car t) 'group) (nth 1 t))))
                    (else (and (buffer-known? (car e)) (buffer-group (car e)))))))
      (if (not g)
          (message "no group here")
          (begin
            (buffer-set-local! buf 'switch-view (list 'locked g))
            (list-set-query! buf "")
            (list-refresh! buf)
            (list-goto-first-entry buf)
            (message (string-append "in " (group-label g) " — C-g widens")))))))

(define-command "switch-quit" "Close the switcher and put back what you were seeing"
  (lambda ()
    (let ((buf (current-buffer)))
      (switch-restore-home! buf)
      (switch-close! buf #f))))

;;; --- the mode --------------------------------------------------------------------

;; every printable key narrows: the keymap binds each one to the same
;; command, and the command reads the key that ran it
(define (switch-chars s)
  (let loop ((i 0) (out '()))
    (if (>= i (string-length s))
        (reverse out)
        (loop (+ i 1) (cons (substring s i (+ i 1)) out)))))

(define *switch-printables*
  (switch-chars
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.,:;!?@#$%^&*()[]{}<>+=~`'/|\\"))

(define *switch-keys*
  (append
    (map (lambda (ch) (list ch "switch-self-insert")) *switch-printables*)
    (list (list "SPC" "switch-self-insert")
          (list "DEL" "switch-del")
          (list "RET" "switch-visit")
          (list "C-RET" "switch-visit-context")
          (list "C-SPC" "switch-mark")
          (list "C-k" "switch-kill")
          (list "C-t" "switch-group")
          (list "C-g" "switch-toggle-groups")
          (list "TAB" "switch-lock")
          (list "ESC" "switch-quit"))))

(mode-icon! "switch-mode" "")

(define-list-mode! "switch-mode"
  (list
    'doc (string-append
           "The buffer switcher. Type to narrow; DEL widens by one "
           "character. The rows are buffers, group cards and browser tabs "
           "in most-recently-used order, and the highlight previews its row "
           "in the window you came from. RET visits the row; with no match, "
           "RET founds a group named what you typed. C-RET enters the "
           "row's group or project. C-SPC marks; C-k kills the marked "
           "buffers or the row at point; C-t puts them in a group. C-g "
           "shows groups and projects; TAB locks to one group; ESC quits.")
    'buffer *switch-buffer*
    'rows switch-rows
    'key (lambda (buf e) (car e))
    'local-filter #t
    'match switch-match?
    ;; C-x k kills a buffer from anywhere, and a chat can end on its own:
    ;; the count moves, the list re-renders
    'stamp (lambda (buf) (length (buffer-list-mru)))
    'columns (lambda (buf)
               (list (list "" 1)
                     (list "buffer" 34)
                     (list "" #f)))
    'cells switch-cells
    'title (lambda (buf)
             (let ((view (or (buffer-local buf 'switch-view) 'buffers)))
               (cond ((equal? view 'groups) "Groups")
                     ((pair? view) (group-label (nth 1 view)))
                     (else "Switch to"))))
    'meta switch-meta
    'markable? (lambda (buf e)
                 (and (not (switch-container? e)) (buffer-known? (car e))))
    'noun "buffer"
    'footer (lambda (buf)
              '(("RET" "switch") ("C-RET" "context") ("C-SPC" "mark")
                ("C-k" "kill") ("C-t" "group") ("C-g" "groups")
                ("TAB" "lock") ("DEL" "widen") ("ESC" "quit")))
    'preview switch-preview!
    'keys *switch-keys*))

;; the runtime locals must not persist: a window id and a woken list mean
;; nothing after a restart. Registered after define-list-mode!, so this
;; setup wins and still runs the list init.
(define-mode "switch-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (desktop-skip! buf 'switch-home-window)
      (desktop-skip! buf 'switch-woken)
      (buffer-set-local! buf 'switch-woken '())
      (list-mode-init! buf "switch-mode"))))

;;; --- opening ---------------------------------------------------------------------

(define (switch-open! view)
  (let* ((from (active-window))
         (here (or (window-buffer from) (current-buffer)))
         ;; C-x b from inside the switcher: keep the home it already has
         (again? (equal? here *switch-buffer*))
         (my-group (if again?
                       (buffer-local *switch-buffer* 'switch-group)
                       (or (buffer-group here) (frame-local 'current-group)))))
    ;; opening the switcher snapshots this group's arrangement: wherever
    ;; you go next, the way back is exact
    (group-layout-save-if-shown! my-group)
    (buffer-create *switch-buffer*)
    (unless again?
      (buffer-set-local! *switch-buffer* 'switch-home-window from)
      (buffer-set-local! *switch-buffer* 'switch-here here)
      (buffer-set-local! *switch-buffer* 'switch-group my-group)
      (buffer-set-local! *switch-buffer* 'switch-woken '()))
    (buffer-set-local! *switch-buffer* 'switch-view view)
    (display-buffer *switch-buffer*)
    ;; select the popup window the display rule opened; switching the
    ;; current window would clobber the window previews should target
    (let ((w (window-showing-other *switch-buffer* from)))
      (if w (select-window! w) (switch-to-buffer! *switch-buffer*)))
    (set-mode! "switch-mode")
    (list-refresh! *switch-buffer*)
    (list-goto-first-entry *switch-buffer*)))

(define-command "switch-to-buffer"
  "Switch buffer: type to narrow, RET visits, C-g shows groups"
  (lambda () (switch-open! 'buffers)))

(define-command "ibuffer" "The buffer switcher (the old ibuffer, merged into it)"
  (lambda () (switch-open! 'buffers)))

;; C-x G: pick a context, then pick a buffer in it
(define-command "switch-groups" "Switch group or project, then pick a buffer in it"
  (lambda ()
    (switch-open! 'groups)
    (buffer-set-local! *switch-buffer* 'switch-then-pick #t)))

(global-set-key "C-x C-b" "switch-to-buffer")
(global-set-key "C-x G" "switch-groups")

(category! 'buffers)
(catalog-meta! 'command "switch-kill" 'domain 'buffers 'effects '(destroy))
(catalog-meta! 'command "switch-group" 'domain 'buffers 'effects '(write))
(public! 'switch-open! "(switch-open! VIEW) — open the switcher on 'buffers, 'groups, or (locked GROUP)")
