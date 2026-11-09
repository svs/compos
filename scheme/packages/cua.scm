;;; cua.scm --- CUA selection: Shift extends the region.
;;;
;;; The shared mechanism behind Emacs's cua-mode and shift-select-mode: a
;;; motion with Shift held starts a region at point when there is none and
;;; extends it. The commands here move by the same primitives as the plain
;;; motions, so a mode that changes what a line or a word is changes them
;;; too. cua-mode owns the keys, in every buffer you are editing.

(domain! 'editing)
(effects! '(write))

(define (cua--select! mover)
  (unless (mark) (set-mark! (point)))
  (mover))

(define-command "cua-select-backward" "Extend the region one character left"
  (lambda () (cua--select! backward-char!))
  'modes '(cua-mode))
(define-command "cua-select-forward" "Extend the region one character right"
  (lambda () (cua--select! forward-char!))
  'modes '(cua-mode))
(define-command "cua-select-backward-word" "Extend the region one word left"
  (lambda () (cua--select! backward-word!))
  'modes '(cua-mode))
(define-command "cua-select-forward-word" "Extend the region one word right"
  (lambda () (cua--select! forward-word!))
  'modes '(cua-mode))
(define-command "cua-select-up" "Extend the region one visual line up"
  (lambda () (visual-previous-line! #t))
  'modes '(cua-mode))
(define-command "cua-select-down" "Extend the region one visual line down"
  (lambda () (visual-next-line! #t))
  'modes '(cua-mode))
(define-command "cua-select-line-start" "Extend the region to the start of the line"
  (lambda () (visual-beginning-of-line! #t))
  'modes '(cua-mode))
(define-command "cua-select-line-end" "Extend the region to the end of the line"
  (lambda () (visual-end-of-line! #t))
  'modes '(cua-mode))
(define-command "cua-select-buffer-start" "Extend the region to the start of the buffer"
  (lambda () (cua--select! beginning-of-buffer!))
  'modes '(cua-mode))
(define-command "cua-select-buffer-end" "Extend the region to the end of the buffer"
  (lambda () (cua--select! end-of-buffer!))
  'modes '(cua-mode))
(define-command "cua-select-all" "Select the entire buffer"
  (lambda ()
    (set-mark! (buffer-size (current-buffer)))
    (goto-char! 0))
  'modes '(cua-mode))

;; a page is a screenful of visual rows, the same page the plain motion
;; steps by (visual-page!)
(define (cua--select-page! dir)
  (let ((n (- (window-rows) 2)))
    (or (visual-row-move! dir #t n)
        (begin (unless (mark) (set-mark! (point)))
               (move-lines n (if (> dir 0) next-line! previous-line!))))))

(define-command "cua-select-page-up" "Extend the region one screen up"
  (lambda () (cua--select-page! -1))
  'modes '(cua-mode))
(define-command "cua-select-page-down" "Extend the region one screen down"
  (lambda () (cua--select-page! 1))
  'modes '(cua-mode))

;; the bindings cua-mode puts in force in a buffer you are editing
(define cua--keys
  '(("S-<left>" "cua-select-backward")
    ("S-<right>" "cua-select-forward")
    ("S-<up>" "cua-select-up")
    ("S-<down>" "cua-select-down")
    ("S-<home>" "cua-select-line-start")
    ("S-<end>" "cua-select-line-end")
    ("C-S-<left>" "cua-select-backward-word")
    ("C-S-<right>" "cua-select-forward-word")
    ;; the macOS shape of the same word selection
    ("M-S-<left>" "cua-select-backward-word")
    ("M-S-<right>" "cua-select-forward-word")
    ("C-S-<home>" "cua-select-buffer-start")
    ("C-S-<end>" "cua-select-buffer-end")
    ("S-<prior>" "cua-select-page-up")
    ("S-<next>" "cua-select-page-down")
    ("s-a" "cua-select-all")))

(define *cua-mode* #f)

(define (cua-mode-on?) *cua-mode*)

;; the mode owns one keymap, and the map answers only in a buffer that
;; stands in the editing state. A buffer you have just landed on keeps
;; the plain meaning of the Shift chords: S-<left> walks buffer history,
;; M-S-<left> moves to the group on the left. The first key that says you
;; are editing here -- a letter, RET, an arrow, anything but the Shift
;; chords themselves -- arms the editing state, and the selections come
;; with it: the state installs this map beside its own, and takes both
;; away at the next landing.
(define-keymap! "cua-mode-map")
;; Cmd-Shift-arrows move views between panes: that chord is not cua's, and
;; the global binding answers it. Alt-Shift-<left>/<right> IS cua's here.
;; The chord moves between groups where you are not editing, and extends
;; the selection one word where you are: the macOS shape of the word
;; selection, beside the C-S-<left>/<right> shape. The unset drops the
;; bindings a reload left, groups.scm's old group move among them;
;; Shift-Home/End retain line selection.
(for-each (lambda (k) (keymap-unset! "cua-mode-map" k))
          '("s-S-<left>" "s-S-<right>" "s-S-<up>" "s-S-<down>"
            "M-S-<left>" "M-S-<right>"))
(for-each (lambda (k) (define-key "cua-mode-map" (car k) (cadr k))) cua--keys)

(define (cua--others)
  (remove (lambda (m) (equal? m "cua-mode-map")) (global-minor-maps)))

(define (cua--drop-from-buffers!)
  (for-each (lambda (b)
              (when (member "cua-mode-map" (buffer-minor-maps b))
                (buffer-minor-maps! b
                  (remove (lambda (m) (equal? m "cua-mode-map")) (buffer-minor-maps b)))))
            (buffer-list)))

(define (cua--enable!)
  ;; the map was a global minor map once; a reload takes it back out
  (global-minor-maps! (cua--others))
  (editing-state-maps! '("cua-mode-map"))
  (set! *cua-mode* #t))

(define (cua--disable!)
  (global-minor-maps! (cua--others))
  (editing-state-maps-drop! '("cua-mode-map"))
  (cua--drop-from-buffers!)
  (set! *cua-mode* #f))

;; the chords cua owns say nothing about whether you are editing: pressing
;; one neither arms the editing state nor leaves it. The list is the
;; commands the chords run, armed (the selections) and unarmed (the
;; buffer walk under S-<left>/S-<right>).
(editing-neutral-commands!
  (append (map cadr cua--keys) '("previous-buffer" "next-buffer")))

(define-command "cua-mode" "Toggle Shift-selection in a buffer you are editing"
  (lambda ()
    (if *cua-mode*
        (begin (cua--disable!) (message "CUA mode disabled"))
        (begin (cua--enable!) (message "CUA mode enabled")))))

(mode-doc! "cua-mode"
  "Shift with a motion key extends the region, in a buffer you are editing. A buffer you have just landed on answers the Shift chords with their plain meaning until any other key arms it, so S-<left> still walks buffer history and M-S-<left> still moves to the group on the left. On by default; M-x cua-mode toggles it. The commands are cua-select-*.")

;; Shift-selection is on from the start, and waits in each buffer for the
;; first key that says you are editing there. On an editable surface the
;; browser answers the plain Shift motions natively; these bindings answer
;; where the server owns the caret, and for the chords the client sends as
;; keys (the Cmd arrows).
(cua--enable!)

(catalog-meta! 'command "cua-mode" 'domain 'editing 'effects '(write))
(public! 'cua-mode-on? "(cua-mode-on?) — #t when cua-mode binds the Shift selections globally")
