;;; detail.scm --- a list opens its rows into one window, and keeps it.
;;;
;;; Every table whose rows are their own buffer needs the same thing:
;;; Sentry issues, WhatsApp chats, MCP servers, Google items. RET on a row
;;; shows that row's buffer beside the list, and the NEXT row takes the
;;; same window. Each row is a new buffer name, so display-buffer's
;;; reuse-window never matches: without this the layout grows a pane per
;;; row, or the row has to be a peek to stay in one place.
;;;
;;; A detail is not a peek. It is kept, it is writable, and it stays when
;;; the list goes. Three things make it:
;;;
;;;   THE WINDOW IS REMEMBERED, per list, the way a peek remembers its own
;;;     (docs/PEEK.md). The first row picks one through the display chain
;;;     as category detail; every row after it retakes that window. This is
;;;     the one place a window is remembered rather than chosen at display
;;;     time, and the memory lapses on its own.
;;;   THE LIST OWNS WHAT IT OPENED: the detail is the list's child
;;;     (dismiss.scm), so q on the list takes the detail with it, and the
;;;     details opened from one list are each other's siblings.
;;;   C-` WALKS THE SIBLINGS in the detail window, most recent first. Three
;;;     rows opened is three buffers to flip through without going back to
;;;     the list. It is chat-mode's key doing chat-mode's job for any list.
;;;
;;; A list that rewrites ONE detail buffer per row (notmuch's *mail*, the
;;; telemetry event) needs none of this: reuse-window already finds the
;;; name. Such a list may still call display-buffer-detail! for the window,
;;; and the walk then has one buffer and says so.

(domain! 'windows)
(effects! '(read))

(define *detail-windows* '())   ;; ((OWNER WINDOW) ...)

;; the window the list OWNER opens its rows into, while it is still one to
;; use: a live work window, not the asking window, and not holding the list
(define (detail-window &optional owner)
  (let* ((o (or owner (window-buffer (active-window))))
         (hit (assoc o *detail-windows*))
         (win (and hit (cadr hit))))
    (and win
         (member win (display--work-windows))
         (not (equal? win (active-window)))
         (not (equal? (window-buffer win) o))
         win)))

;; the list this detail was opened from, or #f. A kept detail is nobody's
;; child any more, and still says which list it came from, so the walk keeps
;; reaching it.
;; The page beside the list you are in reads with you: it keeps the colours
;; of the selected window instead of stepping down as an inactive one, so
;; surfing from the list does not show the page muted.
(define *detail-live* #f)

(define (detail--classes buf)
  (filter (lambda (c) (not (equal? c ""))) (string-split (or (buffer-local buf 'window-class) "") " ")))

(define (detail--set-live! buf on?)
  (when (and buf (buffer-exists? buf))
    (let* ((cs (filter (lambda (c) (not (equal? c "detail-live"))) (detail--classes buf)))
           (cs (if on? (append cs (list "detail-live")) cs)))
      (buffer-set-local! buf 'window-class (if (null? cs) #f (string-join cs " "))))))

(define (detail--beside owner)
  ;; the page on screen that OWNER, the selected window's buffer, opened
  (let loop ((ws (window-list)))
    (cond ((null? ws) #f)
          ((and (not (equal? (car (car ws)) (active-window)))
                (equal? (buffer-local (cadr (car ws)) 'detail-of) owner))
           (cadr (car ws)))
          (else (loop (cdr ws))))))

(define (detail--sync-live!)
  (let* ((owner (window-buffer (active-window)))
         (buf (and owner (detail--beside owner))))
    (unless (equal? buf *detail-live*)
      (detail--set-live! *detail-live* #f)
      (detail--set-live! buf #t)
      (set! *detail-live* buf))))

(add-hook! 'post-command-hook 'detail--sync-live!)

(define-style! 'detail "
.window.inactive.detail-live {
  --text-strong: inherit; --text-body: inherit; --text-soft: inherit; --text-faint: inherit; --text-dim: inherit;
  --accent: inherit; --accent-wash: inherit; --ok: inherit; --warn: inherit; --edge: inherit;
  --surface-pane: var(--paper-bg, #efeadf); --surface-sunken: inherit; --surface-chrome: var(--paper-bg, #efeadf); --surface-select: inherit;
}
")

(define (detail-owner &optional buf)
  (let* ((b (or buf (current-buffer)))
         (of (and (buffer-known? b) (buffer-local b 'detail-of))))
    (or (and of (buffer-known? of) of)
        (buffer-parent b))))

;; the walk order: this buffer, then the other details of the same list,
;; most recently used first. Open buffers only, exactly as a chat pane walks.
(define (detail-ring)
  (let* ((buf (current-buffer))
         (owner (detail-owner buf))
         (open (buffer-list)))
    (cons buf
          (if (not owner)
              '()
              (filter (lambda (b) (and (member b open)
                                       (not (equal? b buf))
                                       (equal? (buffer-local b 'detail-of) owner)))
                      (buffer-list-mru))))))

(public! 'detail-window
  "(detail-window [OWNER]) — the window the list OWNER opens its rows into, or #f")
(public! 'detail-owner
  "(detail-owner [BUF]) — the list BUF was opened from, or #f")

(effects! '(write display))

(define (detail-window-forget! owner)
  (set! *detail-windows*
        (filter (lambda (e) (not (equal? (car e) owner))) *detail-windows*)))

(define (detail-window-note! owner win)
  (detail-window-forget! owner)
  (set! *detail-windows* (cons (list owner win) *detail-windows*))
  win)

;; the list owns what it opened, and what it opened knows the key that
;; walks its siblings
(define (detail-adopt! owner name)
  (when (and (buffer-known? owner) (buffer-known? name) (not (equal? owner name)))
    (buffer-set-local! name 'detail-of owner)
    (when (and (boundp 'buffer-child!)
               (not (buffer-local name 'detail-kept))
               (not (equal? (buffer-parent name) owner)))
      (buffer-child! owner name)))
  (unless (minor-mode-on? name "detail-mode")
    (enable-minor-mode! name "detail-mode"))
  name)

;; show NAME in the window OWNER opens its rows into, keep that window for
;; the next row, and select nothing: point stays in the list. OWNER names
;; the list, and defaults to the buffer that is asking.
(define (display-buffer-detail! name &optional owner)
  (let* ((o (or owner (window-buffer (active-window))))
         (me (active-window))
         ;; already where you stand, or already in another window: a display
         ;; never moves a buffer that is on screen
         (shown (if (equal? (window-buffer me) name) me (window-showing-other name me)))
         ;; else over the list's last detail, or any detail of it on screen
         (last (and (not shown)
                    (or (detail-window o)
                        (find (lambda (w)
                                (and (not (equal? w me))
                                     (equal? (buffer-local (window-buffer w) 'detail-of) o)))
                              (display--work-windows)))))
         ;; else it opens in the pane beside its list, never on top of it
         (win (or shown
                  (and last (window-set-buffer! last name) last)
                  (panes-display-beside! name o))))
    (when win
      (detail-window-note! o win)
      (detail-adopt! o name))
    win))

;;; --- keeping one ----------------------------------------------------------------
;;; A list that rewrites ONE detail buffer per row can still keep a row. The
;;; kept buffer takes a name of its own, and that frees the name the app
;;; writes to, so the next row renders into a fresh buffer with nothing to
;;; overwrite. No app needs a flag for it: renaming is the whole mechanism.
;;;
;;; A kept detail stops being the list's child, so the list's q leaves it
;;; alone, and it stays in the walk, so C-` still reaches it.

