;;; palette.scm --- s-p, the command palette
;;;
;;; The palette answers "how do I do this?" where M-x answers "what is
;;; the command called?". It searches commands by the words typed, their
;;; names, docs and the everyday words people use for them, and puts first
;;; the past asks that match. Words no row is named for go to a model that
;;; picks the command, and the same words run it at once next time. Words
;;; no command does go to the chat of the buffer you were in.

(domain! 'interaction)
(effects! '(write execute))

;;; Cmd-p answers "how do I do this?" while M-x answers "what is the
;;; command called?". Apropos supplies task-language matches from command
;;; docs and aliases; the palette projects that broad catalog down to things
;;; a reader can act on here.
;; A plain sentence can bind a key: "bind C-x C-g k to group-kill". The
;; palette recognizes it, offers it first, and runs it on RET.
(define (command-palette--bind-parse query)
  (let* ((q (string-trim (or query "")))
         (words (remove (lambda (w) (equal? w "")) (string-split q " "))))
    (and (>= (length words) 4)
         (equal? (string-downcase (car words)) "bind")
         (let loop ((ws (cdr words)) (keys '()))
           (cond
             ((null? ws) #f)
             ((equal? (string-downcase (car ws)) "to")
              (and (not (null? keys))
                   (pair? (cdr ws))
                   (null? (cddr ws))
                   (let ((command (cadr ws))
                         (seq (string-join (reverse keys) " ")))
                     (and (not (equal? seq ""))
                          (command-fn command)
                          (list seq command)))))
             (else (loop (cdr ws) (cons (car ws) keys))))))))

(define (command-palette--bind-hit query)
  (let ((parsed (command-palette--bind-parse query)))
    (and parsed
         (list 'kind "intent"
               'name (string-append "bind " (car parsed) " to " (cadr parsed))
               'keys (car parsed)
               'command (cadr parsed)))))

(define (command-palette--candidate hit)
  (let ((kind (plist-get hit 'kind))
        (name (or (plist-get hit 'name) (plist-get hit 'task))))
    (cond
      ((equal? kind "command")
       ;; the key leads in its own column, as in the resting list, so the
       ;; eye finds it before the doc
       (let ((key (or (plist-get hit 'key) (key-for-command name) "")))
         (list name
               (string-append (string-pad-right (key-symbols key) 12) " "
                              (or (plist-get hit 'doc) "")))))
      ((equal? kind "intent")
       (list name
             (string-append "bind  " (plist-get hit 'keys)
                            " → " (plist-get hit 'command)
                            "  everywhere")))
      (else #f))))

;; A command the palette can draw: name, key and doc, in apropos hit shape.
(define (command-palette--command-hit name)
  (list 'kind "command" 'name name 'doc (command-doc name)
        'key (let ((k (key-for-command name))) (if (equal? k "") #f k))))

;; A mode's commands are for its buffers (command-applicable?): the palette
;; leaves out the ones whose modes are not on in BUF, the buffer you are in.
(define (command-palette--for-user hits buf)
  (let ((out (commands-out-of-scope buf)))
    (filter (lambda (h) (not (and (equal? (plist-get h 'kind) "command")
                                  (member (plist-get h 'name) out))))
            hits)))

;; The palette draws the commands apropos finds, in its order,
;; with the ones whose name holds every word first. Its semantic pass can
;; take a second, so the refresh runs it in a task after a pause in typing.
(define (command-palette--search query)
  (let* ((words (apropos-query-words query))
         (hits (filter (lambda (h) (equal? (plist-get h 'kind) "command"))
                       (command-palette--for-user (apropos query 'kind "command")
                                                  (command-palette--origin))))
         (named? (lambda (h) (apropos-text-hit? (plist-get h 'name) words)))
         ;; "undo" is undo and "split window right" is split-window-right:
         ;; the command the words name leads, before any that merely share one
         (exact (let ((n (string-join (filter (lambda (w) (not (equal? w "")))
                                              (string-split (string-downcase (string-trim query)) " "))
                                      "-")))
                  (and (command-fn n)
                       (command-applicable? n (command-palette--origin))
                       n)))
         (exact? (lambda (h) (and exact (equal? (plist-get h 'name) exact))))
         ;; then the everyday commands and the ones you ran before: save-buffer
         ;; before llm-config-save-bundle
         (ran (history-items 'M-x))
         (common? (lambda (h) (and (equal? (plist-get h 'kind) "command")
                                   (or (command-palette--everyday? (plist-get h 'name))
                                       (member (plist-get h 'name) ran)))))
         (q (string-downcase (string-trim query)))
         ;; "save" is the word of save-buffer and write-file: they lead
         (says? (lambda (h) (let ((row (assoc (plist-get h 'name) command-palette-everyday)))
                              (and row (string-contains? (cadr row) q)))))
         ;; a common command leads only when its name has the words: customize
         ;; mentions saving in its doc, and that is no reason to rank it first
         (first? (lambda (h) (or (exact? h) (says? h) (and (common? h) (named? h)))))
         (rest (filter (lambda (h) (not (first? h))) hits)))
    (append
      (let ((bind (command-palette--bind-hit query)))
        (if bind (list bind) '()))
      (if exact (list (command-palette--command-hit exact)) '())
      (filter (lambda (h) (and (says? h) (not (exact? h)))) hits)
      (filter (lambda (h) (and (common? h) (named? h) (not (exact? h)) (not (says? h)))) hits)
      ;; among the rest, a command with a key is a main one: window-layout
      ;; (C-x l) before layout-backward for "layout"
      (let* ((keyed? (lambda (h) (and (equal? (plist-get h 'kind) "command")
                                      (not (equal? (key-for-command (plist-get h 'name) (command-palette--origin)) "")))))
             (named (filter named? rest)))
        (append (filter keyed? named) (filter (lambda (h) (not (keyed? h))) named)))
      (filter (lambda (h) (not (named? h))) rest))))

;; The palette prints keys as the keyboard does, ⌃X ⌃S and ⇧⌘P, where M-x
;; keeps the Emacs spelling: the resting rows come from M-x's table, so their
;; key column is drawn again here. 811 rows cost 4 ms.
(define (command-palette--symbol-row row)
  (let ((k (key-for-command (car row))))
    (if (or (equal? k "") (> (string-length k) 12) (not (pair? (cdr row)))
            (not (string? (cadr row))) (not (string-prefix? k (cadr row))))
        row
        (cons (car row)
              (cons (string-append (string-pad-right (key-symbols k) 12)
                                   (substring (cadr row) (min 12 (string-length (cadr row))) (string-length (cadr row))))
                    (cddr row))))))

(define (command-palette-candidates query)
  (if (equal? (string-trim query) "")
      ;; The resting palette is familiar and cheap: what you ran or asked,
      ;; newest first, then the rest of the M-x command table. The search
      ;; takes over as soon as the user states intent.
      (let* ((hist (history-items 'M-x))
             (asks (take (filter (lambda (h) (not (command-fn h))) hist)
                         *command-palette-past-max*))
             (rows (map command-palette--symbol-row (command-rows)))
             (recent (filter (lambda (h) (or (command-fn h) (member h asks))) hist))
             (top (filter (lambda (r) r)
                          (map (lambda (h)
                                 (if (command-fn h) (assoc h rows) (list h "past  ask")))
                               recent))))
        (append top (filter (lambda (r) (not (member (car r) recent))) rows)))
      (let ((lead (command-palette--past query)))
        (command-palette--with-ask query
          (append lead
                  (filter (lambda (candidate)
                            (and candidate (not (assoc (car candidate) lead))))
                          (map command-palette--candidate (command-palette--search query))))))))

;; What you picked or asked here before, newest first: the entries of the
;; shared M-x history that hold every word typed.
(define *command-palette-past-max* 5)

(define (command-palette--past query)
  (let* ((words (filter (lambda (w) (not (equal? w "")))
                        (string-split (string-downcase (string-trim query)) " ")))
         (hits (filter (lambda (h)
                         (let ((l (string-downcase h)))
                           (null? (filter (lambda (w) (not (string-contains? l w))) words))))
                       (history-items 'M-x))))
    ;; a command you ran before is ranked with the rest, ahead of the rare
    ;; ones (command-palette--search): leading here, llm-config-save-bundle
    ;; once run beat save-buffer for "save". What you asked in words leads.
    (map (lambda (h) (list h "past  ask"))
         (take (filter (lambda (h) (not (command-fn h))) hits) *command-palette-past-max*))))

(define *command-palette-debounce-ms* 250)

(define (command-palette--refresh input)
  ;; A timer can outlive the prompt that scheduled it. Never put Cmd-p's
  ;; results into a later prompt, and never let an old query replace a newer
  ;; one after the user has kept typing. Apropos takes hundreds of ms, so it
  ;; runs in a task and the prompt is checked again when it answers.
  (let ((current? (lambda ()
                    (let ((state (minibuffer-state)))
                      (and state
                           (equal? (plist-get state 'prompt) "Command: ")
                           (equal? (plist-get state 'input) input))))))
    (when (current?)
      (task-run! (lambda () (command-palette-candidates input))
                 (lambda (ok? rows)
                   (when (and ok? (current?))
                     (minibuffer-set-candidates! rows)))))))

(define (command-palette--run choice)
  (let ((bind (command-palette--bind-parse choice)))
    (cond
      ((command-fn choice)
       (history-push! 'M-x choice)
       (run-command choice))
      ((and bind (boundp (quote keys-bind-intent)))
       (keys-bind-intent (car bind) (cadr bind)))
      ((equal? (string-trim choice) "") #f)
      ((command-palette--learned choice)
       (command-palette--run-learned (command-palette--learned choice)))
      (else (command-palette--pick! choice)))))

;; Words no row is named for: a model picks the command that does them, and
;; the same words run it at once next time. When none does, the words go to
;; a chat.
(define (command-palette--pick! text)
  ;; the answer comes seconds later, when the frame's current buffer can be
  ;; the prompt's own: it runs in the buffer you were in when you asked
  (let ((origin (command-palette--origin)))
    (set! *command-palette--request* text)
    (message (string-append "Finding the command for: " text))
    (command-palette-resolve text origin
      (lambda (r)
        (with-frame-windows
          (lambda ()
            (with-current-buffer origin
              (lambda ()
                (if r
                    (command-palette--apply! text r)
                    (command-palette-ask-chat! text))))))))))

;; the buffer the palette was opened from: its rows are that buffer's
;; commands, and what you pick runs there
(define *command-palette--from* #f)

;; the buffer you were in: the current one, unless that is a prompt's input
(define (command-palette--origin)
  (let ((b (if (and *command-palette--from* (buffer-known? *command-palette--from*))
               *command-palette--from*
               (current-buffer))))
    (if (minibuffer-buffer? b)
        (or (find (lambda (v) (not (minibuffer-buffer? v))) (get-visible-buffers)) b)
        b)))

;; What could do TEXT in BUF: the commands for BUF that apropos finds with its
;; semantic pass. Slow: run it in a task.
(define (command-palette--candidates-for text buf)
  (let* ((out (commands-out-of-scope buf))
         (cmds (filter (lambda (h) (and (not (string-contains? (plist-get h 'name) "--"))
                                        (not (member (plist-get h 'name) out))))
                       (apropos text 'semantic #t 'kind "command"))))
    (map (lambda (h) (list 'kind "command" 'name (plist-get h 'name) 'doc (or (plist-get h 'doc) "")))
         (take cmds (min command-palette-candidate-count (length cmds))))))

(define (command-palette--candidate-line c)
  (string-append "- " (plist-get c 'name)
    (if (equal? (plist-get c 'doc) "") "" (string-append ": " (plist-get c 'doc)))))

(define (command-palette--pick-prompt text cands)
  (string-append
    "Someone typed a request into the command palette of an editor. It may have typos. "
    "Pick the command below that does it. Answer with JSON only:\n"
    "{\"name\": \"NAME\"}\n"
    "{\"name\": null} - none of them does it\n\n"
    (string-join (map command-palette--candidate-line cands) "\n")
    "\n\nRequest: " text))

;; ("command" NAME ()) from a model's JSON reply, when NAME is a candidate
(define (command-palette--parse-pick reply cands)
  (let* ((from (string-index reply "{"))
         (to (string-rindex reply "}"))
         (json (and from to (< from to)
                    (ignore-errors (lambda () (json-parse (substring reply from (+ to 1)))))))
         (name (and (pair? json) (plist-get json 'name)))
         (c (and (string? name) (find (lambda (c) (equal? (plist-get c 'name) name)) cands))))
    (and c (list "command" name '()))))

;; What TEXT runs in BUF. K gets ("command" NAME BINDINGS STAGE), or #f when
;; no command does it.
(define (command-palette-resolve text buf k &optional fresh?)
  (let ((learned (and (not fresh?) (command-palette--learned text))))
    (cond
      ((command-fn text) (k (list "command" text '() 'exact)))
      (learned (k (list "command" (cadr learned) '() 'learned)))
      (else
        (task-run! (lambda () (command-palette--candidates-for text buf))
          (lambda (ok? cands)
            (if (or (not ok?) (null? cands))
                (k #f)
                (command-palette--model-pick text cands k))))))))

(define (command-palette--model-pick text cands k)
  (cond
    ;; the small model on this machine reads the whole catalog and names one
    ((and (equal? command-palette-decide-backend 'local) (boundp 'do-pick))
     (do-pick text (lambda (name) (k (and name (list "command" name '() 'local))))))
    ((and (equal? command-palette-decide-backend 'jev) (boundp 'jev-systemone))
      (task-run!
        (lambda ()
          (jev-systemone text
            (list 'which (jev-choice "Which of these is the right command for this request?"
                           (append (apply append (map (lambda (c) (list (string->symbol (plist-get c 'name))
                                                                       (command-palette--candidate-line c)))
                                                      cands))
                                   (list 'none "None of these does what the request asks."))))))
        (lambda (ok? reply)
          (let* ((name (and ok? reply (jev-answer-choice reply 'which)))
                 (c (and name (find (lambda (c) (equal? (plist-get c 'name) name)) cands))))
            (k (and c (list "command" name '() 'jev)))))))
    (else
      (llm-with-model (command-palette--pick-prompt text cands)
                      (llm-model-for command-palette-pick-role)
        (lambda (reply)
          (let ((r (command-palette--parse-pick reply cands)))
            (k (and r (append r (list 'model))))))
        (lambda (_) (k #f))))))

(define (command-palette--apply! text r)
  (let ((name (cadr r)))
    (set! *command-palette--request* #f)
    (command-palette--learn! text name)
    (message (string-append text ": " name))
    (history-push! 'M-x name)
    (run-command name)))

;; What you typed is always the top row, so RET runs your words; a hit is
;; picked only when you move down to it.
(define (command-palette--with-ask query rows)
  (let ((q (string-trim query)))
    (if (equal? q "")
        rows
        (cons (or (and (command-fn q) (assoc q rows)) (command-palette--typed-row q))
              (filter (lambda (r) (not (equal? (car r) q))) rows)))))

;; the typed row says what RET will do with the words
(define (command-palette--typed-row q)
  (let ((learned (command-palette--learned q)))
    (list q (if learned
                (string-append "command  " (cadr learned))
                "find  the command for this, or ask the chat"))))

(domain! 'interaction)
(effects! '(write execute spend))

(defcustom 'command-palette-learned '()
  "What you typed in the palette and the command that ran for it: ((WORDS NAME BINDINGS KIND) ...). RET on the same words runs it at once, and apropos finds NAME by the words."
  'group 'interaction)

(defcustom 'command-mode-scoping #t
  "M-x and the palette offer a mode's commands only in its buffers, as Emacs does with (interactive nil MODE). A command's modes are the ones command-modes! names, else the modes whose -mode-map binds it when no global map does."
  'group 'interaction)

(defcustom 'command-palette-decide-backend 'jev
  "What picks the command for words you type in the palette: jev asks JEV; model asks the command-palette-pick-role model; local asks the small model on this machine (do-endpoint)."
  'group 'interaction)

(defcustom 'command-palette-pick-role 'fast
  "The model role that picks the command for words you type in the palette: llm-model-presets names its model."
  'group 'interaction)

(defcustom 'command-palette-candidate-count 12
  "How many commands apropos hands the picker."
  'group 'interaction)

;; the words of the request the palette is finding a command for, or #f
(define *command-palette--request* #f)

;; the learned row for TEXT, while its command is still there, else #f.
;; A row learned for a recipe, before recipes went, answers #f.
(define (command-palette--learned text)
  (let ((row (assoc (string-downcase (string-trim text)) command-palette-learned)))
    (and row
         (equal? (command-palette--row-kind row) "command")
         (command-fn (cadr row))
         row)))

(define (command-palette--row-kind row)
  (if (> (length row) 3) (list-ref row 3) "recipe"))

(define (command-palette--run-learned row)
  (history-push! 'M-x (cadr row))
  (run-command (cadr row)))

;; the words join NAME's aliases, so apropos finds it by them
(define (command-palette--alias! name kind words)
  (let* ((entry (and (equal? kind "command") (catalog-entry 'command name)))
         (old (or (and entry (catalog--get entry 'aliases)) "")))
    (when (and entry (not (string-contains? old words)))
      (catalog-meta! 'command name 'aliases (string-trim (string-append old " " words))))))

(define (command-palette--learn! text name)
  (let ((key (string-downcase (string-trim text))))
    (command-palette--alias! name "command" key)
    (customize-save! 'command-palette-learned
      (cons (list key name '() "command")
            (filter (lambda (r) (not (equal? (car r) key))) command-palette-learned)))))

;; the aliases are not saved with the catalog: put the learned words back
(for-each (lambda (row)
            (ignore-errors
              (lambda () (command-palette--alias! (cadr row) (command-palette--row-kind row) (car row)))))
          command-palette-learned)

;; A new user types the words of the editor they came from: "close tab",
;; "split editor", "settings". These are those words for the commands
;; that do it, and these commands lead the palette over rarer ones that
;; share a word: "save" is save-buffer before llm-config-save-bundle.
(define command-palette-everyday
  '(("save-buffer" "save file")
    ("write-file" "save as")
    ("revert-buffer" "revert file reload from disk")
    ("undo" "undo")
    ("kill-buffer" "close tab close editor close file")
    ("find-file" "open file")
    ("project-find-file" "go to file quick open find file in project")
    ("buffer-new" "new file new untitled")
    ("switch-to-buffer" "switch tab switch editor open editors")
    ("ibuffer" "open editors list tabs")
    ("split-window-right" "split editor split right side by side")
    ("split-window-below" "split editor down split down")
    ("delete-window" "close pane close split close window")
    ("delete-other-windows" "close other panes single pane maximize")
    ("other-window" "focus next pane next split")
    ("window-layout" "layout change layout choose layout arrange panes")
    ("customize" "settings preferences options")
    ("load-theme" "color theme dark mode light mode")
    ;; zoom offers both: the whole app (ui-scale, VSCode's ⌘=) and this
    ;; buffer (text-scale)
    ("ui-scale-increase" "zoom in zoom bigger ui scale")
    ("ui-scale-decrease" "zoom out zoom smaller ui scale")
    ("ui-scale-reset" "reset zoom zoom normal")
    ("text-scale-increase" "zoom in buffer zoom font size bigger text in this buffer")
    ("text-scale-decrease" "zoom out buffer zoom font size smaller text in this buffer")
    ("text-scale-reset" "reset zoom buffer zoom font size normal text in this buffer")
    ("describe-bindings" "keyboard shortcuts keybindings keymap")
    ("describe-key" "what does this key do shortcut")
    ("shell" "terminal console command line")
    ("visual-line-mode" "move by screen line visual lines")
    ("display-line-numbers-mode" "line numbers")
    ("goto-line" "go to line")
    ("isearch-forward" "find search in file")
    ("query-replace" "find and replace")
    ("project-ripgrep" "find in files search project search all files")
    ("imenu" "go to symbol outline")
    ("code-goto-definition" "go to definition")
    ("cua-select-all" "select all")
    ("dired" "file explorer folder")
    ("chat-new" "new chat ask ai assistant")
    ("vscode-mode" "vscode keys keymap")))

(define (command-palette--everyday? name)
  (and (assoc name command-palette-everyday) #t))

;; idempotent: a word a command already answers to changes nothing, so the
;; index rebuilds only when a command first gets its words
(define (command-palette--everyday-words!)
  (for-each (lambda (row)
              (ignore-errors
                (lambda () (when (command-fn (car row))
                             (command-palette--alias! (car row) "command" (cadr row))))))
            command-palette-everyday))

(command-palette--everyday-words!)

;; Words no command does go to a chat: the chat of the buffer you were in,
;; the one M-o opens, or the chat itself when you asked from one. It shows,
;; and the words are its next prompt.
(define (command-palette-ask-chat! text)
  (let ((origin (command-palette--origin)))
    (set! *command-palette--request* #f)
    (if (chat-buffer? origin)
        (agent-continue! origin text)
        (let ((chat (llm-companion-open! origin)))
          (agent-continue! chat text)))))

(public! 'command-palette-ask-chat!
  "(command-palette-ask-chat! TEXT) -- send TEXT to the chat of the buffer the palette was opened from, and show it")

(domain! 'interaction)
(effects! '(write execute))

;; DEL on an empty palette, or <delete>, removes the highlighted past row
;; from the history. *command-palette-row-delete* is a package's function of
;; the removed words, or #f: fast-code forgets the answer it remembers.
(define *command-palette-row-delete*
  (if (boundp '*command-palette-row-delete*) *command-palette-row-delete* #f))

(define (command-palette--delete-row!)
  (let* ((sel (minibuffer-selected))
         (name (if (pair? sel) (car sel) sel)))
    (if (and (string? name) (member name (history-items 'M-x)))
        (begin
          (history-remove! 'M-x name)
          (when *command-palette-row-delete* (*command-palette-row-delete* name))
          (minibuffer-set-candidates! (command-palette-candidates (minibuffer-input)))
          (message (string-append "Removed from the history: " name)))
        (message "Only a past row can be removed"))))

(define-command "command-palette"
  "Find a command by what it does"
  (lambda ()
    (set! *command-palette--from* (current-buffer))
    (command-palette--everyday-words!)
    (set! *mb-row-delete-fn* command-palette--delete-row!)
    ;; every pick and every ask goes on 'M-x, the one history the palette
    ;; and M-x share, so M-p in either walks them back
    (set! *mb-history-key* 'M-x)
    (set! *mb-history-pos* -1)
    (minibuffer-read* "Command: " (command-palette-candidates "")
      (list (list 'confirm
              (lambda (choice)
                (set! *mb-history-key* #f)
                (set! *mb-row-delete-fn* #f)
                (unless (equal? choice "") (history-push! 'M-x choice))
                (command-palette--run choice)))
            (list 'cancel (lambda () (set! *mb-history-key* #f) (set! *mb-row-delete-fn* #f)))
            (list 'change
              (lambda (input)
                ;; RET must never pick a row the input has left behind: the
                ;; typed words lead at once, and the search fills in after
                (minibuffer-set-candidates!
                  (if (equal? (string-trim input) "")
                      (command-palette-candidates "")
                      (command-palette--with-ask input (command-palette--past input))))
                (debounce!
                  (string-append "command-palette:" (selected-frame))
                  *command-palette-debounce-ms*
                  command-palette--refresh
                  input)))
            ;; Apropos already matched and ranked these results. In
            ;; particular, a doc match need not contain INPUT in its label.
            (list 'filter #f)
            (list 'style "palette")))))

;; the eval that scores what RET runs for the words you type
(load "palette-eval.scm")
