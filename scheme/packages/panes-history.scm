;;; panes-history.scm --- undo and redo over the pane arrangement alone.
;;;
;;; Winner restores whole window configurations, buffers and points
;;; included. This keeps only the layout: the panes, their shares and the
;;; order of their windows. A step back puts that arrangement over the
;;; buffers the windows hold now, so what you were reading stays, and only
;;; the shape of the frame moves.
;;;
;;; One history per frame and group, beside the layout panes-mode.scm keeps.
;;; A change of shape records; a change of buffer alone does not.

(require 'panes)
(require 'panes-mode)

(domain! 'windows)
(effects! '(pure))

(define panes-history-depth 50)

;; the arrangement alone: each pane as (ID SHARE (WINDOW-KEY ...))
(define (panes-shape layout)
  (map (lambda (p) (list (plist-get p 'id) (plist-get p 'share) (plist-get p 'column) (plist-get p 'vshare) (panes-keys p)))
       (panes-panes layout)))

;; a history: the states, newest first, the current one at the head;
;; and the states undone, nearest first
(define (panes-history-empty) (list 'past '() 'future '()))
(define (panes-history-past h) (or (plist-get h 'past) '()))
(define (panes-history-future h) (or (plist-get h 'future) '()))
(define (panes-history-current h) (let ((p (panes-history-past h))) (and (pair? p) (car p))))

;; LAYOUT becomes the current state when its shape is new; a change of
;; buffers alone leaves the history as it is. A new state ends any redo.
(define (panes-history-record h layout)
  (let ((cur (panes-history-current h))
        (entry (panes-strip-handles layout)))
    (if (and cur (equal? (panes-shape cur) (panes-shape layout)))
        (list 'past (cons entry (cdr (panes-history-past h))) 'future (panes-history-future h))
        (list 'past (take (cons entry (panes-history-past h)) panes-history-depth) 'future '()))))

;; (HISTORY TARGET) one step back, or #f at the oldest state
(define (panes-history-undo h)
  (let ((past (panes-history-past h)))
    (and (pair? past) (pair? (cdr past))
         (list (list 'past (cdr past) 'future (cons (car past) (panes-history-future h)))
               (cadr past)))))

;; (HISTORY TARGET) one step forward, or #f with nothing undone
(define (panes-history-redo h)
  (let ((future (panes-history-future h)))
    (and (pair? future)
         (list (list 'past (cons (car future) (panes-history-past h)) 'future (cdr future))
               (car future)))))

;; RECORDED's arrangement over CURRENT's buffers: a window both hold keeps
;; the stack it holds now, and its handle, so the applier reuses the real
;; window; a window only RECORDED holds comes back with the stack it had
;; then, less the buffers that are gone
(define (panes-history-merge current recorded live?)
  (let* ((merged (fold (lambda (l k)
                         (if (panes-window current k)
                             (let ((h (panes-handle current k)))
                               (panes-set-handle (panes-set-buffers l k (panes-window-buffers current k)) k h))
                             l))
                       recorded (panes-window-keys recorded))))
    (panes-validate merged live?)))

;;; --- the frame ------------------------------------------------------------

(domain! 'windows)
(effects! '(write display))

(define panes-history--restoring #f)

(define (panes-history--store) (or (frame-local 'panes-histories) '()))
(define (panes-history)
  (let ((e (assoc (panes--group-key) (panes-history--store))))
    (if e (cadr e) (panes-history-empty))))
(define (panes-history-set! h)
  (set-frame-local! 'panes-histories (alist-put (panes-history--store) (panes--group-key) h))
  h)

;; every layout the model keeps passes through panes-layout-set!; a
;; restore passes too, and must not record itself as a new state
(advice-add! 'panes-layout-set! 'around 'panes-history
  (lambda (next layout)
    (let ((r (next layout)))
      (unless panes-history--restoring
        (panes-history-set! (panes-history-record (panes-history) layout)))
      r)))

(define (panes-history--step! step what)
  (cond ((not (panes-layout)) (message "No layout yet") #f)
        (else
          (let ((r (step (panes-history))))
            (if (not r)
                (begin (message (string-append "No layout to " what)) #f)
                (let ((merged (panes-history-merge (panes-layout) (cadr r) buffer-known?)))
                  (set! panes-history--restoring #t)
                  (unwind-protect
                    (lambda ()
                      (panes-history-set! (car r))
                      (panes-apply! merged)
                      (window-log-note! "layout " what " -> " (length (panes-panes merged)) " panes"))
                    (lambda () (set! panes-history--restoring #f)))
                  #t))))))

(define-command "layout-undo"
  "Put back the previous pane arrangement; the windows keep the buffers they show now"
  (lambda () (panes-history--step! panes-history-undo "undo")))

(define-command "layout-redo"
  "Go forward again to the pane arrangement layout-undo left"
  (lambda () (panes-history--step! panes-history-redo "redo")))

(public! 'panes-history "(panes-history) -> this frame's layout history for its group: past (newest first, the current state at the head) and future")
(catalog-meta! 'function "panes-history" 'effects '(read))
(public! 'panes-shape "(panes-shape LAYOUT) -> the arrangement alone: (ID SHARE (WINDOW-KEY ...)) per pane")
(catalog-meta! 'function "panes-shape" 'effects '(pure))
(public! 'panes-history-merge "(panes-history-merge CURRENT RECORDED LIVE?) -> RECORDED's arrangement over CURRENT's buffers")
(catalog-meta! 'function "panes-history-merge" 'effects '(pure))

(provide 'panes-history)
