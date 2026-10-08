;;; switch.scm --- ONE buffer switcher: C-x b, C-u C-x b, C-x C-b, and ibuffer merged.
;;;
;;; A modal list buffer with its own keymap. Typing narrows — the filter
;;; is the default act, as in every list. Control chords act on rows:
;;; RET visits, C-RET enters the row's context, C-SPC marks, C-k kills,
;;; C-t sets the group, C-o shows groups and projects, TAB locks to a
;;; group, C-g and ESC quit. DEL widens the narrowing by one character.
;;;
;;; The rows are the C-x b pool in sections by group, as ibuffer sections
;;; them: the current group's buffers, every other group's buffers under
;;; its name, the ungrouped buffers (and whatever the switch-buffer-source
;;; seam adds — chrome adds browser tabs), the other groups' cards, then
;;; what peeks let go. Inside a section the order is recency. A heading
;;; is not a choice: the highlight steps over it, and a filter that
;;; empties a section drops its heading too.
;;;
;;; Moving the highlight previews the row in the window you came from.
;;; A preview can wake a dormant buffer; closing the switcher puts every
;;; buffer nobody picked back to sleep.
;;;
;;; The same rows serve the minibuffer prompt (ibuffer-prompt, C-x b):
;;; one rows fn, one act fn, two surfaces.

(define *switch-buffer* "*switch*")

