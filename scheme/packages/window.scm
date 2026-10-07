;;; window.scm --- windows: display-buffer, the float, peek, layouts, special-mode, tiling.
;;;
;;; Emacs's window.el, in one file: the display-buffer chain and its actions,
;;; the float and the look, peek, the mode layouts, special-mode and
;;; quit-window, winner, and the tiling commands. init.scm loads it second,
;;; before dired: a list mode derives from special-mode at load.

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
;;; A buffer with no rule takes *display-buffer-base-action* and then
;;; *display-buffer-fallback-action*: reuse a window that shows it, split
;;; a window big enough, use another window, else this one.
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
  (let ((actions (display-buffer-actions-for name alist)))
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
        (begin
          (split-window! (if (member side '(top bottom)) 'v 'h) (- 1 size))
          (other-window!)
          (set! w (active-window))
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
;;; before — the same move buffer-left and buffer-right make, done for you.
;;; A preview is a look, not a place, so the peek path never evicts.
(define (window-eviction-buffer win name)
  (let* ((shown (map cadr (window-list)))
         (ok? (lambda (b)
                (and b (not (equal? b name)) (buffer-known? b)
                     (not (buffer-context-only? b))
                     (not (float--class? b))
                     (not (peek-buffer? b))
                     (window-fill-member? b)
                     (not (member b shown)))))
         (past (filter ok? (window-prev-buffers win)))
         (rest (filter ok? (window-fill-buffers))))
    (cond ((pair? past) (car past))
          ((pair? rest) (car rest))
          (else #f))))

;; the only buffer in the editor cannot be in two places and nowhere: when
;; there is nothing else to reveal the other window keeps it.
(define (window-release-duplicates! win name)
  (unless *layout-busy*
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
     (filter (lambda (w) (equal? (cadr w) name)) (window-list)))))

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
;;; away again is one entry: (TOKEN REASON TREE GROUP TARGET FOCUS).
;;; arrangement-push! answers the token. arrangement-pop! puts back the
;;; tree, the group, the layout target and the focus; arrangement-drop!
;;; keeps what is on screen. Either one also ends the entries pushed after
;;; it. A pop is not a window command, so winner does not record it.

(define (arrangements) (or (frame-local 'arrangements) '()))

(define (arrangement-push! reason)
  (let ((token (+ 1 (or (frame-local 'arrangement-last) 0))))
    (set-frame-local! 'arrangement-last token)
    (set-frame-local! 'arrangements
      (cons (list token reason (window-tree) (frame-group) (layout-target) (active-window))
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

;; LOOK? draws the tree as a look (window-tree-preview!): the MRU stays
(define (arrangement-pop! token &optional look?)
  (let ((e (and token (arrangement--take! token))))
    (when e
      (with-layout-suppressed
        (lambda ()
          (if look? (window-tree-preview! (nth 2 e)) (window-tree-set! (nth 2 e)))))
      (when (and (window-exists? (nth 5 e)) (not (equal? (active-window) (nth 5 e))))
        (select-window! (nth 5 e)))
      (unless (equal? (layout-target) (nth 4 e)) (layout-target-set! (nth 4 e)))
      ;; a frame derives its group from what it shows: standing where you
      ;; stood is part of giving the frame back
      (unless (equal? (frame-group) (nth 3 e))
        (set-frame-local! 'current-group (nth 3 e))
        (frame-group-label-refresh!))
      (winner--settle-screen!))
    (and e #t)))

;;; --- the preview verb ----------------------------------------------------------
;;; A look shows a buffer for a while without keeping it. It never bumps
;;; the MRU, never moves focus, and never enters winner's ring. A frame
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
                                      (display-buffer buf '(category preview inhibit-same-window #t)))))))
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
      (winner--settle-screen!)
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
               ;; a kept frame look is the user's change: winner records
               ;; the arrangement the look covered
               (let ((e (assoc (nth 5 slot) (arrangements))))
                 (when e (winner-push! (nth 2 e)))
                 (arrangement-drop! (nth 5 slot)))
               (arrangement-pop! (nth 5 slot) #t)))
          ;; the card goes, or gives back the float it covered
          ((equal? where 'float)
           (let ((fw (float-window)))
             (unless (or keep (not fw) (not (equal? (window-buffer fw) buf)))
               (with-layout-suppressed
                 (lambda () (or (window-preview-end! fw) (float-close!)))))))
          ((not (and w (window-exists? w) (equal? (window-buffer w) buf))) #f)
          ((equal? where 'here)
           (if keep (window-set-buffer! w buf) (window-preview-end! w)))
          (keep (set-window-owner! w #f) (set-window-restore! w #f))
          (else (set-window-owner! w #f) (window-quit-restore! w)))))
    (winner--settle-screen!)
    slot))

(domain! 'files)
(effects! '(read))

;;; --- display-buffer actions (Emacs window.el) ---------------------------------
;;; display-buffer shows NAME somewhere and returns the window. It selects
;;; nothing. pop-to-buffer shows and selects. switch-to-buffer! shows in
;;; the selected window. Where "somewhere" is comes from a chain of
;;; actions, tried in order until one answers with a window:
;;;
;;;   the rule for NAME in *display-buffer-alist*
;;;   *display-buffer-base-action*       the user's, empty by default
;;;   *display-buffer-fallback-action*   reuse-window mode-window
;;;                                      pop-up-window use-some-window
;;;                                      same-window
;;;
;;; The actions, each a function of NAME and ALIST on the display-action hook:
;;;
;;;   reuse-window     a window that shows NAME already
;;;   mode-window      a work window whose buffer has NAME's major mode: a
;;;                    group keeps one window per mode, so every chat lands
;;;                    in the chat pane
;;;   pop-up-window    split the largest work window when it is big
;;;                    enough (split-window-sensibly), else the selected one
;;;   use-some-window  another work window; the float and a peek are not one
;;;   same-window      the selected window (also 'same)
;;;   shaped           the dock or the float, by the buffer's window-shape
;;;
;;; ALIST is a plist the caller passes. 'category names the kind of display,
;;; and a rule (category KIND) matches it. 'inhibit-same-window #t keeps
;;; the selected window out of the chain. A window the chain made or took
;;; is noted for quit-window: q deletes the window the display made, or
;;; puts back the buffer the display replaced.
;;;
;;; The thresholds are Emacs' own: a window splits below when it has
;;; split-height-threshold rows, beside when it has split-width-threshold
;;; columns, and the sole work window splits below whatever its size.
;;; layouts.scm makes the four variables customizable.

(define split-height-threshold 80)
(define split-width-threshold 160)
(define window-min-height 4)
(define window-min-width 10)
(define *display-buffer-base-action* '())
(define *display-buffer-fallback-action*
  '(reuse-window mode-window pop-up-window use-some-window same-window))
;; an action is the keyed hook (display-action NAME)
(define (define-display-action! name fn) (add-hook! (list 'display-action name) fn))

(define (display-action-fn name)
  (let ((fs (hook-functions (list 'display-action name))))
    (and (pair? fs) (car fs))))

;; Explicit layouts remain targets as their occupied pane count changes.
(define (layout-target) (frame-local 'layout-target))
(define (layout-target-set! name)
  (set-frame-local! 'layout-target name)
  (when name (set-frame-local! 'layout-freed #f))
  (unless name (set-frame-local! 'layout-slots #f))
  (when (and name (not (frame-local 'layout-slots)))
    (layout-target-note-slots! (layout-visible-buffers)))
  (set-frame-local! 'layout-target-count (length (layout-visible-buffers)))
  (layout-target-modeline!)
  name)

;; A frame with no target takes window-layout-default, unless the person
;; freed it. The shape stays as it is: the layout fills as windows come.
(define (layout-target-default!)
  (unless (or (layout-target) (frame-local 'layout-freed)
              (not (layout-capacity window-layout-default)))
    (layout-target-set! window-layout-default))
  (layout-target))

(define (layout-target-free!)
  (layout-target-set! #f)
  (set-frame-local! 'layout-freed #t))

(add-hook! 'frame-attach-hook 'layout-target-default!)

;;; The modeline names the chosen layout as Markdown: `*layout*:NAME`. The label
;;; is bold and the target reads plainly beside it, with no segment gap between
;;; the two spans. The text is compared before it is set, so the change hook
;;; that calls this on every window move does no work on an unchanged frame.
(define (layout-target-modeline-text)
  (let ((target (layout-target)))
    (string-append ":" (cond ((not target) "free")
                             ((symbol? target) (symbol->string target))
                             (else target)))))

(define (layout-target-modeline-shown)
  (let ((entry (assq 'layout-value *global-mode-string*)))
    (and entry (pair? (cadr entry)) (cadr (cadr entry)))))

(define (layout-target-modeline!)
  (let ((text (layout-target-modeline-text)))
    (unless (equal? text (layout-target-modeline-shown))
      (global-mode-string-set! 'layout-label '("ml-segment ml-strong" "layout"))
      (global-mode-string-set! 'layout-value (list "ml-segment ml-tight" text)))))

;; A target is a layout and a capacity, not a frozen accidental tree.
(define (layout-target-capacity target) (layout-capacity target))

;; Logical slot order is independent of focus and of the side holding main.
;; Match each occurrence once so deliberate duplicate views remain distinct.
(define (layout-target-note-slots! panes)
  (let loop ((names panes) (rows (window-list)) (out '()))
    (if (null? names)
        (begin
          (set-frame-local! 'layout-slots (reverse out))
          (set-frame-local! 'layout-target-count (length out)))
        (let ((matches (filter (lambda (row) (equal? (cadr row) (car names))) rows)))
          (if (null? matches)
              (loop (cdr names) rows out)
              (loop (cdr names)
                    (filter (lambda (row) (not (equal? (car row) (car (car matches))))) rows)
                    (cons (car matches) out)))))))

;; A buffer that makes its window a work window. popper.scm answers #f
;; for a popup: a popup window is ordinary, but the layout does not tile
;; it and a display of another buffer does not take it.
(define window-work-buffer? (lambda (buf) #t))

(define (layout-visible-window? row)
  (and (not (float--class? (cadr row)))
       (window-work-buffer? (cadr row))
       (not (window-dock? (car row) (cadr row)))))

;; The current tree is authoritative: a manual swap or restored tree can
;; keep window IDs while changing their order. Cached IDs must not undo it.
(define (layout-target-visible-buffers)
  (map cadr (filter layout-visible-window? (window-list))))

(define (layout-target-arrange! panes focus)
  (let ((target (layout-target))
        (token (if (equal? focus (window-buffer (active-window)))
                   (layout-focus-token) (list focus 0))))
    (when (pair? panes)
      (tile-windows! target panes)
      (layout-focus-restore! token)
      panes)))

(define (layout-focus-token)
  (let ((name (window-buffer (active-window))))
    (let loop ((rows (window-list)) (occurrence 0))
      (cond ((null? rows) (list name 0))
            ((equal? (car (car rows)) (active-window)) (list name occurrence))
            (else (loop (cdr rows)
                    (+ occurrence (if (equal? (cadr (car rows)) name) 1 0))))))))

(define (layout-focus-restore! token)
  (let ((matches (filter (lambda (row) (equal? (cadr row) (car token))) (window-list))))
    (when (pair? matches)
      (select-window! (car (nth (min (cadr token) (- (length matches) 1)) matches))))))

;; A user open selects its result. A display records how to quit and keeps focus.
(define (layout-target-open! name select? inhibit-same?)
  (and (fill-candidate? name) (window-fill-member? name)
       (not (buffer-context?))
       (let* ((selected (active-window))
              (focus (window-buffer selected))
              (shown (if inhibit-same?
                         (window-showing-other name selected)
                         (window-showing name)))
              ;; One window per mode outranks the target's spare capacity. A
              ;; three-column target is no licence to show two chats: the
              ;; second one takes the pane the first one already holds.
              (kin (and (not shown)
                        (window-showing-mode (display-buffer-mode name)
                                             (and inhibit-same? selected))))
              (panes (layout-target-visible-buffers))
              (capacity (layout-target-capacity (layout-target))))
         (cond (shown
                (when select? (select-window! shown))
                shown)
               (kin
                (display-buffer-in-window! kin name)
                (when select? (select-window! kin))
                kin)
               ((and (not (member name panes))
                     (or (not capacity) (< (length panes) capacity)))
                (layout-target-arrange! (append panes (list name)) (if select? name focus))
                (window-showing name))
               (select?
                 (display-buffer-in-window! selected name)
                 (select-window! selected)
                 selected)
               (else
                 ;; A full layout does not change the buffer of a pane for
                 ;; a display. A window on NAME takes the pane, and the pane's
                 ;; window becomes hidden, with its buffer and point.
                 (let ((win (layout-replacement-window selected)))
                   (and win (layout-open-window-in! win name))))))))

;; Put a window on NAME in the pane of WIN: a hidden window that shows
;; NAME, else a new one. WIN becomes hidden. quit-window in the new pane
;; brings WIN back (window-quit-restore!). Answers the window, or #f.
(define (layout-open-window-in! win name)
  (let* ((hidden (let loop ((rows (window-hidden-list)))
                   (cond ((null? rows) #f)
                         ((equal? (cadr (car rows)) name) (car (car rows)))
                         (else (loop (cdr rows))))))
         (restoring (not (buffer-exists? name)))
         (new (or hidden (window-new-hidden! name))))
    (and new
         (window-swap-hidden! win new)
         (begin
           (when (and restoring (not hidden)) (restore-buffer-runtime! name))
           (set-frame-local! 'layout-displaced
             (cons (list new win)
                   (filter (lambda (e) (not (equal? (car e) new)))
                           (or (frame-local 'layout-displaced) '()))))
           (window-state-changed!)
           new))))

;; A window a full layout opened gives its pane back to the window it took
;; the pane from, and goes. #t when it did.
(define (layout-give-back! win)
  (let ((back (layout-displaced-by win)))
    (and back
         (window-swap-hidden! win back)
         (begin
           (window-hidden-delete! win)
           (window-state-changed!)
           #t))))

;; the hidden window that NEW took the pane of, or #f
(define (layout-displaced-by new)
  (let ((e (assoc new (or (frame-local 'layout-displaced) '()))))
    (and e (member (cadr e) (map car (window-hidden-list))) (cadr e))))

;; Results replace the least recently used other work pane. Ties keep order.
(define (layout-replacement-window selected)
  (let ((mru (buffer-list-mru)))
    (define (rank buf)
      (let loop ((rest mru) (n 0))
        (cond ((null? rest) n)
              ((equal? (car rest) buf) n)
              (else (loop (cdr rest) (+ n 1))))))
    (let loop ((windows (display--work-windows)) (best #f) (age -1))
      (if (null? windows)
          best
          (let* ((win (car windows))
                 (score (rank (window-buffer win))))
            (if (and (not (equal? win selected)) (> score age))
                (loop (cdr windows) win score)
                (loop (cdr windows) best age)))))))

;; Window changes reflow occupied slots. Closing a pane does not reopen hidden work.
(define (layout-target-on-change!)
  (layout-target-modeline!)
  (when (and (layout-target) (not *layout-busy*)
             (not (minibuffer-state)) (not (float-open?)))
    (let ((panes (layout-target-visible-buffers))
          (focus (window-buffer (active-window))))
      (when (pair? panes)
        (unless (equal? (length panes) (frame-local 'layout-target-count))
          (layout-target-arrange! panes focus))))))

(add-hook! 'window-configuration-change-hook 'layout-target-on-change!)

(define (display--keep-shape actions)
  (if (layout-target)
      (map (lambda (a) (if (equal? a 'pop-up-window) 'use-some-window a)) actions)
      actions))

;; the chain for NAME: the rule's actions, then the base, then the fallback
(define (display-buffer-actions-for name &optional alist)
  (let* ((a (display--alist-with-category name (or alist '())))
         (rule (cadr (display-rule-for name a)))
         (own (cond ((null? rule) '())
                    ((pair? rule) rule)
                    (else (list rule)))))
    (display--keep-shape
      (append own *display-buffer-base-action* *display-buffer-fallback-action*))))

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
    (unless (and rec (equal? (car rec) 'preview)) (set-window-restore! win #f))
    (cond ((not rec) #f)
          ((equal? (car rec) 'preview) (window-preview-end! win))
          ((and (equal? (car rec) 'window) (layout-give-back! win)) #t)
          ((and (equal? (car rec) 'window) (pair? (cdr (window-list))))
           (if (equal? win (active-window))
               (delete-window!)
               (delete-window-id! win))
           #t)
          ((and (equal? (car rec) 'other) (cadr rec)
                (fill-candidate? (cadr rec)) (window-fill-member? (cadr rec)))
           (window-set-buffer! win (cadr rec))
           (window-state-changed!)
           #t)
          (else #f))))

;;; geometry, from the selected window's measure and the fractional rects

;; the work windows: not the float, not a dock, not a peek
(define (display--work-windows)
  (let ((float (float-window)))
    (filter (lambda (w) (and (not (equal? w float))
                             (window-work-buffer? (window-buffer w))
                             (not (window-dock? w (window-buffer w)))
                             (not (peek-buffer? (window-buffer w)))))
            (map car (window-list)))))

;; (ROWS COLS) of WIN, as the frame measures them
(define (window-size-of win)
  (let* ((rs (window-rects))
         (me (assoc (active-window) rs))
         (r (assoc win rs)))
    (if (and me r (> (nth 5 me) 0))
        (list (* (nth 5 r) (/ (window-rows) (nth 5 me)))
              (* (nth 4 r) (frame-cols)))
        (list (window-rows) (window-cols)))))

;; the largest work window by area, else the selected one
(define (display--largest-work-window)
  (let ((rs (window-rects)))
    (let loop ((ws (display--work-windows)) (best #f) (area 0))
      (cond ((null? ws) (or best (active-window)))
            (else
              (let* ((r (assoc (car ws) rs))
                     (a (if r (* (nth 4 r) (nth 5 r)) 0)))
                (if (> a area)
                    (loop (cdr ws) (car ws) a)
                    (loop (cdr ws) best area))))))))

;; Emacs window-splittable-p: 'v is one above the other, 'h side by side
(define (window-splittable? win dir)
  (let* ((size (window-size-of win))
         (rows (car size))
         (cols (cadr size)))
    (if (equal? dir 'v)
        (and (>= rows split-height-threshold) (>= rows (* 2 window-min-height)))
        (and (>= cols split-width-threshold) (>= cols (* 2 window-min-width))))))

;; split WIN, which need not be the selected window, and answer the new
;; window. The selection is where it was.
(define (split-window-in! win dir)
  (let ((me (active-window))
        (before (map car (window-list))))
    (unless (equal? win me) (select-window! win))
    (split-window! dir 0.5)
    (let ((new (let loop ((ws (window-list)))
                 (cond ((null? ws) #f)
                       ((member (car (car ws)) before) (loop (cdr ws)))
                       (else (car (car ws)))))))
      (unless (equal? (active-window) me) (select-window! me))
      new)))

;; Emacs split-window-sensibly: below when WIN is tall enough, else
;; beside when it is wide enough, else below anyway when WIN is the only
;; work window and can hold two. The new window, or #f.
(define (split-window-sensibly win)
  (let ((dir (cond ((window-splittable? win 'v) 'v)
                   ((window-splittable? win 'h) 'h)
                   ((and (null? (cdr (display--work-windows)))
                         (>= (car (window-size-of win)) (* 2 window-min-height)))
                    'v)
                   (else #f))))
    (and dir (split-window-in! win dir))))

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
    (if (plist-get alist 'inhibit-same-window)
        #f
        (begin (switch-to-buffer-here! name) (active-window)))))

(define-display-action! 'same (display-action-fn 'same-window))

(define-display-action! 'reuse-window
  (lambda (name alist)
    (if (plist-get alist 'inhibit-same-window)
        (window-showing-other name (active-window))
        (window-showing name))))

;; A window prefers the mode of its work buffer. Temporary covers keep the
;; preference of the nearest work buffer in its own history. This uses the
;; history already carried through tiling and desktop restore.
(define (window-mode win)
  (let ((buf (window-buffer win)))
    (and (string? buf) (buffer-local buf 'mode-name))))

;; special-mode also includes persistent listings, so it does not mean cover.
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
  (let* ((me (active-window))
         (target (layout-target))
         (capacity (and target (layout-target-capacity target)))
         (panes (layout-target-visible-buffers))
         (spares (if (and capacity (< (length panes) capacity))
                     (filter (lambda (b) (and (fill-candidate? b) (not (member b panes))))
                             (buffer-list-mru))
                     '()))
         (others (filter (lambda (r) (not (equal? (car r) me))) (window-list))))
    (define (seen r) (or (buffer-last-seen (cadr r)) 0))
    (cond ((pair? spares)
           (layout-target-arrange! (append panes (list (car spares))) (window-buffer me))
           (window-showing (car spares)))
          ((null? others) (split-window! 'h) (other-window-id me))
          (else
           (let loop ((rs (cdr others)) (best (car others)))
             (cond ((null? rs) (car best))
                   ((< (seen (car rs)) (seen best)) (loop (cdr rs) (car rs)))
                   (else (loop (cdr rs) best))))))))

(define-display-action! 'mode-window
  (lambda (name alist)
    (let ((win (window-showing-mode
                 (display-buffer-mode name)
                 (and (plist-get alist 'inhibit-same-window) (active-window)))))
      (and win (display-buffer-in-window! win name)))))

(define-display-action! 'pop-up-window
  (lambda (name alist)
    (let* ((me (active-window))
           (largest (display--largest-work-window))
           (win (or (split-window-sensibly largest)
                    (and (not (equal? largest me)) (split-window-sensibly me)))))
      (and win (display-buffer-in-window! win name)))))

(define-display-action! 'use-some-window
  (lambda (name alist)
    (let ((win (layout-replacement-window (active-window))))
      (and win (display-buffer-in-window! win name)))))

;; show NAME where the chain says, selecting nothing; the window, or #f
(define (display-buffer-run-actions name alist actions)
  (if (null? actions)
      #f
      (let* ((fn (display-action-fn (car actions)))
             (win (and fn (fn name alist))))
        (or win (display-buffer-run-actions name alist (cdr actions))))))

;; the actions that place a buffer themselves: the layout target does not
;; take their displays. A package adds its own (popper.scm).
(define *display-buffer-outside-layout* '(shaped same same-window))

;; An agent never puts its work in the user's window by accident. It works
;; on a file buffer, or on a buffer it made, by name. When the user asks to
;; see a buffer, the agent shows it in the other window
;; (inhibit-same-window), whoever made the buffer. Any other display of
;; such a buffer gets #f, so the agent can tell nothing was shown.
(define (display-buffer-agent-refuses? name alist)
  (and (agent-edit-author? (current-edit-author))
       (not (plist-get alist 'inhibit-same-window))
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
             (actions (display-buffer-actions-for name a)))
        (window-display!
          (lambda ()
            (or (and (layout-target) (not *layout-busy*) (pair? actions)
                     (not (member (car actions) *display-buffer-outside-layout*))
                     (layout-target-open! name #f (plist-get a 'inhibit-same-window)))
                (display-buffer-run-actions name a actions)))))))

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
  (display-buffer name '(inhibit-same-window #t)))
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
(public! 'window-fill-blank
  "(window-fill-blank) — context scratch fallback, or #f; fixed target layouts leave spare capacity empty")
(public! 'buffer-special?
  "(buffer-special? NAME) — a view of something else (a listing, a diff, a mail thread), not a place you work: Emacs special-mode")
(public! 'fill-candidate?
  "(fill-candidate? NAME) — eligible ordinary buffer: known, not hidden, special, context-only, floating or peek")
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

;; Return the window made by one split. Window ids are stable, so the new id
;; is the only id that was not present before the split.
(define (layout--new-window before)
  (let loop ((windows (window-list)))
    (cond ((null? windows) #f)
          ((not (member (car (car windows)) before)) (car (car windows)))
          (else (loop (cdr windows))))))

(define (layout--valid-ratio ratio fallback)
  (if (and (number? ratio) (> ratio 0) (< ratio 1)) ratio fallback))

;; Fill the selected leaf with BUFFERS along DIR. FIRST-RATIO controls the
;; first pane. Each later split divides the remaining space evenly. Three
;; panes therefore use 1/3, then 1/2, and finish as equal thirds.
(define (layout--fill-line! buffers dir first-ratio)
  (when (pair? buffers)
    (switch-to-buffer-here! (car buffers))
    (let loop ((rest (cdr buffers)) (first? #t))
      (when (pair? rest)
        (let* ((count (+ 1 (length rest)))
               (ratio (if first?
                          (layout--valid-ratio first-ratio (/ 1 count))
                          (/ 1 count)))
               (before (map car (window-list))))
          (split-window! dir ratio)
          (let ((new (layout--new-window before)))
            (when new
              (select-window! new)
              (switch-to-buffer-here! (car rest))
              (loop (cdr rest) #f)))))))
  buffers)

;;; A build makes its windows from one survivor: delete-other-windows!
;;; keeps one, and each split copies that one's history into the new
;;; window. Without a repair every pane remembers the survivor's past,
;;; a kill in a pane then shows the survivor's previous buffer, and the
;;; panes that went away take their pasts with them. So a build captures
;;; every window's (BUFFER . HISTORY) first and hands each new pane the
;;; history of the pane that showed its buffer. A pane on a buffer no
;;; window showed takes a pane that went away, that buffer first, so a
;;; kill there falls back to what the frame lost (Emacs prev-buffers).
(define (layout--capture-histories)
  (map (lambda (row)
         (list (cadr row) (window-prev-buffers (car row))
               (window-point (car row)) (window-restore (car row))))
       (window-list)))

(define (layout--drop-record record records)
  (cond ((null? records) '())
        ((equal? record (car records)) (cdr records))
        (else (cons (car records) (layout--drop-record record (cdr records))))))

(define (layout--restore-histories! captured)
  (let ((shown (map cadr (window-list))))
    (let loop ((rows (window-list)) (remaining captured))
      (when (pair? rows)
        (let* ((win (car (car rows)))
               (buf (cadr (car rows)))
               (own (assoc buf remaining))
               (gone (filter (lambda (e) (not (member (car e) shown))) remaining))
               (record (or own (and (pair? gone) (car gone)))))
          (set-window-restore! win (and own (nth 3 own)))
          (cond (own
                 (set-window-prev-buffers! win (cadr own))
                 (when (number? (caddr own)) (window-set-point! win (caddr own))))
                (record (set-window-prev-buffers! win (cons (car record) (cadr record))))
                (else (set-window-prev-buffers! win '())))
          ;; Rebuilt panes cannot inherit a foreign group's stack or return.
          (set-window-prev-buffers! win (window-eligible-history win))
          (let ((quit (window-restore win)))
            (when (and quit (equal? (car quit) 'other)
                       (not (window-history-member? win (cadr quit))))
              (set-window-restore! win #f)))
          (loop (cdr rows) (if record (layout--drop-record record remaining) remaining)))))))

;; The engine runs one arrangement at a time. switch-to-buffer! wakes a dormant
;; buffer, which re-runs its mode setups; without this flag that wake would ask
;; for another layout in the middle of this one.
(define *layout-busy* #f)

;; Run THUNK with the engine standing down. Desktop restore uses this: it
;; rebuilds the exact windows it saved, and a mode setup that runs inside it
;; must not arrange the frame a second way.
;; Is the engine arranging the frame right now? A package that moves
;; windows of its own — a preview that opens beside its index, say — must
;; ask this and stand down: the engine is mid-build, it will place every
;; declared pane itself, and a split landing inside that build leaves the
;; frame neither arrangement.
(define (layout-arranging?) *layout-busy*)

;; This Scheme has no unwind form, so a throw inside a build leaves the
;; flag raised and every later arrangement returns early — the frame
;; quietly stops obeying its layouts. A top-level, user-initiated build
;; clears it first: nothing can legitimately be arranging the frame at
;; the moment somebody asks for an arrangement.
(define (layout-abort!) (set! *layout-busy* #f))

(define (with-layout-suppressed thunk)
  (let ((was *layout-busy*))
    (set! *layout-busy* #t)
    (let ((r (thunk)))
      (set! *layout-busy* was)
      r)))

;; Put the frame where SPEC says. The anchor keeps focus: a mode that arranges
;; the frame must not move the user out of the buffer they are in.
(define (apply-layout! anchor spec)
  (if *layout-busy*
      (layout--panes anchor spec)
      (begin
        ;; the flag goes up BEFORE the panes resolve: an ensure pane runs a
        ;; command, that command switches buffers and sets a mode, and a
        ;; mode setup asks the engine for a layout of its own. One
        ;; arrangement at a time, materialising included.
        (set! *layout-busy* #t)
        (let ((panes (layout--panes anchor spec))
              (histories (layout--capture-histories)))
          (when (pair? panes)
            (delete-other-windows!)
            (layout--fill-line! panes (layout--dir spec) (layout--ratio spec))
            (layout--restore-histories! histories)
            (let ((w (window-showing anchor)))
              (when w (select-window! w))))
          (set! *layout-busy* #f)
          panes))))

 ;; Visible panes keep tree order. Selecting a pane does not promote it.
(define (layout-visible-buffers)
  (map cadr
    (filter layout-visible-window? (window-list))))
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

;;; --- special-mode (after Emacs) -------------------------------------------
;;; The parent of every view: a listing, a diff, a mail thread. Deriving
;;; from it is how a MODE says "this is not a place you work", which fill,
;;; group seeding and group context all ask through buffer-special?. A
;;; mode answers once; a buffer-local had to be written onto every buffer
;;; and could be stripped again, which is exactly what happened.
;;; It carries NO keys. Emacs' special-mode also forces read-only and binds
;;; q and g; here that is the child's business, and giving the parent a q
;;; broke a writable buffer that owns a child (dismiss-test: "writable
;;; buffers keep typing q"). Classification is what this mode is for.
(define-mode "special-mode" (lambda () #t))
;; Emacs' special-mode: a buffer that is a VIEW of something else -- a
;; listing, a diff, the telemetry, a mail thread -- and not a place you
;; work. Read-only, g re-renders it, q buries it. Nothing fills a window
;; with one, no group is seeded from one, and one never tells the frame
;; which group it stands in. It says NOTHING about persistence: what a
;; view rebuilds from is its mode's business (desktop-skip!), and it was
;; called 'transient until the day that name made four other things true.
;;
;; The MODE answers: a mode that derives from special-mode is a view. The
;; buffer-local stays as an explicit override for a buffer whose mode does
;; not say -- a hand-written view mode, or a test standing one up.
(define (buffer-special? b)
  (and (string? b)
       (or (derived-mode? (buffer-local b 'mode-name) "special-mode")
           (and (buffer-local b 'special) #t))))

;; a buffer a window may be filled with: known, not hidden, not floating,
;; not a peek (a look, not a place)
(define (fill-candidate? b)
  (and (string? b) (buffer-known? b)
       (not (string-prefix? " " b))
       (not (buffer-local b 'context-only))
       (not (buffer-special? b))
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

;; The blank pane: the buffer a layout shows in a pane the pool cannot
;; fill. editor.scm knows no groups, so the base answer is none, and a
;; layout stays short; scratch.scm sets the source to the group's scratch
;; when the frame stands in a group, so a sealed group's layout keeps its
;; shape without a buffer from outside.
(define window-fill-blank (lambda () #f))

;; Explicit fixed layouts fill with hidden work from the same context.
;; Keep the focused buffer when a smaller target hides surplus panes.
(define (layout--fit buffers capacity)
  (let* ((kept (take buffers capacity))
         (focus (window-buffer (active-window))))
    (if (and (member focus buffers) (not (member focus kept)))
        (append (take kept (- capacity 1)) (list focus))
        kept)))

;; A pane that holds a mode (mode-consolidate, or a chosen preference)
;; keeps that mode's buffers in its history. A layout that needs a new
;; window fills it from the rest, so the pane loses no member.
(define (layout-held-buffers)
  (fold (lambda (held win)
          (if (window-mode-preference win)
              (append (filter (lambda (b) (window-prefers-buffer? win b))
                              (window-prev-buffers win))
                      held)
              held))
        '()
        (display--work-windows)))

(define (layout-unheld buffers)
  (let ((held (layout-held-buffers)))
    (if (null? held)
        buffers
        (filter (lambda (b) (not (member b held))) buffers))))

(define (layout--fill-to buffers capacity)
  ;; The fill list costs a walk of every live buffer, so only pay for it when
  ;; the fit actually came up short. The common case -- more buffers than
  ;; panes -- now costs nothing.
  (let ((fitted (layout--fit buffers capacity)))
    (if (>= (length fitted) capacity)
        fitted
        (let loop ((rest (layout-unheld (filter window-fill-primary? (window-fill-buffers))))
                   (result fitted))
          (cond ((>= (length result) capacity) result)
                ((null? rest) result)
                ((member (car rest) result) (loop (cdr rest) result))
                (else (loop (cdr rest) (append result (list (car rest))))))))))

;; Validate each requested pane without removing duplicate buffer names.
(define (layout--known-buffers buffers)
  (let loop ((rest buffers) (acc '()))
    (if (null? rest)
        (reverse acc)
        (let ((buf (car rest)))
          (loop (cdr rest)
            (if (and (string? buf) (buffer-known? buf))
                (cons buf acc)
                acc))))))

;;; --- the five layouts -------------------------------------------------------
;;; A layout is a shape and a capacity, and nothing else. There are five:
;;;
;;;   single     one window
;;;   two-pane   two side by side, the first takes two thirds
;;;   halves     two side by side, equal
;;;   columns    three side by side, equal
;;;   rows       two stacked, equal
;;;
;;; Every layout is a window on the strip (below), so a frame is never
;;; short of buffers and never out of room for one: the panes show a run
;;; of the strip, and a scroll moves the run.

(define *window-layout-algorithms* '(single two-pane halves columns rows two-chat))

;; the panes a layout holds
(define (layout-capacity algorithm)
  (cond ((equal? algorithm 'single) 1)
        ((member algorithm '(columns two-chat)) 3)
        ((member algorithm *window-layout-algorithms*) 2)
        (else #f)))

;; the direction a layout splits in, and the first pane's share
(define (layout-split-dir algorithm) (if (equal? algorithm 'rows) 'v 'h))

;; The first pane's share of COUNT panes. two-pane is the one layout that
;; does not divide evenly. Every other layout gives each pane 1/COUNT, so
;; a layout short of buffers still shares the frame evenly: three columns
;; holding two buffers are two halves, not a third and two thirds.
(define (layout-first-ratio algorithm count)
  (cond ((equal? algorithm 'two-pane)
         (layout--valid-ratio window-layout-main-ratio (/ 2 3)))
        ;; two equal panes and a narrow chat: a share for each pane
        ((equal? algorithm 'two-chat)
         (let ((chat (layout--valid-ratio window-layout-chat-ratio (/ 1 4))))
           (cond ((= count 3) (list (/ (- 1 chat) 2) (/ (- 1 chat) 2) chat))
                 ((= count 2) (- 1 chat))
                 (else 1))))
        (else (/ 1 count))))

;;; --- the ring ---------------------------------------------------------------
;;; The frame's windows make one cyclic ring, and the layout shows a run of
;;; it. A window that leaves the screen does not die: it becomes hidden,
;;; and it keeps its buffer, history and point. A window joins the ring
;;; when it is made. Right is forwards, left is backwards.
;;;
;;; A walk takes the order of the ring when it starts: the panes on screen,
;;; in screen order, then the hidden windows, most recently used first. The
;;; walk keeps that order while it goes on. A selection changes the recent
;;; order, and a ring read again on each step would reorder itself under
;;; the walk: back would not return where forward came from.

;; the commands that continue a walk
(define *layout-walk-commands*
  '("focus-left" "focus-right" "focus-up" "focus-down"
    "layout-forward" "layout-backward"))

(define (layout-strip) (or (frame-local 'layout-strip) '()))
(define (layout-offset) (or (frame-local 'layout-offset) 0))

(define (layout-strip-set! ids offset)
  (set-frame-local! 'layout-strip ids)
  (set-frame-local! 'layout-offset (if (pair? ids) (modulo offset (length ids)) 0))
  ids)

;; the layout's panes, as window ids, in screen order
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

;; A kill can delete a hidden window. Every frame reads its ring again on
;; the next walk.
(define (layout-strip-forget! name)
  (for-each (lambda (frame) (set-frame-local-in! frame 'layout-strip '()))
            (frame-list)))

(public! 'layout-strip-forget!
  "(layout-strip-forget! NAME) — make every frame read its window ring again; a kill runs this")

(define (layout-strip-rebuild!)
  (layout-strip-set! (append (layout-pane-windows) (layout-hidden-windows)) 0))

;; the run of COUNT windows the ring shows now
(define (layout-strip-run count)
  (let* ((strip (layout-strip))
         (n (length strip)))
    (let loop ((i 0) (out '()))
      (if (>= i (min count n))
          (reverse out)
          (loop (+ i 1) (cons (nth (modulo (+ (layout-offset) i) n) strip) out))))))

;; The ring of this walk. A new walk reads the ring again. So does a walk
;; whose ring no longer matches the frame: a window died or was made, or
;; the panes changed under it.
(define (layout-strip-current count)
  (let* ((strip (layout-strip))
         (live (append (layout-pane-windows) (layout-hidden-windows)))
         (valid (and (member (last-command) *layout-walk-commands*)
                     (= (length strip) (length live))
                     (null? (filter (lambda (w) (not (member w live))) strip))
                     (equal? (layout-strip-run count) (layout-pane-windows)))))
    (unless valid (layout-strip-rebuild!))
    (layout-strip)))

;; Move the run by DELTA and lay the frame out again. Answers #f when the
;; ring holds no more windows than the layout shows: there is nothing to
;; scroll to.
(define (layout-scroll! delta)
  (let* ((algorithm (or (layout-target) 'single))
         (capacity (layout-capacity algorithm))
         (strip (and capacity (layout-strip-current capacity)))
         (n (if strip (length strip) 0)))
    (cond ((not capacity) #f)
          ((<= n capacity) #f)
          (else
            (layout-strip-set! strip (+ (layout-offset) delta))
            (layout-arrange-windows! algorithm (layout-strip-run capacity))))))

;;; --- the tiler --------------------------------------------------------------

;; Lay the frame out as ALGORITHM over the windows IDS. A pane that is not
;; in IDS becomes hidden; it is not deleted.
(define (layout-arrange-windows! algorithm ids)
  (float-close!)
  (set! *layout-busy* #t)
  (let ((ok (window-arrange-line! (layout-split-dir algorithm)
                                  (layout-first-ratio algorithm (length ids))
                                  ids)))
    (set! *layout-busy* #f)
    (when ok
      (window-state-changed!)
      (layout-target-note-slots! (map window-buffer ids)))
    (and ok ids)))

;; The window a layout uses for BUF: a pane that shows it, then a hidden
;; window that shows it, else a new window. TAKEN holds the windows this
;; layout uses already, so two panes on one buffer are two windows.
(define (layout-window-for buf taken)
  (let ((free (lambda (rows)
                (let loop ((rows rows))
                  (cond ((null? rows) #f)
                        ((and (equal? (cadr (car rows)) buf)
                              (not (member (car (car rows)) taken)))
                         (car (car rows)))
                        (else (loop (cdr rows))))))))
    (or (free (filter layout-visible-window? (window-list)))
        (free (window-hidden-list))
        ;; a dormant buffer wakes whole, as switch-to-buffer-here! makes it
        (let* ((restoring (not (buffer-exists? buf)))
               (win (window-new-hidden! buf)))
          (when (and win restoring) (restore-buffer-runtime! buf))
          win))))

;; two-chat keeps the first chat of the frame's group in its last pane
(define (layout--chat-last algorithm buffers)
  (let* ((g (and (equal? algorithm 'two-chat) (frame-group)))
         (chats (if g (filter (lambda (b) (equal? (buffer-group-role b g) "chat")) buffers) '())))
    (if (null? chats)
        buffers
        (append (take (filter (lambda (b) (not (equal? b (car chats)))) buffers)
                      (- (layout-capacity algorithm) 1))
                (list (car chats))))))

;; Arrange explicit buffers with a named layout. The first buffer is the main
;; buffer and keeps focus. This is the stable agent-facing entry point.
;; Each pane is a window: one that shows the buffer is used again, and a
;; window that loses its pane becomes hidden, with its history and point.
(define (tile-windows! algorithm buffers)
  (let* ((capacity (layout-capacity algorithm))
         (known (layout--chat-last algorithm (layout--known-buffers buffers)))
         (panes (if capacity (take known capacity) known)))
    (cond
      ((not capacity) (message "Unknown window layout") #f)
      ((null? panes) (message "No live buffers to arrange") #f)
      (*layout-busy* panes)
      (else
        (let ((ids (let loop ((rest panes) (taken '()))
                     (if (null? rest)
                         (reverse taken)
                         (let ((w (layout-window-for (car rest) taken)))
                           (loop (cdr rest) (if w (cons w taken) taken)))))))
          (and (pair? ids)
               (layout-arrange-windows! algorithm ids)
               (begin
                 (select-window! (car ids))
                 panes)))))))

;; The buffers a layout asks for: the panes, then the buffers of the
;; hidden windows, then (in a group) the group's other work.
(define (layout-request-buffers)
  (let* ((visible (layout-target-visible-buffers))
         (hidden (map window-buffer-any (layout-hidden-windows)))
         (work (if (frame-group) (layout-unheld (window-fill-buffers)) '())))
    ;; Existing panes keep their buffers, including deliberate duplicates,
    ;; transient lists and visible non-members. Only hidden fillers are filtered.
    (let loop ((rest (append hidden work)) (out (reverse visible)))
      (cond ((null? rest) (reverse out))
            ((member (car rest) out) (loop (cdr rest) out))
            (else (loop (cdr rest) (cons (car rest) out)))))))

;; Apply ALGORITHM to the frame. This is the top of a layout change, so the
;; next walk reads the ring again from the new panes.
(define (tile-visible-windows! algorithm &optional requested)
  (let* ((focus (layout-focus-token))
         (visible (layout--chat-last algorithm (or requested (layout-request-buffers))))
         (capacity (or (layout-capacity algorithm) 1))
         (panes (take (layout--known-buffers (layout--fill-to visible capacity)) capacity))
         (result (and (pair? panes) (tile-windows! algorithm panes))))
    (when result
      (layout-strip-rebuild!)
      (layout-focus-restore! focus))
    result))

;; The layout that fits COUNT panes: the frame takes the smallest of the
;; five that holds them all, and three is the most any of them holds.
(define (layout-for-count count)
  (cond ((<= count 1) 'single)
        ((<= count 2) 'two-pane)
        (else 'columns)))

;; Tile PANES with the frame's chosen layout, or with the one that fits
;; them when the frame never chose. The caller has panes in hand and wants
;; them on screen; it does not name a shape.
(define (tile-default-windows! buffers)
  (let ((panes (layout--known-buffers buffers)))
    (and (pair? panes)
         (tile-visible-windows! (or (layout-target) (layout-for-count (length panes)))
                                panes))))

(define (window-layout-command algorithm)
  (lambda ()
    (when (tile-visible-windows! algorithm)
      (layout-target-set! algorithm))))

;; Layout selection is a live preview. Keep the complete frame arrangement so
;; cancelling the prompt returns both the windows and the selected window.
(define (window-layout-preview! name &optional requested)
  ;; A failed earlier arrangement must not disable a later interactive
  ;; preview. This command is a new top-level layout request.
  (layout-abort!)
  (tile-visible-windows! (string->symbol name) requested))

;; a look at layout NAME: the frame's look (preview-show ... 'frame)
(define (window-layout-preview-without-history! name &optional requested)
  (let ((result #f))
    (preview-show (lambda () (set! result (window-layout-preview! name requested))) 'frame)
    result))

(define-command "window-layout-single" "Show one window"
  (window-layout-command 'single))
(define-command "window-layout-two-pane"
  "Show two panes side by side; the first pane takes two thirds"
  (window-layout-command 'two-pane))
(define-command "window-layout-halves" "Show two equal panes side by side"
  (window-layout-command 'halves))
(define-command "window-layout-columns" "Show three equal columns"
  (window-layout-command 'columns))
(define-command "window-layout-rows" "Show two equal panes, one above the other"
  (window-layout-command 'rows))
(define-command "window-layout-two-chat"
  "Show two equal panes and the group's chat in a narrow pane on the right"
  (window-layout-command 'two-chat))

;; the commit: the chosen layout is the frame's target from here on
(define (window-layout-choose! saved name &optional requested)
  ;; One visible step: the choice applies from wherever the preview left
  ;; the panes (applying a layout is idempotent), and winner gets the
  ;; arrangement the prompt started from by hand, so one undo returns to
  ;; it. Restoring first and applying again was the two-step flash.
  (debounce-cancel! "window-layout-preview")
  (cond ((equal? name "free")
         (preview-end #f)
         (layout-target-free!)
         (message "Layout free: a display may split a window again"))
        (else
          (if (let ((ok (window-layout-preview-without-history! name requested)))
                (preview-end #t)
                ok)
              (begin
                (layout-target-set! (string->symbol name))
                (message (string-append "Layout " name " is the target")))
              #f))))

;; the rest an arrow takes before the prompt applies its candidate
(define window-layout-preview-delay-ms 120)

(define-command "window-layout" "Choose a tiling layout for visible buffers; the choice is the frame's target layout"
  (lambda ()
    (let ((saved (window-tree))
          (saved-panes (layout-target-visible-buffers))
          (saved-order (layout-request-buffers)))
      (define (restore-preview!)
        (debounce-cancel! "window-layout-preview")
        (preview-end #f)
        (layout-target-note-slots! saved-panes))
      (minibuffer-read-preview "Window layout: "
        '(("single" "one window")
          ("two-pane" "2/3 + 1/3 side by side")
          ("halves" "two equal panes side by side")
          ("columns" "3 equal columns")
          ("rows" "two equal panes, stacked")
          ("two-chat" "2 + chat: two equal panes and a narrow chat")
          ("free" "no target: a display may split a window"))
        ;; A move applies the candidate from the same buffer order the
        ;; choice uses, so the preview is what you get: applying a layout
        ;; is idempotent, so no restore comes first and the choice adds no
        ;; pane. The panes keep their windows, and a pane keeps its
        ;; window's render. The original arrangement comes back once, on
        ;; cancel, or under the choice. and it waits for the arrow to
        ;; rest: a held key applies one layout, not one per step (the
        ;; owner's ruling, 2026-09-19)
        (lambda (name)
          (unless (equal? name "free")
            (debounce! "window-layout-preview" window-layout-preview-delay-ms
              (lambda (n) (window-layout-preview-without-history! n saved-order))
              name)))
        ;; the choice applies from the preview, one step; cancel restores
        (lambda (name) (window-layout-choose! saved name saved-order))
        (lambda () (restore-preview!))
        #f #f #f #f
        '(("1" "single") ("2" "two-pane") ("=" "halves")
          ("c" "columns") ("r" "rows") ("+" "two-chat") ("f" "free"))))))

(define-command "window-layout-free"
  "Drop the frame's target layout: a display may split a window again"
  (lambda ()
    (layout-target-free!)
    (message "Layout free: a display may split a window again")))

;;; --- scrolling the ring -----------------------------------------------------
;;; The layout shows a run of the window ring, and these move the run.
;;; Forward is right, backward is left, and the ring is cyclic, so neither
;;; one reaches an end. A frame with no more windows than panes says so.

;; Scroll by DELTA and stand at EDGE: the window that arrived.
;; The client slides the panes, so the user sees which buffer went out
;; and which came in.
(define (layout-scroll-to! delta edge)
  (and (layout-scroll! delta)
       (let ((panes (layout-pane-windows)))
         (client-slide! (if (> delta 0) "forward" "backward"))
         (when (pair? panes)
           (select-window! (if (equal? edge 'last) (car (reverse panes)) (car panes))))
         #t)))

;; A focus move that finds no window scrolls the strip instead: the frame's
;; edge is not the end of the buffers. Right and down go forwards, left and
;; up go backwards.
(define (layout-edge-scroll! dir)
  (and (layout-target)
       (if (member dir '(right down))
           (layout-scroll-to! 1 'last)
           (layout-scroll-to! -1 'first))))

(define (layout-scroll-command delta edge)
  (lambda ()
    (unless (layout-scroll-to! delta edge)
      (message "No hidden windows in this frame"))))

(define-command "layout-forward"
  "Move the layout one window forward through the frame's window ring"
  (layout-scroll-command 1 'last))
(define-command "layout-backward"
  "Move the layout one window backward through the frame's window ring"
  (layout-scroll-command -1 'first))

(for-each
  (lambda (name) (catalog-meta! 'command name 'domain 'windows 'effects '(write display)))
  '("window-layout" "window-layout-free" "window-layout-single"
    "window-layout-two-pane" "window-layout-halves"
    "window-layout-columns" "window-layout-rows" "window-layout-two-chat"
    "layout-forward" "layout-backward"))

;; The engine's entry point: a mode turned on in BUF. Arrange the frame only
;; when BUF is the buffer the user is looking at.
(define (layout-enter! buf)
  (let ((spec (buffer-layout buf)))
    (if (and spec
             (not (layout-target))
             (not *layout-busy*)
             (equal? (window-buffer (active-window)) buf))
        (apply-layout! buf spec)
        #f)))

(define-command "reset-layout" "Arrange the frame the way this buffer's mode asks"
  (lambda ()
    (layout-abort!)
    (let ((spec (buffer-layout (current-buffer))))
      (if spec
          ;; also the way back from an arrangement that failed part way: the
          ;; flag never outlives the command the user runs to fix the frame
          (begin (set! *layout-busy* #f)
                 (apply-layout! (current-buffer) spec))
          (message "This buffer's modes declare no layout")))))

(define (window-unwind-or-close! win)
  (let* ((cur (window-buffer win))
         (history (window-eligible-history win))
         (record (window-restore win)))
    (cond ((and record (equal? (car record) 'window) (layout-give-back! win)) #t)
          ((and record (equal? (car record) 'window) (other-window-id win))
           (delete-window-id! win) #t)
          ((pair? history)
           (display-buffer-in-window! win (car history))
           (set-window-restore! win #f)
           (set-window-prev-buffers! win (cdr history)) #t)
          ((other-window-id win)
           (delete-window-id! win) #t)
          (else
            (message "No previous buffer; this is the last window") #f))))

;; Quit consumes this window's own stack. An exhausted window closes before
;; the buffer dies, so kill repair cannot refill it from group recency.
(define-command "quit-window" "Kill this buffer and go back"
  (lambda ()
    (cond
      ;; a peek goes with its window: the look is over, and the layout
      ;; is what it was. In a split the split closes; alone, the window
      ;; falls to the next buffer.
      ((peek-buffer? (current-buffer))
        (let ((cur (current-buffer)))
          (cond ((window-quit-restore! (active-window)) #t)
                ((other-window-id (active-window))
                 (delete-window!))
                (else
                 (let loop ((bs (window-fill-buffers)))
                   (cond ((null? bs) #t)
                         ((and (not (equal? (car bs) cur)) (buffer-exists? (car bs)))
                          (switch-to-buffer! (car bs)))
                         (else (loop (cdr bs)))))))
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
;;; Winner records itself (Emacs winner-mode): a command that changed the
;;; frame's windows puts the arrangement it started from on a per-frame
;;; ring, once. C-c <left> walks back through the ring, C-c <right> walks
;;; forward. A change between commands (a reflow, an agent's display) is
;;; where the next command starts, not a command. A look, the pop of a
;;; stack entry and a winner walk settle the screen, so they push nothing
;;; and undo cannot pollute its own history. The record is written only
;;; in the command's own lane: the configuration hook runs in another.

;;; The same two steps are the one recording point for every completed
;;; window change: window-change-recorded-hook runs with the group the
;;; frame stood in when the change began (groups.scm saves its layout).

(define *winner-depth* 12)

;; the screen now is not a change the user made: winner takes it as settled
(define (winner--settle-screen!)
  (set-frame-local! 'winner-last
    (list (window-list) (window-tree) (frame-local 'current-group))))

;; a change between commands is recorded for the group, not for winner
(define (winner--pre-command!)
  (let ((last (frame-local 'winner-last)))
    (unless (and last (equal? (car last) (window-list)))
      (when last (run-hook-with-args 'window-change-recorded-hook (caddr last)))
      (winner--settle-screen!))))

(define (winner--post-command!)
  (let ((last (frame-local 'winner-last)))
    (unless (or (not last) (equal? (car last) (window-list)))
      (winner-push! (cadr last))
      (run-hook-with-args 'window-change-recorded-hook (caddr last))
      (winner--settle-screen!))))

(add-hook! 'pre-command-hook 'winner--pre-command!)
(add-hook! 'post-command-hook 'winner--post-command!)

(define (winner-save!) (winner-push! (window-tree)))

;; TREE goes onto the ring as the arrangement a command destroyed
(define (winner-push! tree)
  (let ((ring (or (frame-local 'winner-ring) '())))
    (unless (and (pair? ring) (equal? (car ring) tree))
      (set-frame-local! 'winner-ring (take (cons tree ring) *winner-depth*)))
    (set-frame-local! 'winner-pos #f)))

(define (winner--restore idx)
  (let ((ring (or (frame-local 'winner-ring) '())))
    (if (or (< idx 0) (>= idx (length ring)))
        (message (if (< idx 0) "at the latest layout" "no earlier layout"))
        (begin
          (set-frame-local! 'winner-pos idx)
          ;; the configuration hook runs in another lane and may run before
          ;; the settle: it must already count the panes the walk restores
          (set-frame-local! 'layout-target-count (length (window-tree-buffers (nth idx ring))))
          (window-tree-set! (nth idx ring))
          (winner--settle-screen!)
          (winner--settle!)
          (message (string-append "layout "
                     (number->string (+ idx 1)) "/"
                     (number->string (length ring))))))))

;; The restored arrangement is the one the user asked for. The layout
;; engine reflows when the panes change: a target compares its slot
;; count. The walk tells it that the restored panes are current, so the
;; configuration hook that follows the restore has nothing to reflow and
;; the undo stands. winner-restore-hook carries the news to packages that
;; keep an arrangement of their own.
(define (winner--settle!)
  (when (layout-target)
    (layout-target-note-slots! (layout-target-visible-buffers)))
  (run-hooks 'winner-restore-hook))

(define (winner-previous!)
  (let ((pos (frame-local 'winner-pos)))
    (if pos
        (winner--restore (+ pos 1))
        ;; entering the walk: the CURRENT arrangement joins the ring
        ;; first, so next can return to it.
        (begin
          (winner-save!)
          (winner--restore 1)))))

(define (winner-next!)
  (let ((pos (frame-local 'winner-pos)))
    (if (and pos (> pos 0))
        (winner--restore (- pos 1))
        (message "at the latest layout"))))

;; The ring holds layouts, and a layout names its buffers. A rename that
;; does not reach the ring makes winner-undo restore a window on a dead
;; name. Every frame keeps its own ring, so the sweep walks them all.
(add-hook! 'buffer-renamed-hook
  (lambda (old new)
    (set! *frame-locals*
      (map (lambda (frame-entry)
             (list (car frame-entry)
                   (map (lambda (item)
                          (cond ((equal? (car item) 'winner-ring)
                                 (list 'winner-ring
                                       (map (lambda (tree)
                                              (window-tree-rename tree old new))
                                            (car (cdr item)))))
                                ((equal? (car item) 'winner-last) (list 'winner-last #f))
                                (else item)))
                        (car (cdr frame-entry)))))
           *frame-locals*))))

;; These names describe the operation as a desktop switch: the saved tree
;; contains both the window arrangement and the buffer shown in each window.
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

;; the window mutators the keyboard reaches (C-x 1/2/3/0) push
;; the arrangement they are about to destroy
(define (window-tree-set! tree)
  (builtin-window-tree-set! tree)
  (window-state-changed!))

;; a look at an arrangement, the way window-preview-buffer! is a look at
;; a buffer: the windows change, the MRU ring does not
(define (window-tree-preview! tree)
  (builtin-window-tree-preview! tree)
  (window-state-changed!))

(define (delete-other-windows!)
  (builtin-delete-other-windows!)
  (window-state-changed!))

(define (split-window! dir &optional ratio)
  (let ((result (if ratio
                    (builtin-split-window! dir ratio)
                    (builtin-split-window! dir))))
    (window-state-changed!)
    result))

(define (delete-window!)
  (let ((result (builtin-delete-window!)))
    (window-state-changed!)
    result))

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

(define (split-window-with-other-buffer! direction)
  (let* ((before (map car (window-list)))
         (shown (map cadr (window-list)))
         (candidates (filter (lambda (b) (not (member b shown))) (window-fill-buffers))))
    (split-window! direction)
    (let ((created (layout--new-window before)))
      (when (and created (pair? candidates))
        (display-buffer-in-window! created (car candidates)))
      created)))

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

;; Cmd-arrows (s- = super) move the focus geometrically: window-rects gives each
;; leaf's normalized frame rectangle, and the neighbor in DIR is the nearest
;; window past the active edge whose span contains the active center — so
;; motion follows what's on screen, not the split tree's shape.
(define (window-in-direction dir)
  (let* ((rs (window-rects))
         (me (let find ((l rs))
               (cond ((null? l) #f)
                     ((equal? (car (car l)) (active-window)) (car l))
                     (else (find (cdr l)))))))
    (and me
         (let* ((mx (list-ref me 2)) (my (list-ref me 3))
                (cx (+ mx (/ (list-ref me 4) 2)))
                (cy (+ my (/ (list-ref me 5) 2)))
                (eps 0.000001))
           (let loop ((l rs) (best #f) (bestd 999))
             (if (null? l)
                 best
                 (let* ((r (car l))
                        (x (list-ref r 2)) (y (list-ref r 3))
                        (w (list-ref r 4)) (h (list-ref r 5))
                        (d (cond ((equal? dir 'left)
                                  (and (<= (+ x w) (+ mx eps)) (<= y cy) (< cy (+ y h))
                                       (- mx (+ x w))))
                                 ((equal? dir 'right)
                                  (and (>= (+ x eps) (+ mx (list-ref me 4))) (<= y cy) (< cy (+ y h))
                                       (- x (+ mx (list-ref me 4)))))
                                 ((equal? dir 'up)
                                  (and (<= (+ y h) (+ my eps)) (<= x cx) (< cx (+ x w))
                                       (- my (+ y h))))
                                 (else
                                  (and (>= (+ y eps) (+ my (list-ref me 5))) (<= x cx) (< cx (+ x w))
                                       (- y (+ my (list-ref me 5))))))))
                   (if (and d (< d bestd))
                       (loop (cdr l) r d)
                       (loop (cdr l) best bestd)))))))))

(define (focus-move! dir)
  (let ((w (window-in-direction dir)))
    (cond (w (select-window! (car w))
             (chat-snap-to-input!))
          ((layout-edge-scroll! dir) (chat-snap-to-input!))
          (else (message (string-append "No window " (symbol->string dir)))))))

;; a move that lands on a peek's window goes back: a preview takes no
;; focus. M-<down> scrolls it; RET on its row opens it.
(define (focus-move-safe! dir)
  (let ((from (active-window)))
    (focus-move! dir)
    (unless (window-focusable? (active-window))
      (select-window! from)
      (message "A peek: RET on its row opens it, M-<down> scrolls it"))))

(define-command "focus-left" "Select the window to the left"
  (lambda () (focus-move-safe! 'left)))
(define-command "focus-right" "Select the window to the right"
  (lambda () (focus-move-safe! 'right)))
(define-command "focus-up" "Select the window above"
  (lambda () (focus-move-safe! 'up)))
(define-command "focus-down" "Select the window below"
  (lambda () (focus-move-safe! 'down)))

;; Move the buffer onto the neighboring stack; consume the source's previous
;; entry instead of exchanging the two visible buffers. Splits stay intact.
(define (buffer-move! dir)
  (let* ((source (active-window))
         (neighbor (window-in-direction dir))
         (buf (window-buffer source))
         (point (window-point source))
         (past (window-prev-buffers source))
         (eligible (filter (lambda (b)
                            (and (not (equal? b buf))
                                 (buffer-known? b) (not (buffer-context-only? b))
                                 (not (float--class? b)) (not (peek-buffer? b))
                                 (window-fill-member? b))) past)))
    (cond ((not neighbor) (message "No neighboring pane"))
          ((or (not (window-focusable? (car neighbor)))
               (not (layout-visible-window? neighbor))
               (not (layout-visible-window? (list source buf)))
               (not (window-fill-member? buf)))
           (message "Cannot move this buffer into that pane"))
          ((null? eligible) (message "No previous buffer to reveal"))
          (else
            (switch-to-buffer-here! (car eligible))
            (set-window-prev-buffers! source
              (filter (lambda (b) (not (equal? b buf))) past))
            (select-window! (car neighbor))
            (switch-to-buffer-here! buf)
            (window-set-point! (car neighbor) point)))))

(for-each
  (lambda (dir)
    (let ((name (string-append "buffer-" (symbol->string dir))))
      (define-command name "Move this buffer to the neighboring pane and reveal its previous buffer"
        (lambda () (buffer-move! dir)))
      (catalog-meta! 'command name 'domain 'windows 'effects '(write display))))
  '(left right up down))

;; Move this logical window into the directional neighbor's pane and follow it.
;; The neighboring logical window moves into this pane; both complete stacks stay whole.
;; (window-left/right/up/down — the window family)
(define (window-swap! dir)
  "Move this logical window to the neighboring pane, carrying its complete stack and state."
  (let ((nb (window-in-direction dir)))
    (if nb
        (if (window-swap-id! (active-window) (car nb))
            (chat-snap-to-input!)
            (message "Could not move window"))
        (message (string-append "No window " (symbol->string dir))))))

(define-command "window-left" "Move this window leftward with its complete buffer stack"
  (lambda () (window-swap! 'left)))
(define-command "window-right" "Move this window rightward with its complete buffer stack"
  (lambda () (window-swap! 'right)))
(define-command "window-up" "Move this window upward with its complete buffer stack"
  (lambda () (window-swap! 'up)))
(define-command "window-down" "Move this window downward with its complete buffer stack"
  (lambda () (window-swap! 'down)))
(for-each
  (lambda (name) (catalog-meta! 'command name 'domain 'windows 'effects '(write display)))
  '("focus-left" "focus-right" "focus-up" "focus-down"
    "window-left" "window-right"
    "window-up" "window-down"))

;; Eat the pane next door: it goes away and this window takes exactly its
;; rectangle. Only a neighbor that shares a whole edge is a meal, so the
;; panes that are not eaten keep the space they had — the space does not
;; fall to whichever sibling the split tree favours, the way a delete
;; leaves it. Without a direction the first neighbor that merges is
;; eaten, right and down first.
(define *window-eat-order* '(right down left up))

(define (window--rect id)
  (let loop ((l (window-rects)))
    (cond ((null? l) #f)
          ((equal? (car (car l)) id) (car l))
          (else (loop (cdr l))))))

;; two panes make one rectangle when they meet along a whole shared edge
(define (window-rects-merge? a b)
  (let* ((eps 1.0e-6)
         (near? (lambda (p q) (< (abs (- p q)) eps)))
         (ax (list-ref a 2)) (ay (list-ref a 3))
         (aw (list-ref a 4)) (ah (list-ref a 5))
         (bx (list-ref b 2)) (by (list-ref b 3))
         (bw (list-ref b 4)) (bh (list-ref b 5)))
    (or (and (near? ay by) (near? ah bh)
             (or (near? (+ ax aw) bx) (near? (+ bx bw) ax)))
        (and (near? ax bx) (near? aw bw)
             (or (near? (+ ay ah) by) (near? (+ by bh) ay))))))

(define (window-eat! &optional dir)
  (let ((me (active-window))
        (mine (window--rect (active-window)))
        (dirs (if dir (list dir) *window-eat-order*)))
    (let loop ((l dirs) (refused #f))
      (if (null? l)
          (message (if refused
                       "That pane and this one make no rectangle"
                       "No neighboring pane"))
          (let ((n (window-in-direction (car l))))
            (cond ((not n) (loop (cdr l) refused))
                  ((or (not (window-focusable? (car n)))
                       (not (layout-visible-window? n))
                       (not (window-rects-merge? mine n)))
                   (loop (cdr l) #t))
                  (else
                    ;; an eat is a delete: C-c <left> brings the pane back
                    (window-eat-id! me (car n))
                    (window-state-changed!)
                    (message (string-append "Ate " (cadr n))))))))))

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

(define (install-arrow-keys! modifiers prefix)
  (for-each
    (lambda (dir)
      (global-set-key (arrow-chord modifiers (string-append "<" dir ">"))
                      (string-append prefix dir)))
    *direction-names*))

(define (focus-default-keybindings &optional modifiers)
  (install-arrow-keys! modifiers "focus-"))

;; default chords: Cmd-Shift for the window and buffer families
(define (window-default-keybindings &optional modifiers)
  (install-arrow-keys! (or modifiers '(shift super)) "window-"))

(define (buffer-default-keybindings &optional modifiers)
  (install-arrow-keys! (or modifiers '(shift super)) "buffer-"))

(domain! 'unknown)
(effects! '(unknown))

;; Cmd-left and Cmd-right move the focus. Cmd-up and Cmd-down do NOT: they
;; walk the group's buffers in the pane you stand in, and groups.scm binds
;; them, because the walk is a group's business. One escape hatch, one
;; axis: whatever the frame looks like, Cmd-down is always the next buffer.
;; Cmd-Shift-arrows swap the two panes. Cmd-Ctrl-left and Cmd-Ctrl-right
;; move this buffer to the neighboring pane.
(global-set-key (arrow-chord 'super "<left>") "focus-left")
(global-set-key (arrow-chord 'super "<right>") "focus-right")
(window-default-keybindings '(shift super))
(global-set-key (arrow-chord '(super control) "<left>") "buffer-left")
(global-set-key (arrow-chord '(super control) "<right>") "buffer-right")

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
  "(display-buffer NAME [ALIST]) — show NAME where the display rules and the action chain say, selecting nothing; returns the window. ALIST is a plist: 'category KIND, 'inhibit-same-window #t")
(public! 'pop-to-buffer
  "(pop-to-buffer NAME [ALIST]) — display-buffer, then select the window it used")
(public! 'display-buffer-actions-for
  "(display-buffer-actions-for NAME [ALIST]) — the action chain a display of NAME would try, in order")
(public! 'layout-target
  "(layout-target) — the frame's target layout, the name chosen at window-layout, or #f")
(public! 'layout-target-set!
  "(layout-target-set! NAME) — keep NAME as the target algorithm as panes open or close; #f frees the frame")
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
(effects! '(write display))
(public! 'get-other-window
  "(get-other-window) — the window to show a buffer in for the user, never the active one; below the target layout's capacity the layout gains a pane")
(effects! '(read))
(public! 'split-window-sensibly
  "(split-window-sensibly WIN) — split WIN below when it is tall enough, beside when wide enough; the new window or #f")
(public! 'window-quit-restore!
  "(window-quit-restore! WIN) — undo what a display did to WIN: delete the window it made, or put back the buffer it replaced")
(public! 'display-buffer-other-window! "(display-buffer-other-window! NAME) — show NAME without leaving this window: the display chain with the selected window kept out of it")
(public! 'apply-layout! "(apply-layout! ANCHOR SPEC) — arrange the frame by SPEC, ANCHOR keeping focus")
(public! 'tile-windows!
  "(tile-windows! ALGORITHM BUFFERS) — arrange names with single, two-pane, halves, columns, or rows")
(public! 'tile-visible-windows!
  "(tile-visible-windows! ALGORITHM) — rearrange visible work windows with a named layout and lay the strip again")
(public! 'tile-default-windows!
  "(tile-default-windows! BUFFERS) — tile BUFFERS with the frame's chosen layout, or the one that fits them")
(public! 'layout-capacity
  "(layout-capacity ALGORITHM) — the number of panes a layout holds: 1, 2 or 3, or #f when the name is not a layout")
(public! 'layout-strip
  "(layout-strip) — the window ring of the current walk: window ids in one cyclic order; the layout shows a run of this list")
(public! 'layout-scroll!
  "(layout-scroll! DELTA) — move the run DELTA windows along the ring, forwards or backwards; #f when the ring is no longer than the layout")
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
(public! 'with-layout-suppressed "(with-layout-suppressed THUNK) — run THUNK without the layout engine arranging the frame")
(domain! 'unknown)
(effects! '(unknown))
(category! 'interaction)
(catalog-meta! 'command "reset-layout" 'domain 'windows 'effects '(write display))
(catalog-meta! 'function "define-mode-layout!" 'domain 'windows 'effects '(write))
(category! 'commands)
(public! 'focus-default-keybindings "(focus-default-keybindings &optional MODIFIERS) — bind the arrows with MODIFIERS (shift control meta super; default shift) to focus-left/right/up/down")
(public! 'window-default-keybindings "(window-default-keybindings &optional MODIFIERS) — bind the arrows with MODIFIERS (default shift super) to window-left/right/up/down; the logical windows exchange panes with their complete stacks and focus follows")
(public! 'buffer-default-keybindings "(buffer-default-keybindings &optional MODIFIERS) — bind the arrows with MODIFIERS (default shift super) to buffer-left/right/up/down; the buffer moves to the neighbor and its previous buffer shows here")
(public! 'arrow-chord "(arrow-chord MODIFIERS KEY) — the key spec for KEY under MODIFIERS, e.g. (arrow-chord '(meta shift) \"<left>\") is \"M-S-<left>\"")
(public! 'layout-arranging? "(layout-arranging?) — #t while the layout engine is building the frame; a package that moves windows must stand down")
(public! 'layout-abort! "(layout-abort!) — clear a layout build left in progress by a failure; a top-level build calls this first")

(domain! 'unknown)
(effects! '(unknown))
