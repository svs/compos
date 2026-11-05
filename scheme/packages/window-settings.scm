;;; window-settings.scm --- the settings of the windows, one owner for each.
;;;
;;; The layouts (panes-mode.scm) and the previews (window.scm) read these
;;; when they run, never at load. init.scm loads this file right after
;;; custom.scm, so each name is bound before any package that reads it.

(category! 'windows)
(domain! 'windows)
(effects! '(write))

(defgroup 'windows "Window layout and responsive popup policy.")

;; the ripgrep and lsp previews (window.scm) read this one.
(defcustom 'preview-max-file-size 1048576
  "The largest file a preview opens. A preview of a bigger file shows nothing and says the size; RET still opens it. 0 removes the cap."
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

;; The two-pane layout reads this one: two thirds, as its doc says.
(defcustom 'window-layout-main-ratio (- 1 (/ 1 3))
  "The first pane's share of the frame in the two-pane layout: a fraction between 0.3 and 0.9."
  'group 'windows 'type 'number)

(defcustom 'window-layout-columns 3
  "How many panes the columns layout shows; it keeps no hidden windows."
  'group 'windows 'type 'integer)

;; The two-chat layout reads this one.
(defcustom 'window-layout-chat-ratio 0.25
  "The chat pane's share of the frame in the two-chat layout, such as 0.25. The other two panes share the rest equally."
  'group 'windows 'type 'number)

(domain! 'unknown)
(effects! '(unknown))
