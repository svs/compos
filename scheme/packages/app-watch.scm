;;; app-watch.scm --- w watches an app buffer: it follows its data, or stops.
;;;
;;; Every app buffer, a listing or a page, takes w. Watched, it shows its data
;;; as it is now without a g; not watched, it holds still until g.
;;;
;;; An app that knows when its data changes says so with app-watch-define!:
;;; its buffers start watched, and its own change signal asks app-watching?
;;; before it redraws. Every other app is read again: while a buffer is
;;; watched and a window shows it, its g runs every app-watch-interval
;;; seconds. Those start unwatched, because each read may cost a fetch.

(domain! 'buffers)
(effects! '(write))

(defcustom 'app-watch-interval 30
  "Seconds between two reads of a watched app buffer whose app cannot say when its data changes."
  'group 'buffers 'type 'integer)

;; mode names whose app redraws on its own change signal
(define *app-watch-self* '())

(define (app-watch-define! mode)
  "(app-watch-define! MODE) -- MODE's app redraws its buffers when its data changes, and asks app-watching? first; its buffers start watched"
  (unless (member mode *app-watch-self*)
    (set! *app-watch-self* (cons mode *app-watch-self*)))
  mode)

(define (app-watch--mode buf) (buffer-local-value 'mode-name buf))

(define (app-watch--self? buf) (and (member (app-watch--mode buf) *app-watch-self*) #t))

(define (app-watching? buf)
  "(app-watching? BUF) -- #t when BUF follows its data; w turns it on and off"
  (let ((v (buffer-local-value 'app-watch buf)))
    (cond ((eq? v 'on) #t)
          ((eq? v 'off) #f)
          (else (app-watch--self? buf)))))

;; the buffer's own g: what reading it again means for this app
(define (app-watch--refresh-command buf)
  (let ((cmd (lookup-key (string-append (app-watch--mode buf) "-map") "g")))
    (and (string? cmd) (not (equal? cmd "self-insert-command")) cmd)))

(define (app-watch--refresh! buf)
  (let ((cmd (app-watch--refresh-command buf)))
    (when cmd (with-current-buffer buf (lambda () (run-command cmd))))))

(define (app-watch--key buf) (string->symbol (string-append "app-watch:" buf)))

;; one read, then the next one is set; a buffer that went away, or stopped
;; watching, ends the run
(define (app-watch--tick buf)
  (when (and (buffer-exists? buf) (app-watching? buf) (not (app-watch--self? buf)))
    (when (window-showing buf) (ignore-errors (app-watch--refresh! buf)))
    (debounce! (app-watch--key buf) (* 1000 app-watch-interval) app-watch--tick buf)))

;; A page's own mode may already give w a verb (amazon copies the link). The
;; detail map is a minor map and would win over it, so w gives way to it.
(define (app-watch--own-w buf)
  (let ((cmd (lookup-key (string-append (app-watch--mode buf) "-map") "w")))
    (and (string? cmd) (not (equal? cmd "app-watch")) (not (equal? cmd "self-insert-command")) cmd)))

(define-command "app-watch" "Follow this buffer's data as it changes, or hold it still"
  (lambda ()
    (let* ((buf (current-buffer)) (own (app-watch--own-w buf)))
      (if own
          (run-command own)
          (let ((on (not (app-watching? buf))))
            (buffer-set-local! buf 'app-watch (if on 'on 'off))
            (cond ((not on) (debounce-cancel! (app-watch--key buf)))
                  ((app-watch--self? buf) (app-watch--refresh! buf))
                  (else (app-watch--tick buf)))
            (message (if on "Watching: this buffer follows its data" "Not watching: g reads it again")))))))

(define-key "list-mode-map" "w" "app-watch")
(define-key "detail-mode-map" "w" "app-watch")

(public! 'app-watch-define!)
(public! 'app-watching?)
(catalog-meta! 'command "app-watch" 'domain 'buffers 'effects '(write) 'aliases "auto revert watch follow live refresh")

(provide 'app-watch)
