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

;; Cmd-P, Cmd-J, Cmd-B and Cmd-L: one key for each thing on the screen.
;; The pane has its card; the window, the buffer and the chat a modal.

(define (vscode--short name)
  (if (and (> (string-length name) 0) (equal? (substring name 0 1) "/"))
      (file-name-nondirectory (strip-trailing-slash name))
      name))

(define (vscode--unique label seen)
  (let loop ((n 2) (l label))
    (if (member l seen)
        (loop (+ n 1) (string-append label " <" (number->string n) ">"))
        l)))

(define-command "vscode-windows" "Choose a layout, each one shows as you move to it; or a window of this group"
  (lambda ()
    (let* ((before (panes--ensure-layout!))
           (pids '())
           (seen '())
           (wins (let loop ((ks (panes-window-keys before)) (out '()))
                   (if (null? ks)
                       (reverse out)
                       (let* ((k (car ks))
                              (b (panes-window-buffer before k))
                              (pid (panes-pane-of before k)))
                         (unless (member pid pids) (set! pids (append pids (list pid))))
                         (if (not b)
                             (loop (cdr ks) out)
                             (let* ((n (length (member pid (reverse pids))))
                                    (label (vscode--unique
                                            (string-append "Pane " (number->string n) ": " (vscode--short b))
                                            seen)))
                               (set! seen (cons label seen))
                               (loop (cdr ks)
                                     (cons (list label k (if (window-exists? k) "on screen" "behind")) out))))))))
           (lays (map (lambda (n) (list (string-append "Layout: " (symbol->string n))
                                        n
                                        (or (plist-get (panes-layout-spec n) 'doc) "")))
                      (panes-layout-names)))
           (rows (append lays wins)))
      (minibuffer-read-preview "Window or layout: "
        (map (lambda (r) (list (car r) (nth 2 r))) rows)
        (lambda (label)
          (let ((r (assoc label lays)))
            (panes-look! (if r (panes-set-layout before (cadr r)) before))))
        (lambda (label)
          (cond ((assoc label lays)
                 => (lambda (r) (panes-choose-layout! (cadr r))
                       (message (string-append "Layout " (symbol->string (cadr r))))))
                ((assoc label wins)
                 => (lambda (r)
                      (let* ((applied (panes-apply! (panes-raise before (cadr r))))
                             (h (panes-handle applied (cadr r))))
                        (when (and h (window-exists? h)) (select-window! h)))))
                (else (panes-apply! before))))
        (lambda () (panes-apply! before))
        #f "modal" #f #f
        '(("1" "Layout: single") ("2" "Layout: two-pane") ("=" "Layout: halves")
          ("c" "Layout: columns") ("+" "Layout: two-chat") ("f" "Layout: free"))))))

(define-command "vscode-buffers" "Choose a buffer of this group, then a file of its project"
  (lambda ()
    (let* ((here (or (window-buffer (active-window)) (current-buffer)))
           (g (or (buffer-group here) (frame-group)))
           (bufs (filter (lambda (b) (and (not (equal? b here)) (equal? (buffer-group b) g)))
                         (map car (switch-prompt-rows here (active-window)))))
           (root (project-current))
           (root (and root (strip-trailing-slash root)))
           (files (if root
                      (filter (lambda (f) (not (member f bufs)))
                              (map car (filter (lambda (c) (not (equal? (cadr c) "dired")))
                                               (project-file-candidates root))))
                      '())))
      (minibuffer-read* "Buffer or file: "
        (append (map (lambda (b) (list b "buffer")) bufs)
                (map (lambda (f) (list f "file")) files))
        (list (list 'style "modal")
              (list 'confirm
                    (lambda (v)
                      (cond ((member v bufs) (ibuffer-pick! v (lambda () #f)) (group-current-recalculate!))
                            ((and root (member v files)) (visit-in-group (string-append root "/" v) g))
                            ((buffer-known? v) (ibuffer-pick! v (lambda () #f)))
                            (else (message (string-append "No buffer or file " v)))))))))))

(define-command "vscode-chats" "Choose a chat, in a modal"
  (lambda ()
    (chat-prompt-open!)
    (when (minibuffer-active?) (minibuffer-style! "modal"))))

;; the VSCode chords on macOS: Cmd is s-, Ctrl is C-
(define vscode--keys
  '(;; the palette
    ("s-P" "command-palette")
    ("<f1>" "command-palette")
    ;; files
    ("s-o" "find-file")
    ("s-F" "project-ripgrep")
    ("s-E" "project-dired")
    ;; the four things on the screen: pane, window, buffer, chat
    ("s-p" "pane-card")
    ("s-j" "vscode-windows")
    ("s-b" "vscode-buffers")
    ("s-l" "vscode-chats")
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
    ;; edit
    ("s-z" "undo")
    ("s-Z" "undo-redo")
    ("C-s-<left>" "window-previous-pane")
    ("C-s-<right>" "window-next-pane")
    ;; Cmd-K is the leader, as C-x is: Cmd-K t n is C-x t n
    ("s-k" (keymap "ctl-x-map"))))

(define-keymap! "vscode-mode-map")
;; Shift with a letter arrives as the capital: s-P, never s-S-p
(for-each (lambda (k) (keymap-unset! "vscode-mode-map" k))
          '("s-S-p" "s-S-f" "s-S-e" "C-<tab>"
            ;; Cmd-K was a prefix before it opened the palette
            "s-k s-<left>" "s-k s-<right>" "s-k s-<up>" "s-k s-<down>" "s-k s-\\" "s-k s-w"
            "s-k <left>" "s-k <right>" "s-k <up>" "s-k <down>" "s-k s-s" "s-k l" "s-k b" "s-k c"))
(for-each (lambda (k) (define-key "vscode-mode-map" (car k) (cadr k))) vscode--keys)

(define (vscode--others)
  (remove (lambda (m) (equal? m "vscode-mode-map")) (global-minor-maps)))

(define (vscode--apply! on)
  ;; global-minor-maps! republishes cmd-keys, so Cmd-W and the rest reach
  ;; the editor exactly while the mode is on
  (global-minor-maps! (if on (cons "vscode-mode-map" (vscode--others)) (vscode--others))))

(defcustom 'vscode-mode #f
  "Use the VSCode keys for the palette, files and windows, in every buffer."
  'group 'vscode 'type 'boolean
  'set vscode--apply!)

(define-command "vscode-mode" "Toggle the VSCode keys for the palette, files and windows"
  (lambda ()
    (customize-save! 'vscode-mode (not vscode-mode))
    (message (if vscode-mode "VSCode keys on" "VSCode keys off"))))

;; Chrome keeps Cmd-W, Cmd-T, Cmd-N, Cmd-1..9 and Ctrl-Tab for itself,
;; except in fullscreen with the Keyboard Lock API. The command asks the
;; page through frame chrome: fullscreen.js reads a new token and toggles
;; fullscreen, and locks the keys when the token says lock. keySpec still
;; decides which keys the editor gets, from cmd-keys.
(defcustom 'vscode-keyboard-lock #f
  "In fullscreen, take the keys the browser keeps: Cmd-W, Cmd-T, Cmd-N, Cmd-1..9, Ctrl-Tab."
  'group 'vscode 'type 'boolean)

(define-command "toggle-frame-fullscreen" "Toggle fullscreen; with vscode-keyboard-lock, the browser keys come to compos"
  (lambda ()
    (frame-chrome-set! "fullscreen"
      (string-append (number->string (monotonic-ms)) (if vscode-keyboard-lock " lock" "")))))

(mode-doc! "vscode-mode"
  "The VSCode keys, in every buffer. Cmd-K, Cmd-Shift-P or F1 opens the command palette, with Start here first. Cmd-P shows this pane's card. Cmd-J chooses a layout, or a window. Cmd-B chooses a buffer of this group, then a file of its project. Cmd-L chooses a chat. Cmd-O opens a file, Cmd-Shift-F searches the project and Cmd-Shift-E shows its files. Cmd-Shift-[ and ] step through this window's buffers, and Cmd-1 to Cmd-9 go to a window by its place. Cmd-\\ splits to the side. Cmd-W closes the buffer. Cmd-Z undoes and Cmd-Shift-Z redoes. Ctrl-Cmd-Left/Right move this window to the pane beside it. M-x vscode-mode turns it on or off, and the choice lasts. In a Chrome tab the browser keeps Cmd-W, Cmd-T, Cmd-N, Cmd-1 to Cmd-9 and Ctrl-Tab. Turn on vscode-keyboard-lock, then M-x toggle-frame-fullscreen: in fullscreen these keys come to compos. Hold Esc, or run the command again, to leave fullscreen and give the keys back.")

(vscode--apply! vscode-mode)

(catalog-meta! 'command "vscode-mode" 'domain 'commands 'effects '(write))
(for-each (lambda (c) (catalog-meta! 'command c 'domain 'windows 'effects '(write display)))
          '("vscode-windows" "vscode-buffers" "vscode-chats"))
(catalog-meta! 'command "toggle-frame-fullscreen" 'domain 'commands 'effects '(write display))
(public! 'vscode--keys "vscode--keys — the ((KEYS COMMAND) ...) vscode-mode puts in force")
