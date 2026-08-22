;;; groups.scm --- Buffer groups, saved layouts, and companion chats.

;;;; A group is a durable context. Its chat buffer owns the group's metadata
;;;; and saved window layout. This package owns membership, switching, the
;;;; groups board, and the commands that connect work buffers to companion chats.

(domain! 'buffers)
(effects! '(write))

;;; --- buffer groups: work buffers + chats, tied by membership tags -------------
;;; The 'group local is the primary membership. The 'groups local contains
;;; additional memberships. Old desktops with only 'group remain valid.
;;; (group-buffers g) derives membership on demand. Membership persists with
;;; the locals, and a killed buffer simply leaves every set.
;;; C-c w from a work buffer groups it by itself and opens the group chat
;;; on the right; C-c g joins a named group; C-c q talks to the group chat.
;;; The "*chat:" names avoid the "*chat*"/"*llm:" popup rules on purpose.

(define (buffer-group b)
  (or (buffer-local b 'group)
      ;; legacy: a pre-group companion pointer doubles as a group tag
      (buffer-local b 'companion-of)))

(define (buffer-extra-groups b)
  (let ((groups (buffer-local b 'groups)))
    (cond ((pair? groups) groups)
          ((string? groups) (list groups))
          (else '()))))

(define (buffer-groups b)
  (let ((primary (buffer-group b)))
    (fold (lambda (acc g)
            (if (or (not g) (member g acc)) acc (append acc (list g))))
          (if primary (list primary) '())
          (buffer-extra-groups b))))

(define (buffer-in-group? b g)
  (if (and g (member g (buffer-groups b))) #t #f))

(define (buffer-move-to-group! b g)
  (buffer-set-local! b 'group g)
  (buffer-set-local! b 'groups #f)
  (buffer-set-local! b 'companion-of #f))

(define (buffer-add-group! b g)
  (unless (buffer-in-group? b g)
    (let ((primary (buffer-group b)))
      (if primary
          (buffer-set-local! b 'groups
            (append (buffer-extra-groups b) (list g)))
          (buffer-set-local! b 'group g)))))

(define (buffer-remove-group! b g)
  (let ((primary (buffer-group b))
        (extra (buffer-extra-groups b)))
    (if (equal? primary g)
        (begin
          (buffer-set-local! b 'companion-of #f)
          (if (pair? extra)
              (begin
                (buffer-set-local! b 'group (car extra))
                (buffer-set-local! b 'groups
                  (if (pair? (cdr extra)) (cdr extra) #f)))
              (buffer-move-to-group! b #f)))
        (let ((kept (remove (lambda (x) (equal? x g)) extra)))
          (buffer-set-local! b 'groups (if (pair? kept) kept #f))))))

(define (buffer-replace-group! b old new)
  (when (buffer-in-group? b old)
    (let ((was-primary? (equal? (buffer-group b) old)))
      (buffer-remove-group! b old)
      (if was-primary?
          (let ((current-primary (buffer-group b)))
            (buffer-set-local! b 'group new)
            (when current-primary
              (buffer-set-local! b 'groups
                (cons current-primary (buffer-extra-groups b)))))
          (buffer-add-group! b new)))))

(define (buffer-context-group b)
  (let ((current (frame-local 'current-group)))
    (if (buffer-in-group? b current) current (buffer-group b))))

;; the group column in a buffer prompt. A group founded by a file
;; buffer carries the full path as its name; show the last segment.
(define (group-label g)
  (if g
      (car (reverse (string-split g "/")))
      ""))

;; a group's metadata lives on its chat buffer: the chat is the group's
;; durable surface, so 'group-meta rides chat-identity-locals and
;; survives reset, restart, and save
;; the buffer that holds a group's durable state ('group-meta,
;; 'group-layout): its chat. A chat made by group-chat but never shown
;; has no mode yet, so fall back to the chat buffer by name.
(define (group-holder g)
  (let ((chats (filter (lambda (b)
                         (and (chat-buffer? b) (equal? (buffer-group b) g)))
                       (group-buffers-mru g))))
    (let ((holders (filter (lambda (b) (buffer-local b 'group-state-holder)) chats)))
      (cond ((pair? holders) (car holders))
            ((pair? chats) (car chats))
            (else
              (let ((buf (group-chat-name g)))
                (and (buffer-exists? buf) buf)))))))

(define (group-state-holder! g)
  (let ((holder (group-holder g)))
    (if holder
        (begin (buffer-set-local! holder 'group-state-holder #t) holder)
        (let ((chat (group-chat g)))
          (buffer-set-local! chat 'group-state-holder #t)
          chat))))

(define (group-meta g)
  (let ((h (group-holder g))) (and h (buffer-local h 'group-meta))))

(define (group-meta-set! g text)
  (buffer-set-local! (group-state-holder! g) 'group-meta text))

;; a group's window arrangement rides its chat too, as one opaque
;; window-tree value: capture on leave, restore on switch
(define (group-layout g)
  (let ((h (group-holder g))) (and h (buffer-local h 'group-layout))))

(define (group-layout-save! g)
  (buffer-set-local! (group-state-holder! g) 'group-layout (window-tree)))

;; switch the frame to a group: save the layout you leave, then bring
;; the group's saved layout back exactly as you left it. A group with
;; no saved layout opens its most recent member full-frame.
;; a group that never saved a layout still ARRIVES arranged: the most
;; recent work buffer on the left, and on the right the group chat
;; (companion noise "loud") or the next work buffer. One member alone
;; fills the frame.
(define (group-default-layout! g)
  (let* ((docs (group-docs g))
         (main (if (pair? docs) (car docs) (group-chat g)))
         (loud (equal? (group-noise g) "loud"))
         (side (cond ((and loud (pair? docs)) (group-chat g))
                     ((and (pair? docs) (pair? (cdr docs))) (car (cdr docs)))
                     (else #f))))
    (delete-other-windows!)
    (switch-to-buffer! main)
    (when side
      (split-window! 'h 0.6)
      (other-window!)
      (switch-to-buffer! side)
      (when loud (set-mode! "chat-mode"))
      (let ((w (window-showing main)))
        (when w (select-window! w))))))

;; a restored window whose buffer is an empty, unmodified, pathlike
;; shell — and whose file exists — re-reads from disk. The layout
;; recreated the NAME; the content lives in the file.
(define (group-restore-files! g)
  (let ((back (active-window)))
    (for-each
      (lambda (w)
        (let ((b (car (cdr w))))
          (when (and (string-prefix? "/" b)
                     (file-exists? b)
                     (not (file-directory? b)))
            ;; a member killed since the snapshot came back as an
            ;; empty shell: re-read its file, and its membership with it
            (when (and (= (buffer-size b) 0)
                       (not (buffer-modified? b)))
              (select-window! (car w))
              (buffer-kill! b)
              (visit b)
              (buffer-set-local! b 'group g)))))
      (window-list))
    (when (window-exists? back) (select-window! back))))

(define (group-restore-prune! g)
  (for-each
    (lambda (w)
      (let ((b (car (cdr w))))
        (when (and (buffer-local b 'transient)
                   (not (buffer-in-group? b g))
                   (> (length (window-list)) 1))
          (delete-window-id! (car w)))))
    (window-list)))

(define (switch-to-group! g)
  ;; one winner entry per switch: the arrangement you leave, not the
  ;; intermediate steps of building the next one
  (winner-save!)
  (set! *winner-inhibit* #t)
  (let ((from (frame-group)))
    (when (and from (not (equal? from g)))
      (group-layout-save-if-shown! from)))
  (set-frame-local! 'current-group g)
  (let ((saved (group-layout g)))
    (if saved
        (begin
          (window-tree-set! saved)
          ;; a layout stores NAMES: a member killed since the snapshot
          ;; comes back as an empty shell with no locals — re-read its
          ;; file and restore its membership FIRST, or the validation
          ;; below sees a group with nothing on screen
          (group-restore-files! g)
          ;; an old snapshot may have memorialized a transient surface
          ;; (the board, a listing) that is not a member: drop it.
          ;; Beyond that the layout restores AS SAVED — it is the
          ;; group's own record, and second-guessing it against
          ;; membership tags kept stomping real arrangements. The
          ;; capture rule (only from inside) keeps new snapshots sane.
          (group-restore-prune! g))
        (group-default-layout! g)))
  (set! *winner-inhibit* #f)
  ;; the switch itself is a history entry: the group joins the one MRU
  ;; stream, above the member buffers the restore just bumped
  (mru-note-group! g)
  (windows-shown-catchup!)
  (message (string-append "switched to group " (group-label g))))

;; the group the FRAME stands in. Switching sets it; a detour through
;; an ungrouped buffer (scratch, help) does not lose it. The buffer's
;; own group is the fallback for a frame that never switched.
(define (frame-group)
  ;; the buffer you are IN is the truth when it has a group; the
  ;; frame-local covers detours through ungrouped buffers. The old
  ;; precedence went stale: drifting into a group by plain switches
  ;; left the frame naming some earlier group, so leaving snapshotted
  ;; the wrong one and "the last arrangement" was never saved.
  (let ((current (frame-local 'current-group))
        (buf (current-buffer)))
    (cond ((buffer-in-group? buf current) current)
          ((buffer-group buf) (buffer-group buf))
          (else current))))

;; a layout snapshot is only true when the group is on screen: saving
;; a scratch detour AS the group's arrangement would overwrite the
;; real one
(define (group-on-screen? g)
  (let loop ((ws (window-list)))
    (cond ((null? ws) #f)
          ((buffer-in-group? (car (cdr (car ws))) g) #t)
          (else (loop (cdr ws))))))

;; a group's layout is captured only from INSIDE the group: the
;; buffer you act from is a member. What happens on any other surface
;; — the board, a listing, a detour — never rewrites it, so the last
;; arrangement made IN the group is the one that comes back.
(define (group-layout-save-if-shown! g)
  (when (and g (buffer-in-group? (current-buffer) g))
    (group-layout-save! g)))

;; a group is UNCOVERED when no window shows a transient surface from
;; outside it — a board, a listing. Its own members are transient too
;; (a mail view, a dired listing), and they are part of the group's
;; arrangement, not a cover on it.
(define (group-uncovered? g)
  (let loop ((ws (window-list)))
    (cond ((null? ws) #t)
          ((let ((b (car (cdr (car ws)))))
             (and (buffer-local b 'transient)
                  (not (buffer-in-group? b g))))
           #f)
          (else (loop (cdr ws))))))

;; NAME is about to take a pane. When it comes from outside the group
;; on screen, the arrangement it covers goes on record first. Only an
;; uncovered arrangement counts: a second board must not overwrite the
;; snapshot the first one earned. A group with no holder yet gets no
;; snapshot — displaying a buffer must not create a chat.
(define (group-layout-save-before-cover! name)
  (let ((g (frame-group)))
    (when (and g
               (not (buffer-in-group? name g))
               (group-holder g)
               (group-on-screen? g)
               (group-uncovered? g))
      (group-layout-save! g))))

;; move what is on screen to one group: every window's buffer joins,
;; the current layout replaces the destination's saved layout, and the
;; group chat holds the durable state. A new name founds the group.
(define (group-visible-buffers)
  (dedupe-names
    (filter (lambda (b) (and b (not (string-prefix? " " b))))
            (map (lambda (w) (car (cdr w))) (window-list)))))

(define (group-move-visible! name)
  (let* ((found? (null? (group-buffers name)))
         (buffers (group-visible-buffers)))
    (for-each (lambda (b) (buffer-move-to-group! b name)) buffers)
    (group-layout-save! name)
    (set-frame-local! 'current-group name)
    (message
      (if found?
          (string-append "founded group " name " from "
                         (number->string (length buffers)) " buffers")
          (string-append "moved " (number->string (length buffers))
                         " visible buffers to group " name)))))

(define (group-add-visible! name)
  (let* ((found? (null? (group-buffers name)))
         (buffers (group-visible-buffers)))
    (for-each (lambda (b) (buffer-add-group! b name)) buffers)
    ;; A new group uses the current arrangement as its initial layout.
    ;; Adding to an existing group must not replace its remembered layout.
    (when found? (group-layout-save! name))
    (message (string-append "added " (number->string (length buffers))
                            " visible buffers to group " name))))

;; The switcher uses this name when a typed query has no match.
(define (group-found-from-windows! name)
  (group-move-visible! name))

;; the LLM reads the member list and writes one sentence of metadata
(define (group-describe! g)
  (message "LLM writing group description...")
  (llm (string-append
         "These buffers form one working group in an editor.\n"
         "Write one sentence that says what the group is for.\n"
         "Return ONLY the sentence.\n\n"
         (string-join (group-buffers-mru g) "\n"))
       (lambda (text)
         (group-meta-set! g (string-trim text))
         (when (buffer-exists? *groups-buffer*)
           (list-refresh! *groups-buffer*))
         (message (string-append (group-label g) ": " (string-trim text))))))

;; C-c d from a grouped buffer
(define-command "group-describe"
  "Ask the LLM to write this group's description"
  (lambda ()
    (let ((g (buffer-group (current-buffer))))
      (if g (group-describe! g) (message "Not in a group")))))

;;; --- the groups board: C-x G --------------------------------------------------
;;; The command-palette design's second panel as a list: one row per group —
;;; members, companion noise, metadata. RET switches (layout and all),
;;; d asks the LLM to describe, n cycles noise, x dissolves.

(define *groups-buffer* "*groups*")

;; companion noise policy, an identity local on the group chat:
;; "off" (no companion window), "quiet" (notify on finish), "loud"
;; (lives in a window). Display rules read it; the board sets it.
(define (group-noise g)
  (let ((h (group-holder g)))
    (or (and h (buffer-local h 'group-noise)) "quiet")))

(define (group-noise-set! g v)
  (buffer-set-local! (group-state-holder! g) 'group-noise v))

(define (group-line buf g)
  (let ((members (group-buffers-mru g))
        (m (group-meta g)))
    (string-append
      (string-pad-right (group-label g) 22)
      (string-pad-right (string-append (number->string (length members)) " buffers") 12)
      (string-pad-right (group-noise g) 8)
      (string-join (map buffer-short-label (take-n members 4)) " · ")
      (if m (string-append "  —  " m) ""))))

;; a group with a modified member has unsaved work in it
(define (group-dirty? g)
  (pair? (filter buffer-modified? (group-buffers g))))

(define (group-noise-face n)
  (cond ((equal? n "loud") "warn")
        ((equal? n "off") "faint")
        (else "dim")))

;; the members read as the group's contents, then what the group is for
(define (group-cells buf g)
  (let ((members (group-buffers-mru g)))
    (list (if (group-dirty? g) (list "●" "warn") "")
          (list (group-label g) "accent")
          (list (number->string (length members)) "dim")
          (list (group-noise g) (group-noise-face (group-noise g)))
          (list (string-append
                  (string-join (map buffer-short-label (take-n members 3)) " · ")
                  (let ((m (group-meta g)))
                    (if m (string-append "  —  " m) "")))
                "faint"))))

(define (groups-meta buf)
  (let* ((rows (list-entries buf))
         (n (length rows))
         (bufs (fold (lambda (acc g) (+ acc (length (group-buffers g)))) 0 rows))
         (dirty (length (filter group-dirty? rows))))
    (string-append (number->string n) (if (= n 1) " group" " groups")
                   " · " (number->string bufs) " buffers"
                   " · " (number->string dirty) " modified"
                   " · most recent first")))

(define (groups--current)
  (let ((g (list-current (current-buffer))))
    (or g (begin (message "no group on this line") #f))))

;; a verb here acts on every marked group, or on the row at point when
;; nothing is marked — the rule every list follows. The marks go when the
;; verb has run, because a mark on a group that no longer exists outlives
;; every refresh.
(define (groups--act! word verb)
  (let* ((buf (current-buffer))
         (targets (list-targets buf)))
    (if (null? targets)
        (message "no group on this line")
        (begin (for-each verb targets)
               (for-each (lambda (g) (list-unmark-key! buf g)) targets)
               (list-refresh! buf)
               (message (string-append word " " (number->string (length targets))
                                       " " (list-noun buf (length targets))))))))

(define-command "group-describe-at-point" "LLM-describe the marked groups"
  (lambda () (groups--act! "describing" group-describe!)))

(define-command "group-noise-cycle" "Cycle the companion noise of the marked groups"
  (lambda ()
    (groups--act! "cycled"
      (lambda (g)
        (let ((cur (group-noise g)))
          (group-noise-set! g (cond ((equal? cur "off") "quiet")
                                    ((equal? cur "quiet") "loud")
                                    (else "off"))))))))

(define-command "group-dissolve" "Remove the group tag from every member"
  (lambda ()
    (groups--act! "dissolved"
      (lambda (g)
        (for-each (lambda (b) (buffer-remove-group! b g))
                  (group-buffers g))))))

;; kill a whole context: every member buffer dies, except a modified
;; file buffer — unsaved work never dies silently
(define (group-kill! g)
  (let* ((members (group-buffers g))
         (shared (filter (lambda (b) (> (length (buffer-groups b)) 1)) members))
         (exclusive (remove (lambda (b) (member b shared)) members))
         (kept (filter (lambda (b) (and (buffer-path b) (buffer-modified? b)))
                       exclusive)))
    (for-each (lambda (b) (buffer-remove-group! b g)) shared)
    (for-each (lambda (b) (unless (member b kept) (buffer-kill! b)))
              exclusive)
    (when (equal? (frame-local 'current-group) g)
      (set-frame-local! 'current-group #f))
    (message (string-append "killed group " (group-label g)
               (if (pair? kept)
                   (string-append " — kept " (number->string (length kept))
                                  " modified")
                   "")
               (if (pair? shared)
                   (string-append " — preserved " (number->string (length shared))
                                  " shared")
                   "")))))

(define-command "group-kill" "Kill every buffer in the current group"
  (lambda ()
    (let ((g (frame-group)))
      (if g (group-kill! g) (message "Not in a group")))))

;; rename a context: every member retags, and the durable state
;; follows. The chat buffer keeps its NAME (there is no buffer
;; rename); membership is by role, so a live chat stays the group's.
;; An unshown chat is found by name, so its identity is copied onto
;; the new name's chat instead.
(define (group-rename! old new)
  (cond
    ((equal? (string-trim new) "") (message "Group needs a name"))
    ((pair? (group-buffers new))
     (message (string-append "Group " new " already exists")))
    ((null? (group-buffers old))
     (message (string-append "No group " old)))
    (else
      (let ((holder (group-holder old)))
        (for-each (lambda (b) (buffer-replace-group! b old new))
                  (group-buffers old))
        (when (and holder (not (chat-buffer? holder)))
          (let ((meta (buffer-local holder 'group-meta))
                (layout (buffer-local holder 'group-layout))
                (noise (buffer-local holder 'group-noise)))
            (buffer-remove-group! holder old)
            (let ((chat (group-chat new)))
              (when meta (buffer-set-local! chat 'group-meta meta))
              (when layout (buffer-set-local! chat 'group-layout layout))
              (when noise (buffer-set-local! chat 'group-noise noise)))))
        (when (equal? (frame-local 'current-group) old)
          (set-frame-local! 'current-group new))
        (message (string-append "renamed group " (group-label old) " to " new))))))

(define-command "group-rename" "Rename the current group"
  (lambda ()
    (let ((g (frame-group)))
      (if (not g)
          (message "Not in a group")
          (minibuffer-read (string-append "Rename " (group-label g) " to: ") '()
            (lambda (new) (group-rename! g (string-trim new))))))))

(define-command "group-rename-at-point" "Rename the group at point"
  (lambda ()
    (let ((g (groups--current)))
      (when g
        (minibuffer-read (string-append "Rename " (group-label g) " to: ") '()
          (lambda (new)
            (group-rename! g (string-trim new))
            (when (buffer-exists? *groups-buffer*)
              (list-refresh! *groups-buffer*))))))))

(define-command "group-kill-at-point" "Kill every buffer of the marked groups"
  (lambda () (groups--act! "killed" group-kill!)))

(define-command "groups-refresh" "Refresh the groups board"
  (lambda () (list-refresh! *groups-buffer*)))

(define-command "groups" "The groups board: switch, describe, set noise"
  (lambda () (list-mode-show! "groups-mode")))

(define-list-mode! "groups-mode"
  (list
    'doc (string-append
           "Every buffer group as a table: members, companion noise, "
           "metadata. RET switches to the group and restores its layout; "
           "d writes its description with the LLM; n cycles noise; "
           "x dissolves; K kills the members. `m` marks a group, `*` marks "
           "every one, and the verbs act on the marked groups — or on the "
           "row at point when nothing is marked. `/` narrows as you type "
           "and `\\` widens by one.")
    'buffer *groups-buffer*
    'rows (lambda (buf) (list-keep buf (group-names)))
    'columns (lambda (buf)
               (list (list "" 1)
                     (list "group" 24)
                     (list "buffers" 7 'right)
                     (list "noise" 6)
                     (list "members" #f)))
    'cells group-cells
    'title (lambda (buf) "Groups")
    'meta groups-meta
    'total (lambda (buf) (length (group-names)))
    'footer (lambda (buf)
              '(("RET" "switch") ("m" "mark") ("*" "all") ("r" "rename")
                ("d" "describe") ("n" "noise") ("x" "dissolve")
                ("K" "kill buffers") ("/" "filter") ("g" "refresh")
                ("q" "quit")))
    'key (lambda (buf g) g)
    'noun "group"
    'keys '(("RET" "group-switch") ("r" "group-rename-at-point")
            ("d" "group-describe-at-point")
            ("n" "group-noise-cycle") ("x" "group-dissolve")
            ("K" "group-kill-at-point")
            ("g" "groups-refresh") ("q" "quit-window"))))

(define (group-buffers g)
  (filter (lambda (b) (buffer-in-group? b g)) (buffer-list)))

;; Members in MRU order; buffers never visited this session trail.
;; A group is a set, so the list dedupes by name.
(define (group-buffers-mru g)
  (let ((mru (filter (lambda (b) (buffer-in-group? b g))
                     (buffer-list-mru))))
    (dedupe-names
      (append mru (remove (lambda (b) (member b mru)) (group-buffers g))))))

(define (group-names)
  (fold (lambda (acc b)
          (fold (lambda (out g)
                  (if (member g out) out (append out (list g))))
                acc (buffer-groups b)))
        '() (append (buffer-list-mru) (buffer-list))))

;; the group's chat counts by NAME as well as by mode: a chat made by
;; group-chat but never shown has no mode yet, and it is still not a
;; work buffer
(define (group-docs g)
  (remove (lambda (b) (or (chat-buffer? b) (equal? b (group-chat-name g))))
          (group-buffers-mru g)))

;; a buffer with no group founds one named after itself
(define (group-ensure! b)
  (or (buffer-group b)
      (begin (buffer-set-local! b 'group b) b)))

;; a fresh group chat is a rich surface from birth: help on top (a "meta"
;; card in the agent design), then the >>> you: input region
(define (group-chat-init! buf g)
  (chat-surface-init! buf (string-append "companion · " g)
    (string-append
      "RET sends · C-c w hops to the document · "
      "C-c m model · C-c C-v plain view\n"
      "it reads the live buffers before it speaks, "
      "and edits them in place when you ask\n")))

(define (group-chat-name g) (string-append "*chat:" g "*"))

;; the group's chat = its most recently used chat-mode member; created on
;; demand already tagged, so a killed chat is simply remade next time
(define (group-chat g)
  (let ((chats (filter (lambda (b)
                         (and (chat-buffer? b) (equal? (buffer-group b) g)))
                       (group-buffers-mru g))))
    (if (pair? chats)
        (car chats)
        (let ((buf (group-chat-name g)))
          (unless (buffer-exists? buf)
            (buffer-create buf)
            (group-chat-init! buf g))
          (buffer-set-local! buf 'group g)
          (buffer-set-local! buf 'group-state-holder #t)
          ;; Optional packages may attach durable group identity (for
          ;; example, a worktree workspace) to the newly created chat.
          (when (boundp (quote workspace-chat-inherit!))
            (workspace-chat-inherit! buf g))
          buf))))

;; Ensure the two-pane layout and select one exact chat buffer.
(define (group-chat-buffer-show! buf)
  (let ((w (window-showing buf)))
    (if w
        (select-window! w)
        (begin
          (delete-other-windows!)
          (split-window! 'h 0.6)
          (other-window!)
          (switch-to-buffer! buf))))
  (set-mode! "chat-mode")
  (end-of-buffer!)
  buf)

;; Open the group's most recent chat.
(define (group-chat-show! g)
  (group-chat-buffer-show! (group-chat g)))

(define (group-chat-new-name g)
  (let loop ((n 2))
    (let ((name (string-append "*chat:" g ":" (number->string n) "*")))
      (if (buffer-known? name) (loop (+ n 1)) name))))

(define (group-chat-new! g)
  ;; Pin the existing chat as the durable state holder before the new chat
  ;; becomes most recent.
  (group-state-holder! g)
  (let ((buf (group-chat-new-name g)))
    (buffer-create buf)
    (group-chat-init! buf g)
    (buffer-move-to-group! buf g)
    (when (boundp (quote workspace-chat-inherit!))
      (workspace-chat-inherit! buf g))
    (group-chat-buffer-show! buf)
    (message (string-append "new chat in group " g))
    buf))

;; ask the group without leaving the current buffer: the minibuffer prompt
;; becomes a group-chat turn, point stays put, the reply lands on the right
(define (group-ask! g)
  (minibuffer-read (string-append "Ask " g ": ") (history-items 'companion-ask)
    (lambda (prompt)
      (history-push! 'companion-ask prompt)
      (let ((back (active-window)))
        (group-chat-show! g)
        (insert! prompt)
        (run-command "agent-send")
        (when (window-exists? back)
          (select-window! back))))))

;; the group a joining buffer gets by default: the group the frame
;; stands in, else the most recent group in history. The buffer's own
;; group is never the default — joining it is a no-op.
(define (group-join-default buf)
  (let ((own (buffer-groups buf))
        (fg (frame-local 'current-group)))
    (if (and fg (not (member fg own)))
        fg
        (let loop ((rows (mru-list)))
          (cond ((null? rows) #f)
                ((and (equal? (car (car rows)) "group")
                      (not (member (car (cdr (car rows))) own)))
                 (car (cdr (car rows))))
                (else (loop (cdr rows))))))))

;; C-c g : join a group. RET takes the default — so a stray buffer
;; moves into the group you last stood in with one press. A typed
;; name joins that group, or founds it.
(define-command "group-join" "Join a group; RET takes the last visited group; a new name founds one"
  (lambda ()
    (let* ((buf (current-buffer))
           (default (group-join-default buf))
           (names (filter (lambda (g) (not (equal? g default))) (group-names))))
      (minibuffer-read
        (if default
            (string-append "Join group (default " (group-label default) "): ")
            "Join group: ")
        (if default
            (cons (list default "last visited") names)
            names)
        (lambda (input)
          (let ((g (if (equal? (string-trim input) "")
                       (or default "")
                       input)))
            (cond
              ((equal? g "") (message "Group needs a name"))
              ;; a group is a set — joining twice is a no-op that says so
              ((buffer-in-group? buf g)
               (message (string-append buf " is already in " (group-label g))))
              (else
                (buffer-move-to-group! buf g)
                (message (string-append buf " joined group " (group-label g)))))))))))

(define-command "group-remove" "Remove the current buffer from its group"
  (lambda ()
    (let* ((buf (current-buffer)) (g (buffer-context-group buf)))
      (if g
          (begin
            (buffer-remove-group! buf g)
            (message (string-append buf " left group " g)))
          (message "Not in a group")))))

(define-command "group-list" "List the current buffer's group members"
  (lambda ()
    (let ((g (buffer-context-group (current-buffer))))
      (if g
          (message (string-append g ": "
                     (string-join (group-buffers-mru g) " · ")
                     (let ((m (group-meta g)))
                       (if m (string-append " — " m) ""))))
          (message "Not in a group")))))

(define-command "group-switch-current"
  "Switch to this buffer's group and restore its layout"
  (lambda ()
    (let ((g (buffer-context-group (current-buffer))))
      (if g
          (switch-to-group! g)
          (message "Not in a group")))))

(define-command "group-switch" "Switch to a selected group and restore its layout"
  (lambda ()
    (if (equal? (list-mode-of (current-buffer)) "groups-mode")
        (let ((g (groups--current)))
          (when g (switch-to-group! g)))
        (let ((names (group-names)))
          (if (null? names)
              (message "No groups")
              (minibuffer-read "Switch to group: " names
                (lambda (input)
                  (let ((name (string-trim input)))
                    (if (member name names)
                        (switch-to-group! name)
                        (message (string-append "No group " name)))))))))))

(define-command "group-move"
  "Move the current buffer to a selected group, or found a new group"
  (lambda ()
    (let ((buf (current-buffer)))
      (minibuffer-read "Move current buffer to group: " (group-names)
        (lambda (input)
          (let ((name (string-trim input)))
            (if (equal? name "")
                (message "Group needs a name")
                (begin
                  (buffer-move-to-group! buf name)
                  (message (string-append buf " moved to group " name))))))))))

(define-command "group-add"
  "Add a selected group to the current buffer, or found a new group"
  (lambda ()
    (let ((buf (current-buffer)))
      (minibuffer-read "Add group to current buffer: " (group-names)
        (lambda (input)
          (let ((name (string-trim input)))
            (cond
              ((equal? name "") (message "Group needs a name"))
              ((buffer-in-group? buf name)
               (message (string-append buf " is already in group " name)))
              (else
                (buffer-add-group! buf name)
                (message (string-append "added group " name " to " buf))))))))))

(define-command "group-find-file"
  "Visit a file and add the active group without removing other memberships"
  (lambda ()
    (let ((g (frame-group)))
      (if g
          (read-file-name "Find file in group: "
            (lambda (path) (visit-in-group path g)))
          (message "Not in a group")))))

(define-command "group-move-visible"
  "Move visible buffers to a selected group, or found a new group"
  (lambda ()
    (minibuffer-read "Move visible buffers to group: " (group-names)
      (lambda (input)
        (let ((name (string-trim input)))
          (if (equal? name "")
              (message "Group needs a name")
              (group-move-visible! name)))))))

(define-command "group-add-visible"
  "Add a selected group to visible buffers, or found a new group"
  (lambda ()
    (minibuffer-read "Add group to visible buffers: " (group-names)
      (lambda (input)
        (let ((name (string-trim input)))
          (if (equal? name "")
              (message "Group needs a name")
              (group-add-visible! name)))))))

;; make an existing conversation a group's chat: pick a buffer, join its
;; group (founding one named after it if it has none)
(define-command "chat-adopt" "Make this chat the companion of a chosen buffer"
  (lambda ()
    (let ((chat (current-buffer)))
      (minibuffer-read "Companion for buffer: "
        (filter (lambda (b) (not (equal? b chat))) (buffer-list-mru))
        (lambda (doc)
          (if (not (buffer-exists? doc))
              (message (string-append "No buffer " doc))
              (let ((g (group-ensure! doc)))
                ;; joining the group is the whole act; the layout is
                ;; group-chat-show!'s job, and it is the only place that
                ;; knows what a chat's two panes look like
                (buffer-set-local! chat 'group g)
                ;; the document takes this window first, so the layout
                ;; builder lands the chat beside it rather than on it
                (switch-to-buffer! doc)
                (group-chat-show! g)
                (message (string-append chat " now accompanies " g)))))))))

;; C-c w toggles sides: in a work buffer it opens (or refocuses) the group
;; chat, grouping the buffer by itself first if needed; in the chat it hops
;; to the group's most recent work buffer; in a groupless chat it adopts
(define-command "chat-companion" "Toggle between a work buffer and its group chat"
  (lambda ()
    (let* ((cur (current-buffer))
           (g (buffer-context-group cur)))
      (cond ((and (chat-buffer? cur) g)
             (let ((docs (group-docs g)))
               (if (null? docs)
                   (message (string-append "Group " g " has no work buffers"))
                   (let ((w (window-showing (car docs))))
                     (if w
                         (select-window! w)
                         (switch-to-buffer! (car docs)))))))
            ((chat-buffer? cur) (run-command "chat-adopt"))
            (else (group-chat-show! (group-ensure! cur)))))))

;; C-c RET in a work buffer: talk to the group chat without leaving it.
;; (In a chat buffer it just sends, exactly like RET.)
(define-command "chat-companion-ask" "Ask the group chat without leaving this buffer"
  (lambda ()
    (let ((cur (current-buffer)))
      (if (chat-buffer? cur)
          (run-command "agent-send")
          (group-ask! (group-ensure! cur))))))


(mode-icon! "groups-mode" "")

(global-set-key "C-c g" "group-join")
(global-set-key "C-c G" "group-switch-current")
(global-set-key "C-c N" "group-move-visible")
(global-set-key "C-c A" "group-add-visible")
(global-set-key "C-c d" "group-describe")
(global-set-key "C-x G" "groups")

;; C-x C-g is the group convenience map.
(global-set-key "C-x C-g s" "switch-groups")
(global-set-key "C-x C-g g" "group-switch")
(global-set-key "C-x C-g f" "group-find-file")
(global-set-key "C-x C-g a" "group-add")
(global-set-key "C-x C-g m" "group-move")
(global-set-key "C-x C-g A" "group-add-visible")
(global-set-key "C-x C-g M" "group-move-visible")
(global-set-key "C-x C-g l" "group-list")

(public! 'buffer-group "(buffer-group NAME) -> the buffer's group tag or #f")
(public! 'buffer-groups "(buffer-groups NAME) -> all group memberships, primary first")
(public! 'buffer-in-group? "(buffer-in-group? NAME GROUP) -> whether NAME belongs to GROUP")
(public! 'group-buffers "(group-buffers G) -> names of the buffers tagged 'group G")
(public! 'group-chat "(group-chat G) — find or create G's chat buffer; returns its name")
(public! 'group-chat-show! "(group-chat-show! G) — open/focus G's chat pane; returns its name")

(catalog-meta! 'command "group-describe" 'domain 'buffers 'effects '(write external spend))
(catalog-meta! 'command "group-describe-at-point" 'domain 'buffers 'effects '(write external spend))
(catalog-meta! 'command "group-kill" 'domain 'buffers 'effects '(destroy))
(catalog-meta! 'command "group-kill-at-point" 'domain 'buffers 'effects '(destroy))
(catalog-meta! 'command "groups" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "buffer-group" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "buffer-groups" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "buffer-in-group?" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "group-buffers" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "group-chat" 'domain 'buffers 'effects '(write))
(catalog-meta! 'function "group-chat-show!" 'domain 'buffers 'effects '(write))

(message "groups.scm loaded")
