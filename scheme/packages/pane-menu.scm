;;; pane-menu.scm — a home page for any pane
;;
;; M-x pane-menu shows a page in the pane you are in: what you can do with
;; the pane (the empty pane's actions), the layouts with a small preview of
;; each, a few next steps picked from what is going on, and the tutorial's
;; lessons. Every row is a click and most have a key; q goes back.

(require 'panes-mode)
(require 'emacs-names)

(domain! 'windows)
(effects! '(write display))

(define pane-home-buffer "*pane home*")
(define pane-card-buffer "*pane card*")

;; (KEY LABEL COMMAND)
(define pane-home--actions
  '(("b" "Switch buffer" "pane-switch-buffer")
    ("f" "Open a file" "find-file")
    ("t" "Go to todos" "todo")
    ("c" "New chat" "pane-home-new-chat")
    ("a" "Add a pane beside" "pane-add")
    ("r" "Bring back a hidden pane" "pane-restore")
    ("k" "Remove this pane" "pane-remove")))

;; (KEY NAME LABEL COMMAND SHARES CHAT-LAST?); SHARES are the column widths, () is free
(define pane-home--layouts
  '(("1" single "single" "window-layout-single" (1) #f)
    ("2" halves "halves" "window-layout-halves" (1 1) #f)
    ("3" two-pane "two-pane" "window-layout-two-pane" (2 1) #f)
    ("4" columns "columns" "window-layout-columns" (1 1 1) #f)
    ("5" two-chat "two-chat" "window-layout-two-chat" (5 5 3) #t)
    ("6" free "free" "window-layout-free" () #f)))

(define (pane-home--hidden-pane?)
  "#t when a pane is hidden and pane-restore can bring it back."
  (let ((l (panes-layout))) (and l (cadr (panes-restore-pane l)) #t)))

(define (pane-home--shown-actions)
  "The actions that can do something now: no restore without a hidden pane."
  (let ((n (pane-home--review-count)))
    (map (lambda (a)
           ;; the todos row counts the tasks that wait for your review
           (if (and (equal? (caddr a) "todo") (> n 0))
               (list (car a) (string-append (cadr a) " (" (number->string n) ")") (caddr a))
               a))
         (if (pane-home--hidden-pane?)
             pane-home--actions
             (filter (lambda (a) (not (equal? (caddr a) "pane-restore"))) pane-home--actions)))))

(define (pane-home--review-count)
  "The tasks of the group you are in that wait for your review: the ones
   the todo list opens on. 0 until the todo files are found: a page drawn
   when its buffer wakes must not walk the folders for a count."
  (if (not (and (boundp 'todo-ready?) (todo-ready?)))
      0
      (let ((g (frame-group)))
        (length (filter (lambda (t) (or (not g) (equal? (plist-get t 'group) g)))
                        (todo-list '(state "review")))))))

(define (pane-home--current-layout)
  (or (and (boundp 'panes-current-layout) (panes-current-layout)) 'free))

(define (pane-home--tutorial-lesson)
  "The lesson the reader is on, or the first."
  (let* ((ls (tutorial-lessons))
         (cur (and (boundp '*tutorial-current*) *tutorial-current*))
         (l (and cur (find (lambda (l) (equal? (plist-get l 'slug) cur)) ls))))
    (or l (and (pair? ls) (car ls)))))

(define (pane-home--inference-ready?)
  "#t when new chats have a model that can answer: one is chosen and its
   connector is ready."
  (and (or (not (boundp 'setup-chosen-connector)) (setup-chosen-connector))
       (or (not (boundp 'llm-connectors-state))
           (equal? (llm-connectors-state *default-connector*) "ready"))))

(define-command "pane-card-chat-new" "Start a new chat in this card's pane, even when a chat window is open elsewhere"
  (lambda ()
    ;; the usual placement joins a chat window elsewhere; the card's pane wins
    (let* ((l (panes--ensure-layout!))
           (pid (and l (panes--current-pane l)))
           (g (or (frame-group) (group-ensure! (current-buffer))))
           (id (and g (group-resolve-id g))))
      (if (not id)
          (message "No group for a chat")
          (let ((buf (group-chat-new-name id)) (record (group-record-by-id id)))
            (buffer-create buf)
            (group-chat-init! buf id)
            (when (boundp 'llm-default-bundle-apply!) (llm-default-bundle-apply! buf id))
            (chat-set-group! buf id)
            (unless (and record (group-record-primary-chat-id record))
              (group-record-update! id 'primary-chat-id (chat-stable-id! buf)))
            (when (boundp 'workspace-chat-inherit!) (workspace-chat-inherit! buf (group-name id)))
            ;; panes-display-in-pane! takes a chat window in another pane
            ;; first; the card's chat stays in the card's pane
            (if pid
                (let* ((l (panes--ensure-layout!))
                       (mode (panes--buffer-mode buf))
                       (same (find (lambda (k) (equal? (panes-window-mode l k) mode))
                                   (panes-pane-keys l pid)))
                       (placed (if same
                                   (list (panes-show (panes-drop-buffer l buf) same buf) same)
                                   (panes-add-window (panes-drop-buffer l buf) pid buf mode)))
                       (l (panes-set-focus (panes-raise (car placed) (cadr placed)) pid)))
                  (panes-apply! l)
                  (window-log-note! "pane card chat" buf "->" (cadr placed)))
                (switch-to-buffer-here! buf))
            (with-current-buffer buf (lambda () (end-of-buffer!)))
            buf))))
  'modes '(pane-card-mode))

(define-command "pane-home-new-chat" "Start a new chat, or set up a model first when none can answer"
  (lambda ()
    (run-command (cond ((not (pane-home--inference-ready?)) "setup-inference")
                       ((pane-card? (current-buffer)) "pane-card-chat-new")
                       ((and (equal? (current-buffer) panes-empty-buffer)
                             (member "pane-empty-chat-new" (command-names)))
                        "pane-empty-chat-new")
                       (else "chat-new")))))

(define (pane-home--next-steps)
  "At most four steps, each (KEY LABEL CLICK); with no model set up, setting
   one up comes first."
  (let* ((setup (if (pane-home--inference-ready?) '()
                    (list (list "S" "Set up a model so chats can answer" "cmd:setup-inference"))))
         (steps (append
                  setup
                  (list (list "p" "Find any command by what it does" "cmd:command-palette")
                        (list "g" "Start a group for a new task" "cmd:group-new")
                        (list "?" "Help about what is here" "cmd:contextual-help")))))
    (list-head steps (min 4 (length steps)))))

(define (pane-home--preview shares chat?)
  "A small drawing of a layout: one box for each column, as wide as its share.
   Columns draws as many columns as window-layout-columns gives it."
  (let ((shares (if (and (equal? shares '(1 1 1)) (not chat?) (boundp 'window-layout-columns)
                         (integer? window-layout-columns) (> window-layout-columns 0))
                    (make-list window-layout-columns 1)
                    shares)))
  (list 'tag "div" 'class (if (null? shares) "ph-preview ph-free" "ph-preview")
        'children
        (if (null? shares)
            (list (list 'tag "div" 'class "ph-col ph-plus" 'text "+"))
            (let loop ((s shares) (i 1) (out '()))
              (if (null? s) (reverse out)
                  (loop (cdr s) (+ i 1)
                        (cons (if (and chat? (null? (cdr s)))
                                  ;; the chat column is drawn as a chat: messages, yours on the right
                                  (list 'tag "div" 'class "ph-col ph-chat"
                                        'attrs (list (list "style" (string-append "flex:" (number->string (car s)))))
                                        'children (map (lambda (side) (list 'tag "div" 'class (string-append "ph-bubble " side) 'text ""))
                                                       '("l" "r" "l")))
                                  (list 'tag "div" 'class "ph-col"
                                        'attrs (list (list "style" (string-append "flex:" (number->string (car s)))))
                                        'text ""))
                              out))))))))

(define (pane-home--layout-card row current)
  (let ((key (list-ref row 0)) (name (list-ref row 1)) (label (list-ref row 2)) (cmd (list-ref row 3)))
    (list 'tag "div" 'class (if (eq? name current) "ph-layout ph-current" "ph-layout")
          'click (string-append "cmd:" cmd)
          'children (list (pane-home--preview (list-ref row 4) (list-ref row 5))
                          (list 'tag "div" 'class "ph-layout-label"
                                'children (list (list 'tag "span" 'class "ph-key" 'text key)
                                                (list 'tag "span" 'class "pc-quiet-label" 'text label)))))))

(define (pane-home--section title children)
  (list 'tag "div" 'class "ph-section"
        'children (cons (list 'tag "div" 'class "ph-heading" 'text title) children)))

(define (pane-home--blocks . empty?)
  "The page as blocks; for the empty pane (EMPTY? #t) it is titled so and has no foot."
  (let ((current (pane-home--current-layout)) (empty? (and (pair? empty?) (car empty?))))
    (list
      (list 'tag "div" 'class "ph"
            'children
            (list
              (list 'tag "div" 'class "ph-title" 'text (if empty? "Empty pane" "This pane"))
              (list 'tag "div" 'class "ph-sub" 'text "Pick what goes here, how the panes are laid out, or what to learn next.")
              (component 'ui/actions
                (list 'class "ph-actions"
                      'actions (map (lambda (a) (append (list (string-append "cmd:" (caddr a)) (cadr a) (car a))
                                                        (if (equal? (car a) "k") '("quiet") '())))
                                    (pane-home--shown-actions))))
              (pane-home--section "Layout"
                (list (list 'tag "div" 'class "ph-layouts"
                            'children (map (lambda (r) (pane-home--layout-card r current)) pane-home--layouts))))
              (pane-home--section "Next steps"
                (list (component 'ui/actions
                        (list 'class "ph-actions"
                              'actions (map (lambda (s) (list (caddr s) (cadr s) (car s))) (pane-home--next-steps))))))
              (list 'tag "div" 'class "ph-foot" 'text (if empty? "" "q goes back to what this pane showed")))))))

(define (pane-home--text)
  "The page as text, for a client that draws text."
  (let* ((line (lambda (k label) (string-append "   " (string-pad-right k 4) label "\n")))
         (rows (lambda (title items) (apply string-append (string-append "\n   " title "\n") items))))
    (string-append
      "\n   This pane\n"
      (rows "" (map (lambda (a) (line (car a) (cadr a))) (pane-home--shown-actions)))
      (rows "Layout" (map (lambda (r) (line (car r) (list-ref r 2))) pane-home--layouts))
      (rows "Next steps" (map (lambda (s) (line (car s) (cadr s))) (pane-home--next-steps)))
      "\n   q goes back\n")))

(define (pane-home--render!)
  (buffer-set-text! pane-home-buffer (pane-home--text) #t)
  (buffer-set-local! pane-home-buffer 'render-blocks (pane-home--blocks))
  (buffer-set-local! pane-home-buffer 'render-mode "blocks"))

(define (pane-home--open-lesson! slug)
  (let ((l (find (lambda (l) (equal? (plist-get l 'slug) slug)) (tutorial-lessons))))
    (when (and l (boundp 'tutorial--go!)) (tutorial--go! l))
    (tutorial-open!)))

(add-hook! (list 'block-click 'pane-home)
  (lambda (buf id)
    (and (or (member buf (list pane-home-buffer panes-empty-buffer)) (pane-card? buf))
         (cond ((string-prefix? "cmd:" id) (run-command (substring id 4 (string-length id))) #t)
               ((string-prefix? "lesson:" id) (pane-home--open-lesson! (substring id 7 (string-length id))) #t)
               (else #f)))))

(define-style! 'pane-home "
.ph { display: flex; flex-direction: column; gap: 6px; max-width: 560px;
  margin: 0 auto; padding: 8vh 24px 24px; }
.ph-title { font-size: 1.15em; font-weight: 600; color: var(--default-fg); }
.ph-sub { color: var(--dim-fg); font-size: 0.92em; margin-bottom: 10px; }
.ph-section { margin-top: 16px; display: flex; flex-direction: column; gap: 6px; }
.ph-heading { color: var(--dim-fg); font-size: 0.8em; letter-spacing: 0.06em; text-transform: uppercase; }
.ph-actions { display: flex; flex-wrap: wrap; gap: 4px; }
.ph-actions .c-action.quiet { opacity: 0.7; }
.ph-layouts { display: grid; grid-template-columns: repeat(auto-fill, minmax(110px, 1fr)); gap: 8px; }
.ph-layout { display: flex; flex-direction: column; gap: 6px; padding: 8px; cursor: pointer;
  border: 1px solid transparent; border-radius: 8px; }
.ph-layout:hover { border-color: var(--dim-fg); }
.ph-current { border-color: var(--default-fg); }
.ph-preview { display: flex; gap: 3px; height: 44px; padding: 3px;
  border: 1.5px solid var(--dim-fg); border-radius: 5px; opacity: 0.8; }
.ph-free { border-style: dashed; }
.ph-col { flex: 1; border-radius: 2px; background: var(--dim-fg); opacity: 0.35; }
.ph-chat { opacity: 0.7; }
.ph-plus { background: none; opacity: 1; color: var(--dim-fg); display: flex;
  align-items: center; justify-content: center; }
.ph-layout-label { display: flex; gap: 6px; font-size: 0.88em; color: var(--default-fg); }
.ph-key { font-family: var(--mono-font, monospace); font-weight: 600; color: var(--dim-fg); }
.ph-foot { margin-top: 18px; color: var(--dim-fg); font-size: 0.85em; }
")

(define-mode "pane-home-mode" (lambda () (pane-home--render!)))
(mode-doc! "pane-home-mode" "A home page for this pane. b moves a window here, f opens a file, t goes to the todos, c starts a chat, a adds a pane, r brings back a hidden one and k removes this one. 1 to 6 choose a layout, each drawn small. The next steps change with what waits for you: S sets up a model when none can answer (c does too), R reviews tasks, T goes on with the tutorial, p finds a command, g starts a group, ? helps. A lesson opens on a click, L lists them all, G draws the page again and q goes back.")

(define-command "pane-home-back" "Go back to what this pane showed before its home page"
  (lambda () (run-command "previous-buffer"))
  'modes '(pane-home-mode))

(define-command "pane-home-refresh" "Draw the home page again"
  (lambda () (pane-home--render!))
  'modes '(pane-home-mode))

(mode-keys! "pane-home-mode"
  (append (map (lambda (a) (list (car a) (caddr a))) pane-home--actions)
          (map (lambda (r) (list (car r) (list-ref r 3))) pane-home--layouts)
          '(("S" "setup-inference") ("R" "todo") ("T" "tutorial") ("p" "command-palette") ("g" "group-new")
            ("?" "contextual-help") ("L" "tutorial-index")
            ("G" "pane-home-refresh") ("q" "pane-home-back"))))

(define-command "pane-menu" "A home page for this pane: actions, layouts with previews, next steps and tutorials"
  (lambda ()
    (unless (and (buffer-exists? pane-home-buffer)
                 (equal? (buffer-local-value 'mode-name pane-home-buffer) "pane-home-mode"))
      (buffer-create pane-home-buffer)
      (with-current-buffer pane-home-buffer (lambda () (set-mode! "pane-home-mode"))))
    (pane-home--render!)
    (switch-to-buffer! pane-home-buffer)))

;; the empty pane's commands work in every pane, so M-x offers them everywhere
(for-each (lambda (c) (command-modes! c '()))
          '("pane-take-window" "pane-remove" "pane-restore"))

;; the empty pane offers restore only when a pane is hidden
(advice-add! 'panes--empty-keys 'around 'pane-home-hide-restore
  (lambda (next)
    (let ((rows (next)))
      (if (pane-home--hidden-pane?)
          rows
          (filter (lambda (r) (not (equal? (car r) "pane-restore"))) rows)))))

;; hiding or restoring a pane redraws the empty pane and the home page
(advice-add! 'panes-apply! 'after 'pane-home-redraw
  (lambda args
    ;; only a page whose content changed is drawn again: a redraw that
    ;; changes nothing still makes the page jump
    (when (and (buffer-exists? panes-empty-buffer)
               (not (equal? (pane-home--empty-blocks) (buffer-local-value 'render-blocks panes-empty-buffer))))
      (panes--empty-render!))
    (when (and (buffer-exists? pane-home-buffer)
               (not (equal? (pane-home--blocks) (buffer-local-value 'render-blocks pane-home-buffer))))
      (pane-home--render!))
    (let ((card (pane-home--empty-blocks "Pane")))
      (for-each (lambda (b)
                  (unless (equal? card (buffer-local-value 'render-blocks b)) (pane-card--render! b)))
                (pane-card--buffers)))))

;; the empty pane is the home page too: its layouts, next steps and lessons
(define (pane-home--key k)
  "A keycap: lower-case letters stay so (they are what you press), RET is a return arrow."
  (list 'tag "kbd" 'class "pc-cap" 'text (if (equal? k "RET") "↵" k)))

(define (pane-home--other-windows?)
  "#t when a window outside this pane could move into it."
  (let ((r (ignore-errors
             (lambda ()
               (let* ((l (panes-layout)) (pid (and l (panes--current-pane l))))
                 (and pid (pair? (filter (lambda (k) (not (equal? (panes-pane-of l k) pid))) (panes-window-keys l)))))))))
    (if (eq? r #f) #f #t)))

(define (pane-home--quest)
  "The one step that matters now, as (LABEL CLICK)."
  (let ()
    (cond ((not (pane-home--inference-ready?)) (list "Set up inference" "cmd:setup-inference"))
          ((let ((l (pane-home--tutorial-lesson))) (and l (not (tutorial-lesson-done? l))))
           (list "Tutorial" "cmd:tutorial"))
          (else (list "Command palette" "cmd:command-palette")))))

(define-command "pane-home-next" "Do the next step the pane card shows"
  (lambda ()
    (let ((click (cadr (pane-home--quest))))
      (run-command (substring click 4 (string-length click))))))

(define (pane-home--tile key label cmd)
  (list 'tag "div" 'class "pc-tile" 'click (string-append "cmd:" cmd)
        'children (list (pane-home--key key) (list 'tag "span" 'class "pc-label" 'text label))))

(define-command "pane-switch-buffer" "Switch buffer in this pane, the C-x b prompt opened on this group's tab"
  (lambda ()
    ;; the prompt reads the tab it opens on when it opens; C-x b keeps its own choice
    (let ((was switch-buffer-initial-tab))
      (set! switch-buffer-initial-tab 'group)
      (run-command "ibuffer-prompt")
      (set! switch-buffer-initial-tab was))))

(define (pane-home--empty-blocks . title)
  "The card: a question, the one next step as a big button, four big keys,
   the layouts drawn small, and a quiet line for the rest. TITLE heads it in
   place of the question (the pane card)."
  (let* ((current (pane-home--current-layout))
         (quest (pane-home--quest))
         (tiles (list (pane-home--tile "b" "Switch buffer" "pane-switch-buffer")
                      (pane-home--tile "f" "Find file" "find-file")
                      (pane-home--tile "c" "New chat" "pane-home-new-chat")
                      (pane-home--tile "t" "Todos" "todo")))
         (quiet (append (if (pane-home--hidden-pane?)
                            (list (list 'tag "div" 'class "pc-quiet-item" 'click "cmd:pane-restore"
                                        'children (list (pane-home--key "r") (list 'tag "span" 'class "pc-quiet-label" 'text "restore pane"))))
                            '())
                        ;; the card over a pane with windows offers to clear it
                        (if (pair? title)
                            (list (list 'tag "div" 'class "pc-quiet-item" 'click "cmd:pane-clear"
                                        'children (list (pane-home--key "x") (list 'tag "span" 'class "pc-quiet-label" 'text "clear pane"))))
                            '())
                        (list (list 'tag "div" 'class "pc-quiet-item" 'click "cmd:pane-remove"
                                    'children (list (pane-home--key "k") (list 'tag "span" 'class "pc-quiet-label" 'text "remove pane")))))))
    (list
      (list 'tag "div" 'class "pc"
            'children
            (list
              (list 'tag "div" 'class "pc-title" 'text (if (pair? title) (car title) "Empty pane"))
              (list 'tag "div" 'class "pc-quest" 'click (cadr quest)
                    'children (list (list 'tag "span" 'class "pc-quest-tag" 'text "Next")
                                    (list 'tag "span" 'class "pc-quest-label" 'text (car quest))
                                    (pane-home--key "RET")))
              (list 'tag "div" 'class "pc-tiles" 'children tiles)
              (list 'tag "div" 'class "pc-heading" 'text "Layout")
              (component 'panes/layouts (list 'current (symbol->string current)))
              ;; splitting comes right after the layouts: a layout is many splits at once
              (list 'tag "div" 'class "pc-quiet pc-split"
                    'children (map (lambda (s)
                                     (list 'tag "div" 'class "pc-quiet-item" 'click (string-append "cmd:" (caddr s))
                                           'children (list (pane-home--key (car s)) (list 'tag "span" 'class "pc-quiet-label" 'text (cadr s)))))
                                   '(("|" "split right" "split-window-right")
                                     ("-" "split below" "split-window-below")
                                     ("u" "unsplit" "unsplit"))))
              (list 'tag "div" 'class "pc-quiet" 'children quiet))))))

(define-style! 'pane-card "
.pc { display: flex; flex-direction: column; align-items: stretch; gap: 14px;
  width: min(440px, 100%); margin: 0 auto; padding: 14vh 20px 24px;
  font-family: var(--font-sans); }
.pc-title { font-size: 1.5em; font-weight: 600; color: var(--default-fg); text-align: center; margin-bottom: 4px; }
.pc-cap { display: inline-flex; align-items: center; justify-content: center;
  min-width: 1.9em; height: 1.9em; padding: 0 6px; box-sizing: border-box;
  font-family: var(--font-mono); font-weight: 700; font-size: 0.95em; line-height: 1;
  color: var(--default-fg); background: var(--hl-line-bg);
  border: 1px solid var(--border-bg); border-bottom-width: 3px; }
.pc-quest { display: flex; align-items: center; gap: 12px; padding: 14px 14px 14px 16px; cursor: pointer;
  background: var(--accent-fg); color: var(--window-bg);
  box-shadow: 4px 4px 0 var(--default-fg); }
.pc-quest:hover { filter: brightness(1.08); }
.pc-quest-tag { font-size: 0.72em; font-weight: 700; letter-spacing: .12em; text-transform: uppercase; opacity: .75; }
.pc-quest-label { flex: 1; font-size: 1.12em; font-weight: 600; }
.pc-quest .pc-cap { background: transparent; color: var(--window-bg); border-color: var(--window-bg); }
.pc-tiles { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; }
.pc-tile { display: flex; align-items: center; gap: 10px; padding: 10px 12px; cursor: pointer;
  border: 1px solid var(--border-bg); }
.pc-tile:hover { background: var(--hl-line-bg); border-color: var(--default-fg); }
.pc-label { font-size: 1em; color: var(--default-fg); }
.pc-heading { margin-top: 6px; font-size: 0.72em; font-weight: 700; letter-spacing: .12em;
  text-transform: uppercase; color: var(--dim-fg); }
.pc-layouts { display: grid; grid-template-columns: repeat(6, 1fr); gap: 8px; margin-top: -6px; }
.pc-layout { display: flex; flex-direction: column; align-items: center; gap: 6px; padding: 6px 4px; cursor: pointer;
  border: 1px solid transparent; }
.pc-layout:hover { border-color: var(--border-bg); background: var(--hl-line-bg); }
.pc-layout .ph-preview { width: 100%; height: 40px; padding: 3px; gap: 3px; border-width: 1.5px; border-radius: 0;
  box-sizing: border-box; }
.pc-layout .ph-col { border-radius: 0; }
.pc-layout .pc-cap { min-width: 1.6em; height: 1.6em; font-size: 0.8em; }
.pc-current { border-color: var(--accent-fg); }
.pc-current .ph-preview { border-color: var(--accent-fg); opacity: 1; }
.pc-current .ph-col { background: var(--accent-fg); }
.ph-col.ph-chat { background: none; opacity: 1; border: 1px solid var(--dim-fg);
  display: flex; flex-direction: column; justify-content: flex-end; gap: 2px; padding: 2px; box-sizing: border-box; }
.ph-bubble { height: 4px; width: 70%; background: var(--dim-fg); opacity: .6; }
.ph-bubble.r { align-self: flex-end; background: var(--accent-fg); opacity: 1; }
.pc-current .ph-col.ph-chat { background: none; border-color: var(--accent-fg); }
.pc-quiet { display: flex; justify-content: center; gap: 18px; margin-top: 10px; color: var(--dim-fg); font-size: 0.85em; }
.pc-quiet-item { display: inline-flex; align-items: center; gap: 6px; cursor: pointer; }
.pc-quiet-item .pc-cap { min-width: 1.7em; height: 1.7em; font-size: 0.85em; color: var(--default-fg);
  background: var(--hl-line-bg); border-color: var(--dim-fg); }
.pc-quiet-item:hover { color: var(--default-fg); }
")

(advice-add! 'panes--empty-blocks 'around 'pane-home-empty-page
  (lambda (next) (pane-home--empty-blocks)))

(define-style! 'pane-home-compact "
.ph-compact { align-items: center; text-align: center; padding-top: 16vh; gap: 10px; max-width: 420px; }
.ph-compact .ph-actions { justify-content: center; }
.ph-mini { grid-template-columns: repeat(6, 44px); gap: 6px; justify-content: center; margin-top: 6px; }
.ph-mini .ph-layout { padding: 3px; gap: 3px; }
.ph-mini .ph-preview { height: 22px; padding: 2px; gap: 2px; border-width: 1px; border-radius: 3px; }
.ph-mini .ph-layout-label span:not(.ph-key) { display: none; }
.ph-mini .ph-layout-label { justify-content: center; font-size: 0.75em; }
.ph-next { margin-top: 6px; opacity: 0.85; }
")

(mode-keys! "pane-empty-mode"
  (append (map (lambda (r) (list (car r) (list-ref r 3))) pane-home--layouts)
          '(("RET" "pane-home-next") ("|" "split-window-right") ("-" "split-window-below") ("u" "unsplit") ("b" "pane-switch-buffer") ("a" "pane-add") ("c" "pane-home-new-chat") ("S" "setup-inference") ("R" "todo") ("T" "tutorial")
            ("p" "command-palette") ("g" "group-new") ("?" "contextual-help") ("L" "tutorial-index"))))

;;; the pane card: the empty pane's card, called up over any pane

(define (pane-card? buf)
  (and (buffer-exists? buf) (equal? (buffer-local-value 'mode-name buf) "pane-card-mode")))

(define (pane-card--buffers)
  "Every pane's card: each pane has its own, so a card shows in the pane it was called from."
  (filter pane-card? (buffer-list)))

(define (pane-card--render! buf)
  (buffer-set-text! buf (pane-home--text) #t)
  (buffer-set-local! buf 'render-blocks (pane-home--empty-blocks "Pane"))
  (buffer-set-local! buf 'render-mode "blocks"))

(define-mode "pane-card-mode" (lambda () (pane-card--render! (current-buffer))))
(mode-doc! "pane-card-mode" "The empty pane's card over this pane: its actions, the layouts drawn small and the one next step that matters. The keys are the empty pane's; q goes back to what the pane showed.")

(define-command "pane-card-back" "Close the card: the pane shows what it showed before"
  (lambda ()
    ;; the card goes for good, so the pane never keeps an old one behind
    (let ((card (current-buffer)))
      (run-command "previous-buffer")
      (buffer-kill! card)))
  'modes '(pane-card-mode))

(mode-keys! "pane-card-mode"
  (append (keymap-bindings (mode-keymap "pane-empty-mode"))
          '(("q" "pane-card-back") ("x" "pane-clear"))))

(define-command "pane-card" "Bring up the empty pane's card over this pane: actions, layouts and the next step"
  (lambda ()
    ;; one card for each pane: a buffer shows in one window only, so a shared
    ;; card would pull the focus to the pane that already shows it
    (let* ((l (panes--ensure-layout!))
           (pid (and l (panes--current-pane l)))
           (buf (if pid (string-append "*pane card " pid "*") pane-card-buffer))
           (shown (get-visible-buffers)))
      ;; one card at most for each pane: a card off screen is a leftover
      (for-each (lambda (c) (unless (or (equal? c buf) (member c shown)) (buffer-kill! c)))
                (pane-card--buffers))
      (unless (pane-card? buf)
        (buffer-create buf)
        (with-current-buffer buf (lambda () (set-mode! "pane-card-mode"))))
      (pane-card--render! buf)
      (switch-to-buffer-here! buf))))

;;; pane-clear: the pane empties, its windows wait behind the pane beside it

(define (pane-clear--neighbour l pid)
  "The pane beside PID that takes its windows: the one before it, else the one after."
  (let* ((ids (panes-pane-ids l))
         (rest (let loop ((xs ids) (prev #f))
                 (cond ((null? xs) #f)
                       ((equal? (car xs) pid) (or prev (and (pair? (cdr xs)) (cadr xs))))
                       (else (loop (cdr xs) (car xs)))))))
    rest))

(define-command "pane-clear" "Empty this pane: its windows wait behind the pane beside it, and Take window (b) brings one back"
  (lambda ()
    ;; called from the card, the card leaves first so it does not travel with the windows
    (when (pane-card? (current-buffer)) (run-command "previous-buffer"))
    (let* ((l (panes--ensure-layout!))
           (pid (panes--current-pane l))
           (keys (if pid (panes-pane-keys l pid) '()))
           (to (and pid (pane-clear--neighbour l pid))))
      (cond ((not pid) (message "Not in a pane"))
            ((null? keys) (message "This pane is empty already"))
            ((not to) (message "No pane beside this one to take its windows"))
            (else
              (let* ((front (panes-handle l (car keys)))
                     (l (if (and front (window-exists? front)) (panes--park-points! l (list front)) l))
                     (moved (fold (lambda (l k) (panes-move-window l k to (length (panes-pane-keys l to)))) l keys)))
                (panes-apply! (panes-set-focus moved pid))
                (message (string-append (number->string (length keys))
                                        (if (= (length keys) 1) " window waits" " windows wait")
                                        " behind the pane beside; b switches one back here"))))))))
