;;; palette-eval.scm --- score what the palette runs for the words you type.
;;;
;;; (palette-eval) puts every scenario through command-palette-resolve, the
;;; same resolver RET uses, without running anything and without the words
;;; you ran before. It writes the table to *palette-eval*, says the score in
;;; the echo area, and sends it as the event palette-eval done. A scenario is
;;; (WORDS EXPECTED [BINDINGS]): EXPECTED is a command or recipe name, a list
;;; of the names that would do, or #f when nothing should run.

(domain! 'interaction)
(effects! '(read external spend))

(define *palette-scenarios*
  '(;; windows and layout
    ("close this window" ("delete-window"))
    ("clsoe this windwo" ("delete-window"))
    ("only this window" ("delete-other-windows"))
    ("make this the only window" ("delete-other-windows"))
    ("split the window side by side" ("split-window-right" "split the window side by side"))
    ("split vertically" ("split-window-right" "split-window-below"))
    ("split the window top and bottom" ("split-window-below"))
    ("go to the other window" ("other-window"))
    ("switch window" ("other-window"))
    ("change the layout" ("window-layout"))
    ("pick a layout" ("window-layout"))
    ("3 column layout" "show the windows in N columns" ((count "3")))
    ("3 columns layout" "show the windows in N columns" ((count "3")))
    ("swtich to 3 colums" "show the windows in N columns" ((count "3")))
    ("two columns please" "show the windows in N columns" ((count "2")))
    ("show four columns" "show the windows in N columns" ((count "4")))
    ("hide the last column" "hide the last column")
    ("get rid of the rightmost column" "hide the last column")
    ("hide column 2" "hide a numbered column" ((col "2")))
    ("undo the layout change" ("layout-undo" "winner-undo"))
    ("put the windows back how they were" ("winner-undo" "layout-undo"))
    ("reset the layout" ("reset-layout"))
    ;; buffers
    ("list all buffers" ("ibuffer"))
    ("list al bufers" ("ibuffer"))
    ("show me the open buffers" ("ibuffer"))
    ("switch buffer" ("switch-to-buffer"))
    ("go to another buffer" ("switch-to-buffer"))
    ("previous buffer" ("previous-buffer"))
    ("go back to the last buffer" ("previous-buffer"))
    ("next buffer" ("next-buffer"))
    ("close this buffer" ("kill-buffer"))
    ("kill buffer" ("kill-buffer"))
    ("rename this buffer" ("buffer-rename"))
    ("new scratch buffer" ("scratch-new"))
    ("reload the file from disk" ("revert-buffer"))
    ("make the buffer read only" ("read-only-mode"))
    ;; files
    ("open a file" ("find-file" "open a file"))
    ("opne a fiel" ("find-file"))
    ("open file in the other window" ("find-file-other-window"))
    ("save" ("save-buffer"))
    ("save the file" ("save-buffer"))
    ("svae this" ("save-buffer"))
    ("save as" ("write-file"))
    ("open the folder" ("dired"))
    ("browse the directory" ("dired"))
    ("find a file in the project" ("project-find-file"))
    ("search the project" ("project-ripgrep"))
    ("grep the codebase" ("project-ripgrep"))
    ;; editing and search
    ("search forward" ("isearch-forward"))
    ("find text in this buffer" ("isearch-forward"))
    ("search backwards" ("isearch-backward"))
    ("replace text" ("query-replace" "replace-string"))
    ("find and replace" ("query-replace" "replace-string"))
    ("go to line" ("goto-line"))
    ("jump to line 40" ("goto-line"))
    ("go to the top" ("beginning-of-buffer"))
    ("go to the end of the file" ("end-of-buffer"))
    ("undo" ("undo"))
    ("undo that" ("undo"))
    ("paste" ("yank"))
    ("count the words" ("count-words"))
    ("wrap long lines" ("visual-line-mode"))
    ("show line numbers" ("display-line-numbers-mode"))
    ("show whitespace" ("whitespace-mode"))
    ("jump to a definition in this file" ("imenu"))
    ;; appearance
    ("make the text bigger" ("text-scale-increase" "ui-scale-increase"))
    ("zoom in" ("text-scale-increase" "ui-scale-increase"))
    ("make text smaller" ("text-scale-decrease" "ui-scale-decrease"))
    ("reset the zoom" ("text-scale-reset" "ui-scale-reset"))
    ("use a dark theme" "use a {{theme}} theme" ((theme "dark")))
    ("dark mode" "use a {{theme}} theme" ((theme "dark")))
    ("use a ligth theme" "use a {{theme}} theme" ((theme "light")))
    ("switch to the tokyo-night theme" "use a {{theme}} theme" ((theme "tokyo-night")))
    ("change the theme" ("load-theme" "use a {{theme}} theme"))
    ;; help
    ("what does this key do" ("describe-key" "what does this key do"))
    ("describe a variable" ("describe-variable"))
    ("what mode am I in" ("describe-mode"))
    ("show all key bindings" ("describe-bindings"))
    ("search the docs" ("apropos"))
    ("find a command by what it does" ("apropos" "command-palette"))
    ("open the tutorial" ("help-with-tutorial"))
    ("show the messages log" ("view-messages"))
    ("change a setting" ("customize"))
    ;; apps and chats
    ("show me my mail" ("mail"))
    ("check my email" ("mail"))
    ("start a new chat" ("chat-new"))
    ("list the chats" ("chat-list" "list the chats"))
    ("how much has this chat cost" ("chat-cost"))
    ("change the chat model" ("chat-set-model"))
    ("configure the llm" ("llm-configure"))
    ("my todo list" ("todo"))
    ("open the agenda" ("morg-agenda"))
    ("play some music" ("spotify"))
    ("open a shell" ("shell"))
    ("open a terminal" ("shell"))
    ("evaluate an expression" ("eval-expression"))
    ("switch group" ("group-switch"))
    ("make a new group" ("group-new"))
    ("restart the editor" ("restart-daemon"))
    ;; nothing should run
    ("order a pizza" #f)
    ("what is the capital of france" #f)
    ("asdf qwer" #f)))

(define (palette-eval--ok? expected got)
  (let ((want (car expected)) (bindings (if (pair? (cdr expected)) (cadr expected) #f)))
    (cond ((not want) (not got))
          ((not got) #f)
          (else (and (if (pair? want) (member (cadr got) want) (equal? (cadr got) want))
                     (or (not bindings)
                         (every (lambda (b) (equal? (assoc (car b) (caddr got)) b)) bindings))
                     #t)))))

(define (palette-eval--row s)
  (let* ((t0 (monotonic-ms))
         (got (app-await (lambda (k) (command-palette-resolve (car s) (palette-eval--buffer) k #t))))
         (ms (- (monotonic-ms) t0)))
    (list (car s) (cdr s) got ms (palette-eval--ok? (cdr s) got))))

;; the buffer the scenarios run in: a plain one, so no mode's commands lead
(define (palette-eval--buffer) "*scratch*")

(define (palette-eval--text rows)
  (let* ((ok (length (filter (lambda (r) (list-ref r 4)) rows)))
         (ms (map (lambda (r) (list-ref r 3)) rows))
         (avg (if (null? ms) 0 (quotient (apply + ms) (length ms)))))
    (string-append
      "palette-eval: " (number->string ok) "/" (number->string (length rows))
      " right, " (number->string avg) " ms on average, picker "
      (symbol->string command-palette-decide-backend) "\n\n"
      (string-join
        (map (lambda (r)
               (let ((got (list-ref r 2)))
                 (string-append (if (list-ref r 4) "ok    " "MISS  ")
                   (string-pad-right (car r) 36) " "
                   (string-pad-right (if got (symbol->string (list-ref got 3)) "-") 10) " "
                   (string-pad-right (if got (string-append (cadr got)
                                                            (if (null? (caddr got)) "" (string-append " " (value->string (caddr got)))))
                                         "none") 44)
                   (if (list-ref r 4) "" (string-append " want " (value->string (car (cadr r)))
                                                          (if (pair? (cdr (cadr r))) (string-append " " (value->string (cadr (cadr r)))) "")))
                   "  " (number->string (list-ref r 3)) " ms")))
             rows)
        "\n")
      "\n")))

;; Run the scenarios one after another, in a task: four at once made JEV and
;; the semantic pass time out. The table lands in
;; *palette-eval*; the score goes to the echo area and the event
;; palette-eval done. SCENARIOS defaults to *palette-scenarios*.
(define (palette-eval &optional scenarios)
  (task-run!
    (lambda () (map palette-eval--row (or scenarios *palette-scenarios*)))
    (lambda (ok? rows)
      (if (not ok?)
          (message (string-append "palette-eval failed: " (value->string rows)))
          (let ((text (palette-eval--text rows)))
            (unless (buffer-known? "*palette-eval*") (buffer-create "*palette-eval*"))
            (buffer-set-text! "*palette-eval*" text)
            (message (car (string-split text "\n")))
            (event-publish! "palette-eval" 'done (car (string-split text "\n"))))))))

(public! 'palette-eval
  "(palette-eval [SCENARIOS]) -- score what the palette would run for each scenario, without running it; the table goes to *palette-eval*")
