;;; layouts.scm — window layout policy.
;;;
;;; The frame has five layouts and nothing else: single, two-pane, halves,
;;; columns and rows. Each one holds a fixed number of panes and shows a
;;; run of the frame's buffer strip, so each one goes on for ever in both
;;; directions. The tiling mechanics remain in window.scm; this package
;;; owns only the policy and the overview.

(category! 'windows)
(domain! 'windows)
(effects! '(write))

(defgroup 'windows "Window layout and responsive popup policy.")

;; peek! and the ripgrep preview (editor.scm) read this one.
(defcustom 'peek-max-file-size 1048576
  "The largest file a look opens. A peek or a ripgrep preview of a bigger file shows nothing and says the size; RET still opens it. 0 removes the cap."
  'group 'windows 'type 'number)

;; visit and visit-quietly (editor.scm) read this one.
(defcustom 'large-file-warning-threshold 10485760
  "The largest file a visit opens without asking (Emacs large-file-warning-threshold). A visit of a bigger file refuses and says the size; M-x find-file asks, and a yes opens it for this session only. 0 removes the cap."
  'group 'files 'type 'number)

;; The display-buffer chain (editor.scm) reads these. They are plain
;; defines there, because editor.scm loads before custom.scm.
(defcustom 'split-height-threshold 80
  "A window with this many rows splits below for a pop-up window (Emacs split-height-threshold)."
  'group 'windows 'type 'number)

(defcustom 'split-width-threshold 160
  "A window with this many columns splits beside for a pop-up window (Emacs split-width-threshold)."
  'group 'windows 'type 'number)

(defcustom 'next-screen-context-lines 2
  "Rows a page scroll keeps from the screen before it. A page overlaps by this much and never leaves a gap (Emacs next-screen-context-lines)."
  'group 'windows 'type 'number)

;; The two-pane layout reads this one.
(defcustom 'window-layout-main-ratio 0.62
  "The first pane's share of the frame in the two-pane layout: a fraction between 0.3 and 0.9."
  'group 'windows 'type 'number)

;; The two-chat layout reads this one.
(defcustom 'window-layout-chat-ratio 0.25
  "The chat pane's share of the frame in the two-chat layout, such as 0.25. The other two panes share the rest equally."
  'group 'windows 'type 'number)

(defcustom '*display-buffer-base-action* '()
  "Display actions tried after the rule for a buffer and before the fallback: a list of pop-up-window, reuse-window, use-some-window, same-window."
  'group 'windows 'type 'list)

(defcustom '*display-buffer-fallback-action*
  '(reuse-window mode-window pop-up-window use-some-window same-window)
  "Display actions tried last for a buffer with no rule."
  'group 'windows 'type 'list)

;;; --- transient frames -------------------------------------------------------
;;; A transient frame mode borrows the frame and gives it back. It records
;;; the arrangement it found on the way in, and leaving puts that
;;; arrangement back EXACTLY: the same panes, the same buffers in them,
;;; and the group the frame stood in.
;;;
;;; This is not window history and it is not quit-restore. Those answer
;;; "what did this one window show before", one window at a time, and a
;;; mode that split, covered or retiled the frame cannot be undone one
;;; window at a time — the window it was invoked in came back holding
;;; whatever the history had, and the pane beside it was simply lost.
;;;
;;; A mode enters by NAME, so two can stand at once without reading each
;;; other's record. Entering twice does not re-record: what a mode gives
;;; back is the arrangement from before it took the frame, never one it
;;; made itself. A mode that stopped standing by some other road — its
;;; buffer was replaced, a layout was applied — abandons its record
;;; instead of restoring a tree of windows that no longer exist.

;; A record is an entry on the frame return stack, pushed for NAME.
(define (transient-frame-standing? name) (and (arrangement-for name) #t))

(define (transient-frame-enter! name)
  (and (not (transient-frame-standing? name)) (arrangement-push! name) #t))

(define (transient-frame-abandon! name)
  (arrangement-drop! (arrangement-for name))
  #f)

;; the mode is standing only while the buffer it took the frame for is on
;; screen. Arriving with a stale record re-arms: the arrangement to give
;; back is the one in front of you now.
(define (transient-frame-rearm! name buf)
  (when (and (transient-frame-standing? name)
             (not (and (string? buf) (buffer-known? buf) (window-showing buf))))
    (transient-frame-abandon! name))
  (transient-frame-enter! name))

(define (transient-frame-exit! name) (arrangement-pop! (arrangement-for name)))

(public! 'transient-frame-enter!
  "(transient-frame-enter! NAME) — record the frame's arrangement so NAME can give it back; #f when NAME already stands")
(public! 'transient-frame-exit!
  "(transient-frame-exit! NAME) — put back exactly the arrangement and group NAME found; #f when NAME never entered")
(public! 'transient-frame-standing?
  "(transient-frame-standing? NAME) — #t while NAME holds an arrangement to give back")
(public! 'transient-frame-rearm!
  "(transient-frame-rearm! NAME BUF) — enter, re-recording when NAME's record is stale because BUF is not on screen")
(public! 'transient-frame-abandon!
  "(transient-frame-abandon! NAME) — drop NAME's record without restoring anything")

;;; --- tile-all: the overview -------------------------------------------------;;; --- tile-all: the overview -------------------------------------------------
;;; tile-all is the context overview. It puts the current group or project
;;; on the frame in three columns and locks it. The arrows select a tile,
;;; and an arrow at the edge scrolls the columns along the group, so the
;;; overview reaches every member. Keys select a tile and do not edit.
;;; SPC pops the selection out into a new group. The new group
;;; records the group the frame was in as its parent, and group-dissolve
;;; merges the members back into that parent. q restores the layout and
;;; the group unchanged.

(define (overview--project-buffers root)
  (let ((members (project-buffers root))
        (mru (buffer-list-mru)))
    (append
      (filter (lambda (buf) (member buf members)) mru)
      (filter (lambda (buf) (not (member buf mru))) members))))

(define (overview-buffers)
  (let ((group (frame-group)))
    (cond
      (group
        (let ((members (group-buffers-mru group)))
          (if (pair? members) members (list (group-chat group)))))
      ((and (boundp (quote project-current)) (project-current))
        (overview--project-buffers (project-current)))
      (else '()))))

(define (overview-active?) (equal? (frame-local 'overview-active) #t))

(define (overview--short-name buf)
  (let loop ((parts (reverse (string-split buf "/"))))
    (cond ((null? parts) buf)
          ((equal? (car parts) "") (loop (cdr parts)))
          (else (car parts)))))

;; A pop-out never prompts. The group takes the buffer's short name, made
;; unique with a counter, and group-rename can improve it later.
(define (overview--fresh-group-name base)
  (let loop ((n 1))
    (let ((name (if (= n 1) base
                    (string-append base " " (number->string n)))))
      (if (group-record-by-name name) (loop (+ n 1)) name))))

(define (overview--bindings)
  (list (list "<left>" "overview-left")
        (list "<right>" "overview-right")
        (list "<up>" "overview-up")
        (list "<down>" "overview-down")
        (list "m" "overview-mark")
        (list "SPC" "overview-pop-out")
        (list "RET" "overview-pop-out")
        (list "q" "overview-quit")
        (list "C-g" "overview-quit")
        (list "ESC" "overview-quit")))

(define (overview--hint!)
  (message "Overview: arrows select and scroll · m marks · SPC pops out into a new group · q quits"))

(define (overview-enter!)
  (if (overview-active?)
      (begin (overview--hint!) #f)
      (let* ((buffers (overview-buffers))
             (token (and (pair? buffers) (arrangement-push! 'overview))))
        (cond
          ((null? buffers)
           (message "Tile all is available only in a group or project") #f)
          ((not (tile-visible-windows! 'columns buffers)) (arrangement-drop! token) #f)
          (else
            (set-frame-local! 'overview-marked '())
            (set-frame-local! 'overview-active #t)
            (transient-keymap-install! (overview--bindings))
            (transient-show! #t)
            (overview--hint!)
            #t)))))

(define (overview--unlock!)
  (transient-show! #f)
  (transient-keymap-clear!)
  (set-frame-local! 'overview-active #f)
  (set-frame-local! 'overview-marked '()))

;; The restore puts back the saved window tree and the saved group. The
;; window walk during the overview can recalculate the frame's group, so
;; standing where you stood is part of the restore. Returns the saved
;; group, the parent of a pop-out.
(define (overview--restore!)
  (let* ((token (arrangement-for 'overview))
         (entry (and token (assoc token (arrangements)))))
    (and (arrangement-pop! token) (nth 3 entry))))

(define (overview-quit!)
  (when (overview-active?)
    (overview--unlock!)
    (overview--restore!)
    (message "")))

(define (overview--move! dir)
  (when (overview-active?) (focus-move! dir)))

(define (overview-mark!)
  (when (overview-active?)
    (let* ((buf (current-buffer))
           (marked (or (frame-local 'overview-marked) '()))
           (next (if (member buf marked)
                     (remove (lambda (b) (equal? b buf)) marked)
                     (append marked (list buf)))))
      (set-frame-local! 'overview-marked next)
      (message (if (null? next)
                   "No marks"
                   (string-append "Marked: "
                     (string-join (map overview--short-name next) " ")))))))

;; The pop-out takes the marked buffers, else the selected one. Each
;; buffer moves out of the parent group and into the new group; a
;; membership in any other group stays.
(define (overview-pop-out!)
  (when (overview-active?)
    (let* ((selected (current-buffer))
           (marked (or (frame-local 'overview-marked) '()))
           (buffers (filter buffer-known?
                            (if (pair? marked) marked (list selected)))))
      (if (null? buffers)
          (message "Nothing to pop out")
          (begin
            (overview--unlock!)
            (let* ((parent (overview--restore!))
                   (name (overview--fresh-group-name
                           (overview--short-name (car buffers))))
                   (id (group-record-create! name)))
              (if (not id)
                  (message (string-append "Could not create group " name))
                  (begin
                    (for-each
                      (lambda (buf)
                        (buffer-add-group! buf id)
                        (when (and parent (buffer-in-group? buf parent))
                          (buffer-remove-group! buf parent)))
                      buffers)
                    (when parent (group-parent-set! id parent))
                    (switch-to-group! id)))))))))

(define-command "tile-all"
  "Open the current group or project in locked columns"
  overview-enter!)
(define-command "overview-left" "Select the overview tile to the left"
  (lambda () (overview--move! 'left)))
(define-command "overview-right" "Select the overview tile to the right"
  (lambda () (overview--move! 'right)))
(define-command "overview-up" "Select the overview tile above"
  (lambda () (overview--move! 'up)))
(define-command "overview-down" "Select the overview tile below"
  (lambda () (overview--move! 'down)))
(define-command "overview-mark" "Mark or unmark the selected overview tile"
  overview-mark!)
(define-command "overview-pop-out"
  "Pop the marked buffers, else the selected one, out into a new group"
  overview-pop-out!)
(define-command "overview-quit" "Leave the overview and restore the layout"
  overview-quit!)

(for-each
  (lambda (name)
    (catalog-meta! 'command name 'domain 'windows 'effects '(write display)))
  '("tile-all" "overview-left" "overview-right" "overview-up" "overview-down"
    "overview-mark" "overview-pop-out" "overview-quit"))

(effects! '(read))
(public! 'overview-buffers
  "(overview-buffers) — current group members, else current project buffers")
(public! 'overview-active?
  "(overview-active?) — #t while this frame shows the locked overview")
(effects! '(write))
(public! 'overview-enter!
  "(overview-enter!) — tile the current group or project and lock the frame keys")

(domain! 'unknown)
(effects! '(unknown))

;; The active target is desktop state too: switching groups is not required
;; before saving. Window IDs and derived slot/count caches are runtime state.
(define (layout-targets-state)
  (map (lambda (frame) (list frame (frame-local-in frame 'layout-target))) (frame-list)))

(define (layout-targets-restore! saved)
  (for-each
    (lambda (frame)
      (let* ((entry (assoc frame saved))
             (target (and entry (cadr entry)))
             (old (assoc frame *frame-locals*))
             (locals (if old (cadr old) '()))
             (kept (filter (lambda (row)
                              (not (member (car row) '(layout-target layout-slots layout-target-count))))
                            locals)))
        (set! *frame-locals* (alist-put *frame-locals* frame (cons (list 'layout-target target) kept)))))
    (frame-list)))

(persist-global! 'layout-targets layout-targets-state layout-targets-restore!)

