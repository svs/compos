;;; switch.scm --- ONE buffer switcher: C-x b, C-x C-b, and ibuffer merged.
;;;
;;; A modal list buffer with its own keymap. Typing narrows — the filter
;;; is the default act, as in every list. Control chords act on rows:
;;; RET visits, C-RET enters the row's context, C-SPC marks, C-k kills,
;;; C-t sets the group, C-o shows groups and projects, TAB locks to a
;;; group, C-g and ESC quit. DEL widens the narrowing by one character.
;;;
;;; The rows are the C-x b pool: buffers and group cards woven by
;;; recency, plus whatever the switch-buffer-source seam adds (chrome
;;; adds browser tabs). Moving the highlight previews the row in the
;;; window you came from. A preview can wake a dormant buffer; closing
;;; the switcher puts every buffer nobody picked back to sleep.

(define *switch-buffer* "*switch*")
;; a modal in the center of the screen — the palette's geometry, as a window
(add-display-rule! *switch-buffer* 'popup (list 'side 'center 'size 0.5))

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

;; every project the editor knows that is not a group yet: the
;; remembered list (project.scm learns one from every visited file),
;; plus any root an open buffer implies. A switch founds its group.
(define (switch-project-roots)
  (let ((gs (group-names)))
    (let loop ((cs (append (if (boundp 'known-projects) (known-projects) '())
                           (map buffer-project-root (buffer-list))))
               (out '()))
      (if (null? cs)
          (reverse out)
          (let ((root (car cs)))
            (loop (cdr cs)
                  (if (and (string? root)
                           (not (equal? root ""))
                           (not (member root gs))
                           (not (member root out)))
                      (cons root out)
                      out)))))))

;; a project card wears the short name; the path rides in the
;; annotation, and the 5th element carries the root for the pick
(define (switch-project-candidate root)
  (list (string-append "[" (group-label root) "]")
        (string-append "project · " root)
        "container" '() root))

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

;; the locked view: ONE group, whole. The card leads as the default —
;; RET there keeps the group as it stands, or opens dired on a project
;; root. The open buffers follow, then the project's files, so the
;; second step of C-x G reaches a file the group never opened.
(define (switch-locked-root g)
  (if (file-directory? g)
      g
      (let loop ((bs (group-buffers-mru g)))
        (cond ((null? bs) #f)
              ((let ((r (buffer-project-root (car bs))))
                 (and (string? r) (not (equal? r "")) r)))
              (else (loop (cdr bs)))))))

(define (switch-locked-card g)
  (list (group-container-label g)
        (if (file-directory? g)
            "the project root — RET opens dired"
            "the group as it stands")
        "container" '()))

(define (switch-file-row? e)
  (and (> (length e) 2) (equal? (nth 2 e) "file")))

(define (switch-file-path e) (string-append (nth 3 e) "/" (car e)))

;; the root's files that no member has open — a file row carries its
;; root, so RET can build the absolute path back
(define (switch-locked-file-rows g)
  (let ((root (switch-locked-root g)))
    (if (not root)
        '()
        (let ((open (group-buffers-mru g)))
          (map (lambda (f) (list f "" "file" root))
               (filter (lambda (f)
                         (not (member (string-append root "/" f) open)))
                       (project-files root)))))))

(define (switch-locked-rows g)
  (append
    (list (switch-locked-card g))
    (annotate 'buffer
      (filter (lambda (b) (not (string-prefix? " " b)))
              (group-buffers-mru g)))
    (switch-locked-file-rows g)))

(define (switch-rows buf)
  (let ((view (or (buffer-local buf 'switch-view) 'buffers)))
    (cond ((equal? view 'groups) (switch-group-rows buf))
          ((and (pair? view) (equal? (car view) 'locked))
           (switch-locked-rows (nth 1 view)))
          (else (switch-buffer-rows buf)))))

;;; --- cells --------------------------------------------------------------------

(define (switch-ann e)
  (if (and (> (length e) 1) (string? (nth 1 e))) (nth 1 e) ""))

;; File buffers are named by their absolute path. Showing that as the row
;; label and then repeating marginalia's path in the detail cell wastes the
;; wide part of the switcher while truncating the one thing a person needs:
;; the filename. Keep the candidate itself untouched (selection and matching
;; still use the absolute path), but give the row a short, non-repeating face.
(define (switch-buffer-label name)
  (let ((path (buffer-path name)))
    (if (and (string? path) (not (equal? path "")))
        (cadr (path-split path))
        name)))

(define (switch-parent-label path)
  (let* ((dir (car (path-split path)))
         (n (string-length dir))
         (bare (if (and (> n 1)
                        (equal? (substring dir (- n 1) n) "/"))
                   (substring dir 0 (- n 1))
                   dir)))
    (cond ((equal? bare "") "")
          ((equal? bare "/") "/")
          (else (cadr (path-split bare))))))

(define (switch-buffer-detail name)
  (let* ((path (buffer-path name))
         (mode (or (buffer-local name 'mode-name) "Fundamental"))
         (parent (if (and (string? path) (not (equal? path "")))
                     (switch-parent-label path)
                     "")))
    (if (equal? parent "")
        mode
        (string-append mode "  ·  " parent))))

;; a container's 4th element is its member chips; a file row's is its
;; root — only a list answers as chips
(define (switch-chips e)
  (let ((c (and (> (length e) 3) (nth 3 e))))
    (if (pair? c) c '())))

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
      ((switch-file-row? e)
       (list "" (list name #f) (list "file" "dim")))
      ((buffer-known? name)
       (list (if (and (buffer-exists? name) (buffer-modified? name))
                 (list "●" "warn") "")
             (list (switch-buffer-label name)
                   (or (buffer-filename-face name)
                       (if (string-prefix? "*" name) "accent" #f)))
             (list (if (buffer-path name)
                       (switch-buffer-detail name)
                       ann)
                   "faint")))
      ;; a seam row — a browser tab
      (else (list "" (list name "accent") (list ann "dim"))))))

;; a row matches on everything it says, untruncated — the name, the
;; annotation, and a card's member chips. Orderless: every
;; space-separated term must match somewhere, in any order, so
;; "text-mode notes" and "notes text-mode" find the same row.
(define (switch-match? buf e input)
  (let ((text (string-join
                (cons (car e) (cons (switch-ann e) (switch-chips e))) " ")))
    (let loop ((ts (filter (lambda (t) (not (equal? t "")))
                           (string-split input " "))))
      (cond ((null? ts) #t)
            ((re-match? (car ts) text) (loop (cdr ts)))
            (else #f)))))

(define (switch-meta buf)
  (let* ((view (or (buffer-local buf 'switch-view) 'buffers))
         (n (length (list-entries buf))))
    (cond ((equal? view 'groups)
           (string-append (number->string n) " contexts · RET switches"))
          ((pair? view)
           (string-append "in " (group-label (nth 1 view))
                          " · the card, then its buffers, then its files"
                          " · RET on the card keeps the group"))
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
;; Groups are records: the reader clears the legacy 'group local the
;; moment a buffer has a real membership, so writing it here founded
;; nothing and left every buffer where it was.
(define (switch-found-project! root)
  (project-enter-group! root))

(define (switch-pick! buf e context?)
  (let ((name (car e))
        (view (buffer-local buf 'switch-view)))
    (cond
      ;; the locked view's own card is the DEFAULT: RET keeps the group
      ;; as it stands, or opens dired on a project root
      ((and (switch-container? e) (pair? view) (equal? (car view) 'locked))
       (let ((g (nth 1 view)))
         (switch-close! buf #f)
         (when (file-directory? g) (dired-open g))))
      ((switch-container? e)
       (let ((target (if (> (length e) 4)
                         (list 'project (nth 4 e))
                         (switch-card-target name)))
             (groups-view? (equal? view 'groups)))
         (switch-close! buf #f)
         (if (equal? (car target) 'group)
             (switch-to-group! (nth 1 target))
             (switch-found-project! (nth 1 target)))
         ;; a pick from the GROUPS view continues to the second step:
         ;; the group's buffers and its files, the card leading as the
         ;; default. A card in the recency stream stays a plain switch.
         (when groups-view?
           (switch-open! (list 'locked (nth 1 target))))))
      ;; a project file nobody has open: visit it — it joins the group
      ((switch-file-row? e)
       (let* ((path (switch-file-path e))
              (g (and (pair? view) (nth 1 view)))
              ;; the locked view can name a PROJECT that has no group
              ;; yet, and visit-in-group adds nothing to a group that
              ;; does not exist. The file joins that project's group, so
              ;; found it here.
              (id (and g (or (group-resolve-id g) (group-ensure-record! g)))))
         (switch-close! buf #f)
         (visit-in-group path id)))
      ((buffer-known? name)
       (switch-close! buf name)
       (if context?
           (buffer-context-switch! name)
           (begin
             ;; the preview already put it in the home window — go there
             (let ((w (window-showing name)))
               (if w (select-window! w) (switch-to-buffer! name)))
             (group-current-recalculate!)
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
    ;; buffer-move-to-group! owns this: membership is 'group-ids, and the
    ;; reader clears the legacy 'group local the moment a buffer has real
    ;; memberships — so writing that local here left the buffers exactly
    ;; where they were.
    (for-each (lambda (b)
                (buffer-move-to-group! b (if out? #f g))
                (list-unmark-key! buf b))
              names)
    (list-refresh! buf)
    (message (string-append (number->string n) " " (list-noun buf n)
                            (if out? " left their group"
                                (string-append " joined " g))))))

(define-command "switch-group"
  "Add the marked or otherwise selected buffers to another group"
  (lambda () (run-command "buffer-add-to-group")))

;; buffer-add-to-group prompts, so it changes membership inside a
;; minibuffer callback and returns long before. The switcher hears about
;; it the same way anything else does: the annotation reads a group, so a
;; changed membership makes the rows stale, and the marks that chose
;; those buffers are spent.
(add-hook! 'group-membership-hook
  (lambda ()
    (when (buffer-known? *switch-buffer*)
      (list-clear-marks! *switch-buffer*)
      (list-refresh! *switch-buffer*))))

(effects! '(read))

;; C-o flips between the buffers and the contexts. C-g keeps its one
;; meaning: the modal disappears.
(define-command "switch-toggle-groups" "Show groups and projects; again shows buffers"
  (lambda ()
    (let* ((buf (current-buffer))
           (groups? (equal? (buffer-local buf 'switch-view) 'groups)))
      (buffer-set-local! buf 'switch-view (if groups? 'buffers 'groups))
      (list-set-query! buf "")
      (list-refresh! buf)
      (list-goto-first-entry buf)
      (message (if groups? "buffers" "groups — RET switches, C-o goes back")))))

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
            (message (string-append "in " (group-label g) " — C-o widens")))))))

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
          ;; select all: every row the narrowing shows; again unmarks
          (list "C-a" "list-mark-all")
          (list "C-k" "switch-kill")
          (list "C-t" "switch-group")
          (list "C-o" "switch-toggle-groups")
          (list "TAB" "switch-lock")
          (list "C-g" "switch-quit")
          (list "ESC" "switch-quit"))))

(define *switch-footer*
  (string-append "type to narrow · DEL widen · RET switch · C-RET context · "
                 "C-SPC mark · C-a all · C-k kill · C-t add to group · "
                 "C-o groups · TAB lock · C-g quit"))


(mode-icon! "switch-mode" "")

(define-list-mode! "switch-mode"
  (list
    'doc (string-append
           "The buffer switcher. Type to narrow; DEL widens by one "
           "character. The rows are buffers, group cards and browser tabs "
           "in most-recently-used order, and the highlight previews its row "
           "in the window you came from. RET visits the row; with no match, "
           "RET founds a group named what you typed. C-RET enters the "
           "row's group or project. C-SPC marks; C-a marks every shown "
           "row, and again unmarks them; C-k kills the marked "
           "buffers or the row at point; C-t adds them to another group. "
           "C-o shows groups and "
           "projects; TAB locks to one group — the card "
           "leads as the default, its buffers and its project files "
           "follow. C-g and ESC quit.")
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
                     (list "buffer" #f)
                     (list "details" 24)))
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
      (buffer-set-local! buf 'footer-line *switch-footer*)
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

;; C-x G: pick a context, then pick a buffer or file in it
(define-command "switch-groups" "Switch group or project, then pick a buffer or file in it"
  (lambda () (switch-open! 'groups)))

(global-set-key "C-x G" "switch-groups")

(category! 'buffers)
(catalog-meta! 'command "switch-kill" 'domain 'buffers 'effects '(destroy))
(catalog-meta! 'command "switch-group" 'domain 'buffers 'effects '(write))
(public! 'switch-open! "(switch-open! VIEW) — open the switcher on 'buffers, 'groups, or (locked GROUP)")
