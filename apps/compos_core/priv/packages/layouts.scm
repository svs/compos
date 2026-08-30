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

;; Tile the complete context, not only the buffers that are already visible.
;; A group is the more specific context. A project supplies the context when
;; the frame is not in a group. The project package loads after this package,
;; so every project call uses its public runtime seam.
(define (tile-all-context-buffers)
  (let ((group (and (boundp (quote frame-group)) (frame-group))))
    (cond
      (group
        (let ((members (group-user-buffers-mru group)))
          ;; An empty durable group still has one reconstructable surface.
          (if (pair? members) members (list (group-chat group)))))
      ((and (boundp (quote project-current)) (project-current))
        (let* ((root (project-current))
               (members (project-buffers root))
               (mru (buffer-list-mru)))
          (append
            (filter (lambda (buf) (member buf members)) mru)
            (filter (lambda (buf) (not (member buf mru))) members))))
      (else '()))))

(define (tile-all!)
  (let ((buffers (tile-all-context-buffers)))
    (if (null? buffers)
        (begin (message "Tile all is available only in a group or project") #f)
        (tile-adaptive-windows! buffers))))

(define-command "tile-all"
  "Tile every buffer in the current group or project"
  tile-all!)

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
(catalog-meta! 'command "tile-all"
  'domain 'windows 'effects '(write display))

(effects! '(read))
(public! 'window-layout-for-width
  "(window-layout-for-width COLS COUNT) — responsive tiler chosen for a frame width and pane count")
(effects! '(write))
(public! 'tile-adaptive-windows!
  "(tile-adaptive-windows! BUFFERS) — tile named buffers for the selected frame width")
(public! 'tile-visible-adaptive!
  "(tile-visible-adaptive!) — tile visible work windows for the selected frame width")
(public! 'tile-all-context-buffers
  "(tile-all-context-buffers) — current group members, else current project buffers")
(public! 'tile-all!
  "(tile-all!) — tile every buffer in the current group or project")

(domain! 'unknown)
(effects! '(unknown))
