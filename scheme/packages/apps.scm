;;; apps.scm --- app identity over buffers and windows.
;;;
;;; An app is more than one buffer: a home, its lists, its details. The
;;; editor has no handle on that set, so moving an app to a group has
;;; nothing to enumerate. Screen position, window count and name prefixes
;;; all lie the moment two instances of the same app are open at once.
;;;
;;; So the app names itself. Every buffer it opens carries an 'app-id
;;; local naming the instance, not the kind, and an 'app-role saying what
;;; that buffer is. Locals persist with the desktop, so the set survives
;;; a restart.

;; a move retags an app's buffers through group membership
(require 'groups)

(domain! 'windows)
(effects! '(read))

(define (app-id buf)
  (and buf (buffer-known? buf) (buffer-local buf 'app-id)))

(define (app-role buf)
  (and buf (buffer-known? buf) (buffer-local buf 'app-role)))

;; Every buffer of the instance, shown or not. The hidden ones are the
;; point: a detail nobody is looking at is still part of the app, and
;; leaving it behind splits the instance across two groups.
(define (app-buffers id)
  (and id (filter (lambda (buf) (equal? (app-id buf) id)) (buffer-list))))

;; ((WINDOW-ID BUFFER-NAME) ...), the shape window-list answers, for the
;; instance's visible windows alone. This is for layout work; a move
;; reads app-buffers instead.
(define (app-windows id)
  (and id (filter (lambda (w) (equal? (app-id (cadr w)) id)) (window-list))))

(public! 'app-id "(app-id BUF) — the app instance BUF belongs to, or #f")
(public! 'app-role "(app-role BUF) — BUF's part in its app: home, list, detail, aux")
(public! 'app-buffers "(app-buffers ID) — every buffer of app instance ID, shown or not")
(public! 'app-windows "(app-windows ID) — ((WINDOW-ID BUFFER-NAME) ...) for the instance's visible windows")

(effects! '(write))

(define (app-claim! buf id role)
  (and (buffer-known? buf) id
       (begin (buffer-set-local! buf 'app-id id)
              (buffer-set-local! buf 'app-role role)
              id)))

;; Retag the whole instance at once. The frame is untouched: every window
;; still shows what it showed, focus and point included. Membership
;; moved, not the user's view of it. Closing the windows afterwards is a
;; separate, louder act, and belongs to whoever asked for it.
(define (app-move-buffers! id group)
  (let ((bufs (or (app-buffers id) '())))
    (and (pair? bufs) group
         (let ((gid (buffer-move-to-group! (car bufs) group)))
           (for-each (lambda (buf) (buffer-move-to-group! buf gid)) (cdr bufs))
           bufs))))

(public! 'app-claim! "(app-claim! BUF ID ROLE) — mark BUF as part of app instance ID")
(public! 'app-move-buffers! "(app-move-buffers! ID GROUP) — move every buffer of instance ID to GROUP, leaving the frame as it is")

(effects! '(write display))

;; Tile what the app has on screen. The set is the app's WINDOWS, not its
;; buffers: an app that has walked twelve rows holds twelve detail
;; buffers and wants exactly one of them tiled. Laying out app-buffers
;; would open eleven panes nobody asked for, so a layout reads the frame.
;;
;; EXTRA names panes that are not the app's — the group's chat is the
;; usual one — and they go first, so the reader's own column stays on the
;; left. Answers the panes it tiled, or #f when the app has no window.
(define (app-layout! id &optional extra)
  (let* ((extras (filter buffer-known? (or extra '())))
         (mine (filter (lambda (buf) (not (member buf extras)))
                       (map cadr (or (app-windows id) '()))))
         (panes (append extras mine)))
    (and (pair? panes)
         (begin (tile-default-windows! panes) panes))))

(public! 'app-layout! "(app-layout! ID &optional EXTRA) — tile the app's on-screen panes, the EXTRA list first; answers the panes")

(effects! '(read))

;; The page open beside a listing, or #f. The detail contract already
;; remembers which window a listing opens its rows into, so this is that
;; window's buffer and not a guess from the name.
(define (app-detail-here &optional buf)
  (let* ((owner (or buf (current-buffer)))
         (win (and owner (boundp 'detail-window) (detail-window owner))))
    (and win (window-buffer win))))

(public! 'app-detail-here "(app-detail-here [LISTING]) — the page open beside the listing, or #f")

(effects! '(write))

(define (app--detail-shim! cmd)
  ;; One command per mirrored key, named after what it runs, so C-h b in the
  ;; listing says where the key goes instead of hiding it behind a lambda.
  (let ((name (string-append "app-detail-" cmd)))
    (define-command name
      (string-append "Run " cmd " in the page beside this listing")
      (lambda ()
        (let ((page (app-detail-here)))
          (if page
              (with-current-buffer page (lambda () (run-command cmd)))
              (message "No page is open beside this listing")))))
    name))

;; In an app the listing and the page are one surface. A key the listing does
;; not claim belongs to the page beside it, so the page's own verbs work from
;; the row that opened them and the focus never leaves the list. Keys the
;; listing already answers are left alone: the listing wins its own map.
;;
;; Answers the keys it mirrored.
(define (app-detail-keys! list-mode detail-mode)
  (let ((lmap (mode-keymap list-mode))
        (dmap (mode-keymap detail-mode)))
    (and lmap dmap
         (fold (lambda (done pair)
                 (let ((keys (car pair)) (cmd (cadr pair)))
                   (if (or (keymap-lookup lmap keys)
                           (string-prefix? "keymap:" cmd))
                       done
                       (begin (define-key lmap keys (app--detail-shim! cmd))
                              (cons keys done)))))
               '() (keymap-bindings dmap)))))

(public! 'app-detail-keys! "(app-detail-keys! LIST-MODE DETAIL-MODE) — a key the listing does not bind runs in the page beside it; answers the keys mirrored")

(effects! '(read))

;; Turn a callback API into a value. STARTER is given a continuation and
;; answers whatever that continuation is handed, or #f at the deadline.
;;
;; This BLOCKS the lane it runs on, so it belongs inside a task-run! or a
;; task-spawn, never on a keypress. Used that way it replaces the retry
;; chains an app otherwise grows one per asynchronous call, each with its
;; own debounce key, its own countdown, and its own way of going quiet.
(define (app-await starter &optional seconds)
  (let ((done #f) (value #f))
    (starter (lambda (v) (set! value v) (set! done #t)))
    (wait-until (lambda () done) (* 1000 (or seconds 20)) 50)
    value))

;; A pause inside a task. wait-until on a predicate that never answers is
;; the sleep this Scheme has.
(define (app-pause ms)
  (wait-until (lambda () #f) ms ms)
  #t)

(public! 'app-await "(app-await STARTER &optional SECONDS) — run STARTER with a continuation and answer what it is given; blocks, so call it inside a task")
(public! 'app-pause "(app-pause MS) — pause inside a task")
