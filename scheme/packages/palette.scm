;;; palette.scm --- s-p, the command palette
;;;
;;; The palette answers "how do I do this?" where M-x answers "what is
;;; the command called?". It searches command docs and recipes by the
;;; words typed, and puts first the past picks and asks that match them,
;;; from the history it shares with M-x. Words a recipe's pattern reads
;;; run that recipe with the arguments in them: "open notes.md" opens the
;;; file. Words nothing reads go to the *recipes* chat, which writes the
;;; recipe into <compos-home>/recipes.scm and runs it, so the next time
;;; the palette knows them.

(domain! 'interaction)
(effects! '(write execute))

;;; Cmd-p answers "how do I do this?" while M-x answers "what is the
;;; command called?". Apropos supplies task-language matches from command
;;; docs and recipes; the palette projects that broad catalog down to things
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
               (string-append (string-pad-right key 12) " "
                              (or (plist-get hit 'doc) "")))))
      ((equal? kind "recipe")
       (let ((inputs (or (plist-get hit 'inputs) '())))
         (list name
               (if (null? inputs)
                   "recipe  runs immediately"
                   (string-append "recipe  asks for "
                                  (number->string (length inputs))
                                  (if (= (length inputs) 1) " input" " inputs"))))))
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

;; The palette draws the commands and recipes apropos finds, in its order,
;; with the ones whose name holds every word first. Its semantic pass can
;; take a second, so the refresh runs it in a task after a pause in typing.
(define (command-palette--search query)
  (let* ((words (apropos-query-words query))
         (found (append (apropos query 'kind "command") (apropos query 'kind "recipe")))
         (hits (filter (lambda (h) h)
                 (map (lambda (h)
                        (let ((kind (plist-get h 'kind)))
                          (cond ((equal? kind "command") h)
                                ;; a recipe read with its arguments is the typed row
                                ((plist-get h 'bindings) #f)
                                ((and (equal? kind "recipe") (boundp (quote *recipes*))
                                      (assoc (plist-get h 'name) *recipes*))
                                 (command-palette--recipe-hit (assoc (plist-get h 'name) *recipes*)))
                                (else #f))))
                      found)))
         (named? (lambda (h) (apropos-text-hit? (plist-get h 'name) words))))
    (append
      (let ((bind (command-palette--bind-hit query)))
        (if bind (list bind) '()))
      (filter named? hits)
      (filter (lambda (h) (not (named? h))) hits))))

;; A recipe the palette can draw, in apropos hit shape.
(define (command-palette--recipe-hit recipe)
  (list 'kind "recipe" 'name (car recipe) 'inputs (caddr recipe)))

(define (command-palette-candidates query)
  (if (equal? (string-trim query) "")
      ;; The resting palette is familiar and cheap: what you ran or asked,
      ;; newest first, then the rest of the M-x command table. The search
      ;; takes over as soon as the user states intent.
      (let* ((hist (history-items 'M-x))
             (asks (take (filter (lambda (h) (not (command-fn h))) hist)
                         *command-palette-past-max*))
             (rows (annotate 'command (history-order 'M-x (command-names))))
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
    ;; a command you ran before reads like any command row, key first
    (map (lambda (h)
           (if (command-fn h)
               (command-palette--candidate (command-palette--command-hit h))
               (list h "past  ask")))
         (take hits *command-palette-past-max*))))

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

(define (command-palette--render-recipe expr bindings)
  ;; Every input becomes a printed Scheme string, not source. Quotes,
  ;; backslashes and newlines are escaped by value->string before the token is
  ;; replaced, so a path or prompt value cannot turn into executable code.
  (if (null? bindings)
      expr
      (let* ((binding (car bindings))
             (token (string-append "{{" (symbol->string (car binding)) "}}"))
             (rendered (string-join (string-split expr token)
                                    (value->string (cadr binding)))))
        (command-palette--render-recipe rendered (cdr bindings)))))

;; "0.3" -> 0.3, "three" -> 3, else #f: string->number answers :error
(define (command-palette--number s)
  (let ((n (string->number s))
        (word (assoc (string-downcase s)
                     '(("one" 1) ("two" 2) ("three" 3) ("four" 4) ("five" 5) ("six" 6)
                       ("seven" 7) ("eight" 8) ("nine" 9) ("ten" 10) ("eleven" 11) ("twelve" 12)))))
    (cond ((number? n) n) (word (cadr word)) (else #f))))

;; An input whose row ends in number takes a number: "0.3" is 0.3.
(define (command-palette--typed recipe bindings)
  (map (lambda (b)
         (let ((input (assoc (car b) (caddr recipe))))
           (if (and input (memq 'number (cddr input)) (string? (cadr b)) (command-palette--number (cadr b)))
               (list (car b) (command-palette--number (cadr b)))
               b)))
       bindings))

;; the result, as eval-string-safe gives it, and in the echo area
(define (command-palette--eval-recipe recipe bindings)
  (let ((result
          (eval-string-safe
            (command-palette--render-recipe
              (cadr recipe) (command-palette--typed recipe bindings)))))
    (if (equal? (car result) 'ok)
        (message (value->string (cadr result)))
        (message (string-append "Recipe error: " (value->string (cadr result)))))
    result))

(define (command-palette--collect-recipe recipe inputs bindings)
  (if (null? inputs)
      (command-palette--eval-recipe recipe bindings)
      (let ((input (car inputs)))
        (minibuffer-read (cadr input) '()
          (lambda (value)
            (command-palette--collect-recipe
              recipe (cdr inputs) (append bindings (list (list (car input) value)))))))))

(define (command-palette--run-recipe recipe &optional bindings)
  (command-palette--collect-recipe
    recipe
    (filter (lambda (input) (not (assoc (car input) (or bindings '())))) (caddr recipe))
    (or bindings '())))

(define (command-palette--run choice)
  (let ((bind (command-palette--bind-parse choice)))
    (cond
      ((command-fn choice)
       (history-push! 'M-x choice)
       (run-command choice))
      ((and bind (boundp (quote keys-bind-intent)))
       (keys-bind-intent (car bind) (cadr bind)))
      ((and (boundp (quote *recipes*)) (assoc choice *recipes*))
       (command-palette--run-recipe (assoc choice *recipes*)))
      ((equal? (string-trim choice) "") #f)
      ((command-palette--learned choice)
       (command-palette--run-learned (command-palette--learned choice)))
      ((command-palette--reading choice)
       (let ((m (command-palette--reading choice)))
         (command-palette--run-recipe (assoc (car m) *recipes*) (cadr m))))
      (else (command-palette--pick! choice)))))

;; Words no row is named for go to the *recipes* chat. It runs the command
;; or recipe that does them; when none does, it writes a command. Either
;; way it saves a recipe, so the same words run at once next time.
(define (command-palette--pick! text)
  (set! *command-palette--request* text)
  (message (string-append "Finding the command for: " text))
  ;; apropos over the commands alone, with its semantic pass, in a task: a
  ;; sentence matches docs that hold its words, and the pass finds the
  ;; commands that do it. The recipes are read by their patterns before
  ;; this, and most of the rest are written for agents: they answer data.
  (task-run!
    (lambda ()
      (let ((hits (apropos text 'semantic #t 'kind "command")))
        (take hits (min 8 (length hits)))))
    (lambda (ok? hits)
      (if (or (not ok?) (null? hits))
          (command-palette--ask-to-write! text)
          (decide-async (list 'request text)
            (list 'pick (decide-choice
                          "Someone typed this request into the command palette of an editor. Which command does what they ask?"
                          (append (apply append
                                         (map (lambda (h)
                                                (list (string->symbol (plist-get h 'name))
                                                      (or (plist-get h 'doc) (plist-get h 'name))))
                                              hits))
                                  (list 'none "None of these does what they ask."))))
            (lambda (r) (command-palette--decided! text hits r))
            'backend command-palette-decide-backend)))))

;; run the hit decide picked and remember it for the words, else ask the
;; *recipes* chat to write the command
(define (command-palette--decided! text hits r)
  (let* ((a (assq 'pick (or (plist-get r 'answers) '())))
         (choice (and a (plist-get (cadr a) 'choice)))
         (hit (and (string? choice)
                   (find (lambda (h) (equal? (plist-get h 'name) choice)) hits))))
    (if (not hit)
        (command-palette--ask-to-write! text)
        (let ((kind (plist-get hit 'kind)))
          (set! *command-palette--request* #f)
          (command-palette--learn! text choice '() kind)
          (message (string-append text ": " choice))
          (if (equal? kind "command")
              (begin (history-push! 'M-x choice) (run-command choice))
              (command-palette--run-recipe (assoc choice *recipes*)))))))

(define (command-palette--ask-to-write! text)
  (command-palette-ask-recipes!
    (string-append "No command the palette found does \"" text "\". Find one with apropos and run it; "
                   "when none does, write one with (command-learn! NAME DOC \"(lambda () ...)\" \"" text "\") "
                   "and run it with (run-command NAME).")))

;; What you typed is always the top row, so RET runs your words; a hit is
;; picked only when you move down to it.
(define (command-palette--with-ask query rows)
  (let ((q (string-trim query)))
    (if (equal? q "")
        rows
        (cons (or (and (command-fn q) (assoc q rows)) (command-palette--typed-row q))
              (filter (lambda (r) (not (equal? (car r) q))) rows)))))

;; the recipe a pattern reads in TEXT, with its arguments: (TITLE BINDINGS)
(define (command-palette--reading text)
  (and (boundp 'recipe-match) (recipe-match text)))

;; the typed row says what RET will do with the words
(define (command-palette--typed-row q)
  (let ((learned (command-palette--learned q))
        (m (command-palette--reading q))
        (say (lambda (title bindings)
               (string-append "recipe  " title
                 (apply string-append
                        (map (lambda (b) (string-append "  " (symbol->string (car b)) "="
                                                        (if (string? (cadr b)) (cadr b) (value->string (cadr b)))))
                             bindings))))))
    (list q (cond ((and (boundp '*recipes*) (assoc q *recipes*)) (say q '()))
                  ((and learned (equal? (command-palette--row-kind learned) "command"))
                   (string-append "command  " (cadr learned)))
                  (learned (say (cadr learned) (caddr learned)))
                  (m (say (car m) (cadr m)))
                  (else "find  the command for this, or write one")))))


;;; Words no recipe reads go to the *recipes* chat: an ordinary chat that
;;; keeps every recipe you asked for, so it learns as it goes. It finds the
;;; calls with apropos, as any chat does, saves the recipe to
;;; <compos-home>/recipes.scm and runs it. The palette stays up and shows the
;;; chat from your words on, the newest line first, until you put it away.

(domain! 'interaction)
(effects! '(write execute spend))

(defcustom 'command-palette-recipes-role 'fast
  "The model role the *recipes* chat starts on: llm-model-presets names its model. fast is the quickest."
  'group 'interaction)

(defcustom 'command-palette-learned '()
  "What you typed in the palette and what ran for it: ((WORDS NAME BINDINGS KIND) ...), KIND \"command\" or \"recipe\". RET on the same words runs it at once, and apropos finds NAME by the words."
  'group 'interaction)

(defcustom 'command-palette-decide-backend 'laya
  "The decide backend that picks, from what apropos finds, the command for words you type: laya is local and quick."
  'group 'interaction)

;; the words of the request the *recipes* chat is on, or #f
(define *command-palette--request* #f)

;; the learned row for TEXT, while its recipe is still there, else #f
(define (command-palette--learned text)
  (let ((row (assoc (string-downcase (string-trim text)) command-palette-learned)))
    (and row
         (if (equal? (command-palette--row-kind row) "command")
             (command-fn (cadr row))
             (and (boundp '*recipes*) (assoc (cadr row) *recipes*)))
         row)))

(define (command-palette--row-kind row)
  (if (> (length row) 3) (list-ref row 3) "recipe"))

(define (command-palette--run-learned row)
  (if (equal? (command-palette--row-kind row) "command")
      (begin (history-push! 'M-x (cadr row))
             (run-command (cadr row)))
      (command-palette--run-recipe (assoc (cadr row) *recipes*) (caddr row))))

;; the words join NAME's aliases, so apropos finds it by them
(define (command-palette--alias! name kind words)
  (let* ((k (if (equal? kind "command") 'command 'recipe))
         (entry (catalog-entry k name))
         (old (or (and entry (catalog--get entry 'aliases)) "")))
    (when (and entry (not (string-contains? old words)))
      (catalog-meta! k name 'aliases (string-trim (string-append old " " words))))))

(define (command-palette--learn! text name bindings &optional kind)
  (let ((key (string-downcase (string-trim text)))
        (kind (or kind "recipe")))
    (command-palette--alias! name kind key)
    (customize-save! 'command-palette-learned
      (cons (list key name bindings kind)
            (filter (lambda (r) (not (equal? (car r) key))) command-palette-learned)))))

;; the aliases are not saved with the catalog: put the learned words back
(for-each (lambda (row)
            (ignore-errors
              (lambda () (command-palette--alias! (cadr row) (command-palette--row-kind row) (car row)))))
          command-palette-learned)

(define command-palette-recipes-chat "*recipes*")

;; what a new *recipes* chat is for; after that it learns from its own turns
(define (command-palette--recipes-intro)
  (string-append
    "You do what the user types in the command palette, and make it instant the next time. Each request reads "
    "do \"WORDS\". In this order:\n"
    "1. A command does it: find it with (apropos WORDS) and run it with (run-command NAME).\n"
    "2. A recipe does it: find it in (recipes) and run it with (recipe-run! TITLE BINDINGS), BINDINGS ((slot \"value\") ...).\n"
    "3. Neither: write a command with (command-learn! NAME DOC \"(lambda () ...)\"), from the calls apropos finds, "
    "and run it with (run-command NAME). It is saved in " (recipes-commands-path) ".\n"
    "After 1 or 3, save a recipe that runs the command, so the palette runs these words at once next time: "
    "(recipe-learn! TITLE EXPR INPUTS PATTERNS). Write it for every value, not for this one: "
    "\"use a dark theme\" is the command words \"use a ... theme\" with the argument dark, so TITLE is \"use a {{theme}} theme\". "
    "TITLE and PATTERNS keep the command words and put a {{slot}} where each argument goes; EXPR has {{slot}} "
    "where each argument goes; INPUTS ((slot \"Prompt: \" [number]) ...); PATTERNS the ways to say it, "
    "as (\"use a {{theme}} theme\" \"{{theme}} theme\"). A recipe with no arguments is (run-command \"NAME\"). "
    "When a recipe you find does one value of a command, make it general and drop the old one with (recipe-forget! TITLE). "
    "Check (recipe-match WORDS). The recipes go to " (recipes-user-path) ". Reply in one line.\n\n"))

;; the live chat, else the one kept for 'recipes read back, else #f
(define (command-palette--recipes-chat)
  (let ((name command-palette-recipes-chat))
    (if (and (buffer-known? name) (chat-buffer? name))
        name
        (ignore-errors (lambda () (chat-for "recipes"))))))

(define (command-palette-ask-recipes! text)
  (let ((chat (command-palette--recipes-chat)))
    (if chat
        (begin (command-palette--watch! chat text)
               (agent-continue! chat text))
        (let* ((model (llm-model-for command-palette-recipes-role))
               (made (agent-buf (execute* (string-append (command-palette--recipes-intro) text)
                                          (list 'title command-palette-recipes-chat 'notify #f
                                                'connector (llm-connector-for-model model) 'model model)))))
          ;; kept under 'recipes, so a restart reads the same chat back
          (ignore-errors (lambda () (chat-for! "recipes" made)))
          (command-palette--watch! made text)))))

;;; The watch: the chat from your words on, the newest line first, kept up
;;; to date as the chat writes. RET or C-g puts it away; the chat goes on.

;; (CHAT START TEXT CHANGE-ID) of the watch that is up, or #f
(define *command-palette--watch* #f)

(define (command-palette--watch-prompt text) (string-append "*recipes*: " text "  "))

(define (command-palette--clip line)
  (if (> (string-length line) 160) (string-append (substring line 0 157) "...") line))

(define (command-palette--watch-rows chat start)
  (let* ((all (buffer-text chat))
         (tail (if (< start (string-length all)) (substring all start (string-length all)) ""))
         (lines (filter (lambda (l) (not (equal? (string-trim l) ""))) (string-split tail "\n")))
         (slug (agent-slug-of chat))
         (busy (and slug (equal? (agent-status slug) 'running))))
    (cons (if busy
              (list "working ..." "C-g puts this away; the chat goes on")
              (list "done" "RET or C-g puts this away"))
          (map (lambda (l) (list (command-palette--clip (string-trim-right l)) ""))
               (reverse lines)))))

(define (command-palette--watch-refresh _)
  (let ((w *command-palette--watch*) (state (minibuffer-state)))
    (when (and w state (equal? (plist-get state 'prompt) (command-palette--watch-prompt (caddr w))))
      (let* ((all (buffer-text (car w)))
             (tail (if (< (cadr w) (string-length all)) (substring all (cadr w) (string-length all)) ""))
             (lines (filter (lambda (l) (not (equal? (string-trim l) ""))) (string-split tail "\n")))
             (asked (let loop ((ls lines))
                      (cond ((null? ls) #f)
                            ((string-prefix? ">>>" (car ls)) (cdr ls))
                            (else (loop (cdr ls))))))
             (slug (agent-slug-of (car w)))
             (busy (and slug (equal? (agent-status slug) 'running))))
        ;; the turn has answered and stopped: put the watch away at once and
        ;; say the answer; the summary lands later
        (if (and (not busy) (pair? asked))
            (begin (minibuffer-cancel!)
                   (message (string-append "*recipes*: " (string-trim (car (reverse asked))))))
            (minibuffer-set-candidates! (command-palette--watch-rows (car w) (cadr w))))))))

(define (command-palette--unwatch!)
  (let ((w *command-palette--watch*))
    (when w
      (remove-on-change! (cadddr w))
      (set! *command-palette--watch* #f))))

(define (command-palette--watch! chat text)
  (command-palette--unwatch!)
  (let* ((start (string-length (buffer-text chat)))
         (id (on-change! chat
               (lambda (pos inserted deleted source)
                 (debounce! "command-palette:recipes" 120 command-palette--watch-refresh #t))
               'eager)))
    ;; the prompt shows the words you typed, not what the chat was sent
    (set! *command-palette--watch* (list chat start (or *command-palette--request* text) id))
    (minibuffer-read* (command-palette--watch-prompt (caddr *command-palette--watch*))
                      (command-palette--watch-rows chat start)
      (list (list 'confirm (lambda (_) (command-palette--unwatch!)))
            (list 'cancel (lambda () (command-palette--unwatch!)))
            (list 'filter #f)
            (list 'style "palette")))))

;; the end of a turn may write nothing new; its summary still lands. The
;; turn is over, so the watch closes and the summary comes to the echo area.
(define (command-palette--recipes-answered buf kind text)
  (when (and (equal? buf command-palette-recipes-chat) (equal? kind 'summary) (string? text))
    (let ((w *command-palette--watch*) (state (minibuffer-state)))
      (when (and w state (equal? (plist-get state 'prompt) (command-palette--watch-prompt (caddr w))))
        (minibuffer-cancel!))
      (set! *command-palette--request* #f)
      (message (string-append "*recipes*: " text)))))

(add-hook! 'chat-summary-hook 'command-palette--recipes-answered)

;; Run recipe TITLE with BINDINGS, ((SLOT VALUE) ...), on the frame you
;; look at; answers what the recipe gave, or its error.
(define (recipe-run! title &optional bindings)
  (let ((recipe (and (boundp '*recipes*) (assoc title *recipes*))))
    (if (not recipe)
        (list 'error (string-append "no recipe named " title))
        (let ((result (with-frame-windows
                        (lambda () (command-palette--eval-recipe recipe (or bindings '()))))))
          ;; the chat ran this for a palette request: the same words run it next time
          (when (and *command-palette--request* (equal? (car result) 'ok))
            (command-palette--learn! *command-palette--request* title (or bindings '())))
          result))))

(public! 'recipe-run!
  "(recipe-run! TITLE '((slot \"value\") ...)) -- run a recipe with its arguments on the user's frame; answers (ok VALUE) or (error TEXT)")
(public! 'command-palette-ask-recipes!
  "(command-palette-ask-recipes! TEXT) -- the *recipes* chat writes a recipe for TEXT and runs it")

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
  "Find an action by intent across command docs and recipes"
  (lambda ()
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

