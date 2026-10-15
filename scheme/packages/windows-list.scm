;;; windows-list.scm --- one buffer for every window of the frame's ring.
;;;
;;; M-x list-windows opens *windows*: the windows of the selected frame in
;;; ring order, the ones on screen filled, the ones waiting off it hollow.
;;;
;;;   RET   go to the window, walking the ring until it is on screen
;;;   k     close the window; a ring window takes its pane
;;;   g / q refresh · bury

(domain! 'windows)
(effects! '(write display))

(define *windows-list-buffer* "*windows*")

(defface! 'win-on 'fg "#2e6b45" 'weight "600")
(defface! 'win-off 'fg "#8a857a")
(defface! 'win-name 'fg "#26356b" 'weight "600")

(define (windows-list-ids buf)
  (map number->string (layout-ring-order)))

(define (windows-list-window id)
  (let ((win (string->number id)))
    (and win (window-exists? win) win)))

(define (windows-list-cells buf id)
  (let* ((win (windows-list-window id))
         (on (and win (member win (layout-pane-windows)) #t))
         (name (if win (window-buffer win) "")))
    (list (list (if on "■" "□") (if on "win-on" "win-off"))
          (list (if (and win (equal? win (active-window))) "●" "") "win-on")
          (list (if (equal? name "") "" (buffer-modeline-name name)) "win-name")
          (list (if on "on screen" "waiting") "faint")
          (list id "dim"))))

(define (windows-list-on-current fn)
  (let* ((id (list-current *windows-list-buffer*))
         (win (and id (windows-list-window id))))
    (if win (fn win) (message "no window on this line — g refreshes"))))

(define-command "windows-list-visit" "Go to the window on this line, walking the ring to it"
  (lambda () (windows-list-on-current layout-ring-show!)))

(define-command "windows-list-close" "Close the window on this line"
  (lambda ()
    (windows-list-on-current
      (lambda (win)
        (if (member win (layout-pane-windows))
            (buffer-move-close-source! win)
            (delete-window-id! win))
        (list-refresh! *windows-list-buffer*)))))

(define-command "windows-list-refresh" "Redraw the window list"
  (lambda () (list-refresh! *windows-list-buffer*)))

(define-list-mode! "windows-mode"
  (list
    'doc (string-append
           "The windows of this frame's ring, in ring order. A filled box is a "
           "window on screen, a hollow one waits off it. `RET` goes to the "
           "window and walks the ring to it, `k` closes it.")
    'buffer *windows-list-buffer*
    'rows windows-list-ids
    'columns (lambda (buf)
               (list (list "" 1) (list "" 1) (list "buffer" 40)
                     (list "state" 10) (list "id" #f)))
    'cells windows-list-cells
    'title (lambda (buf) "Windows")
    'meta (lambda (buf)
            (string-append (number->string (length (list-entries buf))) " windows"))
    'total (lambda (buf) (length (list-source-entries buf)))
    'no-marks #t
    'local-filter #t
    'footer (lambda (buf)
              '(("RET" "go") ("k" "close") ("/" "filter")
                ("g" "refresh") ("q" "quit")))
    'keys '(("RET" "windows-list-visit") ("k" "windows-list-close")
            ("g" "windows-list-refresh") ("q" "quit-window"))))

(define-command "list-windows"
  "List the windows of this frame's ring, on screen and waiting"
  (lambda () (list-mode-show! "windows-mode")))

;; The list follows the ring while it is on screen.
(define (windows-list-follow!)
  (when (and (buffer-known? *windows-list-buffer*) (window-showing *windows-list-buffer*))
    (list-refresh! *windows-list-buffer*)))

(add-hook! 'window-state-change-hook 'windows-list-follow!)
