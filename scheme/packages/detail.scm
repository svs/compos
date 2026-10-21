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
;; two details of one family (an app's pages of different kinds) share a pane
(define (detail-kin? a b)
  (let ((fa (buffer-local a 'detail-family)))
    (and fa (equal? fa (buffer-local b 'detail-family)))))

;; A pane that holds a mode (consolidate, or a chosen preference) that
;; NAME is not of. A page never covers a pane another mode holds.
(define (detail--foreign-pane? win name)
  (let ((held (window-mode-preference win)))
    (and held (not (window-prefers-buffer? win name)))))

;; some other work pane holds another mode: the display chain could land
;; on it, so the detail picks its window itself
(define (detail--held-elsewhere? name me)
  (and (find (lambda (w) (and (not (equal? w me)) (detail--foreign-pane? w name)))
             (display--work-windows))
       #t))

;; The fallback: a new pane beside the list while the layout has room for
;; one, else the pane closest to the list. A detail waiting in a hidden
;; window comes to the front there instead of opening again.
(define (detail--nearest ws ow)
  (let* ((i (let find-ow ((l ws) (k 0))
              (cond ((null? l) 0) ((equal? (car l) ow) k) (else (find-ow (cdr l) (+ k 1))))))
         (n (length ws)))
    (let loop ((d 1))
      (cond ((> d n) #f)
            ((< (+ i d) n) (list-ref ws (+ i d)))
            ((>= (- i d) 0) (list-ref ws (- i d)))
            (else (loop (+ d 1)))))))

(define (detail--place-beside! name o me)
  (let* ((ws (map car (window-list)))
         (ow (or (find (lambda (w) (equal? (window-buffer w) o)) ws) me))
         (target (layout-target))
         (room (or (not target) (< (length ws) (layout-target-capacity target))))
         (hidden (let ((h (find (lambda (p) (equal? (cadr p) name)) (window-hidden-list))))
                   (and h (car h)))))
    (or (and room
             (let ((nw (split-window-in! ow 'h)))
               (and nw (window-display! (lambda () (display-buffer-in-window! nw name))))))
        ;; a pane that holds another mode, a chat pane say, refuses the detail
        (let ((near (detail--nearest (filter (lambda (w) (or (equal? w ow) (not (detail--foreign-pane? w name)))) ws) ow)))
          (and near
               (if (and hidden (window-swap-hidden! near hidden))
                   hidden
                   (window-display! (lambda () (display-buffer-in-window! near name)))))))))

(define (display-buffer-detail! name &optional owner)
  (let* ((o (or owner (window-buffer (active-window))))
         (me (active-window))
         ;; already where you stand, or already in another window: a display
         ;; never moves a buffer that is on screen
         (shown (if (equal? (window-buffer me) name) me (window-showing-other name me)))
         ;; you stand in one of this list's children: its sibling takes your
         ;; window, so walking the list from a detail stays where you are
         (here (and (not shown) (equal? (buffer-local (window-buffer me) 'detail-of) o) me))
         ;; a pane you set to prefer this mode beats the remembered one, so
         ;; window-mode-preference moves where a list opens its rows
         (pinned (and (not shown) (not here)
                      (find (lambda (w)
                              (and (not (equal? w me))
                                   (window-mode-preference w)
                                   (window-prefers-buffer? w name)))
                            (display--work-windows))))
         ;; the last detail of this list still on screen: the next row covers it
         ;; wherever it went, even when the remembered window shows something else
         (sibling (and (not shown) (not here) (not pinned)
                       (find (lambda (w)
                               (and (not (equal? w me))
                                    (equal? (buffer-local (window-buffer w) 'detail-of) o)))
                             (display--work-windows))))
         ;; a pane of the same mode, a detail of another list of the same app:
         ;; mode affinity beats the window the list remembers
         (kin (and (not shown) (not here) (not pinned) (not sibling)
                   (find (lambda (w)
                           (and (not (equal? w me))
                                (not (equal? (window-buffer w) o))
                                (or (window-prefers-buffer? w name)
                                    (detail-kin? (window-buffer w) name))))
                         (display--work-windows))))
         ;; the remembered window only while the layout has no free pane: a
         ;; layout with room opens a new pane instead of covering what you
         ;; put in that window since
         (room (and (layout-target)
                    (< (length (layout-target-visible-buffers))
                       (layout-target-capacity (layout-target)))))
         (kept (and (not shown) (not here) (not pinned) (not sibling) (not kin) (not room) (detail-window o)))
         (win (cond
                (shown shown)
                ;; under the window model a buffer slots into its mode's
                ;; window, as the window policy places it
                ((and (boundp 'panes-mode) panes-mode) (panes-display! name #t))
                (here (window-display! (lambda () (display-buffer-in-window! here name))))
                (pinned (window-display! (lambda () (display-buffer-in-window! pinned name))))
                (sibling (window-display! (lambda () (display-buffer-in-window! sibling name))))
                (kin (window-display! (lambda () (display-buffer-in-window! kin name))))
                (kept (window-display! (lambda () (display-buffer-in-window! kept name))))
                ;; the list's own pane is the only work pane: the chain would end
                ;; on same-window and cover the list, so the detail opens beside it
                ((not (find (lambda (w) (and (not (equal? w me)) (not (equal? (window-buffer w) o))))
                            (display--work-windows)))
                 (let* ((ow (or (find (lambda (w) (equal? (window-buffer w) o)) (display--work-windows)) me))
                        (nw (split-window-in! ow 'h)))
                   (if nw
                       (window-display! (lambda () (display-buffer-in-window! nw name)))
                       (display-buffer name '(category detail inhibit-same-window #t)))))
                ;; a pane that holds another mode is never covered: the layout
                ;; grows a pane while it has room, else the page goes on a
                ;; free pane, else on the app's own stack, over the list
                ((and room (detail--held-elsewhere? name me))
                 (let* ((ow (or (find (lambda (w) (equal? (window-buffer w) o)) (display--work-windows)) me))
                        (nw (split-window-in! ow 'h)))
                   (if nw
                       (window-display! (lambda () (display-buffer-in-window! nw name)))
                       (window-display! (lambda () (display-buffer-in-window! ow name))))))
                ((detail--held-elsewhere? name me)
                 (let ((free (find (lambda (w)
                                     (and (not (equal? w me))
                                          (not (equal? (window-buffer w) o))
                                          (not (detail--foreign-pane? w name))))
                                   (display--work-windows)))
                       (ow (or (find (lambda (w) (equal? (window-buffer w) o)) (display--work-windows)) me)))
                   (window-display! (lambda () (display-buffer-in-window! (or free ow) name)))))
                (else (detail--place-beside! name o me)))))
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
    ("N" "index-next-item") ("P" "index-previous-item") ("^" "index-up")))

(public! 'display-buffer-detail!
  "(display-buffer-detail! NAME [OWNER]) — show NAME in the one window the list OWNER opens its rows into, keep that window for the next row, and select nothing")
(public! 'detail-name!
  "(detail-name! MODE FN) — MODE says what to call a detail it keeps; FN takes the buffer and answers a name")
(public! 'detail-window-forget!
  "(detail-window-forget! OWNER) — drop the window OWNER opens its rows into; the next row picks one again")

;; A group that declares its panes opens a list's rows in its own detail
;; pane: the page is adopted first, so the group's function sees a detail.
(advice-add! 'display-buffer-detail! 'around 'group-panes
  (lambda (next name &optional owner)
    (let* ((o (or owner (window-buffer (active-window))))
           ;; the window model places details itself; the group's panes
           ;; are the old path
           (panes (and (boundp 'group-panes-open!)
                       (not (and (boundp 'panes-mode) panes-mode))
                       (group-panes-of (frame-group)))))
      (when panes (detail-adopt! o name))
      (let ((win (and panes (not (layout-arranging?)) (group-panes-open! name #f))))
        (cond (win (detail-window-note! o win) win)
              (owner (next name owner))
              (else (next name)))))))
