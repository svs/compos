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

(define-command "window-layout-adaptive"
  "Tile visible buffers for the selected frame's usable width"
  (lambda () (tile-visible-adaptive!)))

;; Explicit display rules still win. Only the default follows the frame.
(set! popup-default-side
  (lambda ()
    (if (< (frame-cols) window-layout-compact-cols) 'bottom 'right)))

(catalog-meta! 'command "window-layout-adaptive"
  'domain 'windows 'effects '(write display))

(effects! '(read))
(public! 'window-layout-for-width
  "(window-layout-for-width COLS COUNT) — responsive tiler chosen for a frame width and pane count")
(effects! '(write))
(public! 'tile-adaptive-windows!
  "(tile-adaptive-windows! BUFFERS) — tile named buffers for the selected frame width")
(public! 'tile-visible-adaptive!
  "(tile-visible-adaptive!) — tile visible work windows for the selected frame width")

(domain! 'unknown)
(effects! '(unknown))
