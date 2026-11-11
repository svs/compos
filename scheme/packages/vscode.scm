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

;; a modal with its own drawing on top (Cmd-J, Cmd-L) is a small dialog,
;; not the wide palette: it is narrower and lower, and the drawing says
;; what the facts pane on the right would
(define-style! 'vscode-modals "
.mb-panel.palette:has(.mb-html) {
  width: fit-content;
  min-width: calc(420px / var(--ui-zoom, 1));
  max-width: min(calc(720px / var(--ui-zoom, 1)), calc(88vw / var(--ui-zoom, 1)));
  height: calc(52dvh / var(--ui-zoom, 1));
}
.mb-panel.palette:has(.mb-html) .mb-preview { display: none; }
.mb-panel.palette:has(.mb-html) .mb-head-legend { display: none; }
.mb-panel.palette:has(.mb-html) .mb-cand { column-gap: 12px; }
.vl-tabs { display: flex; flex-wrap: wrap; gap: 6px; }
.vl-tab { display: flex; flex-direction: column; gap: 4px; padding: 6px 10px; min-width: 0;
  border: 1px solid var(--border-bg); }
.vl-on { border-color: var(--accent-fg); background: var(--hl-line-bg); }
.vl-top { display: flex; align-items: center; gap: 6px; }
.vl-name { font-size: .75em; letter-spacing: .08em; text-transform: uppercase; color: var(--dim-fg); }
.vl-on .vl-name { color: var(--default-fg); }
.vl-value { font-size: .85em; color: var(--default-fg); max-width: 260px; overflow-wrap: anywhere; }
")

(define-command "vscode-windows" "Choose a layout, each one shows as you move to it; or a window of this group"
  (lambda ()
    (let* ((before (panes--ensure-layout!))
           (me (panes-key-of-handle before (active-window)))
           (pids '())
           (wins (map (lambda (k)
                        (let* ((w (panes-window before k))
                               (pid (panes-pane-of before k))
                               (b (panes-window-buffer before k))
                               (n (length (or (plist-get w 'buffers) '()))))
                          (unless (member pid pids) (set! pids (append pids (list pid))))
                          (list (window-name k) k
                                (string-append
                                 (cond ((equal? k me) "●") ((window-exists? k) "■") (else "□"))
                                 " pane " (number->string (length (member pid (reverse pids))))
                                 "  " (if b (vscode--short b) "empty")
                                 "  " (number->string n) (if (= n 1) " buffer" " buffers")))))
                      (panes-window-keys before)))
           (lays (map (lambda (t) (list (string-append "Layout: " (symbol->string (cadr t)))
                                        (cadr t)
                                        (or (plist-get (panes-layout-spec (cadr t)) 'doc) "")))
                      panes-layout-tiles))
           (tiles (blocks->html
                   (component 'panes/layouts
                              (list 'current (symbol->string (or (panes-current-layout) 'free))
                                    'click-prefix "Layout: " 'key-prefix "M-"))))
           (cands (append (list (list "Layouts" "" "separator"))
                          (map (lambda (r) (list (car r) (nth 2 r))) lays)
                          (list (list "Windows" "● here  ■ on screen  □ behind" "separator"))
                          (map (lambda (r) (list (car r) (nth 2 r))) wins))))
      (minibuffer-read-preview "Window or layout: "
        cands
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
        (map (lambda (t) (list (car t) (string-append "Layout: " (symbol->string (cadr t)))))
             panes-layout-tiles)
        #f tiles)
      ;; left and right walk the layouts, each shown as you land on it;
      ;; on a window row they stay the cursor keys
      (set! *mb-tab-fn*
            (lambda (step)
              (let* ((labels (map car lays))
                     (sel (minibuffer-selected))
                     (i (let loop ((ls labels) (n 0))
                          (cond ((null? ls) #f) ((equal? (car ls) sel) n) (else (loop (cdr ls) (+ n 1)))))))
                (and i
                     (let ((j (modulo (+ i step) (length labels))))
                       (prompt--do 'move (- j i))
                       (mb-select-notify!)
                       #t))))))))

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

;; Cmd-L: the LLM of this chat. Its setup is drawn on top; the rows below
;; change one thing at once (the model, the effort, a saved preset, the
;; connector) and the change applies at once. Typing narrows, so opus
;; finds the model. The full setup and the chats are the last rows.

(define (vscode--plist-set pl key value)
  (cond ((null? pl) (list key value))
        ((eq? (car pl) key) (cons key (cons value (cddr pl))))
        (else (cons (car pl) (cons (cadr pl) (vscode--plist-set (cddr pl) key value))))))

(define (vscode--llm-apply! chat box what)
  (llm-bundle-apply! chat box)
  (llm-config-remember! box)
  (llm-config-changed! chat)
  (message (string-append chat " now runs " what)))

(define vscode--llm-sections
  ;; (KEY TAB-LABEL); on an empty input the key goes to that tab
  '(("b" "b backend") ("m" "m model") ("e" "e effort") ("p" "p tools")
    ("s" "s saved") ("o" "o other")))

;; the rows that are on (hint starting with the filled dot) before the rest,
;; each part keeping its order, a separator between the two
(define (vscode--on-first rows . more)
  (let* ((all (apply append rows more))
         (on? (lambda (r) (and (> (string-length (cadr r)) 0) (equal? (substring (cadr r) 0 1) "●")))))
    (let ((on (filter on? all)) (off (filter (lambda (r) (not (on? r))) all)))
      (if (or (null? on) (null? off))
          all
          (append on (list (list "off" "" "separator")) off)))))

(define (vscode--llm-rows chat key)
  (let* ((now (llm-config-combination chat))
         (connector (plist-get now 'connector))
         (model (plist-get now 'model))
         (effort (plist-get now 'effort))
         (tools (or (plist-get now 'presets) '()))
         (preset (llm-config-preset-name chat))
         (mark (lambda (on? hint) (if on? (string-append "● in use  " hint) hint))))
    (cond
     ((equal? key "b")
      (map (lambda (n) (list n (mark (equal? n connector) (llm-connectors-state n)))) (connector-names)))
     ((equal? key "m")
      (map (lambda (m) (list (car m) (mark (equal? (car m) model) (cadr m))))
           (chat-model-options chat connector)))
     ((equal? key "e")
      (map (lambda (e) (list e (mark (equal? e effort) (if (equal? e "default") "the model decides" "reasoning effort"))))
           (cons "default" (car (chat-model-effort-info chat connector model)))))
     ((equal? key "p")
      (vscode--on-first
       (map (lambda (e) (list (symbol->string (car e))
                              (string-append (if (member (car e) tools) "● on   " "○ off  ")
                                             (or (plist-get (cadr e) 'description) ""))))
            *chat-presets*)
       (map (lambda (srv) (list (symbol->string (car srv))
                                (string-append (if (member (car srv) tools) "● on   " "○ off  ") "MCP server")))
            (filter (lambda (srv) (not (assq (car srv) *chat-presets*))) *mcp-registry*))))
     ((equal? key "s")
      (let ((g (group-resolve-id (or (buffer-group chat) (frame-group)))))
        (append
         (list (list "Save as a new preset" "name this setup and keep it"))
         (if preset
             (list (list (string-append "Update preset " preset) "write this setup into it"))
             '())
         (if g
             (list (list "Default for this group" (string-append "new chats in " (group-name g) " start with this setup")))
             '())
         (list (list "Default for every group" "new chats start with this setup where the group has none")
               (list "presets" "" "separator"))
         (map (lambda (b) (list (llm-bundle-name b) (mark (equal? (llm-bundle-name b) preset) (or (llm-bundle-label b) ""))))
              *llm-bundles*))))
     (else
      (list (list "Full setup" "every field, saving and defaults (C-c b)")
            (list "Connectors" "set up, sign in and test each connector")
            (list "Switch chat" "go to another chat")
            (list "New chat" "start a chat in this group"))))))

(define (vscode--llm-head chat section)
  (let* ((now (llm-config-combination chat))
         (tools (let ((on (or (plist-get now 'presets) '())))
                  (if (null? on) "none" (string-join (map symbol->string on) ", "))))
         (values (list (list "b" (plist-get now 'connector))
                       (list "m" (plist-get now 'model))
                       (list "e" (plist-get now 'effort))
                       (list "p" tools)
                       (list "s" (string-append (or (llm-config-preset-name chat) "own setup") " · save, default"))
                       (list "o" "setup, chats"))))
    (blocks->html
     (list 'tag "div" 'class "vl-tabs"
           'children
           (map (lambda (s)
                  (let ((key (car s)))
                    (list 'tag "div" 'class (if (equal? key section) "vl-tab vl-on" "vl-tab")
                          'children
                          (list (list 'tag "div" 'class "vl-top"
                                      'children (list (list 'tag "c-action-key" 'class "transient-legend-key" 'text (key-symbol (string-append "M-" key)))
                                                      (list 'tag "span" 'class "vl-name"
                                                            'text (substring (cadr s) 2 (string-length (cadr s))))))
                                (list 'tag "div" 'class "vl-value" 'text (cadr (assoc key values)))))))
                vscode--llm-sections)))))

;; Cmd-L: the LLM of this chat, one thing at a time. The setup is drawn on
;; top; M-b M-m M-e M-p M-s M-o, or Left and Right, choose what the
;; rows set: the backend, the model, the effort, the tools, a saved setup,
;; or the other actions. RET applies at once. Tools toggle and stay open.
(define (vscode--llm-open! chat key)
  (let* ((section key)
         (now (llm-config-combination chat))
         (tabs (lambda () (map (lambda (s) (list (cadr s) (equal? (car s) section))) vscode--llm-sections)))
         ;; another tab opens the dialog again: its drawing on top marks the tab
         (show! (lambda (k)
                  (set! *mb-tab-fn* #f)
                  (set! *mb-shortcuts* '())
                  (minibuffer-detach!)
                  (vscode--llm-open! chat k)))
         (done! (lambda () (set! *mb-tab-fn* #f) (set! *mb-shortcuts* '())))
         (apply! (lambda (box what)
                   (llm-bundle-apply! chat box)
                   (llm-config-remember! box)
                   (llm-config-changed! chat)
                   (message (string-append chat " now runs " what)))))
    (minibuffer-read* "LLM: " (vscode--llm-rows chat section)
      (list (list 'style "modal")
            (list 'html (vscode--llm-head chat section))
            (list 'cancel done!)
            (list 'confirm
                  (lambda (v)
                    (done!)
                    (cond
                     ((equal? v "") #f)
                     ((equal? section "b")
                      (apply! (vscode--plist-set (vscode--plist-set (vscode--plist-set now 'connector v) 'model "default") 'effort "default") v))
                     ((equal? section "m")
                      (apply! (vscode--plist-set (vscode--plist-set now 'model v) 'effort "default") v))
                     ((equal? section "e")
                      (apply! (vscode--plist-set now 'effort v) (string-append (plist-get now 'model) " at " v " effort")))
                     ((equal? section "p")
                      (let* ((name (string->symbol v))
                             (on (or (plist-get now 'presets) '())))
                        (if (eq? name 'compos)
                            (message "The compos tools are the editor bridge: they stay on")
                            (apply! (vscode--plist-set now 'presets
                                                       (if (memq name on)
                                                           (filter (lambda (x) (not (eq? x name))) on)
                                                           (cons name on)))
                                    (string-append "with " v (if (memq name on) " off" " on"))))
                        (vscode--llm-open! chat "p")))
                     ((equal? section "s")
                      (let* ((setup (llm-config-combination chat))
                             (preset (llm-config-preset-name chat))
                             (g (group-resolve-id (or (buffer-group chat) (frame-group))))
                             (save! (lambda (name)
                                      (llm-bundle-save! name setup)
                                      (buffer-set-local! chat 'llm-preset name)
                                      (llm-config-changed! chat)
                                      (message (string-append "saved this setup as preset " name)))))
                        (cond
                         ((equal? v "Save as a new preset")
                          (minibuffer-read "Preset name: " (map llm-bundle-name *llm-bundles*)
                            (lambda (name)
                              (let ((n (string-trim name)))
                                (unless (equal? n "") (save! n))))))
                         ((and preset (equal? v (string-append "Update preset " preset)))
                          (save! preset))
                         ((equal? v "Default for this group")
                          (group-llm! setup g)
                          (message (string-append (group-name g) ": new chats start with this setup")))
                         ((equal? v "Default for every group")
                          (llm-default-save! setup)
                          (message "new chats start with this setup where the group has no default"))
                         ((llm-bundle-named v)
                          => (lambda (b)
                               (llm-bundle-apply! chat b)
                               (buffer-set-local! chat 'llm-preset v)
                               (llm-config-changed! chat)
                               (message (string-append chat " now runs " v)))))))
                     ((equal? v "Full setup") (with-current-buffer chat (lambda () (run-command "llm-configure"))))
                     ((equal? v "Connectors") (run-command "llm-connectors"))
                     ((equal? v "Switch chat") (run-command "vscode-chats"))
                     ((equal? v "New chat") (run-command "chat-new")))))))
    ;; Meta and the tab's letter choose the tab; plain letters type
    (set! *mb-shortcuts* (map (lambda (s) (list (car s) (lambda () (show! (car s))))) vscode--llm-sections))
    (set! *mb-tab-fn*
          (lambda (step)
            (let* ((keys (map car vscode--llm-sections))
                   (i (let loop ((ks keys) (n 0)) (cond ((null? ks) 0) ((equal? (car ks) section) n) (else (loop (cdr ks) (+ n 1)))))))
              (show! (list-ref keys (modulo (+ i step) (length keys))))
              #t)))))

(define-command "vscode-llm" "Change this chat's backend, model, effort, tools or saved setup"
  (lambda ()
    (vscode--llm-open! (llm-config-session (or (window-buffer (active-window)) (current-buffer))) "m")))

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
    ("s-l" "vscode-llm")
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
  "The VSCode keys, in every buffer. Cmd-K, Cmd-Shift-P or F1 opens the command palette, with Start here first. Cmd-P shows this pane's card. Cmd-J chooses a layout, or a window. Cmd-B chooses a buffer of this group, then a file of its project. Cmd-L changes this chat's model, effort, preset or connector. Cmd-O opens a file, Cmd-Shift-F searches the project and Cmd-Shift-E shows its files. Cmd-Shift-[ and ] step through this window's buffers, and Cmd-1 to Cmd-9 go to a window by its place. Cmd-\\ splits to the side. Cmd-W closes the buffer. Cmd-Z undoes and Cmd-Shift-Z redoes. Ctrl-Cmd-Left/Right move this window to the pane beside it. M-x vscode-mode turns it on or off, and the choice lasts. In a Chrome tab the browser keeps Cmd-W, Cmd-T, Cmd-N, Cmd-1 to Cmd-9 and Ctrl-Tab. Turn on vscode-keyboard-lock, then M-x toggle-frame-fullscreen: in fullscreen these keys come to compos. Hold Esc, or run the command again, to leave fullscreen and give the keys back.")

(vscode--apply! vscode-mode)

(catalog-meta! 'command "vscode-mode" 'domain 'commands 'effects '(write))
(for-each (lambda (c) (catalog-meta! 'command c 'domain 'windows 'effects '(write display)))
          '("vscode-windows" "vscode-buffers" "vscode-chats" "vscode-llm"))
(catalog-meta! 'command "toggle-frame-fullscreen" 'domain 'commands 'effects '(write display))
(public! 'vscode--keys "vscode--keys — the ((KEYS COMMAND) ...) vscode-mode puts in force")
