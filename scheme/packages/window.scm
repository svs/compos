;;; window.scm --- windows: display-buffer, the float, peek, layouts, tiling.
;;;
;;; Emacs's window.el, in one file: the display-buffer chain and its actions,
;;; the float and the look, peek, the mode layouts, quit-window, winner,
;;; and the tiling commands. init.scm loads it second, before dired.

(domain! 'files)
(effects! '(read))

;;; --- display-buffer ------------------------------------------------------------
;;; *display-buffer-alist* says WHERE a buffer goes. It is Emacs' alist of
;;; the same name, in the shape this editor needs: a list of
;;;
;;;   (PATTERN ACTION PARAMS)
;;;
;;; read in order, first match wins. PATTERN is a substring of the buffer
;;; name, (category KIND) for a kind of display the caller names
;;; ((category preview) is a peek; (category foreign) is a buffer from
;;; outside the frame's group), or a procedure of NAME and ALIST. ACTION
;;; is one action name or a list of them, tried in order; the
;;; display-buffer section below lists them.
;;;
;;; A buffer with no rule, or a rule whose action is not one of
;;; *display-buffer-outside-layout*, goes where the window model places it.
;;; PARAMS is a plist, and every key has a default, so a rule says only
;;; what it wants to change:
;;;
;;;   'side   'right | 'left | 'top | 'bottom | 'center, for a float
;;;   'size   the share of the frame it takes     default one third
;;;
;;; A popup (popper.scm) is an ordinary buffer in an ordinary window: a
;;; rule with a procedure PATTERN sends it to the bottom of the frame.

(define *window-third* (/ 1 3))

;; The two-pane layout reads this. It is a plain define here, because
;; editor.scm loads before custom.scm; layouts.scm makes it a custom.
;; It is the first pane's share of the frame.
(define window-layout-main-ratio (- 1 *window-third*))
;; The columns layout shows this many panes and keeps no others; layouts.scm makes
;; it a setting.
(define window-layout-columns 3)

;; The layout a frame keeps as its target until the person frees it; a
;; plain define here too, a custom in layouts.scm.
(define window-layout-default 'columns)

(define *display-buffer-defaults* (list 'side 'right 'size *window-third*))

(define *display-buffer-alist*
  ;; no stock rule names a place, so a listing, the messages, a shell
  ;; take the window chain like any other buffer
  (list
        ;; a detail a list opens from one of its rows takes another
        ;; window and KEEPS it (packages/detail.scm): reuse a window
        ;; before growing the layout by a pane per row
        (list '(category detail) '(reuse-window use-some-window pop-up-window) '())
        ;; a preview takes another window, and buffer replacement puts
        ;; the window back. A buffer from outside the frame's group
        ;; takes a window the same way.
        ;; A peek goes to the window of its own mode first, so a Markdown
        ;; file from Dired replaces the Markdown file shown, not the chat.
        ;; Last, so a rule for a name wins, and a rule of your own
        ;; (add-display-rule! conses in front) wins too
        (list '(category preview) '(reuse-window mode-window use-some-window pop-up-window) '())
        (list '(category foreign) '(reuse-window use-some-window pop-up-window) '())))

;; A buffer from outside the frame's group. groups.scm answers; with no
;; groups, no buffer is foreign. A display of a foreign buffer that names
;; no category of its own is a display of category foreign, and the
;; stock rule sends it to another window. A rule of your own for
;; (category foreign) routes it elsewhere; a pane that shows it then
;; takes the frame out of the group.
(define display-foreign? (lambda (name) #f))

(define (display--alist-with-category name alist)
  (if (and (not (plist-get alist 'category)) (display-foreign? name))
      (append (list 'category 'foreign) alist)
      alist))

;; PARAMS is optional, so every rule written before the params existed
;; still reads the same and takes the defaults
(define (add-display-rule! pattern action &optional params)
  (set! *display-buffer-alist*
    (cons (list pattern action (if params params '()))
          *display-buffer-alist*)))

;; a rule matches a name by substring, a category the caller passed in
;; ALIST as 'category, or a procedure of NAME and ALIST that answers true
;; (Emacs display-buffer-alist). A rule written (category . KIND) reads
;; the same.
(define (display-rule-match? condition name alist)
  (cond ((string? condition) (string-contains? name condition))
        ((procedure? condition) (and (condition name alist) #t))
        ((and (pair? condition) (equal? (car condition) 'category))
         (let ((kind (cdr condition)))
           (equal? (if (pair? kind) (car kind) kind)
                   (plist-get alist 'category))))
        (else #f)))

;; the rule for NAME, or a rule with no action: the chain then starts
;; at the base action
(define (display-rule-for name &optional alist)
  (let ((a (or alist '())))
    (let loop ((rules *display-buffer-alist*))
      (cond ((null? rules) (list name '() '()))
            ((display-rule-match? (car (car rules)) name a) (car rules))
            (else (loop (cdr rules)))))))

(define (display-action-for name &optional alist)
  (let ((actions (display--rule-actions name alist)))
    (if (null? actions) #f (car actions))))

;; a rule's own value, else the default for that key
(define (display-rule-param name key)
  (let* ((rule (display-rule-for name))
         (rest (cdr (cdr rule)))
         (params (if (null? rest) '() (car rest)))
         (v (plist-get params key)))
    v))

(define (display-param name key)
  (or (display-rule-param name key)
      (plist-get *display-buffer-defaults* key)))

;; frame-local policy state: values keyed by the selected frame — each
;; browser gets its own look, its own ibuffer home window. Pruned when a
;; frame is deleted.
(define *frame-locals* '())   ; ((frame ((key val) ...)) ...)

(define (frame-local-in frame key)
  (let ((fr (assoc frame *frame-locals*)))
    (if fr
        (let ((kv (assoc key (cadr fr))))
          (if kv (cadr kv) #f))
        #f)))

(define (frame-local key)
  (frame-local-in (selected-frame) key))

;; set-frame-local! writes the SELECTED frame. This one names its frame, so
;; a fact that is true of every frame can be written into each one.
(define (set-frame-local-in! frame key val)
  (let* ((fr (assoc frame *frame-locals*))
         (locals (if fr (cadr fr) '()))
         (rest (filter (lambda (e) (not (equal? (car e) frame))) *frame-locals*))
         (others (filter (lambda (e) (not (equal? (car e) key))) locals)))
    (set! *frame-locals* (cons (list frame (cons (list key val) others)) rest))))

(define (set-frame-local! key val)
  (set-frame-local-in! (selected-frame) key val))

(define (prune-frame-locals!)
  (let ((live (frame-list)))
    (set! *frame-locals*
      (filter (lambda (e) (member (car e) live)) *frame-locals*))))

;;; --- the float -------------------------------------------------------------------
;;; A window floats while its buffer wears the float class. Two surfaces
;;; float: the card of a row preview (preview-show ... 'float) and the
;;; table of a prompt in the panel or the modal shape. The window stays
;;; in the tree, so every window command reaches it. The class takes its
;;; split out of the flow, and the window it covers keeps the frame. A
;;; frame shows at most one float. The class string is the stylesheet's
;;; ("popup popup-SIDE"); it is not a popup in the popper sense.

(define (float--class? buf)
  (let ((c (and (string? buf) (buffer-local buf 'window-class))))
    (and c (string-prefix? "popup" c) #t)))

;; the window that floats in this frame, or #f
(define (float-window)
  (let loop ((ws (window-list)))
    (cond ((null? ws) #f)
          ((float--class? (cadr (car ws))) (car (car ws)))
          (else (loop (cdr ws))))))

(define (float-buffer)
  (let ((w (float-window))) (and w (window-buffer w))))

(define (window-exists? id)
  (assoc id (window-list)))

;; a float that became the sole window (C-x 1 from inside it) is not a
;; float any more
(define (float-open?)
  (and (float-window) (pair? (cdr (window-list))) #t))

;; A buffer can ask for more window classes than the float gives it. The
;; extra words come after the side, so float-side-of still reads the side.
(define (float--extra-classes name)
  (let ((extra (buffer-local name 'window-classes)))
    (if (and (string? extra) (not (equal? extra "")))
        (string-append " " extra)
        "")))

;; A window floats because of its class, and for no other reason: the
;; pane is in the tree either way. So a change of shape is a change of
;; two locals. It runs no mode setup, which is what lets a prompt change
;; shape with its table still standing, filter and row intact. SIDE #f
;; stops the float.
(define (window-float-class! name side &optional size)
  (buffer-set-locals! name
    (list 'window-class
            (and side (string-append "popup popup-" (symbol->string side)
                                     (float--extra-classes name)))
          ;; the share is a number, and CSS cannot read a Scheme list —
          ;; hand it over as a custom property the stylesheet already reads
          'window-style
            (and side size
                 (string-append "--popup-size:" (number->string (* 100 size)) "%")))))

;; the side a floating buffer wears, from its class, or #f. The class can
;; carry more words after the side, so the side is the first word.
(define (float-side-of buf)
  (let ((c (and buf (buffer-local buf 'window-class))))
    (and c (string-prefix? "popup popup-" c)
         (let* ((rest (substring c (string-length "popup popup-") (string-length c)))
                (space (string-index rest " ")))
           (string->symbol (if space (substring rest 0 space) rest))))))

;; Show NAME as the float and answer its window. An open float takes
;; NAME in place; else the selected window splits, and the new window,
;; second in the tree, floats against SIDE. SELECT? selects the float;
;; otherwise the selection stays where it was. A display that is a look
;; (with-display-preview) covers the float's buffer, and the end of the
;; look puts it back. Any other display replaces it, and the replaced
;; buffer stops floating.
(define (float-show! name side size &optional select?)
  (let ((me (active-window))
        (w (float-window)))
    (window-float-class! name side size)
    (if w
        (let ((was (window-buffer w)))
          (window-show-buffer! w name)
          (when (and was (not (equal? was name)) (not *display-preview*)
                     (buffer-exists? was))
            (window-float-class! was #f)))
        ;; the float is a frame window outside the panes model: the raw
        ;; split, not split-window!, which adds a pane to the model
        (let ((before (map car (window-list))))
          (builtin-split-window! (if (member side '(top bottom)) 'v 'h) (- 1 size))
          (set! w (find (lambda (x) (not (member x before))) (map car (window-list))))
          (window-show-buffer! w name)
          ;; the split made this window: the end of a look deletes it
          (set-window-restore! w '(window #f #f))))
    (select-window! (if (or select? (not (window-exists? me))) w me))
    (window-state-changed!)
    w))

;; The float goes: its buffer stops floating and its window is deleted.
;; The last window of a frame is never deleted.
(define (float-close!)
  (let ((w (float-window)))
    (when w
      (let ((buf (window-buffer w)))
        (when buf (window-float-class! buf #f))
        (when (pair? (cdr (window-list))) (delete-window-id! w))))))

(domain! 'files)
(effects! '(read))

;;; --- a look is not a use ------------------------------------------------------
;;; The MRU ring records the buffers the reader USED. A preview is not a
;;; use: the reader moves down a listing and every row shows for as long
;;; as the point rests on it. The buffer table sorts its rows by the ring,
;;; so a preview that bumped the ring rewrote the list under the point.
;;;
;;; While this flag stands, a display sets the window's buffer through
;;; window-preview-buffer!, which changes the window and leaves the ring
;;; alone. peek-show! binds it, so every look goes this way: the buffer
;;; table, dired, occur, and every list mode that peeks a row.

(define *display-preview* #f)

;; show NAME in WIN: the ring records it, unless this is a look
;;; One buffer, one window. A display of NAME in WIN takes NAME away from
;;; every other window of the frame, and each of those reveals what it showed
;;; before — the same move buffer-previous-pane and buffer-next-pane make, done for you.
;;; A preview is a look, not a place, so the peek path never evicts.
(define (window-eviction-buffer win name)
  (let ((action (window-fill-decide
                  (window-fill-snapshot win name 'restore #f 'others #f)
                  (window-fill-buffers))))
    (and (equal? (car action) 'show) (cadr action))))

;; the only buffer in the editor cannot be in two places and nowhere: when
;; there is nothing else to reveal the other window keeps it.
(define (window-release-duplicates! win name)
  (for-each
   (lambda (w)
     (let* ((other (car w))
            (filler (and (not (equal? other win))
                         (window-eviction-buffer other name))))
       (when filler
         (set-window-prev-buffers!
          other
          (filter (lambda (b) (not (equal? b name)))
                  (window-prev-buffers other)))
         (window-set-buffer! other filler))))
   (filter (lambda (w) (equal? (cadr w) name)) (window-list))))

(define (window-show-buffer! win name)
  (if *display-preview*
      (window-preview-buffer! name win)
      (begin (window-set-buffer! win name)
             (window-release-duplicates! win name))))

(define (with-display-preview thunk)
  (let ((was *display-preview*))
    (set! *display-preview* #t)
    (let ((r (thunk)))
      (set! *display-preview* was)
      r)))

;;; --- the frame return stack ----------------------------------------------------
;;; An arrangement that a mode or a prompt puts over the frame and takes
;;; away again is one entry: (TOKEN REASON LAYOUT GROUP), the window
;;; model of the frame's group and the group. arrangement-push! answers the
;;; token. arrangement-pop! draws that model back, focus and layout with it,
;;; and stands in that group again; arrangement-drop! keeps what is on
;;; screen. Either one also ends the entries pushed after it.

(define (arrangements) (or (frame-local 'arrangements) '()))

(define (arrangement-push! reason)
  (let ((token (+ 1 (or (frame-local 'arrangement-last) 0))))
    (set-frame-local! 'arrangement-last token)
    (set-frame-local! 'arrangements
      (cons (list token reason (panes--ensure-layout!) (frame-group))
            (arrangements)))
    token))

;; the token of the newest entry pushed for REASON, or #f
(define (arrangement-for reason)
  (let ((hits (filter (lambda (e) (equal? (cadr e) reason)) (arrangements))))
    (and (pair? hits) (car (car hits)))))

(define (arrangement--take! token)
  (let loop ((s (arrangements)))
    (cond ((null? s) #f)
          ((equal? (car (car s)) token)
           (set-frame-local! 'arrangements (cdr s))
           (car s))
          (else (loop (cdr s))))))

(define (arrangement-drop! token) (and token (arrangement--take! token) #t))

;; LOOK? is kept for the callers: a pop is always a look, nothing is recorded
(define (arrangement-pop! token &optional look?)
  (let ((e (and token (arrangement--take! token))))
    (when e
      ;; a frame derives its group from what it shows: standing where you
      ;; stood is part of giving the frame back
      (unless (equal? (frame-group) (nth 3 e))
        (set-frame-local! 'current-group (nth 3 e))
        (frame-group-label-refresh!))
      (when (nth 2 e) (panes-look! (panes-validate (nth 2 e) buffer-known?) (nth 3 e)))
      (window-state-changed!))
    (and e #t)))

;;; --- the preview verb ----------------------------------------------------------
;;; A look shows a buffer for a while without keeping it. It never bumps
;;; the MRU and never moves focus. A frame
;;; holds one look: (BUF WHERE FROM SHOWN DATA TREE). WHERE says where:
;;;   here   the window FROM itself; its leaf records what the look covers
;;;   other  a window FROM owns: the one it owns already, else a display
;;;   float  the card, the one float (see the float section)
;;;   frame  the whole frame: BUF is a procedure that draws the look, and
;;;          TREE is the return-stack token of the arrangement it covers
;;; DATA is the caller's own note. (preview-end KEEP) ends the look: KEEP
;;; #t keeps what is shown (RET twice keeps), #f puts back what was there.

(define (preview-slot) (frame-local 'preview))
(define (preview-buffer) (let ((s (preview-slot))) (and s (car s))))
(define (preview-data) (let ((s (preview-slot))) (and s (nth 4 s))))

(define (preview--owned-window owner)
  (let loop ((rows (window-list)))
    (cond ((null? rows) #f)
          ((equal? (window-owner (car (car rows))) owner) (car (car rows)))
          (else (loop (cdr rows))))))

;; show BUF in the look slot; answers the window that shows it
(define (preview-show buf where &optional win data)
  (let* ((me (active-window))
         (from (or win me))
         (slot (preview-slot))
         (same? (and slot (equal? (nth 1 slot) where) (equal? (nth 2 slot) from)))
         (borrowed #f))
    ;; one look per frame: a look from elsewhere ends the last one first
    (when (and slot (not same?)) (preview-end #f))
    (let* ((tree (if same? (nth 5 slot) (and (equal? where 'frame) (arrangement-push! 'preview))))
           (shown
             (cond
               ((equal? where 'here) (window-preview-buffer! buf from) from)
               ((equal? where 'other)
                ;; the last look's window is this one's only while it still
                ;; shows that look: once its own buffer came back, the claim
                ;; is spent and the display chain chooses again
                (let* ((owned (preview--owned-window from))
                       (rec (and owned (window-restore owned)))
                       (own (and rec owned))
                       (there (window-showing-other buf from))
                       (w (or own (with-display-preview
                                    (lambda ()
                                      (display-buffer buf '(category preview)))))))
                  ;; the next look takes over the last one's record
                  (when own
                    (window-preview-buffer! buf own)
                    (when rec (set-window-restore! own rec)))
                  ;; a window that showed BUF already is not the look's
                  (if (and w (not own) (equal? w there))
                      (set! borrowed #t)
                      (when w (set-window-owner! w from)))
                  w))
               ;; the side away from the source decides, every time: reusing
               ;; the open float's side left the card at the far edge of a
               ;; wide frame. The card is placed by the PeekCard hook; the
               ;; side only names the tree slot the float hangs from.
               ((equal? where 'float)
                (float-show! buf (peek-side-away-from from)
                             (plist-get *display-buffer-defaults* 'size)))
               (else (buf) (active-window)))))
      ;; a frame look draws the focus with the frame
      (unless (or (equal? where 'frame) (not (window-exists? me)) (equal? (active-window) me))
        (select-window! me))
      (set-frame-local! 'preview (list buf where from (and (not borrowed) shown) data tree))
      shown)))

;; end the look; KEEP #t keeps what it shows. Answers the slot it ended.
(define (preview-end keep)
  (let ((slot (preview-slot)))
    (set-frame-local! 'preview #f)
    (when slot
      (let ((buf (nth 0 slot)) (where (nth 1 slot)) (w (nth 3 slot)))
        (cond
          ((equal? where 'frame)
           (if keep
               (arrangement-drop! (nth 5 slot))
               (arrangement-pop! (nth 5 slot) #t)))
          ;; the card goes, or gives back the float it covered
          ((equal? where 'float)
           (let ((fw (float-window)))
             (unless (or keep (not fw) (not (equal? (window-buffer fw) buf)))
               (begin (or (window-preview-end! fw) (float-close!))))))
          ((not (and w (window-exists? w) (equal? (window-buffer w) buf))) #f)
          ((equal? where 'here)
           (if keep (window-set-buffer! w buf) (window-preview-end! w)))
          (keep (set-window-owner! w #f) (set-window-restore! w #f))
          (else (set-window-owner! w #f) (window-quit-restore! w)))))
    slot))

(domain! 'files)
(effects! '(read))

;;; --- display-buffer (Emacs window.el) -----------------------------------------
;;; display-buffer shows NAME somewhere and returns the window. It selects
;;; nothing. pop-to-buffer shows and selects. switch-to-buffer! shows in
;;; the selected window. The window model places a buffer (panes-display!,
;;; panes-mode.scm). Only a rule whose action places a buffer itself, off
;;; the panes, runs its actions: the float and the dock ('shaped), the
;;; selected window ('same-window), a popup (popper.scm). Those actions are
;;; *display-buffer-outside-layout*.
;;;
;;; ALIST is a plist the caller passes. 'category names the kind of display,
;;; and a rule (category KIND) matches it.

;; an action is the keyed hook (display-action NAME)
(define (define-display-action! name fn) (add-hook! (list 'display-action name) fn))

(define (display-action-fn name)
  (let ((fs (hook-functions (list 'display-action name))))
    (and (pair? fs) (car fs))))

;;; The modeline names the chosen layout as Markdown: `*layout*:NAME`. The label
;;; is bold and the target reads plainly beside it, with no segment gap between
;;; the two spans. The text is compared before it is set, so the change hook
;;; that calls this on every window move does no work on an unchanged frame.
(define (layout-modeline-text)
  (let ((target (panes-current-layout)))
    (string-append ":" (cond ((not target) "free")
                             ((symbol? target) (symbol->string target))
                             (else target)))))

(define (layout-modeline-shown)
  (let ((entry (assq 'layout-value *global-mode-string*)))
    (and entry (pair? (cadr entry)) (cadr (cadr entry)))))

(define (layout-modeline!)
  (let ((text (layout-modeline-text)))
    (unless (equal? text (layout-modeline-shown))
      (global-mode-string-set! 'layout-label '("ml-segment ml-strong" "layout"))
      (global-mode-string-set! 'layout-value (list "ml-segment ml-tight" text))))
  (global-mode-string-remove! 'layout-ring))

;; A buffer that makes its window a work window. popper.scm answers #f
;; for a popup: a popup window is ordinary, but the layout does not tile
;; it and a display of another buffer does not take it.
(define window-work-buffer? (lambda (buf) #t))

(define (layout-visible-window? row)
  (and (not (float--class? (cadr row)))
       (window-work-buffer? (cadr row))
       (not (window-dock? (car row) (cadr row)))))

;; the modeline names the layout of the group in front of you
(add-hook! 'window-state-change-hook 'layout-modeline!)

;; the actions of NAME's rule, in order; () when no rule names one
(define (display--rule-actions name &optional alist)
  (let ((rule (cadr (display-rule-for name (display--alist-with-category name (or alist '()))))))
    (cond ((null? rule) '())
          ((pair? rule) rule)
          (else (list rule)))))

;;; what a display did to a window, for quit-window: (WIN KIND PREV).
;;; KIND 'window: the display made the window, and quit deletes it.
;;; KIND 'other: the display took a window that showed PREV, and quit
;;; puts PREV back.
;;; The record lives on the window's leaf (Emacs quit-restore) and the
;;; core drops it when the window shows another buffer: (window-restore
;;; WIN) answers (KIND BUF POINT). KIND 'window: the display made the
;;; window, and quit deletes it. KIND 'other: the display took a window
;;; that showed BUF, and quit puts BUF back. KIND 'preview: a look
;;; covers BUF, and the end of the look puts BUF back.
(define (window-display! thunk)
  (let* ((before (map (lambda (row) (list (car row) (cadr row) (window-point (car row))))
                      (window-list)))
         (win (thunk))
         (previous (and win (assoc win before))))
    (when (and win (window-exists? win))
      (cond ((not previous) (set-window-restore! win '(window #f #f)))
            ;; a look records itself
            ((equal? (car (or (window-restore win) '(#f))) 'preview) #t)
            ((not (equal? (cadr previous) (window-buffer win)))
             (set-window-restore! win (list 'other (cadr previous) (caddr previous))))))
    win))

;; end the look in WIN: the buffer it covers comes back. #t when it did.
(define (window-preview-end! win)
  (let ((rec (and win (window-exists? win) (window-restore win))))
    (and rec (equal? (car rec) 'preview) (buffer-known? (cadr rec))
         (window-preview-buffer! (cadr rec) win))))

;; undo what a display did to WIN: delete it, or put back what it
;; showed. #t when something was undone. The last window is never deleted.
(define (window-quit-restore! win)
  (let ((rec (and (window-exists? win) (window-restore win))))
    (cond ((not rec) #f)
          ((equal? (car rec) 'preview) (window-preview-end! win))
          (else
            (set-window-restore! win #f)
            ;; undo the display only: the window it made goes, the buffer it
            ;; covered comes back. Nothing fills from the past or the pool.
            (window-fill-apply! win
              (window-fill-decide
                (window-fill-snapshot win #f 'restore rec 'previous '() 'refill #f
                  'others (and (equal? (car rec) 'window)
                               (other-window-id win)
                               #t))
                (window-fill-buffers)))))))

;;; geometry, from the selected window's measure and the fractional rects

;; the work windows: not the float, not a dock, not a peek
(define (display--work-windows)
  (let ((float (float-window)))
    (filter (lambda (w) (and (not (equal? w float))
                             (window-work-buffer? (window-buffer w))
                             (not (window-dock? w (window-buffer w)))
                             (not (peek-buffer? (window-buffer w)))))
            (map car (window-list)))))

;; show NAME in window WIN, selecting nothing. A buffer the user can see
;; is a buffer the user can switch to; a floating buffer shown anywhere
;; but the float stops floating.
(define (display-buffer-in-window! win name)
  (when (and (not *display-preview*) (boundp 'buffer-promote!)) (buffer-promote! name))
  ;; A dormant buffer wakes when a window asks for it, and the wake
  ;; queues its runtime rather than building it. switch-to-buffer-here!
  ;; has always made the buffer whole on this path; this one did not, so
  ;; a display could put a buffer on screen with its text and no mode.
  ;; Same rule in both doors: whole, then shown.
  (let ((restoring (not (buffer-exists? name))))
    (let ((float (float-window)))
      (window-show-buffer! win name)
      (when restoring (restore-buffer-runtime! name))
      (when (and (float--class? name) (not (equal? win float)))
        (window-float-class! name #f))))
  (window-state-changed!)
  win)

;; Where a shaped surface goes: the dock when it is a minibuffer, the
;; float when it is a panel or a modal. A buffer says which with its own
;; 'window-shape, so the rule needs no argument. The float takes the
;; focus: the table is where the reader works.
(define-display-action! 'shaped
  (lambda (name alist)
    (let ((shape (or (buffer-local name 'window-shape) minibuffer-default-shape))
          (docked (window-docked name)))
      (cond ((not (equal? shape "minibuffer"))
             (float-show! name (or (float-side-of name) (display-param name 'side))
                          (display-param name 'size) #t))
            ((and docked (window-exists? docked)) (select-window! docked) docked)
            (else (window-dock! name (display-param name 'size)))))))

(define-display-action! 'same-window
  (lambda (name alist)
    (switch-to-buffer-here! name)
    (active-window)))

(define-display-action! 'same (display-action-fn 'same-window))

;; A window prefers the mode of its work buffer. Temporary covers keep the
;; preference of the nearest work buffer in its own history. This uses the
;; history already carried through tiling and desktop restore.
(define (window-mode win)
  (let ((buf (window-buffer win)))
    (and (string? buf) (buffer-local buf 'mode-name))))

;; Help is a cover by default; other surfaces may opt in with a buffer local.
(define (window-preference-cover? buf)
  (or (buffer-local buf 'window-preference-cover)
      (buffer-derived-mode? buf "help-mode")))

(define (window-preferred-mode win)
  (or (window-mode-preference win)
      (let loop ((buffers (cons (window-buffer win) (window-prev-buffers win))))
        (cond ((null? buffers) (window-mode win))
              ((and (buffer-known? (car buffers))
                    (not (window-preference-cover? (car buffers))))
               (buffer-local (car buffers) 'mode-name))
              (else (loop (cdr buffers)))))))

(define (window-prefers-buffer? win buf)
  (let ((mode (window-preferred-mode win)))
    (and (string? mode) (buffer-derived-mode? buf mode))))

;; The selected window comes first, so a command that opens one thing still
;; opens it where you are: you are already in the window of its mode.
;; the major mode NAME has, or the one it is about to open in: a file a
;; peek just read has no mode yet, and it still belongs beside its kin
(define (display-buffer-mode name)
  (or (buffer-local name 'mode-name)
      (and (buffer-known? name) (auto-mode-for-buffer name))))

(define (window-showing-mode mode &optional except)
  (and (string? mode)
       (let ((me (active-window))
             (work (display--work-windows)))
         (define (fits? w)
           (and (not (equal? w except))
                (or (equal? (window-preferred-mode w) mode)
                    (equal? (window-mode w) mode))))
         (if (and (member me work) (fits? me))
             me
             (let loop ((ws work))
               (cond ((null? ws) #f)
                     ((fits? (car ws)) (car ws))
                     (else (loop (cdr ws)))))))))

;; What the user sees, the last visited first. An agent reads "this" here.
(define (get-visible-buffers)
  (let loop ((ws (window-list)) (seen '()))
    (if (null? ws)
        (map cadr (sort (map (lambda (b) (list (- (or (buffer-last-seen b) 0)) b))
                             seen)))
        (let ((b (cadr (car ws))))
          (loop (cdr ws) (if (member b seen) seen (cons b seen)))))))

;; The window a display for the user goes to, never the active one. While
;; the frame shows fewer panes than its target layout holds, the layout
;; gains a pane with the most recent buffer not on screen, and that pane
;; answers. Otherwise the window whose buffer the user saw longest ago.
(define (get-other-window)
  ;; the model opens a pane while the layout has room; else the window you
  ;; looked at longest ago
  (let* ((me (active-window))
         (l (panes-layout))
         (others (filter (lambda (r) (not (equal? (car r) me))) (window-list))))
    (define (seen r) (or (buffer-last-seen (cadr r)) 0))
    (if (or (null? others) (and l (panes-under-capacity? l)))
        (panes--split-window!)
        (let loop ((rs (cdr others)) (best (car others)))
          (cond ((null? rs) (car best))
                ((< (seen (car rs)) (seen best)) (loop (cdr rs) (car rs)))
                (else (loop (cdr rs) best)))))))

;; show NAME where the chain says, selecting nothing; the window, or #f
(define (display-buffer-run-actions name alist actions)
  (if (null? actions)
      #f
      (let* ((fn (display-action-fn (car actions)))
             (win (and fn (fn name alist))))
        (or win (display-buffer-run-actions name alist (cdr actions))))))

;; the actions that place a buffer themselves, off the panes. A package
;; adds its own (popper.scm).
(define *display-buffer-outside-layout* '(shaped same same-window))

;; An agent never puts its work in the user's window by accident. It works
;; on a file buffer, or on a buffer it made, by name. When the user asks to
;; see a buffer, the agent shows it with display-buffer-other-window!,
;; which marks the display 'requested, whoever made the buffer. Any other display of
;; such a buffer gets #f, so the agent can tell nothing was shown.
(define (display-buffer-agent-refuses? name alist)
  (and (agent-edit-author? (current-edit-author))
       (not (plist-get alist 'requested))
       (buffer-known? name)
       (or (buffer-path name) (buffer-local name 'context-only))
       #t))

(define (display-buffer-agent-refusal name)
  (message (string-append
             "An agent shows a buffer only in the other window: "
             "(display-buffer-other-window! NAME). Link: " (buffer-link name))))

(define (display-buffer name &optional alist)
  (if (display-buffer-agent-refuses? name (or alist '()))
      (begin (display-buffer-agent-refusal name) #f)
      (let* ((a (or alist '()))
             (actions (display--rule-actions name a)))
        (if (and (pair? actions) (member (car actions) *display-buffer-outside-layout*))
            (window-display! (lambda () (display-buffer-run-actions name a actions)))
            (panes-display! name)))))

;; show NAME and select its window (Emacs pop-to-buffer)
(define (pop-to-buffer name &optional alist)
  (let ((win (display-buffer name alist)))
    (when (and win (window-exists? win) (not (equal? win (active-window))))
      (select-window! win))
    win))

;; show NAME in a window other than the selected one, point staying put —
;; the display-buffer contract behind Emacs previews (occur/grep/consult):
;; windows are never remembered, they are chosen HERE, at display time.
;; window-set-buffer! takes a window id. switch-to-buffer! cannot do this
;; job: it answers a frame buffer-context before it looks at a window, so
;; an agent asked to show a file moved only its own context and the window
;; never changed. Nothing here selects a window, so point stays put.
;; The one exception is a list's detail window, which is remembered on
;; purpose so every row lands in the same place (packages/detail.scm).
(define (display-buffer-other-window! name)
  (display-buffer name '(requested #t)))
(domain! 'files)
(effects! '(read))

;;; --- peek -----------------------------------------------------------------------
;;; A peek shows a buffer to look at it, without adopting it into the
;;; workspace. RET on a row peeks; RET again keeps. The rules:
;;;
;;;   ONE peek at a time. The next peek replaces the last one. A buffer
;;;     that a peek MADE is killed when it is replaced. A buffer that
;;;     existed before the peek is only shown, never killed.
;;;   THE PEEK WINDOW is another window, never the float. A look goes
;;;     beside the listing: the peek takes a window that is not the
;;;     reader's, and the next peek takes that same window again. The
;;;     buffer it replaced comes back when the peek goes.
;;;   A PEEK IS READ-ONLY (peek-mode, a minor mode): a stray key changes
;;;     nothing, and q dismisses it.
;;;   OPEN is M-RET on the row (peek-open!): the mark goes, the peek
;;;     window gives the buffer up, and the selected window shows it as
;;;     a visit would. KEEP alone is M-x keep-buffer, or a change from
;;;     outside the keyboard.
;;;   A replaced peek leaves a row in RECENT. The switcher lists recent
;;;     below the live buffers, and RET there peeks it again.
;;;
;;; The mark is the minor mode, and it is saved with the buffer: a peek
;;; on screen at a restart comes back as a peek, read-only.

;; The mode. A peek is read-only: a look changes nothing, and the
;; read-only keymap gives it q. The setup runs on enable and again on a
;; restore, so it records the buffer's own state once; keep puts that
;; state back.
(register-minor-mode! "peek-mode"
  (lambda (buf)
    (unless (buffer-local buf 'peek-own-read-only)
      (buffer-set-local! buf 'peek-own-read-only
        (if (buffer-read-only? buf) 'yes 'no)))
    (buffer-set-read-only! buf #t))
  (lambda (buf)
    (buffer-set-read-only! buf (equal? (buffer-local buf 'peek-own-read-only) 'yes))
    (buffer-set-local! buf 'peek-own-read-only #f)))

(mode-doc! "peek-mode"
  "Deprecated and no longer turned on. A preview now shows an ordinary
buffer in an ordinary window: focusable, editable, and yours. The window
keeps the buffer you were in and your point.")

(define (peek-buffer? name)
  (and (string? name) (buffer-exists? name)
       (buffer-local name 'preview-opened) #t))

(define (peek-buffers) (filter peek-buffer? (buffer-list)))

;;; recent: what a peek showed and let go. An entry is
;;; (LABEL KIND KEY TIME): KIND names the reviver, KEY is what it needs.

(defvar '*peek-recent* '() 'persist #t)
(define *peek-recent-max* 50)

(define (peek-recent-find key)
  (let ((hits (filter (lambda (x) (equal? (nth 2 x) key)) *peek-recent*)))
    (and (pair? hits) (car hits))))

;; how NAME comes back: a file by its path, a page by its URL, a
;; directory by its dir. #f for a buffer nothing can rebuild.
(define (peek-recent-entry name)
  (let ((path (buffer-path name))
        (url (buffer-local name 'browse-url))
        (dir (buffer-local name 'dired-dir)))
    (cond ((and (string? url) (not (equal? url "")))
           (list name 'browse url (current-time)))
          ((and (string? dir) (not (equal? dir "")))
           (list name 'dired dir (current-time)))
          ((and (string? path) (not (equal? path "")))
           (list name 'file path (current-time)))
          (else #f))))

(define (peek-remember! name)
  (let ((e (peek-recent-entry name)))
    (when e
      (set! *peek-recent*
        (take (cons e (filter (lambda (x) (not (equal? (nth 2 x) (nth 2 e))))
                                *peek-recent*))
                *peek-recent-max*)))))

(define (peek-forget-recent! key)
  (set! *peek-recent*
    (filter (lambda (x) (not (equal? (nth 2 x) key))) *peek-recent*)))

;; a recent row comes back as a peek: the same look, the same choice
(define (peek-revive! entry)
  (let ((kind (nth 1 entry))
        (key (nth 2 entry)))
    (cond ((and (equal? kind 'browse) (boundp 'web--tab-for!))
           (peek! (web--buffer-for key) (lambda () (web--tab-for! key))))
          ((equal? kind 'dired)
           (peek! key (lambda () (dired-open key))))
          ((equal? kind 'file)
           (peek-file! key))
          (else #f))))

;; let NAME go: remember it, kill it. A buffer with a live process is
;; never a peek, so nothing here stops one.
;; A buffer the preview opened goes when it leaves the slot. A buffer with
;; unsaved changes never goes: the reader entered it and worked in it, so it
;; stopped being a preview the moment they typed.
(define (peek-drop! name)
  (when (and (peek-buffer? name) (not (buffer-modified? name)))
    (peek-remember! name)
    (buffer-kill! name)))

;; every peek but KEEP-ONE and the buffer the reader is in goes
(define (peek-drop-others! keep-one)
  (let ((here (current-buffer)))
    (for-each (lambda (b)
                (unless (or (equal? b keep-one) (equal? b here)
                            ;; a peek the reader put in a second window
                            ;; is theirs to look at
                            (window-showing b))
                  (peek-drop! b)))
              (peek-buffers))))

;; the side away from the window a look was asked from: the side the
;; card floats against. A window on the right half of the frame gets
;; the card on the left; any other, the right.
(define (peek-side-away-from win)
  (let ((r (assoc win (window-rects))))
    (if (and r (> (+ (nth 2 r) (* 0.5 (nth 4 r))) 0.5)) 'left 'right)))

;; show NAME as the peek: the frame's look, in a window the selected one
;; owns (preview-show ... 'other). The next peek takes that window again,
;; and the buffer it replaced comes back when the peek goes. The selected
;; window and its point stay. Returns the window the peek took.
(define (peek-show! name)
  ;; Peeks are deprecated: a show is an ordinary display in another window
  (display-buffer-other-window! name))

;; a window the focus commands may land on: not a peek's
;; Peeks are deprecated, so no window refuses the focus. A preview shows
;; an ordinary buffer in an ordinary window, and Cmd-arrow lands in it
;; like any other.
(define (window-focusable? w) (and w #t))

;; the peek verb. OPEN makes or finds the buffer and returns its name.
;; KNOWN is the name it will have, so "did the peek make it" is answered
;; before OPEN runs: a buffer that was known stays a real buffer. OPEN
;; may move the selected window (visit does); the window is put back.
;; A look is transparent to the point: nothing in this path
;; selects a window. OPEN opens the buffer, best without a window
;; (visit-quietly); an opener that showed it in the selected window has
;; the listing put back there, in place, with no selection change.
(define (peek! known open)
  ;; Peeks are deprecated. The peek verbs stay for their callers, and each
  ;; one opens an ordinary buffer in another window by the display chain:
  ;; the window of its own mode first. Nothing marks it, nothing kills it
  ;; later, and the focus stays where it is.
  (let* ((here (current-buffer))
         (buf (open)))
    (when (and (string? buf) (not (equal? buf here)))
      (display-buffer-other-window! buf))
    buf))
(domain! 'files)
(effects! '(read))

;;; --- how big a file a look opens --------------------------------------------
;;; A look is not an open. Reading the file costs its bytes, the mode costs
;;; a parse of them, and the window costs one line structure per line. A
;;; listing of machine-generated files can put an 18 MB blob under the
;;; point, and a look there is seconds of work for a row the reader passes
;;; over. Above the cap a look shows nothing and says the size.
;;;
;;; The cap holds a LOOK only. RET opens the file, whatever its size: the
;;; reader asked for that one. A buffer that is open already is shown as
;;; before, because the work is paid.
;;;
;;; layouts.scm makes the variable customizable.

(define peek-max-file-size 1048576)

;; #t when a look at PATH would open a file too big to look at. A path
;; with a buffer already, a directory, and a remote path all answer #f:
;; file-size reads local files, and a remote stat answers 0. So does a
;; file shown from disk: a look at a video reads none of it.
(define (peek-too-big? path)
  (and (> peek-max-file-size 0)
       (string? path)
       (not (file-shown-from-disk? path))
       (let ((p (normalize-file-input path)))
         (and (not (buffer-known? p))
              (not (file-directory? p))
              (> (file-size p) peek-max-file-size)))))

;; Say why the window did not change. The size is the whole reason, so the
;; message carries it and the name of the variable that sets the cap.
(define (peek-say-too-big! path)
  (let ((p (normalize-file-input path)))
    (message (string-append (cadr (path-split p)) " is " (cadr (file-stat p))
                            ", too big to look at. RET opens it."))
    #f))

;; a file, previewed: the one opener every listing of files shares
(define (peek-file! path)
  (if (peek-too-big? path)
      (peek-say-too-big! path)
      (peek! path (lambda () (visit-quietly path)))))

;; Peeks are deprecated, so there is no keep step and no second gesture.
;; This is the C-x 4 door: an ask to open something shows it in the other
;; window and it is yours from that moment — never a buffer some later
;; preview may dispose of. The window you are in keeps its buffer and its
;; point. peek! is the other door, for a listing that shows a row as the
;; highlight moves; only that one leaves the buffer disposable.
(define (peek-or-keep! known open)
  (peek! known open)
  'shown)

;; RET on a row: preview KNOWN, or open it when it is the one on screen
(define (peek-or-open! known open)
  (peek! known open)
  'open)

;; the buffer the frame's look shows beside the reader or in the card,
;; while it still shows: a peek, or a buffer that existed before
(define (peek-shown)
  (let ((s (preview-slot)))
    (and s (member (nth 1 s) '(other float))
         (window-exists? (nth 3 s)) (equal? (window-buffer (nth 3 s)) (car s))
         (car s))))

;; dismiss the look on screen: its window goes or gives back what it
;; covered, and a buffer the peek made goes to recent. #t when there was one.
(define (peek-dismiss!)
  (let* ((b (peek-shown))
         (shown (dedupe-names (append (if b (list b) '())
                                      (filter window-showing (peek-buffers))))))
    (when b (preview-end #f))
    (for-each (lambda (p)
                (unless (equal? p b)
                  (if (equal? (float-buffer) p)
                      (float-close!)
                      (let ((w (window-showing p)))
                        (when w (window-quit-restore! w)))))
                (when (peek-buffer? p) (peek-drop! p)))
              shown)
    (pair? shown)))

;; any work window that is not ME: the float is not one
(define (other-work-window-id me)
  (let ((float (float-window)))
    (let loop ((ws (window-list)))
      (cond ((null? ws) #f)
            ((and (not (equal? (car (car ws)) me))
                  (not (equal? (car (car ws)) float)))
             (car (car ws)))
            (else (loop (cdr ws)))))))

;; show NAME as your own beside the listing, never on top of it: the
;; other work window when there is one, else a split beside this one
;; (Emacs find-file-other-window). Selects the window it used.
(define (show-in-other-work-window! name)
  (let* ((me (active-window))
         (w (other-work-window-id me)))
    (cond ((display-foreign? name) (pop-to-buffer name))
          (w (select-window! w) (switch-to-buffer-here! name))
          (else (split-window! 'h 0.5) (other-window!) (switch-to-buffer-here! name)))
    (active-window)))

;; open KNOWN as a buffer of your own, beside the listing: the float
;; gives it up, the mark goes, and the other work window shows it. Not a
;; peek yet, it opens the same way.
(define (peek-open! known open)
  (let ((me (active-window)))
    (when (and (string? known) (peek-buffer? known))
      (peek-keep! known)
      (when (equal? (float-buffer) known) (float-close!))
      (when (window-exists? me) (select-window! me)))
    (let ((buf (if (and (string? known) (buffer-known? known)) known (open))))
      (when (string? buf)
        ;; an opener may have shown it here; the listing takes its window back
        (when (and (window-exists? me) (not (equal? (window-buffer me) (current-buffer))))
          #t)
        (show-in-other-work-window! buf)))
    'open))

(define (peek-keep! name)
  (when (peek-buffer? name)
    (buffer-set-local! name 'preview-opened #f)
    ;; a kept buffer keeps its window: the look is over
    (when (equal? (peek-shown) name) (preview-end #t))
    (peek-forget-recent! (or (buffer-path name)
                             (buffer-local name 'browse-url)
                             (buffer-local name 'dired-dir)
                             name))
    (message (string-append "kept " name))))

;; an edit keeps: a file you typed in is yours. A listing reports itself
;; as modified and has no path, so only a file answers here.
(define (peek-keep-if-edited! b)
  (when (and (peek-buffer? b) (buffer-path b) (buffer-modified? b))
    (peek-keep! b)))

(define (peek--keep-if-edited-hook!)
    (peek-keep-if-edited! (current-buffer)))

(add-hook! 'post-command-hook 'peek--keep-if-edited-hook!)

(define-command "keep-buffer" "Keep this peek: it becomes an ordinary buffer"
  (lambda ()
    (let ((b (current-buffer)))
      (if (peek-buffer? b)
          (peek-keep! b)
          (message "not a peek")))))

(public! 'window-fill-buffers
  "(window-fill-buffers) — the buffers a window in this frame may be filled with, most recent first: the frame's context, never the raw MRU ring")
(public! 'window-fill-decide
  "(window-fill-decide SNAPSHOT POOL) — the one rule for what fills a window: (delete), (restore BUF), (show BUF) or (blank) from a snapshot plist (restore previous shown dying others refill) and the pool; pure")
(public! 'window-fill-snapshot
  "(window-fill-snapshot WIN DYING &rest MORE) — the live snapshot of WIN for window-fill-decide; MORE overrides keys")
(public! 'window-fill-apply!
  "(window-fill-apply! WIN ACTION) — apply an answer of window-fill-decide to WIN; #t when the window changed")
(public! 'window-fill-blank
  "(window-fill-blank) — context scratch fallback, or #f; fixed target layouts leave spare capacity empty")
(public! 'fill-candidate?
  "(fill-candidate? NAME) — eligible ordinary buffer: known, not hidden, context-only, floating or peek")
(public! 'peek!
  "(peek! KNOWN OPEN) — deprecated name: open the buffer OPEN returns in another window by the display chain, its own mode's window first; the focus stays")
(public! 'peek-or-keep!
  "(peek-or-keep! KNOWN OPEN) — deprecated name: open KNOWN in another window, as peek! does")
(public! 'peek-or-open!
  "(peek-or-open! KNOWN OPEN) — deprecated name: open KNOWN in another window, as peek! does")
(public! 'peek-dismiss!
  "(peek-dismiss!) — dismiss every peek on screen; #t when there was one")
(public! 'peek-open!
  "(peek-open! KNOWN OPEN) — open KNOWN as your own in the selected window: a peek is kept and the float gives it up; not a peek yet, OPEN runs")
(public! 'peek-file!
  "(peek-file! PATH) — deprecated name: open the file at PATH in another window, as peek! does")
(public! 'peek-keep!
  "(peek-keep! NAME) — keep a peek: clear the mark; the buffer and its window stay")
(public! 'peek-buffer?
  "(peek-buffer? NAME) — #t when NAME is a peek: shown to look at, killed when the next peek replaces it")
(public! 'peek-too-big?
  "(peek-too-big? PATH) — #t when a look at PATH would open a file over peek-max-file-size; a path with a buffer already, a directory, and a remote path answer #f")
(public! 'peek-say-too-big!
  "(peek-say-too-big! PATH) — say that PATH is too big to look at, and answer #f; the message names the size")
(public! 'file-shown-from-disk?
  "(file-shown-from-disk? PATH) — #t when PATH opens in a viewer that reads the file from disk: the buffer holds no bytes, and no size cap applies")
(public! 'buffer-unread-file?
  "(buffer-unread-file? BUF) — #t when BUF is bound to a file it never read; nothing in it stands for the file, so it is never saved over it")
(domain! 'files)
(effects! '(read))

;;; --- mode layouts -------------------------------------------------------------
;;; A display rule says where ONE buffer goes. A mode that owns the frame needs
;;; more: writing mode is a document and its scratch, side by side, and nothing
;;; else. The mode declares that arrangement as data, and this engine puts the
;;; windows there:
;;;
;;;   (define-mode-layout! "writing-mode" '(h 0.62 self scratch-buffer))
;;;
;;; The spec is (DIR RATIO PANE PANE ...), or one PANE alone for a full frame.
;;; DIR is 'h (side by side) or 'v (one above the other). RATIO is the share the
;;; first pane takes. A PANE names a buffer in one of three ways:
;;;
;;;   self       the buffer the mode is on
;;;   SYMBOL     the buffer named by that buffer-local of the anchor
;;;   "NAME"     that buffer, by name
;;;
;;; The engine drops a pane whose buffer does not exist, so a document with no
;;; scratch yet fills the frame alone. It arranges the frame when a mode turns
;;; on in the selected window, and stays out of the way everywhere else: the
;;; desktop rebuilds its own saved windows, a background buffer never replaces
;;; the windows in front of somebody, and the ordinary split and delete commands
;;; still work while the mode is on.

(define (define-mode-layout! mode spec) (mode-put! mode 'layout spec))
(define (mode-layout mode) (mode-get mode 'layout))

;; the layout BUF declares. A minor mode answers before the major mode: it is
;; the more specific statement about the same buffer.
(define (buffer-layout buf)
  (let loop ((names (append (or (buffer-local buf 'minor-modes) '())
                            (let ((m (buffer-local buf 'mode-name)))
                              (if m (list m) '())))))
    (if (null? names)
        #f
        (let ((spec (mode-layout (car names))))
          (if spec spec (loop (cdr names)))))))

;; A pane that may not exist yet: (ensure "NAME" "COMMAND") runs COMMAND
;; when NAME is absent, then uses NAME. This is what lets a declared
;; layout be the whole truth — kill a pane's buffer, ask for the layout
;; again, and the command builds it back. A plain "NAME" pane still
;; drops when it is missing, because a document with no scratch yet must
;; fill the frame alone.
(define (layout--ensure name maker)
  (unless (buffer-known? name)
    (when (string? maker) (run-command maker)))
  (and (buffer-known? name) name))

(define (layout--pane anchor pane)
  (cond ((equal? pane 'self) anchor)
        ((string? pane) (and (buffer-known? pane) pane))
        ((and (pair? pane) (equal? (car pane) 'ensure))
         (layout--ensure (car (cdr pane))
                         (and (pair? (cdr (cdr pane))) (car (cdr (cdr pane))))))
        ((symbol? pane)
         (let ((v (buffer-local anchor pane)))
           (and (string? v) (buffer-known? v) v)))
        (else #f)))

;; the buffers the spec names, in order, without repeats
(define (layout--panes anchor spec)
  (let loop ((rest (if (pair? spec) (cdr (cdr spec)) (list spec))) (acc '()))
    (if (null? rest)
        (reverse acc)
        (let ((b (layout--pane anchor (car rest))))
          (loop (cdr rest) (if (and b (not (member b acc))) (cons b acc) acc))))))

(define (layout--dir spec) (if (pair? spec) (car spec) 'h))
(define (layout--ratio spec) (if (pair? spec) (cadr spec) 0.5))

(domain! 'files)
(effects! '(read))

;;; --- the pool: which buffers belong in this frame's windows -------------
;;; One source, the way a completion source answers a prompt. The buffers
;;; a window in this frame may be filled with, most recent first, are the
;;; frame's context: editor.scm knows no groups, so the base answer is the
;;; MRU ring, and groups.scm sets the source to the group's members when
;;; the frame stands in one. Every site that fills a window reads this
;;; and never the ring itself: the columns of a layout, the window a kill
;;; empties, the buffer q falls to. A layout that read the ring pulled
;;; buffers in from other groups.

;; a buffer a window may be filled with: known, not hidden, not floating,
;; not a peek (a look, not a place)
(domain! 'files)
(effects! '(read))

;; a buffer a window may be filled with: known, not hidden, not floating,
;; not a peek (a look, not a place)
(define (fill-candidate? b)
  (and (string? b) (buffer-known? b)
       (not (string-prefix? " " b))
       (not (buffer-local b 'context-only))
       (not (float--class? b))
       (not (peek-buffer? b))))

(define window-fill-source (lambda () (buffer-list-mru)))
(define window-fill-primary? (lambda (buffer) #t))
(define window-fill-member? (lambda (buffer) #t))

;; History permits utility covers, but never another group's content.
;; groups.scm supplies ownership policy separately from layout fill policy.
(define window-history-member? (lambda (win buffer) #t))
(define (window-eligible-history win)
  (filter (lambda (b)
            (and (buffer-known? b) (not (equal? b (window-buffer win)))
                 (window-history-member? win b)))
          (window-prev-buffers win)))

(define (window-fill-buffers)
  (filter fill-candidate? (window-fill-source)))

;;; --- the fill rule: what fills a window ---------------------------------
;;; One pure function answers what fills a window, from a snapshot of the
;;; window and the pool. Every site that empties a pane or adds one asks
;;; it and applies the answer: the window a kill empties, the buffer q
;;; falls to, the pane a moved buffer leaves, the window a split makes,
;;; the columns of a layout. Before it, seven sites each kept their own
;;; precedence and their own eligibility.
;;;
;;; SNAPSHOT is a plist:
;;;   restore   what a display did to the window, (KIND BUF POINT) or #f
;;;   previous  the window's own past, most recent first
;;;   shown     what the other windows of the frame show
;;;   dying     the buffer leaving the window, or #f
;;;   others    #t when the window may go: another window keeps the frame
;;;   refill    #f when the pool only says who is eligible and fills
;;;             nothing itself; #t (the default) when it fills the window
;;;             after the window's own past
;;; POOL is window-fill-buffers, or the pool of the window's own group.
;;;
;;; A buffer is eligible when the pool holds it and it is not the dying
;;; one. The past and the pool never show what another window shows; a
;;; covered buffer comes back even when another window shows it (Q20).
;;; The answer, in order:
;;;   (delete)       the display made the window and another one remains
;;;   (restore BUF)  the display covered BUF, and BUF is eligible
;;;   (show BUF)     the first eligible buffer of the window's past
;;;   (show BUF)     the first eligible buffer of the pool, when refill
;;;   (delete)       nothing to show, and another window remains
;;;   (blank)        nothing to show: the caller's blank, or nothing
(domain! 'windows)
(effects! '(pure))
(define (window-fill-decide snapshot pool)
  (let* ((restore (plist-get snapshot 'restore))
         (previous (or (plist-get snapshot 'previous) '()))
         (shown (or (plist-get snapshot 'shown) '()))
         (dying (plist-get snapshot 'dying))
         (others (plist-get snapshot 'others))
         (refill (let ((m (memq 'refill snapshot))) (if m (cadr m) #t)))
         (eligible? (lambda (b) (and (member b pool) (not (equal? b dying)) #t)))
         (free? (lambda (b) (and (eligible? b) (not (member b shown)))))
         (kind (and (pair? restore) (car restore)))
         (covered (and (pair? restore) (pair? (cdr restore)) (cadr restore)))
         (past (find free? previous))
         (next (and refill (find free? pool))))
    (cond ((and (equal? kind 'window) others) '(delete))
          ((and (equal? kind 'other) covered (eligible? covered)) (list 'restore covered))
          (past (list 'show past))
          (next (list 'show next))
          (others '(delete))
          (else '(blank)))))

;; the buffers the other windows of WIN's frame show
(domain! 'windows)
(effects! '(read))
(define (window-fill-shown-elsewhere win)
  (let ((frame (frame-of-window win)))
    (map cadr
         (filter (lambda (row)
                   (and (equal? (caddr row) frame) (not (equal? (car row) win))))
                 (window-list-all)))))

;; the live snapshot of WIN for window-fill-decide: its restore record,
;; its past, what the frame's other windows show, and whether another
;; window keeps the frame. DYING is the buffer leaving the window. MORE
;; overrides a key: 'restore #f ignores the record, 'others #f keeps the
;; window, 'refill #f keeps the pool out.
(define (window-fill-snapshot win dying &rest more)
  (append more
          (list 'restore (window-restore win)
                'previous (window-prev-buffers win)
                'shown (window-fill-shown-elsewhere win)
                'dying dying
                'others (and (other-window-id win) #t))))

;; apply ACTION, an answer of window-fill-decide, to WIN. #t when the
;; window changed: (blank) leaves it as it is, and so does a (delete) no
;; other window can absorb.
(domain! 'windows)
(effects! '(write display))
(define (window-fill-apply! win action)
  (let ((what (car action)))
    (cond ((member what '(restore show))
           (window-set-buffer! win (cadr action))
           (window-state-changed!)
           #t)
          ((equal? what 'delete)
           (cond ((other-window-id win)
                  (if (equal? win (active-window)) (delete-window!) (delete-window-id! win))
                  #t)
                 (else #f)))
          (else #f))))
(domain! 'files)
(effects! '(read))

;; The blank pane: the buffer a layout shows in a pane the pool cannot
;; fill. editor.scm knows no groups, so the base answer is none, and a
;; layout stays short; scratch.scm sets the source to the group's scratch
;; when the frame stands in a group, so a sealed group's layout keeps its
;; shape without a buffer from outside.
(define window-fill-blank (lambda () #f))

;;; --- the windows of the frame ---------------------------------------------

;; the work windows on screen, as window ids, in screen order
(define (layout-pane-windows)
  (map car (filter layout-visible-window? (window-list))))

;; The hidden windows that this frame may show, most recently used first.
;; The fill policy decides: a hidden window of another group is not one.
(define (layout-hidden-windows)
  (map car (filter (lambda (row)
                     (and (fill-candidate? (cadr row)) (window-fill-member? (cadr row))))
                   (window-hidden-list))))

;; the buffer of a window, visible or hidden
(define (window-buffer-any win)
  (let ((row (or (assoc win (window-list)) (assoc win (window-hidden-list)))))
    (and row (cadr row))))

(define (window-hidden-clear!)
  (for-each (lambda (row) (window-hidden-delete! (car row))) (window-hidden-list)))

;; The engine's entry point: a mode turned on in BUF. Arrange the frame only
;; when BUF is the buffer the user is looking at.
(define (layout-enter! buf)
  (let ((spec (buffer-layout buf)))
    (if (and spec
             (not (panes-current-layout))
             (equal? (window-buffer (active-window)) buf))
        (apply-layout! buf spec)
        #f)))

(define-command "reset-layout" "Arrange the frame the way this buffer's mode asks"
  (lambda ()
    (let ((spec (buffer-layout (current-buffer))))
      (if spec
          (apply-layout! (current-buffer) spec)
          (message "This buffer's modes declare no layout")))))

;; Kill every buffer a window holds: the one it shows and its whole
;; history. One question first; a file with unsaved text still asks for
;; itself, and a no keeps that one and goes on with the rest.
(define (window-kill-buffers! &optional win)
  (let* ((win (or win (active-window)))
         (bufs (filter buffer-known?
                       (cons (window-buffer win) (window-prev-buffers win)))))
    (if (null? bufs)
        (message "This window holds no buffers")
        (y-or-n? (string-append "Kill the " (number->string (length bufs))
                                " buffers of this window? ")
          (lambda (yes)
            (when yes
              (let loop ((left bufs) (killed 0))
                (if (null? left)
                    (message (string-append "Killed " (number->string killed) " buffers"))
                    (kill-buffer-confirm! (car left)
                      (lambda (done)
                        (loop (cdr left) (if done (+ killed 1) killed))))))))))))

(define-command "window-kill-buffers"
  "Kill every buffer in this window: the one it shows and its whole history"
  window-kill-buffers!)
(catalog-meta! 'command "window-kill-buffers" 'domain 'windows 'effects '(destroy))
(global-set-key "C-x K" "window-kill-buffers")

(define (window-unwind-or-close! win)
  ;; q never closes a pane: the model steps back in the window's stack
  ;; (panes-quit!); a window the model does not hold steps back in its
  ;; history, else shows the next work buffer
  (let* ((cur (window-buffer win))
         (history (window-eligible-history win)))
    (cond ((panes-quit! win) #t)
          ((pair? history)
           (display-buffer-in-window! win (car history))
           (set-window-restore! win #f)
           (set-window-prev-buffers! win (cdr history))
           #t)
          ((let ((next (find (lambda (b) (and (not (equal? b cur)) (not (window-showing b))))
                             (window-fill-buffers))))
             (and next
                  (begin (display-buffer-in-window! win next)
                         (set-window-restore! win #f)
                         #t))))
          (else (message "No other buffer to show here") #f))))

;; Quit consumes this window's own stack. An exhausted window closes before
;; the buffer dies, so kill repair cannot refill it from group recency.
(define-command "quit-window" "Kill this buffer and go back"
  (lambda ()
    (cond
      ;; a peek goes with its window: the look is over, and the layout
      ;; is what it was. In a split the split closes; alone, the window
      ;; falls to the next buffer.
      ((peek-buffer? (current-buffer))
        (let* ((cur (current-buffer))
               (win (active-window))
               (rec (window-restore win)))
          (if (and rec (equal? (car rec) 'preview))
              (window-quit-restore! win)
              (begin
                (set-window-restore! win #f)
                (window-fill-apply! win
                  (window-fill-decide (window-fill-snapshot win cur 'restore rec)
                                      (window-fill-buffers)))))
          (peek-drop! cur)))
      ;; from any other buffer, a peek on screen goes first: q in the
      ;; listing that peeked takes the look, then the listing
      ((peek-dismiss!) #t)
      (else
        (let ((cur (current-buffer)))
          ;; a file with edits you did not save is not a listing: say so and
          ;; stay. A listing reports itself as modified — it has no path.
          (if (and (buffer-path cur) (buffer-modified? cur))
              (message "Buffer is modified — save it, or C-x k to kill it")
              (when (window-unwind-or-close! (active-window))
                ;; A live process dies only when its buffer can be dismissed.
                (if (process-running? cur) (process-kill! cur))
                (buffer-kill! cur))))))))

;; q quits every buffer you cannot type in. The read-only keymap sits
;; between the buffer's own map and the global one, so a mode that wants q
;; for something else — code-mode's exit, notmuch's search — still wins.
(local-set-key* " *read-only*" "q" "quit-window")

(domain! 'processes)
(effects! '(write execute))
(domain! 'processes)
(effects! '(write execute))

;;; --- winner: layout undo ------------------------------------------------------
;;; C-c <left> and C-c <right> walk the window model's layout history
;;; (panes-history.scm); winner is the Emacs name for the walk.

(define (winner-previous!) (run-command "layout-undo"))
(define (winner-next!) (run-command "layout-redo"))

(define-command "winner-previous" "Switch to the previous window and buffer arrangement"
  (lambda () (winner-previous!)))
(define-command "winner-next" "Switch to the next window and buffer arrangement"
  (lambda () (winner-next!)))
(define-command "winner-undo" "Restore the previous window and buffer arrangement"
  (lambda () (winner-previous!)))
(define-command "winner-redo" "Walk forward to a later window and buffer arrangement"
  (lambda () (winner-next!)))

(for-each
  (lambda (name) (catalog-meta! 'command name 'domain 'windows 'effects '(write display)))
  '("winner-previous" "winner-next" "winner-undo" "winner-redo"))

;; C-x 1, C-x 2 and 3, C-x 0 are model edits (panes-mode.scm): the frame
;; shows what the model then says
(define (delete-other-windows!) (panes--delete-other-windows!))

(define (split-window! dir &optional ratio) (panes--split-window!))

(define (delete-window!) (panes--delete-window!))

(define (delete-window-id! id)
  (let ((result (builtin-delete-window-id! id)))
    (window-state-changed!)
    result))
(domain! 'processes)
(effects! '(write execute))

;;; --- asking about windows -------------------------------------------------------
;;; (window-list) is ((id buffer) ...) and five places walked it by hand,
;;; each with its own loop and its own idea of what to return when nothing
;;; matched. These are the four questions that were being asked.

;; the window showing NAME, or #f
(define (window-showing name)
  (let ((ws (filter (lambda (w) (equal? (cadr w) name)) (window-list))))
    (if (null? ws) #f (car (car ws)))))

;; ...that is not EXCEPT — for "put it somewhere other than here"
(define (window-showing-other name except)
  (let ((ws (filter (lambda (w) (and (equal? (cadr w) name)
                                     (not (equal? (car w) except))))
                    (window-list))))
    (if (null? ws) #f (car (car ws)))))

;; the buffer a window is showing, or #f
(define (window-buffer id)
  (let ((w (assoc id (window-list))))
    (and w (cadr w))))

;; any window that is not ME, or #f when ME is the only one
(define (other-window-id me)
  (let loop ((ws (window-list)))
    (cond ((null? ws) #f)
          ((not (equal? (car (car ws)) me)) (car (car ws)))
          (else (loop (cdr ws))))))

;; C-c q : ask from anywhere. In a grouped buffer (its chat included) the
;; prompt becomes a turn in the group's one chat; ungrouped, it goes to
;; the global *chat* buffer -- follow-ups with C-c RET.
(domain! 'unknown)
(effects! '(unknown))

;;; --- tiling windows --------------------------------------------------------

;; C-x 2 and C-x 3: an empty pane beside this one, filled by the fill rule
(define (split-window-with-other-buffer! direction)
  (panes--split-window!))

(define-command "split-window-below" "Split the window in two, one above the other"
  (lambda () (split-window-with-other-buffer! 'v)))
(define-command "split-window-right" "Split the window in two, side by side"
  (lambda () (split-window-with-other-buffer! 'h)))
(define-command "delete-window" "Delete the selected window"
  (lambda ()
    (if (not (delete-window!)) (message "Attempt to delete sole window"))))
;; `C-x 1` from anywhere makes one window. A float is not one of them:
;; its buffer stops floating rather than float in the one window left.
(define-command "delete-other-windows" "Make the selected window the only one"
  (lambda ()
    (let ((buf (float-buffer)))
      (delete-other-windows!)
      (when buf (window-float-class! buf #f)))))

;; frames: one per attached browser. Deleting the selected frame while its
;; browser is still connected resets it to a fresh single window (the client
;; immediately re-attaches under the same id); deleting a disconnected
;; frame removes it for good.
(define-command "delete-frame" "Delete the selected frame"
  (lambda ()
    (delete-frame!)
    (prune-frame-locals!)))

;; landing in a rich chat/agent window puts point in its input region —
;; the transcript is for reading, the prompt is where typing goes
(define (chat-snap-to-input!)
  (let ((buf (current-buffer)))
    (when (chat-rich-view? buf)
      (when (< (point) (chat-input-start buf))
        (end-of-buffer!)))))

(define-command "other-window" "Select another window in cyclic order"
  (lambda ()
    ;; a peek's window is passed by: a preview takes no focus
    (let ((start (active-window)))
      (other-window!)
      (let loop ((n (length (window-list))))
        (when (and (> n 0) (not (window-focusable? (active-window)))
                   (not (equal? (active-window) start)))
          (other-window!)
          (loop (- n 1)))))
    (chat-snap-to-input!)))
(for-each
  (lambda (name) (catalog-meta! 'command name 'domain 'windows 'effects '(write display)))
  '("split-window-below" "split-window-right" "delete-window"
    "delete-other-windows" "other-window"))

(define-command "previous-pane" "Select the previous pane"
  (lambda () (focus-move-safe! 'previous)))
(define-command "next-pane" "Select the next pane"
  (lambda () (focus-move-safe! 'next)))
(define-command "focus-up" "Select the window above"
  (lambda () (focus-move-safe! 'up)))
(define-command "focus-down" "Select the window below"
  (lambda () (focus-move-safe! 'down)))

(for-each
  (lambda (spec)
    (let ((name (car spec)) (dir (cadr spec)))
      (define-command name "Move this buffer to the neighboring pane and reveal its previous buffer"
        (lambda () (buffer-move! dir)))
      (catalog-meta! 'command name 'domain 'windows 'effects '(write display))))
  '(("buffer-previous-pane" previous) ("buffer-next-pane" next)))

(define-command "window-previous-pane" "Move this window to the front of the previous pane with its complete buffer stack"
  ;; the window model moves it (panes--shift-window!, panes-mode.scm)
  (lambda () (panes--shift-window! -1)))
(define-command "window-next-pane" "Move this window to the front of the next pane with its complete buffer stack"
  (lambda () (panes--shift-window! 1)))
(for-each
  (lambda (name) (catalog-meta! 'command name 'domain 'windows 'effects '(write display)))
  '("previous-pane" "next-pane" "focus-up" "focus-down"
    "window-previous-pane" "window-next-pane"))

(define-command "window-eat" "Eat the neighboring pane and take its space"
  (lambda () (window-eat!)))
(catalog-meta! 'command "window-eat" 'domain 'windows 'effects '(write display))

;; No arrow family has default keys; an installer binds them:
;; (focus-default-keybindings MODIFIERS) binds the arrows to focus-*,
;; (window-default-keybindings MODIFIERS) to window-*, and
;; (buffer-default-keybindings MODIFIERS) to buffer-*. MODIFIERS is one
;; symbol or a list from shift, control, meta, super. The client sends
;; the Cmd-arrows from an editable buffer only in its movement state
;; (before the first key, or after ESC); in the editing state the
;; browser keeps them as line and document start and end.
(define *direction-names* '("left" "right" "up" "down"))

(define (arrow-chord modifiers key)
  (let* ((mods (cond ((or (not modifiers) (null? modifiers)) '(shift))
                     ((symbol? modifiers) (list modifiers))
                     (else modifiers)))
         (has? (lambda (m) (member m mods))))
    (string-append (if (has? 'super) "s-" "")
                   (if (has? 'control) "C-" "")
                   (if (has? 'meta) "M-" "")
                   (if (has? 'shift) "S-" "")
                   key)))

(define (arrow-command family dir)
  "The command FAMILY (focus, window or buffer) runs on the arrow DIR: left
and right walk the panes. The panes are one row, so up and down move only
the focus; #f for a window or a buffer."
  (let ((pane (cond ((equal? dir "left") "previous-pane")
                    ((equal? dir "right") "next-pane")
                    (else #f))))
    (cond ((and (not pane) (equal? family "focus")) (string-append family "-" dir))
          ((not pane) #f)
          ((equal? family "focus") pane)
          (else (string-append family "-" pane)))))

(define (install-arrow-keys! modifiers family)
  (for-each
    (lambda (dir)
      (let ((cmd (arrow-command family dir)))
        (when cmd (global-set-key (arrow-chord modifiers (string-append "<" dir ">")) cmd))))
    *direction-names*))

(define (focus-default-keybindings &optional modifiers)
  (install-arrow-keys! modifiers "focus"))

;; default chords: Cmd-Shift for the window and buffer families
(define (window-default-keybindings &optional modifiers)
  (install-arrow-keys! (or modifiers '(shift super)) "window"))

(define (buffer-default-keybindings &optional modifiers)
  (install-arrow-keys! (or modifiers '(shift super)) "buffer"))

(domain! 'unknown)
(effects! '(unknown))

;; The motion keys of the focus state. Left and right walk the panes:
;; Cmd moves the focus, Cmd-Shift moves the window, Shift moves the buffer.
;; Up and down walk this window's buffers in the minibuffer (switch.scm):
;; Shift walks all of them, Cmd only those of this mode. The editing state
;; keeps these keys for CUA motion and selection.
(for-each
  (lambda (k) (global-set-key (car k) (cadr k)))
  '(("s-<left>" "previous-pane")
    ("s-<right>" "next-pane")
    ("s-S-<left>" "pane-move-left")
    ("s-S-<right>" "pane-move-right")
    ("S-<left>" "window-previous-pane")
    ("S-<right>" "window-next-pane")
    ("S-<up>" "pane-previous-window")
    ("S-<down>" "pane-next-window")
    ("s-<up>" "window-previous-mode-buffer")
    ("s-<down>" "window-next-mode-buffer")))

;;; --- the public API of this file ----------------------------------------------
;;; The catalog scope of each entry is the one it had in editor.scm.

(domain! 'buffers)
(effects! '(write display))
(category! 'buffers)
(public! 'display-foreign? "(display-foreign? NAME) — #t when a pane on NAME would take the frame out of its group; groups.scm answers")
(domain! 'windows)
(effects! '(read))
(category! 'windows)
(public! 'window-showing "(window-showing NAME) — the window showing NAME, or #f")
(public! 'window-buffer "(window-buffer ID) — the buffer that window shows, or #f")
(public! 'other-window-id "(other-window-id ME) — any window that is not ME, or #f")
(effects! '(write display))
(public! 'split-window! "(split-window! 'h|'v [RATIO]) — ratio = first pane's share")
(public! 'delete-window-id! "(delete-window-id! ID)")
(public! 'delete-other-windows! "Make the active window the only one")
(public! 'display-buffer
  "(display-buffer NAME [ALIST]) — show NAME where the window model places it, or where a rule's own action puts it (the float, the dock, a popup), selecting nothing; returns the window. ALIST is a plist: 'category KIND, 'requested #t (an agent shows what the user asked to see)")
(public! 'pop-to-buffer
  "(pop-to-buffer NAME [ALIST]) — display-buffer, then select the window it used")
(public! 'define-display-action!
  "(define-display-action! NAME FN) — register a display action; FN takes NAME and ALIST and returns a window or #f")
(public! 'window-mode
  "(window-mode WIN) — the major mode of the buffer WIN shows, or #f")
(public! 'window-preferred-mode
  "(window-preferred-mode WIN) — explicit cycle mode, else the nearest work buffer's mode beneath temporary covers")
(public! 'window-prefers-buffer?
  "(window-prefers-buffer? WIN BUF) — whether BUF matches WIN's preferred mode, including derived modes")
(public! 'window-showing-mode
  "(window-showing-mode MODE [EXCEPT]) — the work window preferring or showing MODE, or #f")
(public! 'get-visible-buffers
  "(get-visible-buffers) — the buffers in the user's frame windows, most recently visited first")
(catalog-meta! 'function "get-visible-buffers" 'effects '(read))
(effects! '(write display))
(public! 'get-other-window
  "(get-other-window) — the window to show a buffer in for the user, never the active one; below the layout's capacity the model adds a pane")
(effects! '(read))
(public! 'window-quit-restore!
  "(window-quit-restore! WIN) — undo what a display did to WIN: delete the window it made, or put back the buffer it replaced")
(public! 'display-buffer-other-window! "(display-buffer-other-window! NAME) — show NAME without leaving this window, as the user asked: an agent's way to show a buffer")
(public! 'apply-layout! "(apply-layout! ANCHOR SPEC) — arrange the frame by SPEC, ANCHOR keeping focus")
(public! 'window-hidden-clear!
  "(window-hidden-clear!) — delete every hidden window of the selected frame")
(public! 'window-buffer-any
  "(window-buffer-any WIN) — the buffer of window WIN, visible or hidden, or #f")
(public! 'window-eat!
  "(window-eat! [DIR]) — the neighboring pane goes away and this window takes its rectangle; DIR is left, right, up or down")
(effects! '(write))
(public! 'add-display-rule!
  "(add-display-rule! PATTERN ACTION [PARAMS]) — set display policy without showing a buffer. PATTERN is a name substring, (category KIND), or a procedure of NAME and ALIST; ACTION is one action name or a list: pop-up-window, reuse-window, use-some-window, same-window")
(public! 'define-mode-layout!
  "(define-mode-layout! MODE '(h|v RATIO PANE ...)) — set a mode layout without applying it")
(effects! '(read))
(public! 'buffer-layout "(buffer-layout NAME) — the layout NAME's modes declare, or #f")
(effects! '(write))
;;; The flat window list. M-x windows-list-ring opens *windows*: the windows of the
;;; selected frame in ring order, the ones on screen filled, the ones
;;; waiting off it hollow. RET goes to one, k closes it, c consolidates
;;; from it, r names it.

(domain! 'windows)
(effects! '(write display))

(define *windows-list-buffer* "*windows*")

(defface! 'win-on 'fg "#2e6b45" 'weight "600")
(defface! 'win-off 'fg "#8a857a")
(defface! 'win-name 'fg "#26356b" 'weight "600")

(define (windows-list-ids buf)
  ;; the windows on screen first, left to right; then the waiting ones
  (map number->string (append (layout-pane-windows) (layout-hidden-windows))))

(define (windows-list-window id)
  (let ((win (string->number id)))
    (and win (or (window-exists? win) (assoc win (window-hidden-list))) win)))

(define (windows-list-pane win)
  (let* ((l (panes-layout))
         (k (and l win (panes-key-of-handle l win))))
    (or (and k (panes-pane-of l k)) "")))

(define (windows-list-narrow-cells buf id)
  (let ((cells (windows-list-cells buf id)))
    (list (nth 0 cells) (nth 1 cells) (nth 4 cells) (nth 5 cells))))

(define (windows-list-cells buf id)
  ;; ● the window you are in, ■ on screen, □ waiting behind its pane
  (let* ((win (windows-list-window id))
         (on (and win (member win (layout-pane-windows)) #t))
         (here (and win (equal? win (active-window))))
         (top (if win (or (window-buffer-any win) "") ""))
         (more (if win (length (window-prev-buffers win)) 0)))
    (list (list (cond (here "●") (on "■") (else "□")) (if on "ok" "faint"))
          (list (if win (window-name win) "") #f)
          (list (windows-list-pane win) "faint")
          (list (if (equal? top "") "" (buffer-modeline-name top)) "faint")
          (list (let ((m (or (and win (mode-consolidate-window-mode win)) "")))
                  (if (string-suffix? "-mode" m) (substring m 0 (- (string-length m) 5)) m))
                "dim")
          (list (if win (number->string (+ 1 more)) "") "faint"))))

(define (windows-list-on-current fn)
  (let* ((id (list-current *windows-list-buffer*))
         (win (and id (windows-list-window id))))
    (if win (fn win) (message "no window on this line — g refreshes"))))

(define (windows-list-take! win)
  ;; the chosen window comes to the front of its pane and takes the focus
  (panes-raise-window! win))

(define-command "windows-list-visit" "Show the window on this line in the list's pane"
  (lambda () (windows-list-on-current windows-list-take!)))

(define-command "windows-list-close" "Close the window on this line"
  (lambda ()
    (windows-list-on-current
      (lambda (win)
        (let* ((l (panes--ensure-layout!)) (k (panes-key-of-handle l win)))
          (if k
              (panes-apply! (panes-remove-window l k))
              (window-hidden-delete! win)))
        (list-refresh! *windows-list-buffer*)))))

(define-command "windows-list-consolidate"
  "Give every major mode one window, from the window on this line; visible panes keep their modes"
  (lambda ()
    (windows-list-on-current
      (lambda (win)
        (let ((list-win (active-window)))
          (begin
              ;; the panes model consolidates every window it holds, shown or not
              (when (member win (map car (window-list))) (select-window! win))
              (consolidate!))
          (when (window-exists? list-win) (select-window! list-win))
          (list-refresh! *windows-list-buffer*))))))

(define-command "windows-list-refresh" "Redraw the window list"
  (lambda () (list-refresh! *windows-list-buffer*)))

(define-command "windows-list-rename" "Name the window on this line"
  (lambda ()
    (windows-list-on-current
      (lambda (win)
        (window-rename-prompt! win (lambda () (list-refresh! *windows-list-buffer*)))))))

(define-list-mode! "windows-mode"
  (list
    'doc (string-append
           "The windows of this frame, pane by pane, or in ring order without panes. ● is the window you are in, "
           "■ one on screen, □ one waiting behind its pane; the last column counts its buffers. `RET` shows the "
           "window in the list's pane, `k` closes it, `c` gives every major mode one window from the window on the line, `r` names the window.")
    'buffer *windows-list-buffer*
    'rows windows-list-ids
    ;; a narrow window keeps the mark, the name and the count; the pane and
    ;; the buffer it shows come back past 80 columns
    'layouts (list (list 'name 'wide
                         'min-cols 80
                         'columns (lambda (buf)
                                    (list (list "" 1) (list "window" 20) (list "pane" 7)
                                          (list "showing" 40) (list "mode" 18) (list "bufs" #f)))
                         'cells windows-list-cells)
                   (list 'name 'narrow
                         'default #t
                         'columns (lambda (buf) (list (list "" 1) (list "window" #f) (list "mode" 18) (list "bufs" 4)))
                         'cells windows-list-narrow-cells))
    'cells windows-list-cells
    'title (lambda (buf) "Windows")
    'meta (lambda (buf)
            (string-append (number->string (length (list-entries buf))) " windows"))
    'total (lambda (buf) (length (list-source-entries buf)))
    'no-marks #t
    'local-filter #t
    'footer (lambda (buf)
              '(("RET" "go") ("k" "close") ("c" "consolidate") ("r" "rename") ("/" "filter")
                ("g" "refresh") ("q" "quit")))
    'keys '(("RET" "windows-list-visit") ("k" "windows-list-close") ("c" "windows-list-consolidate") ("r" "windows-list-rename")
            ("g" "windows-list-refresh") ("q" "quit-window"))))

(define-command "windows-list-ring"
  "List the windows of this frame's ring in one flat list, on screen and waiting"
  (lambda ()
    ;; a list that waits behind a pane comes to this one: popping to it
    ;; would leave it hidden in its own window
    (let ((waiting (find (lambda (w) (equal? (window-buffer-any w) *windows-list-buffer*))
                         (map car (window-hidden-list)))))
      (if waiting
          (begin (windows-list-take! waiting) (list-refresh! *windows-list-buffer*))
          ;; else it opens in this pane: popping lets display send it to another group's window
          (let ((buf *windows-list-buffer*))
            (buffer-create buf)
            (with-current-buffer buf (lambda () (set-mode! "windows-mode")))
            (window-set-buffer! (active-window) buf)
            (list-refresh! buf))))))



(define-key "ctl-x-map" "w" "windows-list")

;; The list follows the ring while it is on screen.
(define (windows-list-follow!)
  ;; only a list on screen follows: a hidden window holding the list does
  ;; not count as showing it
  (when (and (buffer-known? *windows-list-buffer*)
             (find (lambda (w) (equal? (cadr w) *windows-list-buffer*)) (window-list)))
    (list-refresh! *windows-list-buffer*)))

(add-hook! 'window-state-change-hook 'windows-list-follow!)

(domain! 'unknown)
(effects! '(unknown))
(category! 'interaction)
(catalog-meta! 'command "reset-layout" 'domain 'windows 'effects '(write display))
(catalog-meta! 'function "define-mode-layout!" 'domain 'windows 'effects '(write))
(category! 'commands)
(public! 'focus-default-keybindings "(focus-default-keybindings &optional MODIFIERS) — bind the arrows with MODIFIERS (shift control meta super; default shift) to previous-pane/next-pane and focus-up/down")
(public! 'window-default-keybindings "(window-default-keybindings &optional MODIFIERS) — bind the arrows with MODIFIERS (default shift super) to window-previous-pane/next-pane; the window moves to the neighboring pane with its complete stack and focus follows")
(public! 'buffer-default-keybindings "(buffer-default-keybindings &optional MODIFIERS) — bind the arrows with MODIFIERS (default shift super) to buffer-previous-pane/next-pane; the buffer moves to the neighboring pane's front window")
(public! 'arrow-chord "(arrow-chord MODIFIERS KEY) — the key spec for KEY under MODIFIERS, e.g. (arrow-chord '(meta shift) \"<left>\") is \"M-S-<left>\"")

(domain! 'unknown)
(effects! '(unknown))
