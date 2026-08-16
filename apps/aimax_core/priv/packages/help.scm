;;; help.scm --- every help page is a document: markdown, rendered, read-only.
;;;
;;; The house rule: help is never a wall of plain text in a scratch
;;; buffer. A help page is markdown (or html), it opens in *Help* with the
;;; renderer on, and the buffer is read-only — a page you read, not a
;;; buffer you edit. `q` closes it. `C-c C-v` shows the markdown source.
;;;
;;; The mechanism is help-doc!. Anything that can build a markdown string
;;; gets a rendered page for free, so a new help command writes text, not
;;; window code.
;;;
;;;   ? in any list (ibuffer, dired, *chats*, mcp-hub, notmuch)
;;;   M-?     contextual-help    — the name at point, this buffer, its keys
;;;   C-h m   describe-mode      — this buffer's mode and its keys
;;;   C-h b   describe-bindings  — every binding, local first
;;;   C-h a   apropos            — search the editor by words

(define *help-buffer* "*Help*")
;; A help page is a popup: it floats over the right of the frame instead
;; of taking the work's space. `<down>` and `C-v` scroll the page when it
;; has focus, `M-<down>` scrolls it from the other window, and `C-M-\``
;; turns it into an ordinary window when you want to keep it.
(add-display-rule! *help-buffer* 'popup)

;;; --- the mechanism -------------------------------------------------------------

;; markdown in a table cell: "|" ends the cell and "*" starts an italic,
;; and docstrings contain both ("the *ibuffer* listing"). A newline ends
;; the ROW, so a multi-line docstring becomes one line here.
(define (help--cell s)
  (string-join
    (string-split
      (string-join (string-split (string-join (string-split s "|") "\\|") "*") "\\*")
      "\n")
    " "))

;; TITLE names the page in the modeline; MARKDOWN is the page.
(define (help-doc! title markdown)
  (let ((from (active-window)))
    (buffer-create *help-buffer*)
    (buffer-set-read-only! *help-buffer* #f)
    (buffer-delete-range! *help-buffer* 0 (buffer-size *help-buffer*))
    (buffer-append! *help-buffer* markdown)
    (buffer-set-local! *help-buffer* 'help-title title)
    (display-buffer *help-buffer*)
    ;; select the popup the display rule opened, the way ibuffer does
    (let ((w (window-showing-other *help-buffer* from)))
      (if w (select-window! w) (switch-to-buffer! *help-buffer*)))
    (set-mode! "help-mode")
    (goto-char! 0)
    *help-buffer*))

;; A real mode, so a restored *Help* comes back rendered and read-only
;; instead of showing its own markdown source.
(define-mode "help-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      ;; the buffer has no ".md" to read a renderer from — it says so
      (buffer-set-local! buf 'preview-renderer "markdown")
      (buffer-set-local! buf 'render-mode "markdown")
      (buffer-set-read-only! buf #t)
      (local-set-key* buf "q" "quit-window"))))

(mode-doc! "help-mode"
  "A help page: markdown, rendered. `q` closes it, `C-c C-v` shows the source.")

;;; --- the pages -----------------------------------------------------------------

(define (help--key-rows keys)
  (map (lambda (r)
         (string-append "| `" (car r) "` | " (cadr r) " | "
                        (help--cell (command-doc (cadr r))) " |"))
       (sort keys)))

(define (help--key-table title keys empty)
  (if (null? keys)
      (string-append "## " title "\n\n" empty "\n")
      (string-append "## " title "\n\n"
                     "| key | command | what it does |\n"
                     "| --- | --- | --- |\n"
                     (string-join (help--key-rows keys) "\n")
                     "\n")))

(define (help--minor-modes buf)
  (let ((ms (or (buffer-local buf 'minor-modes) '())))
    (if (null? ms) "" (string-append "\nMinor modes: `" (string-join ms "` · `") "`\n"))))

;; each minor mode gets its say, the way the major mode does — the
;; name-only list answered "which" but never "so what"
(define (help--minor-sections buf)
  (let ((ms (or (buffer-local buf 'minor-modes) '())))
    (if (null? ms)
        ""
        (string-join
          (map (lambda (m)
                 (string-append
                   "## " m " (minor)\n\n"
                   (or (mode-doc m)
                       "No description. Its keys are in the table below.")
                   "\n\n"))
               ms)
          ""))))

;; the buffer's group, with what the group knows about itself
(define (help--group-line buf)
  (let ((g (buffer-group buf)))
    (if (not g)
        ""
        (string-append
          "\nGroup: `" (group-label g) "` — "
          (number->string (length (group-buffers g))) " buffers, companion "
          (group-noise g)
          (let ((m (group-meta g))) (if m (string-append ". " m) "."))
          "\n"))))

(define (help--mode-markdown buf mode)
  (let ((doc (mode-doc mode)))
    (string-append
      "# " mode "\n\n"
      (if doc (string-append doc "\n\n") "")
      "Buffer `" buf "`."
      (if (buffer-read-only? buf) " Read-only." "")
      "\n"
      (help--minor-modes buf)
      "\n"
      (help--minor-sections buf)
      (help--key-table "Keys in this buffer" (local-keys buf)
                       "This buffer adds no keys of its own.")
      "\n---\n\n"
      "`C-h b` lists every binding · `M-x` searches every command "
      "· `q` closes this page\n")))

(define-command "describe-mode" "Show this buffer's mode, its keys and what they do"
  (lambda ()
    ;; read the buffer BEFORE the page opens: from inside *Help*, the
    ;; question is still about the buffer the reader came from
    (let* ((buf (if (equal? (current-buffer) *help-buffer*)
                    (or (buffer-local *help-buffer* 'help-from) (current-buffer))
                    (current-buffer)))
           (mode (or (buffer-local buf 'mode-name) "fundamental-mode")))
      (help-doc! mode (help--mode-markdown buf mode))
      (buffer-set-local! *help-buffer* 'help-from buf))))

(define-command "describe-bindings" "Show every key binding, this buffer's first"
  (lambda ()
    (let* ((buf (current-buffer))
           (mode (or (buffer-local buf 'mode-name) "fundamental-mode")))
      (help-doc! "bindings"
        (string-append
          "# Key bindings\n\n"
          "Buffer `" buf "`, mode `" mode "`. A local key wins over a global one.\n\n"
          (help--key-table "This buffer" (local-keys buf)
                           "This buffer adds no keys of its own.")
          "\n"
          (help--key-table "Everywhere" (global-keys) "None.")
          "\n---\n\n"
          "`C-h m` describes this mode · `q` closes this page\n")))))

;;; --- apropos: the agent's search, for the reader -------------------------------
;;; apropos was Scheme only — a function and an LLM tool with no way in from
;;; the keyboard, so `M-x` listed every command except the one that finds
;;; commands. The page shows the same rows the agent reads: recipes first,
;;; then public functions, M-x commands, keybindings and settings.

(define (help--apropos-row h)
  (let ((kind (plist-get h 'kind))
        (doc (or (plist-get h 'doc) "")))
    (cond
      ((equal? kind "recipe")
       (list "recipe" (plist-get h 'task) (plist-get h 'run) ""))
      ((equal? kind "command")
       (list "command" (plist-get h 'name)
             (let ((k (plist-get h 'key))) (if k k "M-x")) doc))
      ((equal? kind "key")
       (list "key" (plist-get h 'name) (plist-get h 'runs)
             (command-doc (plist-get h 'runs))))
      ((equal? kind "variable") (list "setting" (plist-get h 'name) "" doc))
      ((equal? kind "component")
       (list "component" (plist-get h 'qualified-name)
             (or (plist-get h 'use) "") doc))
      ((equal? kind "mode")
       (list "mode" (plist-get h 'name) (or (plist-get h 'use) "") doc))
      ;; a query that matched nothing comes back as the closest names
      (else (list (if (plist-get h 'note) "closest" "function")
                  (plist-get h 'name) (or (plist-get h 'sig) "") doc)))))

(define (help--code s)
  (if (equal? s "") "" (string-append "`" (help--cell s) "`")))

(define (help--apropos-table hits)
  (string-append
    "| kind | name | call it | owner | effects | what it does |\n"
    "| --- | --- | --- | --- | --- | --- |\n"
    (string-join
      (map (lambda (h)
             (let ((r (help--apropos-row h)))
               (string-append "| " (nth 0 r) " | " (help--code (nth 1 r))
                              " | " (help--code (nth 2 r))
                              " | " (help--cell (or (plist-get h 'package) "core"))
                              " | " (help--cell
                                       (string-join (or (plist-get h 'effects) '()) ", "))
                              " | " (help--cell (nth 3 r)) " |")))
           hits)
      "\n")
    "\n"))

(define (apropos-page query &optional filters)
  (let ((hits (apply apropos (cons query (or filters '())))))
    (help-doc! (string-append "apropos " query)
      (string-append
        "# apropos `" query "`\n\n"
        (if (null? hits)
            "Nothing matched, and no name is close.\n"
            (string-append (number->string (length hits)) " hits.\n\n"
                           (help--apropos-table hits)))
        "\n---\n\n"
        "`C-h b` lists every binding · `M-x` runs a command by name "
        "· `q` closes this page\n"))))

(define-command "apropos"
  "Search the whole editor by words: functions, commands, keys and settings"
  (lambda ()
    (minibuffer-read "Apropos (words): " (history-items 'apropos)
      (lambda (query)
        (history-push! 'apropos query)
        (apropos-page query)))))

;;; --- contextual help: what is here, right now ----------------------------------
;;; `M-?` answers one question: "what am I looking at, and what can I do
;;; here?". The page reads the editor, not a manual. It describes the name
;;; under the cursor first, then this buffer, its mode and its keys. A name
;;; that matches no command and no function falls back to the apropos hits
;;; for the same word, so the key still answers over prose.

;; the help alphabet: the code alphabet plus `*`, so a point on a Scheme
;; global like `*mode-docs*` reads the whole name and finds it
(define *help-symbol-chars* (string-append *symbol-chars* "*"))

(define (help--symbol-at) (symbol-at-point-in *help-symbol-chars*))

(define (help--api-entry name)
  (let loop ((es (public-api)))
    (cond ((null? es) #f)
          ((equal? (car (car es)) name) (car es))
          (else (loop (cdr es))))))

(define (help--take xs n)
  (if (or (null? xs) (= n 0)) '() (cons (car xs) (help--take (cdr xs) (- n 1)))))

(define (help--command-section name)
  (let ((k (key-for-command name)))
    (string-append
      "## `" name "` — a command\n\n"
      (help--cell (command-doc name)) "\n\n"
      (if (equal? k "")
          (string-append "Run it with `M-x " name "`.\n\n")
          (string-append "Bound to `" k "`. `M-x " name "` runs it too.\n\n")))))

(define (help--function-section e)
  (string-append
    "## `" (car e) "` — a function\n\n"
    "`" (help--cell (nth 2 e)) "`\n\n"
    (help--cell (nth 1 e)) "\n\n"))

(define (help--mode-section name doc)
  (string-append "## `" name "` — a mode\n\n" doc "\n\n"
                 "`M-x " name "` turns it on in this buffer.\n\n"))

;; A word that matches nothing is prose, not a name — most words in a diff
;; or a mail are. The page says nothing about it and goes straight to the
;; buffer, instead of opening with a heading that reports a dead end.
(define (help--apropos-section name)
  (let ((hits (help--take (apropos name) 8)))
    (if (null? hits)
        ""
        (string-append "## `" name "` — the closest matches\n\n"
                       (help--apropos-table hits) "\n"))))

;; the name at point, described by whatever registry knows it
(define (help--at-point-section name)
  (if (not name)
      ""
      (let ((fn (help--api-entry name))
            (md (mode-doc name)))
        (cond ((member name (command-names)) (help--command-section name))
              (fn (help--function-section fn))
              (md (help--mode-section name md))
              (else (help--apropos-section name))))))

(define (help--here-markdown buf name)
  (let ((mode (or (buffer-local buf 'mode-name) "fundamental-mode"))
        (doc (mode-doc (or (buffer-local buf 'mode-name) "fundamental-mode"))))
    (string-append
      "# Here\n\n"
      "Buffer `" buf "` in `" mode "`."
      (if (buffer-read-only? buf) " Read-only." "")
      "\n"
      (help--minor-modes buf)
      (help--group-line buf)
      "\n"
      (help--at-point-section name)
      (if doc (string-append "## " mode "\n\n" doc "\n\n") "")
      (help--minor-sections buf)
      (help--key-table "Keys in this buffer" (local-keys buf)
                       "This buffer adds no keys of its own.")
      "\n---\n\n"
      "`C-h b` lists every binding · `C-h a` searches by words "
      "· `M-x` runs a command by name · `q` closes this page\n")))

(define-command "contextual-help"
  "Describe what is here: the name at point, this buffer, its mode and its keys"
  (lambda ()
    ;; read point BEFORE the page opens — from inside *Help*, the question
    ;; is still about the buffer the reader came from
    (let* ((here (current-buffer))
           (from-help (equal? here *help-buffer*))
           (buf (if from-help
                    (or (buffer-local *help-buffer* 'help-from) here)
                    here))
           (name (if from-help #f (help--symbol-at))))
      (help-doc! "here" (help--here-markdown buf name))
      (buffer-set-local! *help-buffer* 'help-from buf))))

(global-set-key "M-?" "contextual-help")
(global-set-key "C-h m" "describe-mode")
(global-set-key "C-h b" "describe-bindings")
(global-set-key "C-h a" "apropos")

(category! 'help)
(public! 'help-doc!
  "(help-doc! TITLE MARKDOWN) — open MARKDOWN as a rendered, read-only page in *Help*")
(public! 'mode-doc! "(mode-doc! MODE DOC) — what a mode is for; describe-mode prints it")
(public! 'local-keys "(local-keys BUF) — ((KEYS COMMAND) ...) for BUF's own bindings")
(public! 'apropos-page "(apropos-page \"words\") — the apropos hits as a rendered *Help* page")
