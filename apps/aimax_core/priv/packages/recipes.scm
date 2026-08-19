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

;; recipes are searched FIRST: a task-level hit beats four name-level ones
(define (recipe-search query)
  (let ((words (apropos--words query)))
    (map (lambda (r)
           (apropos--enrich
             (list 'kind "recipe" 'task (car r) 'name (car r)
                   'run (cadr r) 'inputs (caddr r))
             "recipe"))
         (filter (lambda (r) (apropos--hit? (string-append (car r) " " (cadr r)) words))
                 *recipes*))))

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
  "(visit {{path}})"
  (list (list 'path "File: ")))
(defrecipe! "open a file in a split"
  "(begin (split-window! 'h) (other-window!) (visit {{path}}))"
  (list (list 'path "File: ")))
(defrecipe! "split the window side by side"
  "(split-window! 'h 0.5)")
(defrecipe! "split the window above and below"
  "(split-window! 'v 0.5)")
(defrecipe! "one window again"
  "(delete-other-windows!)")
(defrecipe! "show a buffer in the other window"
  "(display-buffer-other-window! {{buffer}})"
  (list (list 'buffer "Buffer: ")))
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
(defrecipe! "save the current buffer"
  "(run-command \"save-buffer\")")
(defrecipe! "which buffer am I in"
  "(current-buffer)")
(defrecipe! "insert text where the cursor is"
  "(insert! {{text}})"
  (list (list 'text "Text: ")))
(defrecipe! "go to the end of the buffer"
  "(end-of-buffer!)")

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
  "(visit {{path}})"
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
  "(load-theme! {{theme}})"
  (list (list 'theme "Theme: ")))

;;; --- telling the user something -----------------------------------------------

(defrecipe! "show a message in the echo area"
  "(message {{text}})"
  (list (list 'text "Message: ")))
(defrecipe! "run any M-x command"
  "(run-command {{command}})"
  (list (list 'command "M-x command: ")))

(category! 'discovery)
(public! 'recipes "(recipes) — every task -> expression recipe")
(public! 'defrecipe!
  "(defrecipe! \"task\" \"expression\" [INPUTS]) — add a recipe; INPUTS are (name prompt) rows substituted into {{name}} safely")
