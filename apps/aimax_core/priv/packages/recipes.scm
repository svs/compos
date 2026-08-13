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

(define (defrecipe! title expr)
  (set! *recipes*
    (append (remove (lambda (r) (equal? (car r) title)) *recipes*)
            (list (list title expr))))
  title)

(define (recipes) *recipes*)

;; recipes are searched FIRST: a task-level hit beats four name-level ones
(define (recipe-search query)
  (let ((words (apropos--words query)))
    (map (lambda (r) (list 'kind "recipe" 'task (car r) 'run (cadr r)))
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
  "(visit \"/abs/path\")")
(defrecipe! "open a file in a split"
  "(begin (split-window! 'h) (other-window!) (visit \"/abs/path\"))")
(defrecipe! "split the window side by side"
  "(split-window! 'h 0.5)")
(defrecipe! "split the window above and below"
  "(split-window! 'v 0.5)")
(defrecipe! "one window again"
  "(delete-other-windows!)")
(defrecipe! "show a buffer in the other window"
  "(display-buffer-other-window! \"NAME\")")
(defrecipe! "what windows are open"
  "(window-list-all)")

;;; --- buffers ------------------------------------------------------------------

(defrecipe! "list the open buffers"
  "(buffer-list)")
(defrecipe! "read a buffer"
  "(buffer-text \"NAME\")")
(defrecipe! "add text to the end of a buffer"
  "(buffer-append! \"NAME\" \"text\\n\")")
(defrecipe! "change text in a live buffer"
  "(buffer-replace! \"NAME\" \"old exact unique\" \"new\")")
(defrecipe! "make a scratch buffer and show it"
  "(begin (buffer-create \"*notes*\") (switch-to-buffer! \"*notes*\"))")
(defrecipe! "save the current buffer"
  "(run-command \"save-buffer\")")
(defrecipe! "which buffer am I in"
  "(current-buffer)")
(defrecipe! "insert text where the cursor is"
  "(insert! \"text\")")
(defrecipe! "go to the end of the buffer"
  "(end-of-buffer!)")

;;; --- finding things -----------------------------------------------------------

(defrecipe! "find what a function is called"
  "(apropos \"words describing it\")")
(defrecipe! "list one area of the API"
  "(apropos-category 'windows)")
(defrecipe! "read a function's real source"
  "(describe-function 'name)")
(defrecipe! "list every M-x command"
  "(command-names)")
(defrecipe! "what does this key do"
  "(key-for-command \"find-file\")")

;;; --- files and projects -------------------------------------------------------

(defrecipe! "open a directory"
  "(dired \"/abs/path\")")
(defrecipe! "open a file over ssh"
  "(visit \"/ssh:host:/abs/path\")")

;;; --- chat and agents ----------------------------------------------------------

(defrecipe! "start an agent on a task"
  "(execute \"the task\")")
(defrecipe! "start an agent on a named connector"
  "(execute* \"the task\" '(connector \"api\"))")
(defrecipe! "list the chats"
  "(run-command \"chat-list\")")
(defrecipe! "what has this chat cost"
  "(run-command \"chat-cost\")")
(defrecipe! "send a message to a running agent"
  "(agent-prompt! \"a1\" \"the message\")")

;;; --- appearance ---------------------------------------------------------------

(defrecipe! "change how something looks"
  "(customize-apropos \"font\") then (customize-save! 'name value)")
(defrecipe! "set a face colour"
  "(set-face-attribute! 'default 'fg \"#d6d8de\")")
(defrecipe! "load a theme"
  "(load-theme! \"paper\")")

;;; --- telling the user something -----------------------------------------------

(defrecipe! "show a message in the echo area"
  "(message \"text\")")
(defrecipe! "run any M-x command"
  "(run-command \"command-name\")")

(category! 'discovery)
(public! 'recipes "(recipes) — every task -> expression recipe")
(public! 'defrecipe! "(defrecipe! \"task\" \"expression\") — add a recipe")