;; the seam's pick fn from the last rows fetch — a closure, so it lives
;; here and not in a buffer-local
(define *switch-pick* (lambda (picked) #f))

;;; --- rows ---------------------------------------------------------------------

(define (switch-container? e)
  (and (> (length e) 2) (equal? (nth 2 e) "container")))

;; group ids whose card can appear: every group and every pseudo group,
;; except the one you are in
(define (switch-groups buf)
  (filter (lambda (g) (not (equal? g (buffer-local buf 'switch-group))))
          (group-names-all)))

;; every project the editor knows that is not a group yet: the
;; remembered list (project.scm learns one from every visited file),
;; plus any root an open buffer implies. A switch founds its group.
(define (switch-project-roots)
  (let ((gs (group-names)))
    (let loop ((cs (append (known-projects)
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

;; a heading row: kind "separator". list-mode steps over it and drops
;; it when its section empties; the minibuffer does the same.
(define (switch-separator label) (list label "" "separator"))

(define (switch-separator? buf e)
  (and (> (length e) 2) (equal? (nth 2 e) "separator")))

(define (switch-section label rows)
  (if (pair? rows) (cons (switch-separator label) rows) '()))

;; the C-x b pool: MRU-woven buffers and group cards, plus the seam's
;; rows (chrome tabs). The place you stand is not an offer — HERE, and
;; the seam's own standing (from a page, the tab you pressed the key
;; in) — and neither is this list itself. A peek is a look, not a
;; buffer of yours. WIN's own history leads: the buffers this window
;; showed, newest first, then the editor's one stream — another window
;; cannot reorder this window's previous buffers (Emacs other-buffer).
(define (switch-pool here my-group win)
  (let* ((source (switch-buffer-source (switch-history-pool my-group)))
         (standing (nth 1 source))
         ;; the buffer you are on is a candidate like any other: you came
         ;; here to see the group, and a group without its own buffer in
         ;; it reads wrong. It only never LEADS, so the default pick and
         ;; the first row are still somewhere else
         (self? (lambda (c) (or (equal? (car c) here) (equal? (car c) standing))))
         (cands (filter (lambda (c) (and (not (equal? (car c) *switch-buffer*))
                                         (not (peek-buffer? (car c)))))
                        (car source)))
         (pool (filter (lambda (c) (not (self? c))) cands))
         (self (filter self? cands))
         (mine (if (and win (window-exists? win)) (window-prev-buffers win) '()))
         ;; one pass over the history picks its rows in history order;
         ;; a sort over the rows cost seconds at four hundred rows
         (led (let loop ((names mine) (out '()))
                (cond ((null? names) (reverse out))
                      ((assoc (car names) pool)
                       (loop (cdr names) (cons (assoc (car names) pool) out)))
                      (else (loop (cdr names) out))))))
    (set! *switch-pick* (nth 2 source))
    (append led (filter (lambda (c) (not (member c led))) pool) self)))

;; is NAME a member of the group with ID? A read of the buffer's own
;; locals, not buffer-in-group?: that one resolves every id against the
;; group records, and over four hundred rows it held the Session for
;; seconds. A legacy 'group tag names the group, so only it resolves.
(define (switch-member? name id)
  (let ((raw (if (chat-buffer? name)
                 (buffer-local name 'group-id)
                 (buffer-local name 'group-ids))))
    (cond ((pair? raw) (and (member id raw) #t))
          ((string? raw) (equal? raw id))
          (else
           (let ((legacy (and (not (chat-buffer? name)) (buffer-local name 'group))))
             (and (string? legacy) (equal? (group-resolve-id legacy) id)))))))

;; the group ids a row's buffer holds, read from its own locals the way
;; switch-member? reads them: no resolve per row
(define (switch-memberships name)
  (let ((raw (if (chat-buffer? name)
                 (buffer-local name 'group-id)
                 (buffer-local name 'group-ids))))
    (cond ((pair? raw) raw)
          ((string? raw) (list raw))
          (else
           (let ((legacy (and (not (chat-buffer? name)) (buffer-local name 'group))))
             (let ((id (and (string? legacy) (group-resolve-id legacy))))
               (if id (list id) '())))))))

;; the pool in sections, the ibuffer way: this group's buffers, then
;; every other group's buffers under the group's name, then the buffers
;; no group claims (and whatever the switch-buffer-source seam adds —
;; chrome adds browser tabs), then the other groups' cards, then what
;; peeks let go. Inside a section the order is the window's history.
;; WIN is the window the rows are for.
(define (switch-sectioned-rows here my-group &optional win)
  (let* ((pool (switch-pool here my-group win))
         (id (and my-group (group-resolve-id my-group)))
         (cards (filter switch-container? pool))
         (bufs (filter (lambda (c) (not (switch-container? c))) pool)))
    (append
      (fold (lambda (out bucket)
              (append out (switch-section (car bucket) (nth 2 bucket))))
            '()
            (ibuffer-group-buckets bufs id (lambda (c) (switch-memberships (car c)))))
      (switch-section (if id "other groups" "groups") cards)
      (switch-section "recent" (switch-recent-rows)))))

;; the buffers view of the modal: the rows are for the home window
(define (switch-buffer-rows buf)
  (switch-sectioned-rows (buffer-local buf 'switch-here)
                         (buffer-local buf 'switch-group)
                         (switch-home-window buf)))

;; what peeks showed and let go, below the live buffers. RET peeks it
;; again; a row that is live again is not repeated.
(define (switch-recent-row? e)
  (and (> (length e) 2) (equal? (nth 2 e) "recent")))

(define (switch-recent-rows)
  (map (lambda (e)
         (list (car e)
               (string-append "recent · " (symbol->string (nth 1 e)))
               "recent" (nth 2 e)))
       (filter (lambda (e) (not (buffer-known? (car e))))
               *peek-recent*)))

;; the locked view: ONE group, whole. The card leads as the default —
;; RET there keeps the group as it stands, or opens dired on a project
;; root. The open buffers follow, then the project's files, so the
;; second step of C-x G reaches a file the group never opened.
(define (switch-locked-root g)
  (if (file-directory? g)
      g
      (let loop ((bs (group-user-buffers-mru g)))
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
        (let ((open (group-user-buffers-mru g)))
          (map (lambda (f) (list f "" "file" root))
               (filter (lambda (f)
                         (not (member (string-append root "/" f) open)))
                       (project-files root)))))))

(define (switch-locked-rows g)
  (append
    (list (switch-locked-card g))
    (annotate 'buffer
      (filter (lambda (b) (not (string-prefix? " " b)))
              (group-user-buffers-mru g)))
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

;; A chat is known by its title, not by *chat:GROUP:N*. A titled chat has
;; been renamed already; an untitled one keeps its derived name, and the
;; first label its running summary wrote stands in for it. Every other
;; buffer answers with its own name.
(define (switch-chat-label name)
  (let ((label (chat-prompt-label name)))
    (if (and (string? label) (not (equal? label ""))) label name)))

;; File buffers are named by their absolute path. Showing that as the row
;; label and then repeating marginalia's path in the detail cell wastes the
;; wide part of the switcher while truncating the one thing a person needs:
;; the filename. Keep the candidate itself untouched (selection and matching
;; still use the absolute path), but give the row a short, non-repeating face.
(define (switch-buffer-label name)
  (let ((path (buffer-path name)))
    (if (and (string? path) (not (equal? path "")))
        (cadr (path-split path))
        (switch-chat-label name))))

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
      ((switch-separator? buf e)
       (list "" (list (string-append "── " name " ") "accent") ""))
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
      ((switch-recent-row? e)
       (list "" (list name "faint") (list ann "dim")))
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
;; the switcher narrows the way the prompt does: one matcher, so
;; "*scratch*" is a name and "Foo" finds foo
(define (switch-match? buf e input)
  (let ((text (string-join
                (cons (car e)
                      (cons (switch-chat-label (car e))
                            (cons (switch-ann e) (switch-chips e))))
                " ")))
    (completion-match? text input 'substring)))

(define (switch-meta buf)
  (let* ((view (or (buffer-local buf 'switch-view) 'buffers))
         ;; headings are not candidates; list-count asks markable? per
         ;; row and costs a wide list 200ms per draw
         (n (length (filter (lambda (e) (not (switch-separator? buf e)))
                            (list-entries buf)))))
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
        (preview-show b 'here w)
        ;; the primitive wakes a sleeper; the mode setup must follow, or
        ;; switch-to-buffer! later sees the buffer live and skips it
        (when (and sleeping (buffer-exists? b))
          (restore-buffer-runtime! b)
          (switch-note-woken! buf b))))))

;; put HOME back to what it showed at open — the cancel path, and the
;; guard before a kill takes the previewed buffer off screen
(define (switch-restore-home! buf)
  (preview-end #f))

;; close the popup and settle dormancy; KEEP stays awake (#f keeps none)
;; a pick from outside the group takes another window (docs/groups.md,
;; sealed groups): the home window takes back what it showed, and the
;; switch that follows finds the buffer off screen
(define (switch-close! buf keep)
  (switch-sleep-woken! buf keep)
  ;; the look ends: a pick keeps it, a foreign pick or none gives it back
  (preview-end (and keep (not (display-foreign? keep)) #t))
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
  (let loop ((gs (group-names-all)))
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

(define (switch-locked-view? view)
  (and (pair? view) (equal? (car view) 'locked)))

;; What a pick means — ONE answer for the modal and the prompt. E is the
;; row, VIEW the view it came from, CONTEXT? the C-RET verb. CLOSE! takes
;; the surface down first and takes the buffer to keep awake (#f keeps
;; none); the prompt is already down, so it passes a no-op.
(define (switch-act! e view context? close!)
  (let ((name (car e)))
    (cond
      ;; the locked view's own card is the DEFAULT: RET keeps the group
      ;; as it stands, or opens dired on a project root
      ((and (switch-container? e) (switch-locked-view? view))
       (let ((g (nth 1 view)))
         (close! #f)
         (when (file-directory? g) (dired-open g))))
      ((switch-container? e)
       (let ((target (if (> (length e) 4)
                         (list 'project (nth 4 e))
                         (switch-card-target name)))
             (groups-view? (equal? view 'groups)))
         (close! #f)
         (if (equal? (car target) 'group)
             (switch-to-group! (nth 1 target))
             (switch-found-project! (nth 1 target)))
         ;; a pick from the GROUPS view continues to the second step:
         ;; the group's buffers and its files, the card leading as the
         ;; default. A card in the recency stream stays a plain switch.
         (when groups-view?
           (switch-open! (list 'locked (nth 1 target))))))
      ;; a recent row: what a peek let go comes back as a peek, in the
      ;; home window's frame, beside where you were
      ((switch-recent-row? e)
       (let ((entry (peek-recent-find (nth 3 e))))
         (close! #f)
         (when entry (peek-revive! entry))))
      ;; a project file nobody has open: visit it — it joins the group
      ((switch-file-row? e)
       (let* ((path (switch-file-path e))
              (g (and (pair? view) (nth 1 view)))
              ;; the locked view can name a PROJECT that has no group
              ;; yet, and visit-in-group adds nothing to a group that
              ;; does not exist. The file joins that project's group, so
              ;; found it here.
              (id (and g (or (group-resolve-id g) (group-ensure-record! g)))))
         (close! #f)
         (visit-in-group path id)))
      ((buffer-known? name)
       (close! name)
       (if context?
           (buffer-context-switch! name)
           (begin
             ;; the buffer comes to you: a switch opens it in the group you
             ;; are standing in, and the frame keeps the layout you picked
             ;; from. The preview already put it in the home window.
             (switch-to-buffer! name)
             (group-current-recalculate!)
             (windows-shown-catchup!))))
      ((*switch-pick* name)
       (close! #f))
      (else (message "no buffer here")))))

(define (switch-pick! buf e context?)
  (switch-act! e (buffer-local buf 'switch-view) context?
               (lambda (keep) (switch-close! buf keep))))

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

;; group-add prompts, so it changes membership inside a
;; minibuffer callback and returns long before. The switcher hears about
;; it the same way anything else does: the annotation reads a group, so a
;; changed membership makes the rows stale, and the marks that chose
;; those buffers are spent.
(define (switch--membership-hook!)
    (when (buffer-known? *switch-buffer*)
      (list-clear-marks! *switch-buffer*)
      ;; Opening the switcher fetches fresh rows. Hidden tables need no draw.
      (when (member *switch-buffer* (map cadr (window-list-all)))
        (list-refresh! *switch-buffer*))))

(add-hook! 'group-membership-hook 'switch--membership-hook!)

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
    (list (list "DEL" "switch-del")
          (list "RET" "switch-visit")
          (list "C-RET" "switch-visit-context")
          ;; select all: every row the narrowing shows; again unmarks
          (list "C-a" "list-mark-all")
          (list "C-k" "switch-kill")
          (list "C-t" "group-add")
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
           "character. The rows are this group's buffers, the other groups' "
           "cards, every other buffer and browser tab, then recent peeks, "
           "each section in most-recently-used order. The highlight "
           "previews its row "
           "in the window you came from. RET visits the row; with no match, "
           "RET founds a group named what you typed. C-RET enters the "
           "row's group or project. SPC marks; C-a marks every shown "
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
    'separator? switch-separator?
    'markable? (lambda (buf e)
                 (and (not (switch-container? e)) (buffer-known? (car e))))
    'mark-command "switch-mark"
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

(define-key "ctl-x-map" "G" "switch-groups")

;;; --- the prompt form -------------------------------------------------------------
;;; The same rows as a minibuffer prompt, for the surfaces that draw only
;;; a prompt: a browser page under the chrome extension. RET, C-RET and
;;; C-c C-o mean what they mean in the modal.

;; a recent row carries its peek entry in the 4th slot and a file row
;; its root; the prompt's candidate encoder reads a 4th slot as chips,
;; so the prompt gets the row without it and the confirm looks the full
;; row up by name
(define (switch-prompt-row e)
  (cond ((switch-recent-row? e) (list (car e) (nth 1 e) "recent"))
        ((switch-file-row? e) (list (car e) (string-append "file · " (nth 3 e)) "file"))
        ((buffer-known? (car e)) (cons (switch-chat-label (car e)) (cdr e)))
        (else e)))

;; the rows the prompt offers, labelled the way you would name them: a
;; chat by its title. A label must name ONE row, so a title another row
;; already wears -- as its own name or as an earlier label -- is dropped
;; for the buffer's own name, which is unique.
(define (switch-prompt-rows rows)
  (let ((names (map car rows)))
    (let loop ((rs rows) (seen '()) (out '()))
      (if (null? rs)
          (reverse out)
          (let* ((e (car rs))
                 (r (switch-prompt-row e))
                 (label (if (or (equal? (car r) (car e))
                                (and (not (member (car r) names))
                                     (not (member (car r) seen))))
                            (car r)
                            (car e))))
            (loop (cdr rs) (cons label seen) (cons (cons label (cdr r)) out)))))))

;; RET with nothing typed takes the first row that is neither a heading
;; nor the buffer you are already on, so the prompt advertises exactly that
(define (switch-first-choice rows &optional here)
  (let loop ((rs rows))
    (cond ((null? rs) #f)
          ((switch-separator? #f (car rs)) (loop (cdr rs)))
          ;; the buffer you are on is a row, never the default: RET on an
          ;; empty input has to take you somewhere
          ((and here (equal? (car (car rs)) here)) (loop (cdr rs)))
          (else (car (car rs))))))

;; the prompt lists buffers, not group cards: the sectioned rows
;; without the containers, and without a heading that then has no rows.
;; A group is reached by C-RET on one of its buffers, by TAB on its
;; name, or by C-x G.
(define (switch-buffer-only-rows rows)
  (let loop ((rs (filter (lambda (e) (not (switch-container? e))) rows))
             (out '()))
    (cond ((null? rs) (reverse out))
          ((and (switch-separator? #f (car rs))
                (or (null? (cdr rs)) (switch-separator? #f (cadr rs))))
           (loop (cdr rs) out))
          (else (loop (cdr rs) (cons (car rs) out))))))

;; the buffers C-x b offers, in the order the pool keeps: the window's
;; own history first, then the editor's recency, the buffer you are on
;; last, then the files a peek let go. Names only: the pool annotates
;; every buffer for the candidate panel, and that cost 800ms the table
;; never shows.
(define (switch-prompt-buffers here my-group win)
  (let* ((bufs (filter (lambda (b)
                         (and (not (string-prefix? " " b))
                              (not (equal? b *switch-buffer*))
                              (not (buffer-context-only? b))
                              (not (peek-buffer? b))))
                       (buffer-list-mru)))
         (mine (if (and win (window-exists? win)) (window-prev-buffers win) '()))
         (led (filter (lambda (n) (and (member n bufs) (not (equal? n here)))) mine))
         (rest (filter (lambda (b) (and (not (member b led)) (not (equal? b here)))) bufs)))
    (append led rest
            (if (member here bufs) (list here) '())
            (map car (switch-recent-rows)))))

;; the wall time of the last C-x b, key dispatch to a usable minibuffer:
;; (ibuffer-prompt-last-ms) reads it back for a measurement outside eval
(define *ibuffer-prompt-last-ms* #f)

;; C-x b in the editor: the ibuffer table in the minibuffer form. The
;; candidate prompt below stays for the surfaces that draw only a prompt.
(define (switch-buffer-table! options)
    (let ((t0 (monotonic-ms)))
      (let* ((here (or (window-buffer (active-window)) (current-buffer)))
             (my-group (or (buffer-group here) (frame-local 'current-group)))
             (rows (switch-prompt-buffers here my-group (active-window))))
        (if (null? (filter (lambda (b) (not (equal? b here))) rows))
            (message "No other buffer available")
            (ibuffer-prompt! rows *ibuffer-prompt-buffer* "ibuffer-pretty-mode" "Switch to: "
              (lambda (row close!)
                (ibuffer-pick! row close!)
                (group-current-recalculate!))
              "minibuffer" options)))
      (set! *ibuffer-prompt-last-ms* (- (monotonic-ms) t0))))


;; The title picker is deliberately window-local: it offers only the buffers
;; in this pane's own previous-buffer stack, not the frame-wide switch pool.
(define (switch-window-buffers)
  (let* ((win (active-window))
         (here (window-buffer win)))
    (filter (lambda (name)
              (and (string? name)
                   (not (equal? name here))
                   (buffer-known? name)))
            (window-prev-buffers win))))

(define-command "switch-window-buffer"
  "Choose another buffer from this window's title"
  (lambda ()
    (let* ((home (active-window))
           (here (window-buffer home))
           (rows (switch-window-buffers)))
      (if (null? rows)
          (message "No other buffer in this window")
          (let ((restore! (lambda () (preview-end #f))))
            (minibuffer-read-preview "Window buffers: " (annotate 'buffer rows)
              (lambda (row)
                (when (and (string? row) (buffer-known? row) (window-exists? home))
                  (preview-show row 'here home)))
              (lambda (row)
                (restore!)
                (when (and (string? row) (buffer-known? row))
                  (switch-to-buffer-here! row)
                  (group-current-recalculate!)))
              restore!
              #f "minibuffer"))))))

(define (switch-bare-candidates names)
  (let* ((pairs (map (lambda (name)
                  (list (if (string-prefix? "/" name) (cadr (ibuffer-split-path name)) name) name)) names))
         (labels (sort (map car pairs)))
         (duplicates (let loop ((rest labels) (out '()))
                       (if (or (null? rest) (null? (cdr rest))) out
                           (loop (cdr rest) (if (equal? (car rest) (cadr rest))
                                               (cons (car rest) out) out))))))
    (map (lambda (pair)
           (if (member (car pair) duplicates) (list (cadr pair) (cadr pair)) pair)) pairs)))

(define (switch-buffer-info-candidates candidates rows groups)
  ;; CANDIDATES and ROWS come in the same order, so a row is the next one,
  ;; never a search through every row
  (let loop ((cs candidates) (rs rows) (out '()))
    (if (null? cs)
        (reverse out)
        (let* ((candidate (car cs))
               (r (if (and (pair? rs) (equal? (car (car rs)) (cadr candidate)))
                      (car rs)
                      (or (assoc (cadr candidate) rows) (list (cadr candidate) #f #f #f #f #f #f))))
               (mode (or (nth 3 r) ""))
               (ids (if (equal? mode "chat-mode") (nth 4 r) (or (nth 5 r) (nth 6 r))))
               (ids (cond ((string? ids) (list ids)) ((pair? ids) ids) (else '())))
               (group (string-join (map (lambda (id)
                        (let ((g (assoc id groups))) (if g (cadr g) id))) ids) ", "))
               (parts (filter (lambda (s) (not (equal? s "")))
                        (list (if (and (nth 1 r) (nth 2 r)) "*" "") mode group))))
          (loop (cdr cs) (if (pair? rs) (cdr rs) rs)
                (cons (list (car candidate) (string-join parts "  ")) out))))))

(define (switch-prompt-rows here win)
  ;; switch-prompt-buffers' order from one read of the buffer rows: the
  ;; buffers WIN showed before, every other buffer by recent use, HERE,
  ;; then the recent files. A row is (NAME PATH MODIFIED MODE GROUP-ID
  ;; GROUP-IDS GROUP); a file that is no buffer has #f for each.
  (let* ((all (filter (lambda (r) (not (and (nth 7 r) (nth 8 r))))
                      (cadr (buffer-rows (list 'sort 'recent 'exclude-names (list *switch-buffer*)
                                               'fields '(path modified mode group-id group-ids group
                                                         live preview-opened))))))
         (row-of (lambda (r) (list-head r 7)))
         (mine (if (and win (window-exists? win)) (window-prev-buffers win) '()))
         (led (filter (lambda (r) r)
                      (map (lambda (n) (and (not (equal? n here)) (assoc n all))) mine)))
         (led-names (map car led))
         (rest (filter (lambda (r) (not (or (equal? (car r) here) (member (car r) led-names)))) all))
         (self (let ((r (assoc here all))) (if r (list r) '())))
         (buffers (map row-of (append led rest self))))
    (append buffers
            (map (lambda (f) (list (car f) #f #f #f #f #f #f))
                 (filter (lambda (f) (not (assoc (car f) buffers))) (switch-recent-rows))))))

(define (switch-bare-prompt!)
  (let* ((start (monotonic-ms))
         (home (active-window))
         (here (or (window-buffer home) (current-buffer)))
         (group (or (buffer-group here) (frame-local 'current-group)))
         (rows (filter (lambda (r) (ibuffer-workspace-path? (cadr r)))
                       (switch-prompt-rows here (active-window))))
         (names (map car rows))
         (candidates (switch-bare-candidates names))
         (display (if ibuffer-info
                      (switch-buffer-info-candidates candidates rows (ibuffer-table-group-labels))
                      ;; the mode stays beside every buffer, info or not
                      (map (lambda (c)
                             (let ((r (assoc (cadr c) rows)))
                               (list (car c) (or (and r (nth 3 r)) ""))))
                           candidates)))
         (woken '())
         (restore! (lambda () (preview-end #f)))
         (sleep-woken! (lambda (keep)
                         (for-each (lambda (b) (unless (equal? b keep) (buffer-sleep! b))) woken)
                         (set! woken '()))))
    (minibuffer-read-preview "Switch to: " display
      (lambda (label)
        (let* ((entry (assoc label candidates)) (target (and entry (cadr entry))))
          (if (and target (buffer-known? target) (window-exists? home))
              (let ((sleeping? (not (buffer-exists? target))))
                (preview-show target 'here home)
                (when (and sleeping? (buffer-exists? target))
                  (restore-buffer-runtime! target)
                  (set! woken (cons target woken))))
              (restore!))))
      (lambda (label)
        (let* ((entry (assoc label candidates)) (target (and entry (cadr entry))))
          (restore!)
          (when target (ibuffer-pick! target (lambda () #f))
                       (group-current-recalculate!))
          (sleep-woken! target)))
      (lambda () (restore!) (sleep-woken! #f))
      ibuffer-info "minibuffer")
    (set! *ibuffer-prompt-last-ms* (- (monotonic-ms) start))))

(define-command "ibuffer-prompt" "Switch to a buffer with the plain minibuffer list"
  (lambda () (switch-bare-prompt!)))

(define-command "ibuffer-prompt-pretty" "Switch to a buffer with the pretty minibuffer list"
  (lambda () (switch-buffer-table! '(pretty #t))))

(define (ibuffer-prompt-last-ms) *ibuffer-prompt-last-ms*)

(global-set-key "C-x b" "ibuffer-prompt")
(global-set-key "C-x C-t" "switch-window-buffer")

(category! 'buffers)
(catalog-meta! 'command "switch-kill" 'domain 'buffers 'effects '(destroy))
(public! 'switch-open! "(switch-open! VIEW) — open the switcher on 'buffers, 'groups, or (locked GROUP)")
