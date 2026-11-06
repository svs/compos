;;; recipes.scm --- task -> expression.
;;;
;;; apropos answers "what is this called". A recipe answers the question
;;; before that: "how do I do the thing". An agent that knows the editor
;;; has an API still has to compose three calls in the right order to open
;;; a file in a split, and getting that wrong costs a round-trip each time.
;;;
;;; These are the tasks agents actually perform. Keep them short enough to
;;; paste and true enough to run. Add yours with (defrecipe! ...).

(define *recipes* '())

(define (defrecipe! title expr &optional inputs)
  (set! *recipes*
    (append (remove (lambda (r) (equal? (car r) title)) *recipes*)
            (list (list title expr (or inputs '())))))
  (catalog-register! 'recipe title title
    'use expr 'props (or inputs '()))
  title)

(define (recipes) *recipes*)

;; recipes are searched FIRST: a task-level hit beats four name-level ones.
;;
;; The expression is searched too, so "http-text" finds the recipe that
;; runs it. That match is a weaker thing than a match on the task, and it
;; must not lead the answer: seven graphql recipes led "string", because
;; every one of them writes (string->symbol ...). A hit that only the
;; expression made says so, and the ranking puts it back with the rest.

;; the primer's tail: enough recipes to work from, not the whole book
(define (recipes-text)
  (string-append
    "RECIPES — task, then the expression:\n"
    (fold (lambda (acc r)
            (string-append acc "  " (string-pad-right (car r) 34) (cadr r) "\n"))
          ""
          (chat-take *recipes* 12))
    "  ...(apropos \"words\") finds the rest\n"))

;;; --- windows ------------------------------------------------------------------

(defrecipe! "open a file"
  "(run-command \"find-file\")")
(catalog-meta! 'recipe "open a file" 'domain 'files 'effects '(write display))
(defrecipe! "open a file in a split"
  "(let ((group (buffer-group (current-buffer)))) (split-window! 'h) (other-window!) (visit {{path}} group))"
  (list (list 'path "File: ")))
(catalog-meta! 'recipe "open a file in a split"
  'domain 'files 'effects '(write display))
(defrecipe! "split the window side by side"
  "(split-window! 'h 0.5)")
(catalog-meta! 'recipe "split the window side by side"
  'domain 'windows 'effects '(write display))
(defrecipe! "split the window above and below"
  "(split-window! 'v 0.5)")
(catalog-meta! 'recipe "split the window above and below"
  'domain 'windows 'effects '(write display))
(defrecipe! "one window again"
  "(delete-other-windows!)")
(catalog-meta! 'recipe "one window again" 'domain 'windows 'effects '(write display))
(defrecipe! "show a buffer in the other window"
  "(display-buffer-other-window! {{buffer}})"
  (list (list 'buffer "Buffer: ")))
(catalog-meta! 'recipe "show a buffer in the other window"
  'domain 'windows 'effects '(write display))
;; Keep the words people use for this action. Re-registering the old title
;; also corrects its previous-buffer mapping during a hot reload.
(defrecipe! "other buffer"
  "(display-buffer-other-window! {{buffer}})"
  (list (list 'buffer "Buffer: ")))
(catalog-meta! 'recipe "other buffer" 'domain 'windows 'effects '(write display))
(defrecipe! "switch to the previous buffer"
  "(run-command \"previous-buffer\")")
(catalog-meta! 'recipe "switch to the previous buffer"
  'domain 'buffers 'effects '(write display))

(defrecipe! "what windows are open"
  "(window-list-all)")

;;; --- buffers ------------------------------------------------------------------

(defrecipe! "list the open buffers"
  "(buffer-list)")
(defrecipe! "read a buffer"
  "(buffer-text {{buffer}})"
  (list (list 'buffer "Buffer: ")))
(defrecipe! "add text to the end of a buffer"
  "(buffer-append! {{buffer}} {{text}})"
  (list (list 'buffer "Buffer: ") (list 'text "Text: ")))
(defrecipe! "change text in a live buffer"
  "(buffer-replace! {{buffer}} {{old}} {{new}})"
  (list (list 'buffer "Buffer: ")
        (list 'old "Replace exact text: ")
        (list 'new "With: ")))
(defrecipe! "make a scratch buffer and show it"
  "(begin (buffer-create \"*notes*\") (switch-to-buffer! \"*notes*\"))")

(defrecipe! "kill a buffer"
  "(buffer-kill! {{buffer}})"
  '((buffer "Buffer: ")))
(catalog-meta! 'recipe "kill a buffer" 'domain 'buffers 'effects '(destroy))
(catalog-meta! 'recipe "make a scratch buffer and show it"
  'domain 'buffers 'effects '(write display))
(defrecipe! "save the current buffer"
  "(run-command \"save-buffer\")")
(defrecipe! "which buffer am I in"
  "(current-buffer)")
(defrecipe! "insert text where the cursor is"
  "(insert! {{text}})"
  (list (list 'text "Text: ")))
(catalog-meta! 'recipe "insert text where the cursor is"
  'domain 'editing 'effects '(write display))
(defrecipe! "go to the end of the buffer"
  "(end-of-buffer!)")
(catalog-meta! 'recipe "go to the end of the buffer"
  'domain 'editing 'effects '(write display))

;;; --- finding things -----------------------------------------------------------

(defrecipe! "find what a function is called"
  "(apropos {{query}})"
  (list (list 'query "Describe the operation: ")))
(defrecipe! "list one area of the API"
  "(apropos-category 'windows)")
(defrecipe! "read a function's real source"
  "(describe-function (string->symbol {{name}}))"
  (list (list 'name "Function: ")))
(defrecipe! "list every M-x command"
  "(command-names)")
(defrecipe! "what does this key do"
  "(key-for-command {{command}})"
  (list (list 'command "Command: ")))

;;; --- files and projects -------------------------------------------------------

(defrecipe! "open a directory"
  "(dired {{path}})"
  (list (list 'path "Directory: ")))
(defrecipe! "open a file over ssh"
  "(visit {{path}} (buffer-group (current-buffer)))"
  (list (list 'path "Remote path (/ssh:host:/path): ")))

;;; --- chat and agents ----------------------------------------------------------

(defrecipe! "start an agent on a task"
  "(execute {{task}})"
  (list (list 'task "Task: ")))
(defrecipe! "start an agent on a named connector"
  "(execute* {{task}} (list 'connector {{connector}}))"
  (list (list 'task "Task: ") (list 'connector "Connector: ")))
(defrecipe! "list the chats"
  "(run-command \"chat-list\")")
(defrecipe! "what has this chat cost"
  "(run-command \"chat-cost\")")
(defrecipe! "send a message to a running agent"
  "(llm-session-send! {{agent}} {{message}})"
  (list (list 'agent "Agent: ") (list 'message "Message: ")))

;;; --- appearance ---------------------------------------------------------------

(defrecipe! "change how something looks"
  "(customize-apropos {{query}})"
  (list (list 'query "Customize search: ")))
(defrecipe! "set a face colour"
  "(set-face-attribute! 'default 'fg {{colour}})"
  (list (list 'colour "Colour: ")))
(defrecipe! "load a theme"
  "(run-command \"load-theme\")")

;;; --- telling the user something -----------------------------------------------

(defrecipe! "show a message in the echo area"
  "(message {{text}})"
  (list (list 'text "Message: ")))
(defrecipe! "run any M-x command"
  "(run-command {{command}})"
  (list (list 'command "M-x command: ")))

;;; --- the words people use -----------------------------------------------------
;;
;; A title is one phrasing of a task; a directive arrives in another. Search
;; wants every word of the query to appear somewhere in the entry, so "show
;; it beside this" only reaches the other-window recipe if "beside" is
;; written down. Synonyms live here rather than bloating the titles.

(define (recipe-aliases! title words)
  (catalog-meta! 'recipe title 'aliases words))

(recipe-aliases! "load a theme"
  "apply theme switch theme choose theme select theme change theme theme appearance colours colors")

(recipe-aliases! "show a buffer in the other window"
  "beside side by side next pane other pane second window adjacent over there elsewhere alongside right left split view without switching keep focus display show put open preview")
(recipe-aliases! "other buffer"
  "beside next pane over there elsewhere other window second window show display open")
(recipe-aliases! "open a file"
  "visit load find edit open file path here same window")
(recipe-aliases! "open a file in a split"
  "split open show file beside new pane side by side two windows")
(recipe-aliases! "split the window side by side"
  "vertical split two panes horizontally beside side by side divide")
(recipe-aliases! "split the window above and below"
  "horizontal split stacked top bottom above below divide")
(recipe-aliases! "one window again"
  "unsplit single only window full screen maximize maximise maximize buffer maximize this buffer close other windows delete others")
(recipe-aliases! "switch to the previous buffer"
  "back last previous buffer toggle switch return")
(recipe-aliases! "what windows are open"
  "windows panes layout frame list open")
(recipe-aliases! "list the open buffers"
  "buffers list open what files")
(recipe-aliases! "read a buffer"
  "read contents text show content whole file")
(recipe-aliases! "save the current buffer"
  "save write file to disk")
(recipe-aliases! "make a scratch buffer and show it"
  "new empty buffer notes create")
(recipe-aliases! "open a directory"
  "directory folder dired browse files listing")

(category! 'discovery)
(public! 'recipes "(recipes) — every task -> expression recipe")
(public! 'recipe-aliases!
  "(recipe-aliases! \"task\" \"words people use\") — extra search vocabulary for a recipe")
(public! 'defrecipe!
  "(defrecipe! \"task\" \"expression\" [INPUTS]) — add a recipe; INPUTS are (name prompt) rows substituted into {{name}} safely")

(recipe-aliases! "kill a buffer"
  "kill close delete remove discard buffer")

;;; Patterns: the words that ask for a recipe, with its arguments in them.
;;; "dired {{path}}" reads "dired src" as the recipe "open a directory" with
;;; path "src": the literal words are the command, and each {{slot}}
;;; takes the words between them. The palette reads what you type this way,
;;; so a recipe runs with its arguments and asks for none.

(domain! 'discovery)
(effects! '(write))

;; ((TITLE (PATTERN ...)) ...)
(define *recipe-patterns* '())

(define (recipe-patterns! title patterns)
  (set! *recipe-patterns* (alist-put *recipe-patterns* title patterns))
  title)

(effects! '(read))

(define (recipe--words s)
  (remove (lambda (w) (equal? w "")) (string-split (string-trim s) " ")))

;; "{{path}}" -> path; a literal word -> #f
(define (recipe--slot word)
  (and (> (string-length word) 4)
       (string-prefix? "{{" word)
       (string-suffix? "}}" word)
       (string->symbol (substring word 2 (- (string-length word) 2)))))

;; ((SLOT VALUE) ...) when WORDS read as PATTERN, else #f. A slot takes the
;; fewest words that let the rest match, so the last one takes what is left.
(define (recipe--match-words pattern words)
  (cond
    ((null? pattern) (and (null? words) '()))
    ((recipe--slot (car pattern))
     (let ((slot (recipe--slot (car pattern))))
       (let loop ((n 1))
         (and (<= n (length words))
              (let ((rest (recipe--match-words (cdr pattern) (list-tail words n))))
                (if rest
                    (cons (list slot (string-join (take words n) " ")) rest)
                    (loop (+ n 1))))))))
    ((and (pair? words)
          (equal? (string-downcase (car pattern)) (string-downcase (car words))))
     (recipe--match-words (cdr pattern) (cdr words)))
    (else #f)))

;; (TITLE BINDINGS) for the pattern that reads TEXT, else #f. The pattern
;; with the most literal words wins; a pattern of slots alone reads nothing.
;; A pattern that opens with a slot reads the end of the words, with the
;; shortest argument that fits: in "switch to 2 column layout" the words
;; before "2" are the asking, not the argument.
(define (recipe--match-tail pattern words)
  (if (and (pair? pattern) (recipe--slot (car pattern)))
      (let loop ((k (- (length words) 1)))
        (and (>= k 0)
             (or (recipe--match-words pattern (list-tail words k))
                 (loop (- k 1)))))
      (recipe--match-words pattern words)))

(define (recipe-match text)
  (let ((words (recipe--words text)))
    (cadr
      (fold (lambda (best row)
              (fold (lambda (best p)
                      (let* ((pw (recipe--words p))
                             (n (length (remove recipe--slot pw)))
                             (b (and (> n (car best))
                                     (assoc (car row) *recipes*)
                                     (recipe--match-tail pw words))))
                        (if b (list n (list (car row) b)) best)))
                    best
                    (cadr row)))
            (list 0 #f)
            *recipe-patterns*))))

;;; The recipes you asked for: the *recipes* chat writes them into
;;; <compos-home>/recipes.scm, a Scheme file you can read and edit. Each
;;; recipe is one block under its marker line, so learning one again leaves
;;; the others, and your edits to them, as they are.

(define (recipes-user-path) (string-append (compos-home) "/recipes.scm"))

(define recipes--marker "\n;;; recipe: ")

(define recipes--header
  ";;; recipes.scm --- the recipes the *recipes* chat learned for you.\n;;; Each block is a defrecipe! and its recipe-patterns!. Edit them freely.\n")

(define (recipe--block title expr inputs patterns)
  (string-append
    title "\n"
    "(defrecipe! " (value->string title) "\n  " (value->string expr)
    (if (null? inputs) "" (string-append "\n  '" (value->string inputs)))
    ")\n"
    (if (null? patterns)
        ""
        (string-append "(recipe-patterns! " (value->string title)
                       "\n  '" (value->string patterns) ")\n"))))

(effects! '(write))

(define (recipe-learn! title expr &optional inputs patterns)
  (let* ((inputs (or inputs '()))
         (patterns (or patterns '()))
         (path (recipes-user-path))
         (old (if (file-exists? path) (read-file path) recipes--header))
         (parts (string-split old recipes--marker))
         (kept (remove (lambda (b) (string-prefix? (string-append title "\n") b))
                       (cdr parts)))
         (entry (catalog-entry 'recipe title))
         (aliases (or (and entry (catalog--get entry 'aliases)) "")))
    (defrecipe! title expr inputs)
    (recipe-patterns! title patterns)
    ;; the words of the patterns find the recipe in a search, too
    (recipe-aliases! title
      (string-join (cons aliases (map (lambda (p) (string-join (remove recipe--slot (recipe--words p)) " "))
                                      patterns))
                   " "))
    (write-file! path
      (string-append (car parts)
                     (string-join (map (lambda (b) (string-append recipes--marker b))
                                       (append kept (list (recipe--block title expr inputs patterns))))
                                  "")))
    title))

(effects! '(write execute))
(define (recipes-commands-path) (string-append (compos-home) "/commands.scm"))

(define recipes--command-marker "\n;;; command: ")

(define recipes--commands-header
  ";;; commands.scm --- the commands the *recipes* chat wrote for you.\n;;; Each block is one define-command. Edit them freely.\n(effects! '(unknown))\n")

;; Define the M-x command NAME, which runs the procedure SOURCE (Scheme text,
;; as "(lambda () ...)"), with WORDS as its apropos aliases, and keep it in <compos-home>/commands.scm: a
;; request no command does gets a command, and a recipe runs it after.
(define (command-learn! name doc source &optional words)
  (let* ((path (recipes-commands-path))
         (old (if (file-exists? path) (read-file path) recipes--commands-header))
         (parts (string-split old recipes--command-marker))
         (kept (remove (lambda (b) (string-prefix? (string-append name "\n") b)) (cdr parts)))
         ;; the words someone asked with are aliases, so apropos finds it by them
         (form (string-append "(define-command " (value->string name) " " (value->string doc)
                              "\n  " source ")\n"
                              (if (and words (not (equal? words "")))
                                  (string-append "(catalog-meta! 'command " (value->string name)
                                                 " 'aliases " (value->string words) ")\n")
                                  "")))
         (result (eval-string-safe form)))
    (if (not (equal? (car result) 'ok))
        (list 'error (value->string (cadr result)))
        (begin
          (write-file! path
            (string-append (car parts)
              (string-join (map (lambda (b) (string-append recipes--command-marker b))
                                (append kept (list (string-append name "\n" form))))
                           "")))
          name))))

(effects! '(destroy))
;; Drop a recipe: from the book, its patterns, apropos and your file.
(define (recipe-forget! title)
  (let ((path (recipes-user-path)))
    (set! *recipes* (remove (lambda (r) (equal? (car r) title)) *recipes*))
    (set! *recipe-patterns* (remove (lambda (r) (equal? (car r) title)) *recipe-patterns*))
    (set! *catalog* (remove-plists *catalog* 'kind "recipe" 'name title))
    (set! *catalog-keys* (remove (lambda (k) (equal? k (string-append "recipe:" title))) *catalog-keys*))
    (catalog--touch!)
    (when (file-exists? path)
      (let ((parts (string-split (read-file path) recipes--marker)))
        (write-file! path
          (string-append (car parts)
            (string-join (map (lambda (b) (string-append recipes--marker b))
                              (remove (lambda (b) (string-prefix? (string-append title "\n") b))
                                      (cdr parts)))
                         "")))))
    title))

(effects! '(write))
(define (recipes-load-user!)
  ;; the commands first: a recipe may run one
  (for-each (lambda (path)
              (when (file-exists? path)
                (ignore-errors (lambda () (load path)))))
            (list (recipes-commands-path) (recipes-user-path))))

(public! 'recipe-patterns!
  "(recipe-patterns! \"task\" '(\"open {{path}}\" ...)) -- the words that ask for a recipe; literal words are the command, each {{slot}} an argument")
(public! 'recipe-match
  "(recipe-match \"open notes.md\") -- (TITLE ((SLOT VALUE) ...)) for the pattern that reads the words, else #f")
(public! 'recipe-learn!
  "(recipe-learn! TITLE EXPR [INPUTS PATTERNS]) -- define a recipe and save it to <compos-home>/recipes.scm")
(public! 'recipe-forget!
  "(recipe-forget! TITLE) -- drop a recipe from the book, apropos and <compos-home>/recipes.scm")
(public! 'command-learn!
  "(command-learn! NAME DOC \"(lambda () ...)\" [WORDS]) -- define an M-x command, found by WORDS, and keep it in <compos-home>/commands.scm")
(public! 'recipes-user-path "(recipes-user-path) -- the file of the recipes you learned")

(recipe-patterns! "open a directory"
  '("dired {{path}}" "open directory {{path}}" "open folder {{path}}"))
(recipe-patterns! "kill a buffer"
  '("kill {{buffer}}" "kill buffer {{buffer}}" "close {{buffer}}"))
(recipe-patterns! "show a buffer in the other window"
  '("show {{buffer}}" "show {{buffer}} in the other window"))

;; the recipes you learned come last, so one of yours replaces a recipe here
(recipes-load-user!)
