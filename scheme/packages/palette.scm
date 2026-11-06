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

;; The palette draws commands and recipes, so it searches those two alone.
;; The whole catalog costs an index rebuild after every package load, and
;; the semantic pass costs a network call. The palette searches again on
;; every keystroke burst and can pay neither.
(define (command-palette--search query)
  (let* ((words (apropos-query-words query))
         ;; (SCORE LENGTH NAME KIND): a name that holds every word ranks
         ;; above one matched only by its doc or aliases, then shorter first
         (key (lambda (name kind)
                (list (if (apropos-text-hit? name words) 0 1)
                      (string-length name) name kind)))
         (commands (map (lambda (name) (key name "command"))
                        (filter (lambda (name)
                                  (apropos-text-hit?
                                    (string-append name " " (command-doc name)) words))
                                (command-names))))
         (recipes (map (lambda (row) (key (car (car row)) "recipe"))
                       (filter (lambda (row) (apropos-text-hit? (cadr row) words))
                               (command-palette--recipe-texts)))))
    (append
      (let ((bind (command-palette--bind-hit query)))
        (if bind (list bind) '()))
      (map (lambda (k)
             (if (equal? (nth 3 k) "command")
                 (command-palette--command-hit (nth 2 k))
                 (command-palette--recipe-hit (assoc (nth 2 k) *recipes*))))
           (sort (append commands recipes))))))

;; A recipe the palette can draw, in apropos hit shape.
(define (command-palette--recipe-hit recipe)
  (list 'kind "recipe" 'name (car recipe) 'inputs (caddr recipe)))

;; Each recipe with its text, made once for each *recipes* list: a catalog
;; lookup costs about 10 ms, and a keystroke used to make sixty of them.
(define *command-palette--recipe-cache* (list #f '()))

(define (command-palette--recipe-texts)
  (let ((recipes (if (boundp (quote *recipes*)) *recipes* '())))
    (unless (eq? (car *command-palette--recipe-cache*) recipes)
      (set! *command-palette--recipe-cache*
            (list recipes (map (lambda (r) (list r (command-palette--recipe-text r))) recipes))))
    (cadr *command-palette--recipe-cache*)))

;; A recipe matches on its task words and the aliases people use for it.
(define (command-palette--recipe-text recipe)
  (let ((entry (catalog-entry 'recipe (car recipe))))
    (string-append (car recipe) " "
                   (or (and entry (catalog--get entry 'aliases)) ""))))

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
      (let* ((hit (command-palette--pattern-row query))
             (lead (append (if hit (list hit) '())
                           (filter (lambda (r) (not (and hit (equal? (car r) (car hit)))))
                                   (command-palette--past query)))))
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

(define *command-palette-debounce-ms* 80)

(define (command-palette--refresh input)
  ;; A timer can outlive the prompt that scheduled it. Never put Cmd-p's
  ;; results into a later prompt, and never let an old query replace a newer
  ;; one after the user has kept typing.
  (let ((state (minibuffer-state)))
    (when (and state
               (equal? (plist-get state 'prompt) "Command: ")
               (equal? (plist-get state 'input) input))
      (minibuffer-set-candidates! (command-palette-candidates input)))))

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

;; An input whose row ends in number takes a number: "0.3" is 0.3.
(define (command-palette--typed recipe bindings)
  (map (lambda (b)
         (let ((input (assoc (car b) (caddr recipe))))
           (if (and input (memq 'number (cddr input)) (string? (cadr b)) (string->number (cadr b)))
               (list (car b) (string->number (cadr b)))
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
      ((command-palette--pattern choice)
       (let ((m (command-palette--pattern choice)))
         (command-palette--run-recipe (assoc (car m) *recipes*) (cadr m))))
      ((equal? (string-trim choice) "") #f)
      (else (command-palette-ask-recipes! choice)))))

;; The recipe a pattern reads in QUERY, and its arguments: (TITLE BINDINGS)
(define (command-palette--pattern query)
  (and (boundp 'recipe-match) (recipe-match query)))

;; What you typed, as the row of the recipe it runs: RET reads it again.
(define (command-palette--pattern-row query)
  (let ((m (command-palette--pattern query)))
    (and m
         (list (string-trim query)
               (string-append "recipe  " (car m) "  "
                              (string-join (map (lambda (b) (string-append (symbol->string (car b)) "=" (cadr b)))
                                                (cadr m))
                                           "  "))))))

;; Words no row is named for are a row too, so RET asks the *recipes* chat.
;; A sentence (three words or more) leads; a word or two follows the hits.
(define (command-palette--with-ask query rows)
  (let ((q (string-trim query)))
    (if (or (equal? q "") (assoc q rows))
        rows
        (let ((ask (list q "ask  *recipes* writes a recipe for this")))
          (if (>= (length (string-split q " ")) 3)
              (cons ask rows)
              (append rows (list ask)))))))


;;; Words no recipe reads become one. apropos finds the calls for the
;;; words; the fast model sees those calls alone and answers the recipe as
;;; data: which words are the command, which are the arguments, and the
;;; expression. The palette checks it, runs it, and saves it. One search and
;;; one short model call; a wrong answer gets one more, with the reason.
;;; While it works the palette stays up and shows each step, the newest
;;; first, and RET or C-g puts it away. An answer that does not hold leaves
;;; a row that hands the words, and what was found, to the *recipes* chat.

(domain! 'interaction)
(effects! '(write execute external spend))

(defcustom 'command-palette-recipes-role 'fast
  "The model role that writes a recipe for the palette: llm-model-presets names its model. fast is the quickest."
  'group 'interaction)

(define (command-palette--recipes-model) (llm-model-for command-palette-recipes-role))

;; how many hits the model reads: enough to hold the call, few enough that
;; a fast model reads every one
(define *command-palette-recipe-hits* 15)

(define (command-palette--recipe-hits text)
  (let ((hits (filter (lambda (e) (member (plist-get e 'kind) '("function" "command" "recipe" "variable")))
                      (apropos text))))
    (take hits (min *command-palette-recipe-hits* (length hits)))))

;; one line a hit: the call as written, then its doc
(define (command-palette--hit-line e)
  (let ((kind (plist-get e 'kind)) (name (plist-get e 'name)))
    (string-append "  "
      (cond ((equal? kind "command") (string-append "(run-command " (value->string name) ")"))
            ((equal? kind "recipe") (string-append (or (plist-get e 'use) "") "  ; " name))
            ((equal? kind "variable") name)
            (else (or (plist-get e 'sig) name)))
      "  -- " (command-palette--clip (or (plist-get e 'doc) "") 120))))

(define (command-palette--clip line &optional n)
  (let ((n (or n 160)))
    (if (> (string-length line) n) (string-append (substring line 0 (- n 3)) "...") line)))

(define (command-palette--recipe-prompt text hits reason)
  (string-append
    "Write one recipe for the compos editor. Its language is compos Scheme, not Emacs Lisp.\n"
    "The user typed: " (value->string text) "\n\n"
    "The calls that may do it:\n" (string-join (map command-palette--hit-line hits) "\n") "\n\n"
    "Split the words. The command is what to do. Each argument is a value in the words: a file, buffer, name, number or text.\n"
    "Answer one Scheme list and nothing else:\n"
    "(recipe TITLE EXPR INPUTS PATTERNS)\n"
    "TITLE: the task in general words, with no argument values.\n"
    "EXPR: a string, one expression made of the calls above, with {{slot}} where each argument goes. {{slot}} becomes a quoted string, so never quote it.\n"
    "INPUTS: ((slot \"Prompt: \") ...), one row per slot; end a row with number when the value is a number; () when there are no arguments.\n"
    "PATTERNS: 2 to 4 ways to say it, the command words with {{slot}} for each argument. One must read the typed words.\n"
    "Example, for open notes.md:\n"
    "(recipe \"open a file\" \"(visit {{path}} (buffer-group (current-buffer)))\" ((path \"File: \")) (\"open {{path}}\" \"visit {{path}}\"))\n"
    (if reason (string-append "\nYour last answer failed: " reason "\nAnswer again.\n") "")))

(define (command-palette--unfence s)
  (string-trim (string-join (filter (lambda (l) (not (string-prefix? "```" (string-trim l))))
                                    (string-split (string-trim s) "\n"))
                            "\n")))

;; A fast model quotes a slot, "\"{{name}}\"", though the slot is a quoted
;; string already; the quotes go, so the value is not quoted twice.
(define (command-palette--unquote-slots recipe)
  (let* ((slots (append (map car (caddr recipe))
                        (apply append (map (lambda (p) (filter (lambda (s) s) (map recipe--slot (recipe--words p))))
                                           (cadddr recipe)))))
         (expr (fold (lambda (e s)
                       (let ((token (string-append "{{" (symbol->string s) "}}")))
                         (string-join (string-split e (string-append "\"" token "\"")) token)))
                     (cadr recipe) slots)))
    (list (car recipe) expr (caddr recipe) (cadddr recipe))))

;; (ok RECIPE BINDINGS CODE) or (no REASON). RECIPE is (TITLE EXPR INPUTS
;; PATTERNS); BINDINGS are what the pattern reads in TEXT, as the palette
;; will read them the next time; CODE is the expression they make.
(define (command-palette--recipe-check text reply)
  (let* ((forms (ignore-errors (lambda () (scheme-read (command-palette--unfence reply)))))
         (form (and (pair? forms) (car forms))))
    (if (not (and (pair? form) (eq? (car form) 'recipe) (= (length form) 5)
                  (string? (list-ref form 1)) (string? (list-ref form 2))
                  (list? (list-ref form 3)) (list? (list-ref form 4))
                  (pair? (list-ref form 4)) (null? (filter (lambda (p) (not (string? p))) (list-ref form 4)))))
        (list 'no "answer exactly one list: (recipe TITLE EXPR INPUTS PATTERNS), strings where the example has strings")
        (let* ((recipe (command-palette--unquote-slots (cdr form)))
               (words (recipe--words text))
               (read (find (lambda (p) (recipe--match-words (recipe--words p) words)) (cadddr recipe)))
               (bindings (and read (recipe--match-words (recipe--words read) words))))
          (if (not read)
              (list 'no (string-append "no pattern reads " (value->string text)))
              (let* ((code (command-palette--render-recipe
                             (cadr recipe) (command-palette--typed recipe bindings)))
                     (accepted (if (boundp 'fast-accept) (fast-accept code) (list 'ok code))))
                (if (equal? (car accepted) 'ok)
                    (list 'ok recipe bindings code)
                    (list 'no (let ((why (cadr accepted))) (if (string? why) why (value->string why)))))))))))

;; the ask that is up: (TEXT STEPS DONE? REASON); STEPS are rows, newest first
(define *command-palette--ask* #f)

(define command-palette--chat-row "ask the *recipes* chat")

(define (command-palette--ask-prompt text) (string-append "recipe: " text "  "))

(define (command-palette--ask-rows)
  (let ((a *command-palette--ask*))
    (append
      (list (if (caddr a)
                (list "done" "RET or C-g puts this away")
                (list "working ..." "C-g puts this away")))
      (if (and (caddr a) (cadddr a))
          (list (list command-palette--chat-row "RET hands it the words and what was found"))
          '())
      (cadr a))))

(define (command-palette--ask-refresh!)
  (let ((a *command-palette--ask*) (state (minibuffer-state)))
    (when (and a state (equal? (plist-get state 'prompt) (command-palette--ask-prompt (car a))))
      (minibuffer-set-candidates! (command-palette--ask-rows)))))

(define (command-palette--step! label &optional hint)
  (let ((a *command-palette--ask*))
    (when a
      (set! *command-palette--ask*
            (list (car a) (cons (list (command-palette--clip label) (or hint "")) (cadr a)) (caddr a) (cadddr a)))
      (command-palette--ask-refresh!))))

(define (command-palette--ask-done! &optional reason)
  (let ((a *command-palette--ask*))
    (when a
      (set! *command-palette--ask* (list (car a) (cadr a) #t reason))
      (command-palette--ask-refresh!))))

(define (command-palette--ms t0) (string-append (number->string (- (monotonic-ms) t0)) " ms"))

(define (command-palette-ask-recipes! text)
  (set! *command-palette--ask* (list text '() #f #f))
  (minibuffer-read* (command-palette--ask-prompt text) (command-palette--ask-rows)
    (list (list 'confirm
            (lambda (choice)
              (let ((a *command-palette--ask*))
                (set! *command-palette--ask* #f)
                (when (and a (equal? choice command-palette--chat-row))
                  (command-palette--ask-chat! (car a) (cadddr a))))))
          (list 'cancel (lambda () (set! *command-palette--ask* #f)))
          (list 'filter #f)
          (list 'style "palette")))
  ;; the search costs most of a second: off the lane, with the prompt up
  (let ((t0 (monotonic-ms)))
    (task-run! (lambda () (command-palette--recipe-hits text))
      (lambda (ok? hits)
        (if (not ok?)
            (begin (command-palette--step! (string-append "apropos failed: " (value->string hits)))
                   (command-palette--ask-done! "apropos failed"))
            (begin
              (command-palette--step! (string-append "apropos  " (number->string (length hits)) " calls")
                                      (command-palette--ms t0))
              (command-palette--recipe-ask! text hits #f 1)))))))

(define (command-palette--recipe-ask! text hits reason tries)
  (let ((t0 (monotonic-ms)) (model (command-palette--recipes-model)))
    (command-palette--step! (string-append "asking " model))
    (llm-with-model (command-palette--recipe-prompt text hits reason) model
      (lambda (reply)
        (let ((r (command-palette--recipe-check text reply)))
          (if (equal? (car r) 'ok)
              (command-palette--recipe-run! text hits r t0 tries)
              (command-palette--recipe-retry! text hits (cadr r) t0 tries))))
      (lambda (err)
        (command-palette--step! (string-append "model error: " (value->string err)) (command-palette--ms t0))
        (command-palette--ask-done! (value->string err))))))

(define (command-palette--recipe-retry! text hits reason t0 tries)
  (command-palette--step! (string-append "wrong: " reason) (command-palette--ms t0))
  (if (< tries 2)
      (command-palette--recipe-ask! text hits reason (+ tries 1))
      (command-palette--ask-done! reason)))

;; run it first: a recipe is saved only when it ran clean
(define (command-palette--recipe-run! text hits r t0 tries)
  (let* ((recipe (cadr r)) (bindings (caddr r)) (code (cadddr r)))
    (command-palette--step! (string-append "recipe  " (car recipe)) (command-palette--ms t0))
    (command-palette--step! (string-append "  " code))
    (let ((res (with-frame-windows (lambda () (eval-string-safe code)))))
      (if (equal? (car res) 'ok)
          (begin
            (apply recipe-learn! recipe)
            (command-palette--step! (string-append "ran  " (value->string (cadr res))) "saved to recipes.scm")
            (command-palette--ask-done!))
          (command-palette--recipe-retry! text hits
            (string-append "running " code " gave: " (value->string (cadr res))) t0 tries)))))

;;; The *recipes* chat takes what the fast model could not: the words, the
;;; calls apropos found, and why the answer failed.

(define command-palette-recipes-chat "*recipes*")

;; the live chat, else the one kept for 'recipes read back, else #f
(define (command-palette--recipes-chat)
  (let ((name command-palette-recipes-chat))
    (if (and (buffer-known? name) (chat-buffer? name))
        name
        (ignore-errors (lambda () (chat-for "recipes"))))))

(define (command-palette--recipes-brief text reason)
  (string-append
    "The palette could not make a recipe for " (value->string text)
    (if reason (string-append "; the fast model's last try failed: " reason) "") ".\n"
    "Write it with (recipe-learn! TITLE EXPR INPUTS PATTERNS), saved to " (recipes-user-path) ". "
    "EXPR has {{slot}} where each argument goes; INPUTS is ((slot \"Prompt: \") ...); "
    "PATTERNS are the command words with {{slot}} for each argument, as (\"open {{path}}\"). "
    "Check (recipe-match " (value->string text) "), then run it with (recipe-run! TITLE BINDINGS). "
    "Reply in one line."))

(define (command-palette--ask-chat! text reason)
  (let ((brief (command-palette--recipes-brief text reason))
        (chat (command-palette--recipes-chat)))
    (if chat
        (agent-continue! chat brief)
        (let ((made (agent-buf (execute* brief (list 'title command-palette-recipes-chat 'notify #f
                                                     'presets '(compos))))))
          ;; kept under 'recipes, so a restart reads the same chat back
          (ignore-errors (lambda () (chat-for! "recipes" made)))))
    (message (string-append "*recipes* has it; C-x b *recipes* shows it"))))

;; the chat works out of sight; its answer comes to the echo area
(define (command-palette--recipes-answered buf kind text)
  (when (and (equal? buf command-palette-recipes-chat) (equal? kind 'summary) (string? text))
    (message (string-append "*recipes*: " text))))

(add-hook! 'chat-summary-hook 'command-palette--recipes-answered)

;; Run recipe TITLE with BINDINGS, ((SLOT VALUE) ...), on the frame you
;; look at; answers what the recipe gave, or its error.
(define (recipe-run! title &optional bindings)
  (let ((recipe (and (boundp '*recipes*) (assoc title *recipes*))))
    (if (not recipe)
        (list 'error (string-append "no recipe named " title))
        (with-frame-windows
          (lambda () (command-palette--eval-recipe recipe (or bindings '())))))))

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
                (debounce!
                  (string-append "command-palette:" (selected-frame))
                  *command-palette-debounce-ms*
                  command-palette--refresh
                  input)))
            ;; Apropos already matched and ranked these results. In
            ;; particular, a doc match need not contain INPUT in its label.
            (list 'filter #f)
            (list 'style "palette")))))

