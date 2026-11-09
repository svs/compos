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

;; A mode's commands are for its buffers (command-applicable?): the palette
;; leaves out the ones whose modes are not on in BUF, the buffer you are in.
(define (command-palette--for-user hits buf)
  (let ((out (commands-out-of-scope buf)))
    (filter (lambda (h) (not (and (equal? (plist-get h 'kind) "command")
                                  (member (plist-get h 'name) out))))
            hits)))

;; The palette draws the commands and recipes apropos finds, in its order,
;; with the ones whose name holds every word first. Its semantic pass can
;; take a second, so the refresh runs it in a task after a pause in typing.
(define (command-palette--search query)
  (let* ((words (apropos-query-words query))
         (found (command-palette--for-user
                  (append (apropos query 'kind "command") (apropos query 'kind "recipe"))
                  (command-palette--origin)))
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
      (filter named? rest)
      (filter (lambda (h) (not (named? h))) rest))))

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
             (rows (command-rows))
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
      (else (command-palette--pick! choice)))))

;; Words no row is named for go to the *recipes* chat. It runs the command
;; or recipe that does them; when none does, it writes a command. Either
;; way it saves a recipe, so the same words run at once next time.
(define (command-palette--pick! text)
  ;; the answer comes seconds later, when the frame's current buffer can be
  ;; the prompt's own: it runs in the buffer you were in when you asked
  (let ((origin (command-palette--origin)))
    (set! *command-palette--request* text)
    (message (string-append "Finding the command for: " text))
    (command-palette-resolve text origin
      (lambda (r)
        (if r
            (with-frame-windows
              (lambda () (with-current-buffer origin (lambda () (command-palette--apply! text r)))))
            (command-palette--ask-to-write! text))))))

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

;; The recipes the palette offers: the ones in your recipes file, written to
;; be run from words. The bundled ones are written for agents: they answer data.
(define (command-palette--own-recipes)
  (let ((path (recipes-user-path)))
    (if (not (file-exists? path))
        '()
        (filter (lambda (r) r)
                (map (lambda (b) (assoc (car (string-split b "\n")) *recipes*))
                     (cdr (string-split (read-file path) recipes--marker)))))))

;; What could do TEXT in BUF: the commands for BUF that apropos finds with its
;; semantic pass, then your own recipes. Slow: run it in a task.
(define (command-palette--candidates-for text buf)
  (let* ((out (commands-out-of-scope buf))
         (cmds (filter (lambda (h) (and (not (string-contains? (plist-get h 'name) "--"))
                                        (not (member (plist-get h 'name) out))))
                       (apropos text 'semantic #t 'kind "command"))))
    (append (map (lambda (h) (list 'kind "command" 'name (plist-get h 'name)
                                   'doc (or (plist-get h 'doc) "") 'inputs '()))
                 (take cmds (min command-palette-candidate-count (length cmds))))
            (map (lambda (r) (list 'kind "recipe" 'name (car r) 'doc (car r) 'inputs (caddr r)))
                 (command-palette--own-recipes)))))

(define (command-palette--candidate-line c)
  (string-append "- " (plist-get c 'name)
    (if (equal? (plist-get c 'doc) (plist-get c 'name)) "" (string-append ": " (plist-get c 'doc)))
    (if (null? (plist-get c 'inputs))
        ""
        (string-append "  [inputs: "
          (string-join (map (lambda (i) (string-append (symbol->string (car i)) " (" (string-trim (cadr i)) ")"))
                            (plist-get c 'inputs))
                       ", ")
          "]"))))

(define (command-palette--pick-prompt text cands)
  (string-append
    "Someone typed a request into the command palette of an editor. It may have typos. "
    "Pick the command or recipe below that does it, and read the recipe's inputs from the request. "
    "Answer with JSON only:\n"
    "{\"name\": \"NAME\", \"inputs\": {\"INPUT\": \"VALUE\"}} - leave out an input the request does not give\n"
    "{\"name\": null} - none of them does it\n\n"
    (string-join (map command-palette--candidate-line cands) "\n")
    "\n\nRequest: " text))

;; (KIND NAME BINDINGS) from a model's JSON reply, when NAME is a candidate
(define (command-palette--parse-pick reply cands)
  (let* ((from (string-index reply "{"))
         (to (string-rindex reply "}"))
         (json (and from to (< from to)
                    (ignore-errors (lambda () (json-parse (substring reply from (+ to 1)))))))
         (name (and (pair? json) (plist-get json 'name)))
         (c (and (string? name) (find (lambda (c) (equal? (plist-get c 'name) name)) cands))))
    (and c
         (list (plist-get c 'kind) name
               (filter (lambda (b) b)
                       (map (lambda (i)
                              (let ((v (plist-get (or (plist-get json 'inputs) '()) (car i))))
                                (cond ((string? v) (list (car i) v))
                                      ((number? v) (list (car i) (number->string v)))
                                      (else #f))))
                            (plist-get c 'inputs)))))))

;; The answer to TEXT when a recipe pattern reads it: "3 col layout" against
;; "{{count}} col layout" gives the recipe's expression with 3 in it. apropos
;; puts it first, so a request a recipe knows is answered without a model.
(define (recipe-answer text)
  (let* ((m (recipe-match text))
         (recipe (and m (assoc (car m) *recipes*))))
    (and recipe
         (list 'kind "recipe" 'name (car m) 'doc (car m) 'bindings (cadr m) 'answer #t
               'use (command-palette--render-recipe
                      (cadr recipe) (command-palette--typed recipe (cadr m)))))))

;; words that carry a number: "3 col layout", "show four columns"
(define (command-palette--has-number? text)
  (any command-palette--number (string-split text " ")))

;; What TEXT runs in BUF. K gets (KIND NAME BINDINGS STAGE), KIND "command"
;; or "recipe", or #f when nothing does it. An exact name and words you
;; ran before answer at once; the rest go to a model that picks among the
;; candidates and reads the arguments, typos and all. FRESH? skips the
;; words you ran before, as the eval does.
(define (command-palette-resolve text buf k &optional fresh?)
  (let ((learned (and (not fresh?) (command-palette--learned text)))
        ;; your own recipes answer by pattern; the bundled ones are for agents
        (answer (let ((a (recipe-answer text)))
                  (and a (member (plist-get a 'name) (map car (command-palette--own-recipes))) a)))
        (written (and (not fresh?) (boundp 'fast-remembered) (fast-remembered text)))
        ;; a command takes no value, so words that carry a number ("3 col
        ;; layout") are not done by one: fast-code writes the call with it
        (write (lambda (r) (if (and r (not (and (equal? (car r) "command")
                                                 (command-palette--has-number? text))))
                               (k r)
                               (command-palette--write text k)))))
    (cond
      ((command-fn text) (k (list "command" text '() 'exact)))
      ((and (boundp '*recipes*) (assoc text *recipes*)) (k (list "recipe" text '() 'exact)))
      (learned (k (list (command-palette--row-kind learned) (cadr learned) (caddr learned) 'learned)))
      (answer (k (list "recipe" (plist-get answer 'name) (plist-get answer 'bindings) 'pattern)))
      (written (k (list "code" written '() 'remembered (list 'code written 'source 'remembered))))
      (else
        (task-run! (lambda () (command-palette--candidates-for text buf))
          (lambda (ok? cands)
            (if (or (not ok?) (null? cands))
                (write #f)
                (command-palette--model-pick text cands write))))))))

;; No command fits TEXT: fast-code writes the code, one model call that
;; composes what apropos finds and names a function when the job takes one.
;; K gets ("code" CODE () written R), R being what fast-resolve gave, or #f.
(define (command-palette--write text k)
  (if (boundp 'fast-resolve)
      (fast-resolve text
        (lambda (r) (k (and (plist-get r 'code) (list "code" (plist-get r 'code) '() 'written r)))))
      (k #f)))

(define (command-palette--model-pick text cands k)
  (cond
    ;; the small model on this machine reads the whole catalog and names one
    ;; command; it reads no arguments, so it answers commands only
    ((and (equal? command-palette-decide-backend 'local) (boundp 'do-pick))
     (do-pick text (lambda (name) (k (and name (list "command" name '() 'local))))))
    ((and (equal? command-palette-decide-backend 'jev) (boundp 'jev-systemone))
      ;; JEV picks among them; it reads no arguments, so a recipe asks for them
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
            (cond ((not c) (k #f))
                  ((null? (plist-get c 'inputs)) (k (list (plist-get c 'kind) name '() 'jev)))
                  ;; JEV reads no arguments: the model reads them for the one it picked
                  (else (llm-with-model (command-palette--pick-prompt text (list c))
                                        (llm-model-for command-palette-pick-role)
                          (lambda (reply)
                            (let ((r (command-palette--parse-pick reply (list c))))
                              (k (list (plist-get c 'kind) name (if r (caddr r) '()) 'jev+model))))
                          (lambda (_) (k (list (plist-get c 'kind) name '() 'jev))))))))))
    (else
      (llm-with-model (command-palette--pick-prompt text cands)
                      (llm-model-for command-palette-pick-role)
        (lambda (reply)
          (let ((r (command-palette--parse-pick reply cands)))
            (k (and r (append r (list 'model))))))
        (lambda (_) (k #f))))))

;; run what resolve found, and remember it for the words
(define (command-palette--apply! text r)
  (let ((kind (car r)) (name (cadr r)) (bindings (caddr r)))
    (set! *command-palette--request* #f)
    (cond
      ((equal? kind "code") (fast-run-resolved! text (list-ref r 4) "palette" (current-buffer)))
      (else
        (command-palette--learn! text name bindings kind)
        (message (string-append text ": " name))
        (if (equal? kind "command")
            (begin (history-push! 'M-x name) (run-command name))
            (command-palette--run-recipe (assoc name *recipes*) bindings))))))

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

;; the typed row says what RET will do with the words
(define (command-palette--typed-row q)
  (let ((learned (command-palette--learned q))
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

(defcustom 'command-mode-scoping #t
  "M-x and the palette offer a mode's commands only in its buffers, as Emacs does with (interactive nil MODE). A command's modes are the ones command-modes! names, else the modes whose -mode-map binds it when no global map does."
  'group 'interaction)

(defcustom 'command-palette-decide-backend 'jev
  "What picks the command for words you type in the palette: jev asks JEV, and the command-palette-pick-role model reads the arguments of a recipe it picks; model asks that model to pick and read them in one call; local asks the small model on this machine (do-endpoint), which picks a command and reads no arguments."
  'group 'interaction)

(defcustom 'command-palette-pick-role 'fast
  "The model role that picks the command for words you type in the palette: llm-model-presets names its model."
  'group 'interaction)

(defcustom 'command-palette-candidate-count 12
  "How many commands apropos hands the picker, besides your own recipes."
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
    ("customize" "settings preferences options")
    ("load-theme" "color theme dark mode light mode")
    ("text-scale-increase" "zoom in font size bigger text")
    ("text-scale-decrease" "zoom out font size smaller text")
    ("text-scale-reset" "reset zoom font size")
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

;; The Claude Code adapter names its models by family (sonnet, opus,
;; haiku), not by id: claude-sonnet-5-5 is refused, and the chat would stay
;; on its old model.
(define (command-palette--chat-model model)
  (cond ((not (and (string? model) (string-prefix? "claude-" model)
                   (equal? (llm-connector-for-model model) "claude-code")))
         model)
        ((string-contains? model "sonnet") "sonnet")
        ((string-contains? model "opus") "opus")
        ((string-contains? model "haiku") "haiku")
        (else model)))

(define (command-palette-ask-recipes! text)
  (let ((chat (command-palette--recipes-chat)))
    (if chat
        (begin (command-palette--watch! chat text)
               (agent-continue! chat text))
        (let* ((model (command-palette--chat-model (llm-model-for command-palette-recipes-role)))
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
