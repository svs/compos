;;; pane-overview.scm --- every window of a pane at a glance, in the pane
;;; itself. M-x pane-overview puts a page of tiles at the front of the
;;; pane: one tile for each of its windows, with its buffer, its mode and
;;; the lines around its point. RET, a click or a digit brings that window
;;; to the front; q leaves the pane as it was. The tiles are text read once
;;; from the buffers: no window draws for them.

(require 'panes-mode)

(domain! 'windows)
(effects! '(read))

(define pane-overview-lines 14)

(define (pane-overview--buffer pid) (string-append "*pane overview " pid "*"))

(define (pane-overview--of? buf)
  (and (string? buf) (string-prefix? "*pane overview " buf)))

(define (pane-overview--preview buf pos)
  "The lines of BUF from a few above byte POS, its point when POS is #f,
   each one cut to fit a tile; the empty string when BUF cannot be read."
  (or (ignore-errors
        (lambda ()
          (with-current-buffer buf
            (lambda ()
              (let* ((line (line-number-at-pos (or pos (buffer-point buf))))
                     (first (max 1 (- line 3)))
                     (text (buffer-substring (line-start-position first)
                                             (line-start-position (+ first pane-overview-lines)))))
                (string-join (map (lambda (s) (if (> (string-length s) 160) (substring s 0 160) s))
                                  (string-split text "\n"))
                             "\n"))))))
      ""))

(define (pane-overview--chat-preview buf)
  "A chat as a tile: its newest running summary, then the opening lines
   of its last reply."
  (let* ((log (filter (lambda (e) (equal? (cadr e) 'summary)) (or (buffer-summary-log-entries buf) '())))
         (summary (if (pair? log) (caddr (car (reverse log))) ""))
         (reply (or (subagent-last-assistant buf) ""))
         (lines (string-split reply "\n"))
         (head (string-join (list-head lines (min (length lines) pane-overview-lines)) "\n")))
    (string-append summary (if (and (> (string-length summary) 0) (> (string-length head) 0)) "\n\n" "") head)))

(define pane-overview-previews
  (list (list "chat-mode" pane-overview--chat-preview)))

(define (pane-overview--tile l k)
  "(KEY BUFFER MODE COUNT TEXT) for window K of L: what it shows and the
   lines around its point, the live point when it is on screen."
  (let* ((buf (panes-window-buffer l k))
         (h (panes-handle l k))
         (pos (if (and buf h (window-exists? h) (equal? (window-buffer h) buf))
                  (window-point h)
                  (panes-window-point l k)))
         (mode (or (panes-window-mode l k) ""))
         (short (if (string-suffix? "-mode" mode) (substring mode 0 (- (string-length mode) 5)) mode)))
    (list k (cond ((not buf) "empty window") ((string-prefix? "/" buf) (file-name-nondirectory buf)) (else buf)) short (length (panes-window-buffers l k))
          (let ((own (assoc mode pane-overview-previews)))
            (cond ((not (and buf (buffer-known? buf))) "")
                  (own (or (ignore-errors (lambda () ((cadr own) buf))) ""))
                  (else (pane-overview--preview buf pos)))))))

(define (pane-overview--columns n)
  "Tiles in a row: the side of the smallest square grid that holds N,
   six at most."
  (let loop ((c 1)) (if (or (>= (* c c) n) (>= c 6)) c (loop (+ c 1)))))

(define (pane-overview--blocks tiles sel)
  "The page as blocks: a title over a grid of TILES, SEL marked. A click
   on a tile is pov:INDEX."
  (list
    (list 'tag "div" 'class "pane-overview"
          'children
          (list (list 'tag "div" 'class "pane-overview-title"
                      'text (string-append (number->string (length tiles)) " windows in this pane"))
                (list 'tag "div"
                      'class (string-append "pane-overview-grid pane-overview-cols-"
                                            (number->string (pane-overview--columns (length tiles))))
                      'children
                      (let loop ((ts tiles) (i 0) (acc '()))
                        (if (null? ts)
                            (reverse acc)
                            (let ((t (car ts)))
                              (loop (cdr ts) (+ i 1)
                                    (cons (list 'tag "div"
                                                'class (if (= i sel) "pane-overview-tile selected" "pane-overview-tile")
                                                'click (string-append "pov:" (number->string i))
                                                'children
                                                (list (list 'tag "div" 'class "pane-overview-head"
                                                            'children
                                                            (list (list 'tag "span" 'class "pane-overview-n"
                                                                        'text (if (< i 9) (number->string (+ i 1)) ""))
                                                                  (list 'tag "span" 'class "pane-overview-name" 'text (cadr t))
                                                                  (list 'tag "span" 'class "pane-overview-mode" 'text (caddr t))))
                                                      (list 'tag "pre" 'class "pane-overview-text" 'text (list-ref t 4))))
                                          acc))))))))))

(define (pane-overview--render! buf)
  "Writes BUF from its tiles: the blocks, and for a client that draws
   text one line for each window, the selected one marked."
  (let* ((tiles (or (buffer-local buf 'pane-overview-tiles) '()))
         (sel (or (buffer-local buf 'pane-overview-sel) 0))
         (rows (let loop ((ts tiles) (i 0) (acc '()))
                 (if (null? ts)
                     (reverse acc)
                     (loop (cdr ts) (+ i 1)
                           (cons (string-append (if (= i sel) " > " "   ") (number->string (+ i 1)) "  "
                                                (cadr (car ts)) "  " (caddr (car ts)) "\n")
                                 acc))))))
    (buffer-set-local! buf 'render-blocks (pane-overview--blocks tiles sel))
    (buffer-set-local! buf 'render-mode "blocks")
    (buffer-set-text! buf (apply string-append (cons "\n   Windows in this pane\n\n" rows)) #t)))

(effects! '(write display))

(define (pane-overview--here)
  "The overview buffer the command runs in, or #f."
  (let ((b (current-buffer))) (and (pane-overview--of? b) b)))

(define (pane-overview--leave! buf key)
  "BUF's window leaves its pane, window KEY comes to the front of its
   pane with the focus, and BUF dies. A KEY the model no longer holds
   leaves the pane on the window that was in front before."
  (let* ((l (panes-layout))
         (ov (and l (find (lambda (k) (equal? (panes-window-buffer l k) buf)) (panes-window-keys l))))
         (l (if (and l ov) (panes-remove-window l ov) l)))
    (when l
      (panes-apply! (if (and key (panes-window l key)) (panes-focus-window l key) l)))
    (buffer-kill! buf)))

(define (pane-overview--pick! i)
  (let* ((buf (pane-overview--here))
         (tiles (and buf (buffer-local buf 'pane-overview-tiles))))
    (when (and tiles (>= i 0) (< i (length tiles)))
      (pane-overview--leave! buf (car (list-ref tiles i))))))

(define (pane-overview--step! d)
  (let* ((buf (pane-overview--here))
         (n (if buf (length (or (buffer-local buf 'pane-overview-tiles) '())) 0)))
    (when (> n 0)
      (buffer-set-local! buf 'pane-overview-sel
                         (modulo (+ (or (buffer-local buf 'pane-overview-sel) 0) d) n))
      (pane-overview--render! buf))))

(define (pane-overview--row)
  "The tiles in a row of the overview at hand."
  (let ((buf (pane-overview--here)))
    (pane-overview--columns (if buf (length (or (buffer-local buf 'pane-overview-tiles) '())) 1))))

(define-mode "pane-overview-mode"
  (lambda () #t))

(define-command "pane-overview"
  "Show every window of this pane as a tile in the pane; pick one to bring it to the front"
  (lambda ()
    (let* ((l (panes--ensure-layout!))
           (pid (panes--current-pane l))
           (all (if pid (panes-pane-keys l pid) '()))
           (keys (filter (lambda (k) (not (pane-overview--of? (panes-window-buffer l k)))) all)))
      (cond ((not pid) (message "Not in a pane"))
            ((< (length keys) 2) (message "Only one window in this pane"))
            (else
              (let* ((buf (pane-overview--buffer pid))
                     (tiles (map (lambda (k) (pane-overview--tile l k)) keys))
                     (old (find (lambda (k) (equal? (panes-window-buffer l k) buf)) all)))
                (unless (buffer-exists? buf) (buffer-create buf))
                (unless (equal? (buffer-local buf 'mode-name) "pane-overview-mode")
                  (with-current-buffer buf (lambda () (set-mode! "pane-overview-mode"))))
                (buffer-set-local! buf 'pane-overview-tiles tiles)
                (buffer-set-local! buf 'pane-overview-sel 0)
                (pane-overview--render! buf)
                (panes-apply!
                  (if old
                      (panes-focus-window l old)
                      (let ((made (panes-add-window l pid buf "pane-overview-mode")))
                        (panes-focus-window (car made) (cadr made)))))))))))

(define-command "pane-overview-pick" "Bring the window of the selected tile to the front"
  (lambda ()
    (let ((buf (pane-overview--here)))
      (when buf (pane-overview--pick! (or (buffer-local buf 'pane-overview-sel) 0))))))

(define-command "pane-overview-quit" "Leave the overview; the pane shows what it showed before"
  (lambda ()
    (let* ((buf (pane-overview--here))
           (tiles (and buf (buffer-local buf 'pane-overview-tiles))))
      (when buf (pane-overview--leave! buf (and (pair? tiles) (car (car tiles))))))))

(define-command "pane-overview-next" "Select the next tile" (lambda () (pane-overview--step! 1)))
(define-command "pane-overview-previous" "Select the previous tile" (lambda () (pane-overview--step! -1)))
(define-command "pane-overview-down" "Select the tile below" (lambda () (pane-overview--step! (pane-overview--row))))
(define-command "pane-overview-up" "Select the tile above" (lambda () (pane-overview--step! (- (pane-overview--row)))))

(for-each
  (lambda (n)
    (define-command (string-append "pane-overview-pick-" (number->string n))
      (string-append "Bring the window of tile " (number->string n) " to the front")
      (lambda () (pane-overview--pick! (- n 1)))))
  '(1 2 3 4 5 6 7 8 9))

(mode-keys! "pane-overview-mode"
  (append '(("RET" "pane-overview-pick") ("q" "pane-overview-quit") ("ESC" "pane-overview-quit")
            ("C-g" "pane-overview-quit") ("g" "pane-overview")
            ("<right>" "pane-overview-next") ("<left>" "pane-overview-previous")
            ("<down>" "pane-overview-down") ("<up>" "pane-overview-up")
            ("n" "pane-overview-next") ("p" "pane-overview-previous")
            ("TAB" "pane-overview-next") ("S-TAB" "pane-overview-previous"))
          (map (lambda (n) (list (number->string n) (string-append "pane-overview-pick-" (number->string n))))
               '(1 2 3 4 5 6 7 8 9))))

;; a click on a tile brings its window to the front
(add-hook! (list 'block-click 'pane-overview)
  (lambda (buf id)
    (and (pane-overview--of? buf)
         (string-prefix? "pov:" id)
         (begin
           (with-current-buffer buf
             (lambda () (pane-overview--pick! (string->number (substring id 4 (string-length id))))))
           #t))))

(define-style! 'pane-overview "
.pane-overview { padding: 14px; }
.pane-overview-title { color: var(--dim-fg); font-size: 0.9em; margin: 0 0 10px 2px; }
.pane-overview-grid { display: grid; gap: 10px; }
.pane-overview-cols-1 { grid-template-columns: minmax(0, 1fr); }
.pane-overview-cols-2 { grid-template-columns: repeat(2, minmax(0, 1fr)); }
.pane-overview-cols-3 { grid-template-columns: repeat(3, minmax(0, 1fr)); }
.pane-overview-cols-4 { grid-template-columns: repeat(4, minmax(0, 1fr)); }
.pane-overview-cols-5 { grid-template-columns: repeat(5, minmax(0, 1fr)); }
.pane-overview-cols-6 { grid-template-columns: repeat(6, minmax(0, 1fr)); }
.pane-overview-tile { min-width: 0; border: 1px solid color-mix(in srgb, var(--dim-fg) 35%, transparent);
  border-radius: 8px; overflow: hidden; cursor: pointer; }
.pane-overview-tile:hover { border-color: var(--dim-fg); }
.pane-overview-tile.selected { border-color: var(--accent-fg); box-shadow: 0 0 0 1px var(--accent-fg); }
.pane-overview-head { display: flex; gap: 8px; align-items: baseline; padding: 6px 8px;
  border-bottom: 1px solid color-mix(in srgb, var(--dim-fg) 20%, transparent); }
.pane-overview-n { font-family: var(--font-mono); color: var(--accent-fg); font-weight: 600; }
.pane-overview-name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 600; }
.pane-overview-mode { color: var(--dim-fg); font-size: 0.85em; white-space: nowrap; }
.pane-overview-text { margin: 0; padding: 6px 8px; font-family: var(--font-mono); font-size: 0.7em;
  line-height: 1.35; height: 18.9em; overflow: hidden; white-space: pre; color: var(--dim-fg); }
")

(provide 'pane-overview)
