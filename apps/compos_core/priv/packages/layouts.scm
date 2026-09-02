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

;; The display-buffer chain (editor.scm) reads these. They are plain
;; defines there, because editor.scm loads before custom.scm.
(defcustom 'split-height-threshold 80
  "A window with this many rows splits below for a pop-up window (Emacs split-height-threshold)."
  'group 'windows 'type 'number)

(defcustom 'split-width-threshold 160
  "A window with this many columns splits beside for a pop-up window (Emacs split-width-threshold)."
  'group 'windows 'type 'number)

;; The main layouts (editor.scm layout--main-stack!) read these two.
(defcustom 'window-layout-main-ratio 0.62
  "The main pane's share of the frame in the main layouts: a fraction between 0.3 and 0.9."
  'group 'windows 'type 'number)

(defcustom 'window-layout-stack 'column
  "How the other panes arrange beside the main pane: 'column stacks them, 'grid tiles them."
  'group 'windows 'type 'choice)

(defcustom 'window-layout-main-side 'left
  "Where the auto layout puts the main pane: 'left or 'right."
  'group 'windows 'type 'choice)

(defcustom '*display-buffer-base-action* '()
  "Display actions tried after the rule for a buffer and before the fallback: a list of popup, pop-up-window, reuse-window, use-some-window, same-window."
  'group 'windows 'type 'list)

(defcustom '*display-buffer-fallback-action*
  '(reuse-window pop-up-window use-some-window same-window)
  "Display actions tried last for a buffer with no rule."
  'group 'windows 'type 'list)

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

;;; --- autolayout: one main pane, the rest beside it ---------------------------
;;; The StumpWM shape. The selected window's buffer is the main pane on
;;; window-layout-main-side, with window-layout-main-ratio of the frame.
;;; The other visible buffers share the rest, as a column or as tiles
;;; (window-layout-stack). autolayout-mode keeps the frame in this shape:
;;; when a window comes or goes, the frame re-arranges, the main pane
;;; stays main while its buffer is visible, and a new buffer joins the
;;; stack. A popup and the minibuffer are not panes.

(define *autolayout-mode* #f)

;; main pane on the left = the stack on the right, in the tiler's names
(define (autolayout--algorithm)
  (if (equal? window-layout-main-side 'right) 'main-left 'main-right))

;; the panes, main first: MAIN while it is visible, else the selected
;; window's buffer. Duplicates stay: two windows on one buffer are two panes.
(define (autolayout--panes main)
  (let ((visible (layout-visible-buffers)))
    (cond ((null? visible) '())
          ((and main (member main visible))
           (cons main (let loop ((rest visible) (dropped #f))
                        (cond ((null? rest) '())
                              ((and (not dropped) (equal? (car rest) main)) (loop (cdr rest) #t))
                              (else (cons (car rest) (loop (cdr rest) dropped)))))))
          (else visible))))

(define (autolayout--same-panes? a b)
  (and (= (length a) (length b))
       (let loop ((xs a) (ys b))
         (or (null? xs)
             (and (member (car xs) ys)
                  (loop (cdr xs) (let drop ((rest ys))
                                   (cond ((null? rest) '())
                                         ((equal? (car rest) (car xs)) (cdr rest))
                                         (else (cons (car rest) (drop (cdr rest))))))))))))

;; arrange the frame with MAIN as the main pane. One pane: one window.
(define (autolayout-apply! main)
  (let ((panes (autolayout--panes main)))
    (cond ((null? panes) #f)
          (else
            (set-frame-local! 'autolayout-main (car panes))
            (set-frame-local! 'autolayout-panes panes)
            (if (null? (cdr panes))
                (begin (delete-other-windows!) panes)
                (tile-windows! (autolayout--algorithm) panes))))))

;; the hook: the frame's panes changed, so the shape is re-made. Nothing
;; runs while a tiler runs, or while a prompt is open.
(define (autolayout--on-change!)
  (when (and *autolayout-mode* (not *layout-busy*) (not (minibuffer-state)))
    (let ((panes (autolayout--panes (frame-local 'autolayout-main))))
      (when (and (pair? panes)
                 (not (autolayout--same-panes? panes (or (frame-local 'autolayout-panes) '()))))
        (autolayout-apply! (car panes))))))

(add-hook! 'window-configuration-change-hook 'autolayout--on-change!)

;; "62", not "62.0": the dialect has no round
(define (autolayout--percent ratio)
  (car (string-split (number->string (* 100 ratio)) ".")))

(define (autolayout--ratio-from-input text)
  (let ((n (string->number text)))
    (cond ((not (number? n)) #f)
          ((> n 1) (/ n 100))
          (else n))))

(define-command "autolayout"
  "Make the selected window's buffer the main pane; the other buffers stack beside it"
  (lambda () (autolayout-apply! (window-buffer (active-window)))))

(define-command "autolayout-main-left"
  "Put the main pane on the left and arrange the frame"
  (lambda ()
    (customize-set! 'window-layout-main-side 'left)
    (autolayout-apply! (window-buffer (active-window)))))

(define-command "autolayout-main-right"
  "Put the main pane on the right and arrange the frame"
  (lambda ()
    (customize-set! 'window-layout-main-side 'right)
    (autolayout-apply! (window-buffer (active-window)))))

(define-command "autolayout-set-main-width"
  "Set the main pane's share of the frame, as a fraction or a percent, and arrange the frame"
  (lambda ()
    (minibuffer-read
      (string-append "Main pane width (now "
                     (autolayout--percent window-layout-main-ratio) "%): ")
      '()
      (lambda (text)
        (let ((ratio (autolayout--ratio-from-input text)))
          (if (and ratio (>= ratio 0.3) (<= ratio 0.9))
              (begin
                (customize-set! 'window-layout-main-ratio ratio)
                (autolayout-apply! (or (frame-local 'autolayout-main)
                                       (window-buffer (active-window)))))
              (message "The main pane takes between 30% and 90% of the frame")))))))

(define-command "autolayout-toggle-stack"
  "Arrange the other panes as a column, or as tiles; again goes back"
  (lambda ()
    (customize-set! 'window-layout-stack
                    (if (equal? window-layout-stack 'grid) 'column 'grid))
    (message (if (equal? window-layout-stack 'grid) "Tiles beside the main pane" "A column beside the main pane"))
    (autolayout-apply! (or (frame-local 'autolayout-main) (window-buffer (active-window))))))

(define-command "autolayout-mode"
  "Keep the frame in the main-and-stack layout as windows come and go; again turns it off"
  (lambda ()
    (set! *autolayout-mode* (not *autolayout-mode*))
    (if *autolayout-mode*
        (begin
          (autolayout-apply! (window-buffer (active-window)))
          (message "Autolayout on: the selected buffer is the main pane"))
        (message "Autolayout off"))))

(for-each
  (lambda (name) (catalog-meta! 'command name 'domain 'windows 'effects '(write display)))
  '("autolayout" "autolayout-main-left" "autolayout-main-right"
    "autolayout-set-main-width" "autolayout-toggle-stack" "autolayout-mode"))

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
(public! 'autolayout-apply!
  "(autolayout-apply! MAIN) — arrange the frame with MAIN as the main pane and the other visible buffers beside it")
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
