;;; palette.scm --- s-p, the command palette
;;;
;;; The palette answers "how do I do this?" where M-x answers "what is
;;; the command called?". It searches command docs and recipes by the
;;; words typed, and puts first the past picks and asks that match them,
;;; from the history it shares with M-x. fast-code wraps
;;; command-palette-candidates and command-palette--run, so input that
;;; matches nothing becomes Scheme.

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
       (list name
             (string-append "command  "
                            (let ((key (plist-get hit 'key))) (if key key ""))
                            "  " (or (plist-get hit 'doc) ""))))
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
      ;; The resting palette is familiar and cheap: the past asks, then the
      ;; same MRU command table as M-x. The search takes over as soon as the
      ;; user states intent.
      (append (map (lambda (h) (list h "past  ask"))
                   (take (filter (lambda (h) (not (command-fn h))) (history-items 'M-x))
                         *command-palette-past-max*))
              (annotate 'command (history-order 'M-x (command-names))))
      (let ((past (command-palette--past query)))
        (append past
                (filter (lambda (candidate)
                          (and candidate (not (assoc (car candidate) past))))
                        (map command-palette--candidate (command-palette--search query)))))))

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
    (map (lambda (h) (list h (if (command-fn h) "past  command" "past  ask")))
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

(define (command-palette--eval-recipe recipe bindings)
  (let ((result
          (eval-string-safe
            (command-palette--render-recipe (cadr recipe) bindings))))
    (if (equal? (car result) 'ok)
        (message (value->string (cadr result)))
        (message (string-append "Recipe error: " (cadr result))))))

(define (command-palette--collect-recipe recipe inputs bindings)
  (if (null? inputs)
      (command-palette--eval-recipe recipe bindings)
      (let ((input (car inputs)))
        (minibuffer-read (cadr input) '()
          (lambda (value)
            (command-palette--collect-recipe
              recipe (cdr inputs) (append bindings (list (list (car input) value)))))))))

(define (command-palette--run-recipe recipe)
  (command-palette--collect-recipe recipe (caddr recipe) '()))

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
      (else (message (string-append "No command or recipe named " choice))))))

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

