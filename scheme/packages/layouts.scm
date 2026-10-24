;;; layouts.scm — window layout policy.
;;;
;;; The settings of the windows: the layouts read them (panes-mode.scm
;;; defines the layouts), and transient frames borrow the frame and give
;;; it back.

(category! 'windows)
(domain! 'windows)
(effects! '(write))

(defgroup 'windows "Window layout and responsive popup policy.")

;; peek! and the ripgrep preview (editor.scm) read this one.
(defcustom 'peek-max-file-size 1048576
  "The largest file a look opens. A peek or a ripgrep preview of a bigger file shows nothing and says the size; RET still opens it. 0 removes the cap."
  'group 'windows 'type 'number)

;; visit and visit-quietly (editor.scm) read this one.
(defcustom 'large-file-warning-threshold 10485760
  "The largest file a visit opens without asking (Emacs large-file-warning-threshold). A visit of a bigger file refuses and says the size; M-x find-file asks, and a yes opens it for this session only. 0 removes the cap."
  'group 'files 'type 'number)

(defcustom 'next-screen-context-lines 2
  "Rows a page scroll keeps from the screen before it. A page overlaps by this much and never leaves a gap (Emacs next-screen-context-lines)."
  'group 'windows 'type 'number)

;; A frame's target layout until the person frees it (C-x l free).
(defcustom 'window-layout-default 'columns
  "The layout a new group takes: 'single, 'two-pane, 'halves, 'columns, 'two-chat or 'free. Windows are added as buffers open, up to the layout's panes."
  'group 'windows 'type 'choice)

;; The two-pane layout reads this one.
(defcustom 'window-layout-main-ratio 0.62
  "The first pane's share of the frame in the two-pane layout: a fraction between 0.3 and 0.9."
  'group 'windows 'type 'number)

(defcustom 'window-layout-columns 3
  "How many panes the columns layout shows; it keeps no hidden windows."
  'group 'windows 'type 'integer)

;; The two-chat layout reads this one.
(defcustom 'window-layout-chat-ratio 0.25
  "The chat pane's share of the frame in the two-chat layout, such as 0.25. The other two panes share the rest equally."
  'group 'windows 'type 'number)

;;; --- transient frames -------------------------------------------------------
;;; A transient frame mode borrows the frame and gives it back. It records
;;; the arrangement it found on the way in, and leaving puts that
;;; arrangement back EXACTLY: the same panes, the same buffers in them,
;;; and the group the frame stood in.
;;;
;;; This is not window history and it is not quit-restore. Those answer
;;; "what did this one window show before", one window at a time, and a
;;; mode that split, covered or retiled the frame cannot be undone one
;;; window at a time — the window it was invoked in came back holding
;;; whatever the history had, and the pane beside it was simply lost.
;;;
;;; A mode enters by NAME, so two can stand at once without reading each
;;; other's record. Entering twice does not re-record: what a mode gives
;;; back is the arrangement from before it took the frame, never one it
;;; made itself. A mode that stopped standing by some other road — its
;;; buffer was replaced, a layout was applied — abandons its record
;;; instead of restoring a tree of windows that no longer exist.

;; A record is an entry on the frame return stack, pushed for NAME.
(define (transient-frame-standing? name) (and (arrangement-for name) #t))

(define (transient-frame-enter! name)
  (and (not (transient-frame-standing? name)) (arrangement-push! name) #t))

(define (transient-frame-abandon! name)
  (arrangement-drop! (arrangement-for name))
  #f)

;; the mode is standing only while the buffer it took the frame for is on
;; screen. Arriving with a stale record re-arms: the arrangement to give
;; back is the one in front of you now.
(define (transient-frame-rearm! name buf)
  (when (and (transient-frame-standing? name)
             (not (and (string? buf) (buffer-known? buf) (window-showing buf))))
    (transient-frame-abandon! name))
  (transient-frame-enter! name))

(define (transient-frame-exit! name) (arrangement-pop! (arrangement-for name)))

(public! 'transient-frame-enter!
  "(transient-frame-enter! NAME) — record the frame's arrangement so NAME can give it back; #f when NAME already stands")
(public! 'transient-frame-exit!
  "(transient-frame-exit! NAME) — put back exactly the arrangement and group NAME found; #f when NAME never entered")
(public! 'transient-frame-standing?
  "(transient-frame-standing? NAME) — #t while NAME holds an arrangement to give back")
(public! 'transient-frame-rearm!
  "(transient-frame-rearm! NAME BUF) — enter, re-recording when NAME's record is stale because BUF is not on screen")
(public! 'transient-frame-abandon!
  "(transient-frame-abandon! NAME) — drop NAME's record without restoring anything")

(domain! 'unknown)
(effects! '(unknown))

