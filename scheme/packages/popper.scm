;;; popper.scm --- popups: buffers you call up and send away, after popper.el.
;;;
;;; A popup is an ordinary buffer in an ordinary window. The list
;;; popper-reference-buffers names the buffers that are popups: a string
;;; is a regexp on the buffer name, a symbol is a major mode (a derived
;;; mode matches too), and a procedure takes the name and answers.
;;;
;;; A display of a popup goes through display-buffer. The rule here sends
;;; it to the popup window: the one window across the bottom of the frame
;;; that popper made. The frame local 'popper-window names that window.
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
;;; A close shows the popup that the closed popup covered in the popup
;;; window. When no popup is under it, the close deletes the popup window.

;; the popup keys take the backtick family from groups
(require 'groups)

(domain! 'windows)
(effects! '(read))

;; Empty by default: no buffer is a popup until the list names it. The
;; popper README example is '("\\*Messages\\*" "Output\\*$" help-mode).
(defcustom 'popper-reference-buffers '()
  "The buffers that are popups. A string is a regexp on the buffer name, a symbol is a major mode, and a procedure takes the name. popper-toggle-type overrides the list for one buffer. Example: '(\"\\\\*Messages\\\\*\" help-mode)."
  'group 'windows 'type 'list)

;; the share of the frame a new popup window takes (popper-window-height)
(define popper-window-height (/ 1 3))

;; the list's answer for BUF
(define (popper--reference? buf)
  (let ((mode (buffer-local buf 'mode-name)))
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
;; writes 'popper-popup-status, 'popup or 'raised. A hidden buffer, a peek
;; and a float are never popups: each has its own window.
(define (popper-popup? buf)
  (and (string? buf) (buffer-known? buf)
       (not (string-prefix? " " buf))
       (not (peek-buffer? buf))
       (not (float--class? buf))
       (let ((status (buffer-local buf 'popper-popup-status)))
         (cond ((equal? status 'popup) #t)
               ((equal? status 'raised) #f)
               (else (popper--reference? buf))))))

;; the popup window: the window that popper made, while it lives and
;; shows a popup, else #f
(define (popper-window)
  (let ((w (frame-local 'popper-window)))
    (and w (assoc w (window-list))
         (popper-popup? (window-buffer w))
         w)))

;; the popups, most recent first: the buffer ring is the record of use
(define (popper-buffers)
  (filter popper-popup? (buffer-list-mru)))

;;; --- the display ---------------------------------------------------------------

;; A display of a popup that is not a look takes the popper rule.
(define (popper-display-control? name alist)
  (and (not *display-preview*)
       (not (plist-get alist 'category))
       (popper-popup? name)))

;; popper-display-popup-at-bottom: the popup window, else a new window
;; across the bottom of the frame. A popup display of NAME covers the
;; popup there, and the close shows that popup again.
(define-display-action! 'popper-bottom
  (lambda (name alist)
    (let* ((own (popper-window))
           (win (or own (split-root! 'v (- 1 popper-window-height)))))
      (when win
        (unless own
          (set-frame-local! 'popper-window win)
          (set-frame-local! 'popper-return (active-window)))
        (unless (equal? (window-buffer win) name)
          (display-buffer-in-window! win name)))
      win)))

(add-display-rule! popper-display-control? 'popper-bottom)
(set! *display-buffer-outside-layout*
  (cons 'popper-bottom (remove (lambda (a) (equal? a 'popper-bottom))
                               *display-buffer-outside-layout*)))
(set! window-work-buffer? (lambda (buf) (not (popper-popup? buf))))

;;; --- close, toggle, cycle ----------------------------------------------------------

;; Close the popup window WIN. The window shows the popup that the closed
;; popup covered. When no popup is under it, the window goes, and the
;; focus goes back to the window that had it before the popup opened.
(define (popper-close! win)
  (let* ((rec (window-restore win))
         (under (and rec (equal? (car rec) 'other) (cadr rec))))
    (cond ((and under (buffer-known? under) (popper-popup? under))
           (display-buffer-in-window! win under)
           (set-window-restore! win '(window #f #f))
           #t)
          ((pair? (cdr (window-list)))
           (let ((back (frame-local 'popper-return))
                 (had-focus (equal? (active-window) win)))
             (delete-window-id! win)
             (set-frame-local! 'popper-window #f)
             (when (and had-focus back (assoc back (window-list))) (select-window! back)))
           #t)
          (else (message "The popup is the last window") #f))))

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

;; popper-toggle-type. A popup becomes an ordinary buffer where it stands:
;; its popup window becomes a work window. Any other buffer becomes a
;; popup, and its window keeps it. The next popup display of it goes to
;; the popup window.
(define-command "popper-toggle-type" "Make this popup an ordinary buffer, or make this buffer a popup"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (popper-popup? buf)
          (begin
            (when (equal? (popper-window) (active-window))
              (set-frame-local! 'popper-window #f))
            (buffer-set-local! buf 'popper-popup-status 'raised)
            (message (string-append buf " is an ordinary buffer now")))
          (begin
            (buffer-set-local! buf 'popper-popup-status 'popup)
            (message (string-append buf " is a popup now")))))))

;; popper's README keys, less C-`: C-` belongs to group-next-mode-buffer, so
;; popper-toggle has no key. M-` cycles, C-M-` changes the type.
(global-set-key "M-`" "popper-cycle")
(global-set-key "C-M-`" "popper-toggle-type")

(catalog-meta! 'command "popper-toggle" 'domain 'windows 'effects '(write display))
(catalog-meta! 'command "popper-cycle" 'domain 'windows 'effects '(write display))
(catalog-meta! 'command "popper-toggle-type" 'domain 'windows 'effects '(write display))

(public! 'popper-popup?
  "(popper-popup? NAME) — #t when NAME is a popup: its own status, else popper-reference-buffers")
(public! 'popper-window
  "(popper-window) — the popup window that popper made, or #f")
(public! 'popper-buffers
  "(popper-buffers) — the popups, most recent first")
(effects! '(write display))
(public! 'popper-close!
  "(popper-close! WIN) — close the popup in the popup window WIN: show the popup under it, or delete the window")
