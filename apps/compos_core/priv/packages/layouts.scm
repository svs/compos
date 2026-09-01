;;; layouts.scm — monitor-width-aware window policy.
;;;
;;; Width is measured in usable text columns, not pixels. That makes the same
;;; breakpoints respond naturally to monitor size, browser width, sidebars,
;;; font size, and display scaling. The tiling mechanics remain in editor.scm;
;;; this package owns only the policy that chooses among them.

(category! 'windows)
(domain! 'windows)
(effects! '(write))

(defgroup 'windows "Window layout and responsive popup policy.")

(defcustom 'window-layout-compact-cols 100
  "Below this usable frame width, layouts stack and popups use the bottom."
  'group 'windows 'type 'number)

(defcustom 'window-layout-wide-cols 200
  "At this usable frame width, three panes become columns and four become a grid."
  'group 'windows 'type 'number)

;; Deliberately pure: agents can inspect the choice before they change a frame.
(define (window-layout-for-width width pane-count)
  (cond
    ((< width window-layout-compact-cols) 'main-bottom)
    ((< width window-layout-wide-cols) 'main-right)
    ((<= pane-count 2) 'main-right)
    ((equal? pane-count 3) 'columns)
    (else 'grid)))

(define (tile-adaptive-windows! buffers)
  (let ((panes (layout--known-buffers buffers)))
    (tile-windows!
      (window-layout-for-width (frame-cols) (length panes))
      panes)))

(define (tile-visible-adaptive!)
  (let ((panes (layout-visible-buffers)))
    (if (< (length panes) 2)
        (begin (message "Open at least two work buffers") #f)
        (tile-adaptive-windows! panes))))

;;; --- tile-all: the overview -------------------------------------------------
;;; tile-all is the context overview. It tiles each buffer in the current
;;; group or project and locks the frame. Keys select a tile and do not edit.
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
  (message "Overview: arrows select · m marks · SPC pops out into a new group · q quits"))

(define (overview-enter!)
  (if (overview-active?)
      (begin (overview--hint!) #f)
      (let ((buffers (overview-buffers))
            (base (window-tree))
            (group (frame-group)))
        (cond
          ((null? buffers)
           (message "Tile all is available only in a group or project") #f)
          ((not (tile-windows! 'grid buffers)) #f)
          (else
            (set-frame-local! 'overview-return (list base group))
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
  (let ((return (frame-local 'overview-return)))
    (set-frame-local! 'overview-return #f)
    (if (not (pair? return))
        #f
        (let ((group (car (cdr return))))
          (window-tree-set! (car return))
          (unless (equal? (frame-group) group)
            (set-frame-local! 'current-group group)
            (frame-group-label-refresh!))
          group))))

(define (overview-quit!)
  (when (overview-active?)
    (overview--unlock!)
    (overview--restore!)
    (message "")))

(define (overview--move! dir)
  (when (overview-active?) (windmove! dir)))

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
  "Open the current group or project in one locked grid"
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

(define-command "window-layout-adaptive"
  "Tile visible buffers for the selected frame's usable width"
  (lambda () (tile-visible-adaptive!)))

;; The popup's default side is the right edge, on every frame: a compact
;; frame once got the bottom edge, and the estimate of the frame's width
;; read narrow after a stale window measurement, so the popup wandered.
;; A rule names a side, and M-<arrows> in the popup move it.
(set! popup-default-side (lambda () 'right))

(catalog-meta! 'command "window-layout-adaptive"
  'domain 'windows 'effects '(write display))
(for-each
  (lambda (name)
    (catalog-meta! 'command name 'domain 'windows 'effects '(write display)))
  '("tile-all" "overview-left" "overview-right" "overview-up" "overview-down"
    "overview-mark" "overview-pop-out" "overview-quit"))

(effects! '(read))
(public! 'window-layout-for-width
  "(window-layout-for-width COLS COUNT) — responsive tiler chosen for a frame width and pane count")
(effects! '(write))
(public! 'tile-adaptive-windows!
  "(tile-adaptive-windows! BUFFERS) — tile named buffers for the selected frame width")
(public! 'tile-visible-adaptive!
  "(tile-visible-adaptive!) — tile visible work windows for the selected frame width")
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
