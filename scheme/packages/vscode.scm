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
    ("s-{" "window-previous-buffer")
    ("s-}" "window-next-buffer")
    ("s-1" "vscode-focus-window-1") ("s-2" "vscode-focus-window-2")
    ("s-3" "vscode-focus-window-3") ("s-4" "vscode-focus-window-4")
    ("s-5" "vscode-focus-window-5") ("s-6" "vscode-focus-window-6")
    ("s-7" "vscode-focus-window-7") ("s-8" "vscode-focus-window-8")
    ("s-9" "vscode-focus-window-9")
    ;; split, close and move windows
    ("s-\\" "split-window-right")
    ("s-w" "vscode-close-buffer")
    ("C-s-<left>" "window-previous-pane")
    ("C-s-<right>" "window-next-pane")
    ;; Cmd-K opens M-x, as the Cmd-K bar of a web app does: the tutorial
    ;; commands come first while nothing is typed
    ("s-k" "execute-extended-command")))

(define-keymap! "vscode-mode-map")
;; Shift with a letter arrives as the capital: s-P, never s-S-p
(for-each (lambda (k) (keymap-unset! "vscode-mode-map" k))
          '("s-S-p" "s-S-f" "s-S-e" "C-<tab>"
            ;; Cmd-K was a prefix before it opened M-x
            "s-k s-<left>" "s-k s-<right>" "s-k s-<up>" "s-k s-<down>" "s-k s-\\" "s-k s-w"
            "s-k <left>" "s-k <right>" "s-k <up>" "s-k <down>" "s-k s-s" "s-k l" "s-k b" "s-k c"))
(for-each (lambda (k) (define-key "vscode-mode-map" (car k) (cadr k))) vscode--keys)

(define (vscode--others)
  (remove (lambda (m) (equal? m "vscode-mode-map")) (global-minor-maps)))

;; the browser keeps a Cmd chord unless the client knows a keymap wants
;; it. The base key of every Cmd chord the global maps bind rides the
;; frame chrome as cmd-keys: s-P gives P, s-k s-\\ gives k, C-s-<left>
;; gives <left>.
(define (vscode--base key)
  (if (and (> (string-length key) 2)
           (member (substring key 0 2) '("C-" "M-" "S-" "s-")))
      (vscode--base (substring key 2 (string-length key)))
      key))

;; the base of a chord that holds Cmd, else the chord itself
(define (vscode--cmd-base key)
  (if (string-contains? key "s-") (vscode--base key) key))

(define (cmd-keys)
  (let loop ((rows (apply append (map keymap-bindings (cons "global" (global-minor-maps)))))
             (out '()))
    (if (null? rows)
        (reverse out)
        (let* ((first (car (string-split (car (car rows)) " ")))
               (base (vscode--cmd-base first)))
          (loop (cdr rows)
                (if (and (not (equal? base first)) (not (member base out)))
                    (cons base out)
                    out))))))

(define (cmd-keys-publish!)
  (frame-chrome-set! "cmd-keys" (cmd-keys)))

(define (vscode--apply! on)
  (global-minor-maps! (if on (cons "vscode-mode-map" (vscode--others)) (vscode--others)))
  (cmd-keys-publish!))

(defcustom 'vscode-mode #f
  "Use the VSCode keys for the palette, files and windows, in every buffer."
  'group 'vscode 'type 'boolean
  'set vscode--apply!)

(define-command "vscode-mode" "Toggle the VSCode keys for the palette, files and windows"
  (lambda ()
    (customize-save! 'vscode-mode (not vscode-mode))
    (message (if vscode-mode "VSCode keys on" "VSCode keys off"))))

(mode-doc! "vscode-mode"
  "The VSCode keys, in every buffer. Cmd-K opens M-x, with the tutorial commands first. Cmd-Shift-P or F1 opens the command palette. Cmd-P finds a file in the project, Cmd-O opens a file, Cmd-Shift-F searches the project and Cmd-Shift-E shows its files. Cmd-Shift-[ and ] step through this window's buffers, and Cmd-1 to Cmd-9 go to a window by its place. Cmd-\\ splits to the side. Cmd-W closes the buffer. Ctrl-Cmd-Left/Right move this window to the pane beside it. M-x vscode-mode turns it on or off, and the choice lasts.")

(vscode--apply! vscode-mode)

(catalog-meta! 'command "vscode-mode" 'domain 'commands 'effects '(write))
(public! 'cmd-keys "(cmd-keys) — the base keys of the Cmd chords the global maps bind; the browser passes these through")
(public! 'cmd-keys-publish! "(cmd-keys-publish!) — send cmd-keys to every frame")
(public! 'vscode--keys "vscode--keys — the ((KEYS COMMAND) ...) vscode-mode puts in force")
