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

(define command-palette-recipes-chat "*recipes*")

;; what a new *recipes* chat is for; after that it learns from its own turns
(define (command-palette--recipes-intro)
  (string-append
    "You turn what the user types in the command palette into recipes. For each request: "
    "find the calls with apropos; split the words into the command and its arguments (each file, buffer, name, number or text); "
    "save it with (recipe-learn! TITLE EXPR INPUTS PATTERNS), EXPR with {{slot}} where each argument goes, "
    "INPUTS ((slot \"Prompt: \" [number]) ...), PATTERNS the command words with {{slot}} for each argument, as (\"open {{path}}\"); "
    "check (recipe-match WORDS), then run it with (recipe-run! TITLE BINDINGS). "
    "The recipes go to " (recipes-user-path) ". Reply in one line.\n\n"))

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
      (minibuffer-set-candidates! (command-palette--watch-rows (car w) (cadr w))))))

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
    (set! *command-palette--watch* (list chat start text id))
    (minibuffer-read* (command-palette--watch-prompt text) (command-palette--watch-rows chat start)
      (list (list 'confirm (lambda (_) (command-palette--unwatch!)))
            (list 'cancel (lambda () (command-palette--unwatch!)))
            (list 'filter #f)
            (list 'style "palette")))))

;; the end of a turn may write nothing new; its summary still lands. With
;; no watch up, the summary comes to the echo area.
(define (command-palette--recipes-answered buf kind text)
  (when (and (equal? buf command-palette-recipes-chat) (equal? kind 'summary) (string? text))
    (if *command-palette--watch*
        (command-palette--watch-refresh #t)
        (message (string-append "*recipes*: " text)))))

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

