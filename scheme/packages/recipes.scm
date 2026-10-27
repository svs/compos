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
  "(visit {{path}} (buffer-group (current-buffer)))"
  (list (list 'path "File: ")))
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
