;;; vscode.scm --- VSCode keys for files, windows and the palette.
;;;
;;; vscode-mode is one switch, as evil-mode is: on, the VSCode chords for
;;; the palette, quick open, search and the editor groups answer in every
;;; buffer; off, they go and the Emacs keys answer again. The keys live in
;;; one global minor map, so nothing else is rebound. The choice is a
;;; customize variable: it lasts across sessions.

(domain! 'commands)
(effects! '(write display))

;; VSCode's editor groups are the panes, left to right, top to bottom
(define (vscode--focus-pane! n)
  (let* ((l (panes--ensure-layout!))
         (ids (panes-pane-ids l)))
    (if (<= n (length ids))
        (panes-apply! (panes-set-focus l (list-ref ids (- n 1))))
        (message (string-append "No window " (number->string n))))))

(define (vscode--define-focus! n)
  (define-command (string-append "vscode-focus-window-" (number->string n))
    (string-append "Go to window " (number->string n) ", counting left to right")
    (lambda () (vscode--focus-pane! n))))

(for-each vscode--define-focus! '(1 2 3 4 5 6 7 8 9))

;; Cmd-W closes the editor: this buffer, asking first when it holds unsaved work
(define-command "vscode-close-buffer" "Close this buffer, asking when it has unsaved changes"
  (lambda () (kill-buffer-confirm! (current-buffer) (lambda (killed?) #t))))

;; the VSCode chords on macOS: Cmd is s-, Ctrl is C-
(define vscode--keys
  '(;; the palette
    ("s-P" "command-palette")
    ("<f1>" "command-palette")
    ;; files
    ("s-p" "project-find-file")
    ("s-o" "find-file")
    ("s-F" "project-ripgrep")
    ("s-E" "project-dired")
    ;; switch between buffers and windows
    ("C-<tab>" "ibuffer-prompt")
    ("s-{" "window-previous-buffer")
    ("s-}" "window-next-buffer")
    ("s-1" "vscode-focus-window-1") ("s-2" "vscode-focus-window-2")
    ("s-3" "vscode-focus-window-3") ("s-4" "vscode-focus-window-4")
    ("s-5" "vscode-focus-window-5") ("s-6" "vscode-focus-window-6")
    ("s-7" "vscode-focus-window-7") ("s-8" "vscode-focus-window-8")
    ("s-9" "vscode-focus-window-9")
    ("s-k s-<left>" "focus-left") ("s-k s-<right>" "focus-right")
    ("s-k s-<up>" "focus-up") ("s-k s-<down>" "focus-down")
    ;; split, close and move windows
    ("s-\\" "split-window-right")
    ("s-k s-\\" "split-window-below")
    ("s-w" "vscode-close-buffer")
    ("s-k s-w" "delete-window")
    ("C-s-<left>" "window-previous-pane")
    ("C-s-<right>" "window-next-pane")
    ("s-k <left>" "pane-move-left") ("s-k <right>" "pane-move-right")
    ("s-k <up>" "pane-move-up") ("s-k <down>" "pane-move-down")
    ;; Keyboard Shortcuts
    ("s-k s-s" "keys")))

(define-keymap! "vscode-mode-map")
;; Shift with a letter arrives as the capital: s-P, never s-S-p
(for-each (lambda (k) (keymap-unset! "vscode-mode-map" k)) '("s-S-p" "s-S-f" "s-S-e"))
(for-each (lambda (k) (define-key "vscode-mode-map" (car k) (cadr k))) vscode--keys)

(define (vscode--others)
  (remove (lambda (m) (equal? m "vscode-mode-map")) (global-minor-maps)))

(define (vscode--apply! on)
  (global-minor-maps! (if on (cons "vscode-mode-map" (vscode--others)) (vscode--others))))

(defcustom 'vscode-mode #f
  "Use the VSCode keys for the palette, files and windows, in every buffer."
  'group 'vscode 'type 'boolean
  'set vscode--apply!)

(define-command "vscode-mode" "Toggle the VSCode keys for the palette, files and windows"
  (lambda ()
    (customize-save! 'vscode-mode (not vscode-mode))
    (message (if vscode-mode "VSCode keys on" "VSCode keys off"))))

(mode-doc! "vscode-mode"
  "The VSCode keys, in every buffer. Cmd-Shift-P or F1 opens the command palette. Cmd-P finds a file in the project, Cmd-O opens a file, Cmd-Shift-F searches the project and Cmd-Shift-E shows its files. Ctrl-Tab switches buffers, Cmd-Shift-[ and ] step through this window's buffers, Cmd-1 to Cmd-9 go to a window by its place, and Cmd-K Cmd-arrow goes to the window in that direction. Cmd-\\ splits to the side and Cmd-K Cmd-\\ below. Cmd-W closes the buffer and Cmd-K Cmd-W the window. Ctrl-Cmd-Left/Right move this window to the pane beside it, and Cmd-K arrow moves the pane. Cmd-K Cmd-S lists the keys. M-x vscode-mode turns it on or off, and the choice lasts.")

(vscode--apply! vscode-mode)

(catalog-meta! 'command "vscode-mode" 'domain 'commands 'effects '(write))
(public! 'vscode--keys "vscode--keys — the ((KEYS COMMAND) ...) vscode-mode puts in force")
