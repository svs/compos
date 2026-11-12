;;; popper.scm --- popups: buffers you call up and send away, after popper.el.
;;;
;;; A popup is an ordinary buffer in the float: one window that floats
;;; above the panes, outside the layout, along one edge. The list
;;; popper-reference-buffers names the buffers that are popups: a string
;;; is a regexp on the buffer name, a symbol is a major mode (a derived
;;; mode matches too), and a procedure takes the name and answers.
;;;
;;; A display of a popup goes through display-buffer. The rule here sends
;;; it to the float, the popup window. popper-side names the edge, and a buffer moved with
;;; C-M-<arrow> keeps its own edge.
;;; Popper changes no other window. A popup buffer that the reader shows
;;; in a work window stays there. A display from code does not move the
;;; focus. popper-toggle and popper-cycle select the popup window, and a
;;; close gives the focus back to the window that had it. The layout does
;;; not tile the popup window (window-work-buffer?).
;;;
;;; popper-toggle closes the popup on screen, or shows the latest popup
;;; again. popper-cycle shows the next popup in the popup window.
;;; popper-toggle-type makes the popup an ordinary buffer, or makes the
;;; current buffer a popup.
;;;
;;; A close sends the float away. A pick from a popup list (RET) goes to
;;; the window you called the popup from, and the popup goes away.

