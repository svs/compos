;;; canvas-overview.scm --- spatial HTML-in-Canvas overview of groups, panes,
;;; window stacks, and buffers.
;;;
;;; M-x canvas-overview opens an interactive infinite canvas showing every
;;; group, its panes, each pane's stack of windows, and its remaining buffers.
;;; Expanding a pane stack spreads all stacked windows out as live-updating
;;; HTML cards painted inside <canvas layoutsubtree> via drawElementImage
;;; (with automatic CSS-transform fallback when the browser flag is off).

(require 'panes-mode)
(require 'preview)

(domain! 'windows)
(effects! '(read))

(define *canvas-overview-buffer* "*canvas-overview*")
(define *canvas-overview-lines* 16)
(define *canvas-overview-max-unshown* 24)
(define *canvas-overview-rev* 0)
(define *canvas-overview-watches* '())
(define *canvas-overview-dirty* '())
(define *canvas-overview-extra-watch* '())
(define *canvas-overview-demo-buf* "*canvas-spike-pulse*")
(define *canvas-overview-demo-on* #f)
(define *canvas-overview-demo-seq* 0)

(define canvas-overview--html
  "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><link rel=\"stylesheet\" href=\"canvas-overview.css\"></head><body><script src=\"canvas-overview.js\"></script></body></html>")

(define (canvas-overview--own-dir)
  (let ((ds (filter (lambda (d) (string-suffix? "/canvas-overview" d)) (stdlib-dirs))))
    (if (pair? ds)
        (car ds)
        (string-append (default-directory) "scheme/stdlib/canvas-overview"))))

(define (canvas-overview--visible?)
  (and (buffer-known? *canvas-overview-buffer*)
       (and (find (lambda (w) (equal? (cadr w) *canvas-overview-buffer*)) (window-list)) #t)))

(define (canvas-overview--short-name buf)
  (cond ((not (string? buf)) "")
        ((string-prefix? "/" buf) (file-name-nondirectory buf))
        (else buf)))

(define (canvas-overview--short-mode mode)
  (cond ((not (string? mode)) "fundamental")
        ((string-suffix? "-mode" mode) (substring mode 0 (- (string-length mode) 5)))
        (else mode)))

(define (canvas-overview--internal? buf)
  (or (not (string? buf))
      (string-prefix? " " buf)
      (equal? buf *canvas-overview-buffer*)))

(define (canvas-overview--clip-line s)
  (if (> (string-length s) 140) (substring s 0 140) s))

(define (canvas-overview--theme)
  (list 'dark (and (ignore-errors (lambda () (theme-dark?))) #t)
        'bg (or (ignore-errors (lambda () (face-color 'default 'bg))) "#141519")
        'fg (or (ignore-errors (lambda () (face-color 'default 'fg))) "#e6e7ec")
        'dim (or (ignore-errors (lambda () (face-color 'dim 'fg))) "#8b90a0")
        'accent (or (ignore-errors (lambda () (face-color 'accent 'fg))) "#6ba4ff")
        'modeBg (or (ignore-errors (lambda () (face-color 'mode-line 'bg))) "#1f222a")
        'modeFg (or (ignore-errors (lambda () (face-color 'mode-line 'fg))) "#cfd3df")
        'keyword (or (ignore-errors (lambda () (face-color 'keyword 'fg))) "#c594c5")
        'string (or (ignore-errors (lambda () (face-color 'string 'fg))) "#99c794")
        'comment (or (ignore-errors (lambda () (face-color 'comment 'fg))) "#727786")))

(define (canvas-overview--chat-text buf)
  (let* ((log (or (ignore-errors (lambda ()
                    (filter (lambda (e) (equal? (cadr e) 'summary))
                            (or (buffer-summary-log-entries buf) '()))))
                  '()))
         (summary (if (pair? log) (caddr (car (reverse log))) ""))
         (reply (or (ignore-errors (lambda () (subagent-last-assistant buf))) ""))
         (body (if (> (string-length reply) 0)
                   reply
                   (or (ignore-errors (lambda ()
                         (with-current-buffer buf
                           (lambda ()
                             (let* ((end-line (line-number-at-pos (buffer-size buf)))
                                    (start-line (max 1 (- end-line *canvas-overview-lines*))))
                               (buffer-substring (line-start-position start-line)
                                                 (line-start-position (+ end-line 1))))))))
                       "")))
         (lines (string-split body "\n"))
         (n (length lines))
         (tail (if (> n *canvas-overview-lines*)
                   (list-tail lines (- n *canvas-overview-lines*))
                   lines))
         (clipped (string-join (map canvas-overview--clip-line tail) "\n")))
    (if (and (> (string-length summary) 0) (> (string-length clipped) 0))
        (string-append "[summary] " summary "\n---\n" clipped)
        (if (> (string-length clipped) 0) clipped summary))))

(define (canvas-overview--buffer-preview buf pos)
  "Read a compact preview plist for BUF around byte POS."
  (if (not (and (string? buf) (buffer-known? buf)))
      (list 'name (or buf "") 'shortName (canvas-overview--short-name buf)
            'mode "" 'shortMode "empty" 'modified #f 'firstLine 1 'pointLine 1
            'totalLines 0 'bytes 0 'text "" 'ts (monotonic-ms))
      (let* ((mode (or (buffer-local-value 'mode-name buf) "fundamental-mode"))
             (short-mode (canvas-overview--short-mode mode))
             (mod (and (ignore-errors (lambda () (buffer-modified? buf))) #t))
             (bytes (or (ignore-errors (lambda () (buffer-size buf))) 0))
             (is-chat (equal? mode "chat-mode")))
        (if is-chat
            (let* ((txt (canvas-overview--chat-text buf))
                   (pt (or (ignore-errors (lambda () (with-current-buffer buf (lambda () (line-number-at-pos (or pos (buffer-point buf))))))) 1))
                   (tot (or (ignore-errors (lambda () (with-current-buffer buf (lambda () (line-number-at-pos bytes))))) pt)))
              (list 'name buf 'shortName (canvas-overview--short-name buf)
                    'mode mode 'shortMode short-mode 'modified mod
                    'firstLine (max 1 (- tot *canvas-overview-lines*))
                    'pointLine pt 'totalLines tot 'bytes bytes
                    'kind "chat" 'text txt 'ts (monotonic-ms)))
            (let ((info (or (ignore-errors
                              (lambda ()
                                (with-current-buffer buf
                                  (lambda ()
                                    (let* ((pt-pos (or pos (buffer-point buf)))
                                           (line (line-number-at-pos pt-pos))
                                           (tot (line-number-at-pos (buffer-size buf)))
                                           (first (max 1 (- line 3)))
                                           (raw (buffer-substring (line-start-position first)
                                                                  (line-start-position (+ first *canvas-overview-lines*))))
                                           (clipped (string-join (map canvas-overview--clip-line (string-split raw "\n")) "\n")))
                                      (list first line tot clipped))))))
                            (list 1 1 0 ""))))
              (list 'name buf 'shortName (canvas-overview--short-name buf)
                    'mode mode 'shortMode short-mode 'modified mod
                    'firstLine (car info) 'pointLine (cadr info)
                    'totalLines (caddr info) 'bytes bytes
                    'kind (or (buffer-local-value 'render-mode buf) "text")
                    'text (cadddr info) 'ts (monotonic-ms)))))))

(define (canvas-overview--group-color g members)
  (or (ignore-errors
        (lambda ()
          (let ((b (find (lambda (m) (buffer-tab-color m)) members)))
            (and b (group-color-hex (buffer-tab-color b))))))
      #f))

(define (canvas-overview--window-data l k idx active-win)
  (let* ((buf (panes-window-buffer l k))
         (bufs (or (panes-window-buffers l k) '()))
         (h (panes-handle l k))
         (live? (and buf h (window-exists? h) (equal? (window-buffer h) buf)))
         (pos (if live? (window-point h) (panes-window-point l k)))
         (mode (or (panes-window-mode l k)
                   (and buf (buffer-known? buf) (buffer-local-value 'mode-name buf))
                   "fundamental-mode"))
         (preview (if (= idx 0)
                      (canvas-overview--buffer-preview buf pos)
                      ;; Stacked windows still send a real preview so opening a stack is instant.
                      (canvas-overview--buffer-preview buf pos))))
    (list 'key k
          'index idx
          'front (= idx 0)
          'live (and live? #t)
          'selected (and live? (equal? h active-win))
          'mode mode
          'shortMode (canvas-overview--short-mode mode)
          'buffer (or buf "")
          'shortName (canvas-overview--short-name buf)
          'buffers bufs
          'bufferCount (length bufs)
          'point (or pos 0)
          'preview preview)))

(define (canvas-overview--pane-data l pane focus-id active-win)
  (let* ((pid (plist-get pane 'id))
         (share (or (plist-get pane 'share) 1))
         (keys (or (panes-pane-keys l pid) '()))
         (wins (let loop ((ks keys) (i 0) (acc '()))
                 (if (null? ks)
                     (reverse acc)
                     (loop (cdr ks) (+ i 1)
                           (cons (canvas-overview--window-data l (car ks) i active-win) acc))))))
    (list 'id pid
          'share share
          'focused (equal? pid focus-id)
          'windowCount (length wins)
          'windows wins)))

(define (canvas-overview--group-data g active-g active-win all-bufs)
  (let* ((l (if (equal? g active-g)
                (or (panes-layout) (panes-layout-of g) (panes-adopt))
                (panes-layout-of g)))
         (members (filter (lambda (b)
                            (and (not (canvas-overview--internal? b))
                                 (equal? (buffer-group b) g)))
                          all-bufs))
         (focus-id (and l (panes-focus l)))
         (cols (if l
                   (map (lambda (col)
                          (map (lambda (p) (canvas-overview--pane-data l p focus-id active-win)) col))
                        (panes-columns l))
                   '()))
         (in-wins (if l
                      (apply append
                             (map (lambda (k) (or (panes-window-buffers l k) '()))
                                  (or (panes-window-keys l) '())))
                      '()))
         (unshown-all (filter (lambda (b) (not (member b in-wins))) members))
         (unshown-head (if (> (length unshown-all) *canvas-overview-max-unshown*)
                           (list-head unshown-all *canvas-overview-max-unshown*)
                           unshown-all))
         (unshown (map (lambda (b)
                         (let ((m (or (buffer-local-value 'mode-name b) "fundamental-mode")))
                           (list 'name b
                                 'shortName (canvas-overview--short-name b)
                                 'mode m
                                 'shortMode (canvas-overview--short-mode m)
                                 'modified (and (ignore-errors (lambda () (buffer-modified? b))) #t)
                                 'bytes (or (ignore-errors (lambda () (buffer-size b))) 0))))
                       unshown-head))
         (layout-sym (and l (plist-get l 'layout))))
    (list 'id g
          'name (or (ignore-errors (lambda () (group-name g))) g)
          'active (equal? g active-g)
          'color (canvas-overview--group-color g members)
          'layoutName (if (symbol? layout-sym) (symbol->string layout-sym) (or layout-sym "free"))
          'focusPane (or focus-id "")
          'hiddenPaneCount (if l (length (or (panes-hidden l) '())) 0)
          'memberCount (length members)
          'columns cols
          'unshownBuffers unshown
          'unshownTotal (length unshown-all))))

(define (canvas-overview-snapshot)
  "Return the current spatial snapshot plist of groups, panes, window stacks, and buffers."
  (set! *canvas-overview-rev* (+ *canvas-overview-rev* 1))
  (let* ((active-g (frame-group))
         (active-win (active-window))
         (all-bufs (buffer-list))
         (mru (or (ignore-errors (lambda () (group-ids-mru-all))) '()))
         (ordered (if (and active-g (not (member active-g mru)))
                      (cons active-g mru)
                      (if active-g
                          (cons active-g (filter (lambda (x) (not (equal? x active-g))) mru))
                          mru)))
         (groups (map (lambda (g) (canvas-overview--group-data g active-g active-win all-bufs)) ordered)))
    (list 'rev *canvas-overview-rev*
          'ts (monotonic-ms)
          'activeGroup (or active-g "")
          'activeBuffer (or (and active-win (window-buffer active-win)) "")
          'demoRunning (and *canvas-overview-demo-on* #t)
          'theme (canvas-overview--theme)
          'groups groups)))
(public! 'canvas-overview-snapshot
  "(canvas-overview-snapshot) -- spatial snapshot plist of all groups, panes, window stacks, and buffers")

;;; Live buffer watches and debounced pushes

(effects! '(write))

(define (canvas-overview--unwatch-all!)
  (for-each (lambda (pair)
              (ignore-errors (lambda () (remove-on-change! (cdr pair)))))
            *canvas-overview-watches*)
  (set! *canvas-overview-watches* '())
  (set! *canvas-overview-dirty* '())
  (ignore-errors (lambda () (debounce-cancel! 'canvas-overview-bufs)))
  (ignore-errors (lambda () (debounce-cancel! 'canvas-overview-layout))))

(define (canvas-overview--mark-dirty! buf)
  (when (and (canvas-overview--visible?) (string? buf))
    (unless (member buf *canvas-overview-dirty*)
      (set! *canvas-overview-dirty* (cons buf *canvas-overview-dirty*)))
    (debounce! 'canvas-overview-bufs 120 canvas-overview--flush-dirty! #f)))

(define (canvas-overview--flush-dirty! _)
  (when (and (canvas-overview--visible?) (pair? *canvas-overview-dirty*))
    (let* ((batch (reverse *canvas-overview-dirty*)))
      (set! *canvas-overview-dirty* '())
      (let ((updates (map (lambda (b) (canvas-overview--buffer-preview b #f))
                          (filter buffer-known? batch))))
        (when (pair? updates)
          (app-post! *canvas-overview-buffer*
                     (list 'type "buffers"
                           'ts (monotonic-ms)
                           'buffers updates)))))))

(define (canvas-overview--default-watch-buffers)
  (let* ((g (frame-group))
         (l (and g (or (panes-layout) (panes-layout-of g))))
         (win-bufs (if l
                       (filter string?
                               (map (lambda (k) (panes-window-buffer l k))
                                    (or (panes-window-keys l) '())))
                       '())))
    (let loop ((xs (append win-bufs *canvas-overview-extra-watch*)) (acc '()))
      (cond ((null? xs) (reverse acc))
            ((or (not (string? (car xs)))
                 (canvas-overview--internal? (car xs))
                 (not (buffer-known? (car xs)))
                 (member (car xs) acc))
             (loop (cdr xs) acc))
            (else (loop (cdr xs) (cons (car xs) acc)))))))

(define (canvas-overview--sync-watches! &optional extra)
  (when (list? extra) (set! *canvas-overview-extra-watch* extra))
  (let ((want (canvas-overview--default-watch-buffers)))
    ;; Remove watches for buffers no longer needed.
    (for-each (lambda (pair)
                (unless (member (car pair) want)
                  (ignore-errors (lambda () (remove-on-change! (cdr pair))))
                  (set! *canvas-overview-watches* (alist-delete *canvas-overview-watches* (car pair)))))
              *canvas-overview-watches*)
    ;; Add eager watches for newly tracked buffers so stacked and hidden windows stream live.
    (for-each (lambda (b)
                (unless (assoc b *canvas-overview-watches*)
                  (let ((id (ignore-errors
                              (lambda ()
                                (on-change! b
                                  (lambda (pos ins del src) (canvas-overview--mark-dirty! b))
                                  'eager)))))
                    (when id
                      (set! *canvas-overview-watches* (alist-put *canvas-overview-watches* b id))))))
              want)
    want))

(define (canvas-overview--push-layout! _)
  (when (canvas-overview--visible?)
    (canvas-overview--sync-watches!)
    (app-post! *canvas-overview-buffer*
               (list 'type "snapshot" 'snapshot (canvas-overview-snapshot)))))

(define (canvas-overview--on-window-change!)
  (when (canvas-overview--visible?)
    (debounce! 'canvas-overview-layout 100 canvas-overview--push-layout! #f)))

(add-hook! 'window-state-change-hook 'canvas-overview--on-window-change!)

;;; Optional live-pulse spike demo buffer (only runs while toggled on by user)

(define (canvas-overview--demo-stop!)
  (set! *canvas-overview-demo-on* #f)
  (ignore-errors (lambda () (debounce-cancel! 'canvas-overview-demo)))
  (when (buffer-known? *canvas-overview-demo-buf*)
    (ignore-errors (lambda () (buffer-kill! *canvas-overview-demo-buf*)))))

(define (canvas-overview--demo-step! _)
  (when (and *canvas-overview-demo-on* (canvas-overview--visible?))
    (set! *canvas-overview-demo-seq* (+ *canvas-overview-demo-seq* 1))
    (let* ((n *canvas-overview-demo-seq*)
           (bar-len (+ 4 (modulo (* n 7) 24)))
           (bar (let loop ((i 0) (acc "")) (if (>= i bar-len) acc (loop (+ i 1) (string-append acc "#"))))))
      (unless (buffer-known? *canvas-overview-demo-buf*)
        (buffer-create *canvas-overview-demo-buf*)
        (let ((g (frame-group)))
          (when g (buffer-move-to-group! *canvas-overview-demo-buf* g))))
      (buffer-append! *canvas-overview-demo-buf*
                      (string-append "tick " (number->string n) "  [" bar "]  "
                                     (number->string (monotonic-ms)) "ms\n"))
      (canvas-overview--sync-watches! (if (member *canvas-overview-demo-buf* *canvas-overview-extra-watch*)
                                          *canvas-overview-extra-watch*
                                          (cons *canvas-overview-demo-buf* *canvas-overview-extra-watch*)))
      (debounce! 'canvas-overview-demo 450 canvas-overview--demo-step! #f))))

(define (canvas-overview--demo-toggle! start?)
  (if start?
      (begin
        (set! *canvas-overview-demo-on* #t)
        (set! *canvas-overview-demo-seq* 0)
        (unless (buffer-known? *canvas-overview-demo-buf*)
          (buffer-create *canvas-overview-demo-buf*))
        (let ((g (frame-group)))
          (when g (buffer-move-to-group! *canvas-overview-demo-buf* g)))
        (buffer-replace! *canvas-overview-demo-buf* (buffer-text *canvas-overview-demo-buf*)
                         ";; Live pulse buffer for canvas-overview spike\n")
        ;; Put the pulse buffer into the first pane stack behind its front window so the user can fan it open.
        (let* ((l (or (panes-layout) (panes-adopt)))
               (pids (and l (panes-pane-ids l))))
          (when (and l (pair? pids)
                     (not (find (lambda (k) (equal? (panes-window-buffer l k) *canvas-overview-demo-buf*))
                                (or (panes-window-keys l) '()))))
            (let ((made (panes-add-window l (car pids) *canvas-overview-demo-buf* "fundamental-mode" #t)))
              (panes-apply! (car made)))))
        (canvas-overview--demo-step! #f))
      (canvas-overview--demo-stop!)))

(define (canvas-overview--on-kill! buf)
  (when (equal? buf *canvas-overview-buffer*)
    (canvas-overview--demo-stop!)
    (canvas-overview--unwatch-all!)
    (set! *canvas-overview-extra-watch* '())))

(add-hook! 'kill-buffer-hook 'canvas-overview--on-kill!)

;;; App bridge actions

(define (canvas-overview--focus-target! group key buf)
  (when (and (string? group) (> (string-length group) 0)
             (not (equal? group (frame-group))))
    (ignore-errors (lambda () (switch-to-group! group))))
  (let* ((l (or (panes-layout) (panes-adopt)))
         (num-key (if (string? key) (or (string->number key) key) key)))
    (cond ((and l num-key (panes-window l num-key))
           (let* ((next (if (and (string? buf) (> (string-length buf) 0) (buffer-known? buf))
                            (panes-show (panes-focus-window l num-key) num-key buf)
                            (panes-focus-window l num-key)))
                  (applied (panes-apply! next))
                  (h (panes-handle applied num-key)))
             (when (and h (window-exists? h)) (select-window! h))))
          ((and (string? buf) (buffer-known? buf))
           (display-buffer-other-window! buf)))))

(define (canvas-overview--app-request buf method body)
  (and (equal? buf *canvas-overview-buffer*)
       (let* ((o (if (equal? method "POST") (or (ignore-errors (lambda () (json-parse body))) '()) '()))
              (op (plist-get o 'op)))
         (cond
           ((equal? op "watch")
            (let* ((bs (or (plist-get o 'buffers) '()))
                   (watched (canvas-overview--sync-watches! bs))
                   (previews (map (lambda (b) (canvas-overview--buffer-preview b #f))
                                  (filter buffer-known? bs))))
              (list 200 (json-encode (list 'ok #t 'watched watched 'buffers previews)))))
           ((equal? op "preview")
            (let* ((bs (or (plist-get o 'buffers) '()))
                   (previews (map (lambda (b) (canvas-overview--buffer-preview b #f))
                                  (filter buffer-known? bs))))
              (list 200 (json-encode (list 'ok #t 'buffers previews)))))
           ((equal? op "focus")
            (canvas-overview--focus-target! (plist-get o 'group) (plist-get o 'key) (plist-get o 'buffer))
            (list 200 (json-encode (list 'ok #t 'snapshot (canvas-overview-snapshot)))))
           ((equal? op "demo")
            (canvas-overview--demo-toggle! (and (plist-get o 'start) #t))
            (list 200 (json-encode (list 'ok #t 'demoRunning (and *canvas-overview-demo-on* #t)
                                         'snapshot (canvas-overview-snapshot)))))
           ((equal? op "quit")
            (canvas-overview-quit!)
            (list 200 (json-encode (list 'ok #t))))
           (else
            (canvas-overview--sync-watches!)
            (list 200 (json-encode (canvas-overview-snapshot))))))))

(add-hook! '(app-request canvas-overview) 'canvas-overview--app-request)

;;; Mode and commands

(domain! 'windows)
(effects! '(write display))

(define (canvas-overview--fill! name)
  (let ((cur (buffer-text name)))
    (unless (equal? cur canvas-overview--html)
      (buffer-replace! name cur canvas-overview--html))))

(define-mode "canvas-overview-mode"
  (lambda ()
    (let ((name (current-buffer)))
      (buffer-set-local! name 'app-directory (list (canvas-overview--own-dir)))
      (canvas-overview--fill! name)
      (buffer-set-local! name 'render-mode "app"))))

(mode-doc! "canvas-overview-mode"
  "Spatial HTML-in-Canvas overview of all groups, panes, window stacks, and buffers. Pan and zoom across the canvas, expand any pane stack to watch its windows live-update, and jump straight to any window or buffer.")

(define (canvas-overview-quit!)
  "Close the canvas overview window and release its watches."
  (canvas-overview--demo-stop!)
  (canvas-overview--unwatch-all!)
  (let ((win (find (lambda (w) (equal? (cadr w) *canvas-overview-buffer*)) (window-list))))
    (when win
      (let ((prev (active-window)))
        (select-window! (car win))
        (quit-window)
        (when (and prev (window-exists? prev) (not (equal? prev (car win))))
          (select-window! prev))))))

(define-command "canvas-overview-quit" "Close the spatial canvas overview"
  (lambda () (canvas-overview-quit!))
  'modes '(canvas-overview-mode))

(define-command "canvas-overview-refresh" "Refresh the spatial canvas overview"
  (lambda ()
    (when (buffer-known? *canvas-overview-buffer*)
      (canvas-overview--sync-watches!)
      (app-post! *canvas-overview-buffer*
                 (list 'type "snapshot" 'snapshot (canvas-overview-snapshot)))))
  'modes '(canvas-overview-mode))

(mode-quit! "canvas-overview-mode" (lambda (_) (canvas-overview-quit!) #t))

(mode-keys! "canvas-overview-mode"
  '(("q" "canvas-overview-quit")
    ("g" "canvas-overview-refresh")))

;;;###autoload
(define-command "canvas-overview"
  "Open the spatial HTML-in-Canvas overview of groups, panes, window stacks, and buffers"
  (lambda ()
    (let ((name *canvas-overview-buffer*))
      (unless (buffer-known? name) (buffer-create name))
      (let ((g (frame-group)))
        (when (and g (not (equal? (buffer-group name) g)))
          (buffer-move-to-group! name g)))
      (unless (equal? (buffer-local-value 'mode-name name) "canvas-overview-mode")
        (with-current-buffer name (lambda () (set-mode! "canvas-overview-mode"))))
      (buffer-set-local! name 'app-directory (list (canvas-overview--own-dir)))
      (canvas-overview--fill! name)
      (app-reload! name)
      (buffer-set-local! name 'render-mode "app")
      (canvas-overview--sync-watches!)
      (display-buffer-other-window! name)
      name)))

(provide 'canvas-overview)