(define *detail-names* '())   ;; ((MODE FN) ...)

;; MODE says what to call a detail it keeps; FN takes the buffer and answers
;; a name. Without a rule the buffer's own name takes a number.
(define (detail-name! mode fn)
  (set! *detail-names* (alist-put *detail-names* mode fn))
  mode)

(define (detail--free-name name)
  (if (not (buffer-known? name))
      name
      (let loop ((n 2))
        (let ((try (string-append name "<" (number->string n) ">")))
          (if (buffer-known? try) (loop (+ n 1)) try)))))

(define (detail-kept-name buf)
  (let* ((mode (buffer-local buf 'mode-name))
         (hit (assoc mode *detail-names*))
         (named (and hit ((cadr hit) buf)))
         (want (if (and (string? named) (not (equal? named ""))) named buf)))
    ;; a page already under its own name keeps it; only a clash takes a number
    (if (equal? want buf) buf (detail--free-name want))))

;; keep the detail in this window: it takes its own name, and the next row
;; opens a new one. It is nobody's child from here, and the walk keeps it.
(define (detail-keep!)
  (let* ((buf (current-buffer))
         (owner (detail-owner buf)))
    (cond
      ((not owner) (message "This buffer is not a list's detail") #f)
      ((buffer-local buf 'detail-kept) (message "This detail is already kept") #f)
      (else
        (let* ((want (detail-kept-name buf))
               (new (if (equal? want buf) buf (rename-buffer! buf want))))
          (cond
            ((not new) (message "That name is taken") #f)
            (else
              (buffer-set-local! new 'detail-of owner)
              (buffer-set-local! new 'detail-kept #t)
              (buffer-unchild! new)
              (message (string-append "Kept as " new))
              new)))))))

(define-command "detail-keep"
  "Keep this detail: it takes a name of its own, and the next row opens a new one"
  (lambda () (detail-keep!)))

;;; --- the walk -------------------------------------------------------------------

(define *detail-ring* '())
(define *detail-pos* 0)

;; The first press lands on the buffer you came from and each further press
;; goes one deeper; any other command ends the walk. Two details and the key
;; flips between them.
(define (detail-cycle! dir)
  (unless (member (last-command) '("detail-next" "detail-previous"))
    (set! *detail-ring* (detail-ring))
    (set! *detail-pos* 0))
  (let ((live (filter buffer-known? *detail-ring*)))
    (unless (= (length live) (length *detail-ring*))
      (set! *detail-ring* live)
      (when (>= *detail-pos* (length live)) (set! *detail-pos* 0))))
  (let ((n (length *detail-ring*)))
    (if (< n 2)
        (message "No other detail open from this list")
        (begin
          (set! *detail-pos* (modulo (+ *detail-pos* dir) n))
          (switch-to-buffer! (list-ref *detail-ring* *detail-pos*))))))

(define-command "detail-next"
  "Walk the details opened from this list, most recently used first"
  (lambda () (detail-cycle! 1)))

(define-command "detail-previous"
  "Walk the details opened from this list, the other way"
  (lambda () (detail-cycle! -1)))

;; the key is the detail's own, so it shadows the global binding only
;; while you stand in a detail, the way chat-mode shadows it in a chat
(register-minor-mode! "detail-mode" (lambda (buf) #t) (lambda (buf) #t))
(minor-mode-keys! "detail-mode"
  '(("C-`" "detail-next") ("C-M-`" "detail-previous") ("M-RET" "detail-keep")
    ;; the list's own items, from here (index.scm)
    ("N" "index-next-item") ("P" "index-previous-item") ("^" "index-up") ("x" "index-hide-item")))

(public! 'display-buffer-detail!
  "(display-buffer-detail! NAME [OWNER]) — show NAME in the one window the list OWNER opens its rows into, keep that window for the next row, and select nothing")
(public! 'detail-name!
  "(detail-name! MODE FN) — MODE says what to call a detail it keeps; FN takes the buffer and answers a name")
(public! 'detail-window-forget!
  "(detail-window-forget! OWNER) — drop the window OWNER opens its rows into; the next row picks one again")