;; the popup keys take the backtick family from groups
(require 'groups)
(require 'window)

(domain! 'windows)
(effects! '(read))

;; Empty by default: no buffer is a popup until the list names it. The
;; popper README example is '("\\*Messages\\*" "Output\\*$" help-mode).
(defcustom 'popper-reference-buffers '()
  "The buffers that are popups. A string is a regexp on the buffer name, a symbol is a major mode, and a procedure takes the name. popper-toggle-type overrides the list for one buffer. Example: '(\"\\\\*Messages\\\\*\" help-mode)."
  'group 'windows 'type 'list)

;; the share of the frame a new popup window takes (popper-window-height)
(define popper-window-height (/ 1 3))

(defcustom 'popper-side "bottom"
  "The edge of the frame a popup opens on: \"bottom\", \"top\", \"left\" or \"right\". A popup moved with C-M-<arrow> keeps its own edge."
  'group 'windows 'type 'string)

;; BUF's edge: the one it was moved to, else popper-side
(define (popper--side buf)
  (let ((own (buffer-local-value 'popper-side buf)))
    (string->symbol (if own (symbol->string own) popper-side))))

;; BUF's share of the frame: its own 'popper-size, else popper-window-height
(define (popper--size buf)
  (or (buffer-local-value 'popper-size buf) popper-window-height))

;; the list's answer for BUF
(define (popper--reference? buf)
  (let ((mode (buffer-local-value 'mode-name buf)))
    (let loop ((refs popper-reference-buffers))
      (cond ((null? refs) #f)
            ((cond ((string? (car refs)) (re-match? (car refs) buf))
                   ((symbol? (car refs))
                    (and (string? mode) (derived-mode? mode (symbol->string (car refs)))))
                   ((procedure? (car refs)) ((car refs) buf))
                   (else #f))
             #t)
            (else (loop (cdr refs)))))))

;; A popup. The buffer's own status wins over the list: popper-toggle-type
;; writes 'popper-popup-status, 'popup or 'raised. A hidden buffer is never
;; a popup, and a float is one only when popper floated it.
(define (popper-popup? buf)
  (and (string? buf) (buffer-known? buf)
       (not (string-prefix? " " buf))
       (or (buffer-local-value 'popper-floating buf) (not (float--class? buf)))
       (let ((status (buffer-local-value 'popper-popup-status buf)))
         (cond ((equal? status 'popup) #t)
               ((equal? status 'raised) #f)
               (else (popper--reference? buf))))))

;; the popup window: the float, while it shows a popup that popper
;; floated, else #f
(define (popper-window)
  (let ((w (float-window)))
    (and w (buffer-local-value 'popper-floating (window-buffer w))
         (popper-popup? (window-buffer w))
         w)))

;; the popups, most recent first: the buffer ring is the record of use
(define (popper-buffers)
  ;; a group keeps its own popups: one with no group belongs to every group
  (let ((g (frame-group)))
    (filter (lambda (b)
              (and (popper-popup? b)
                   (let ((bg (buffer-group b))) (or (not bg) (equal? bg g)))))
            (buffer-list-mru))))

;;; --- the display ---------------------------------------------------------------

;; A display of a popup that is not a look takes the popper rule.
(define (popper-display-control? name alist)
  (and (not *display-preview*)
       (not (plist-get alist 'category))
       (popper-popup? name)))

;; popper-display-popup-at-bottom, on any edge: NAME floats above the
;; panes along its edge. A popup display of NAME takes the float from the
;; popup there. The focus stays.
(define-display-action! 'popper-bottom
  (lambda (name alist)
    (let ((own (popper-window)))
      (if own
          (let ((was (window-buffer own)))
            (unless (equal? was name) (buffer-set-local! was 'popper-floating #f)))
          (set-frame-local! 'popper-return (active-window)))
      (buffer-set-local! name 'popper-floating #t)
      (float-show! name (popper--side name) (popper--size name)))))

(add-display-rule! popper-display-control? 'popper-bottom)
(set! *display-buffer-outside-layout*
  (cons 'popper-bottom (remove (lambda (a) (equal? a 'popper-bottom))
                               *display-buffer-outside-layout*)))
(set! window-work-buffer? (lambda (buf) (not (popper-popup? buf))))

;;; --- close, toggle, cycle ----------------------------------------------------------

;; the window you were in when the popup opened, while it lives
(define (popper-return-window)
  (let ((back (frame-local 'popper-return)))
    (and back (assoc back (window-list)) back)))

;; Close the popup window WIN: the float goes, and the focus goes back to
;; the window that had it before the popup opened.
(define (popper-close! win)
  (let ((back (popper-return-window))
        (had-focus (equal? (active-window) win))
        (buf (window-buffer win)))
    (when buf (buffer-set-local! buf 'popper-floating #f))
    ;; a popup list's peek goes with it
    (when (and buf (boundp 'listing-preview-dismiss!)) (listing-preview-dismiss! buf))
    (float-close!)
    (when (and had-focus back) (select-window! back))
    #t))

;; a pick from the popup sends it away
(define (popper-dismiss! win)
  (when (and win (equal? win (popper-window))) (popper-close! win)))

;; show BUF in the popup window, and select that window
(define (popper-show! buf)
  (let ((w (display-buffer buf)))
    (when w (select-window! w))
    w))

;; the latest popup that no window shows
(define (popper-latest)
  (let loop ((bs (popper-buffers)))
    (cond ((null? bs) #f)
          ((window-showing (car bs)) (loop (cdr bs)))
          (else (car bs)))))

(define-command "popper-toggle" "Close the popup on screen, or show the latest popup again"
  (lambda ()
    (let ((w (popper-window)))
      (cond (w (popper-close! w))
            ((popper-latest) (popper-show! (popper-latest)))
            (else (message "No popup"))))))

;; The next popup is the one used least recently, so each press shows a
;; popup that did not show for longest, and the presses reach them all.
(define-command "popper-cycle" "Show the next popup in the popup window"
  (lambda ()
    (let ((w (popper-window))
          (others (let ((bs (popper-buffers)))
                    (filter (lambda (b) (not (window-showing b))) bs))))
      (cond ((null? others)
             (if w (message "No other popup") (message "No popup")))
            (w (popper-show! (car (reverse others))))
            (else (popper-show! (car others)))))))

;; popper-toggle-type, as popper.el lowers and raises. A floating popup
;; becomes an ordinary buffer: the float goes and the buffer shows in the
;; window you called it from. Any other buffer becomes a popup: its window
;; goes back to the buffer before it, and the buffer floats.
(define-command "popper-toggle-type" "Make this popup an ordinary buffer, or make this buffer a popup"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (popper-popup? buf)
          (let ((w (popper-window)))
            (buffer-set-local! buf 'popper-popup-status 'raised)
            (when (and w (equal? (window-buffer w) buf))
              (let ((back (or (popper-return-window) (active-window))))
                (popper-close! w)
                (select-window! back)
                (window-set-buffer! back buf)))
            (message (string-append buf " is an ordinary buffer now")))
          (begin
            (buffer-set-local! buf 'popper-popup-status 'popup)
            (when (equal? (window-buffer (active-window)) buf)
              (run-command "previous-buffer"))
            (popper-show! buf)
            (message (string-append buf " is a popup now")))))))

;; popper's README keys, less C-`: C-` belongs to group-next-mode-buffer, so
;; popper-toggle has no key. M-` cycles, C-M-` changes the type.
(global-set-key "M-`" "popper-cycle")
(global-set-key "C-M-`" "popper-toggle-type")

;; Move the popup on screen to another edge; the buffer keeps SIDE for its
;; next display. The focus stays where it was. The old popup.scm used M-<arrow>, which
;; browse and morg take for landmarks.
(define (popper-move! side)
  (let ((w (popper-window)))
    (if (not w)
        (message "No popup")
        (let ((buf (window-buffer w))
              (me (active-window)))
          (buffer-set-local! buf 'popper-side side)
          (float-show! buf side (popper--size buf) (equal? me w))
          (message (string-append "Popup on the " (symbol->string side)))))))

(define-command "popper-move-left" "Move the popup to the left edge of the frame"
  (lambda () (popper-move! 'left)))
(define-command "popper-move-right" "Move the popup to the right edge of the frame"
  (lambda () (popper-move! 'right)))
(define-command "popper-move-up" "Move the popup to the top edge of the frame"
  (lambda () (popper-move! 'top)))
(define-command "popper-move-down" "Move the popup to the bottom edge of the frame"
  (lambda () (popper-move! 'bottom)))

(global-set-key "C-M-<left>" "popper-move-left")
(global-set-key "C-M-<right>" "popper-move-right")
(global-set-key "C-M-<up>" "popper-move-up")
(global-set-key "C-M-<down>" "popper-move-down")

(catalog-meta! 'command "popper-toggle" 'domain 'windows 'effects '(write display))
(catalog-meta! 'command "popper-cycle" 'domain 'windows 'effects '(write display))
(catalog-meta! 'command "popper-toggle-type" 'domain 'windows 'effects '(write display))
(for-each (lambda (c) (catalog-meta! 'command c 'domain 'windows 'effects '(write display)))
          '("popper-move-left" "popper-move-right" "popper-move-up" "popper-move-down"))

(public! 'popper-popup?
  "(popper-popup? NAME) — #t when NAME is a popup: its own status, else popper-reference-buffers")
(public! 'popper-window
  "(popper-window) — the popup window that popper made, or #f")
(public! 'popper-buffers
  "(popper-buffers) — the popups, most recent first")
(effects! '(write display))
(public! 'popper-close!
  "(popper-close! WIN) — close the popup in the popup window WIN: the float goes and the focus goes back")
