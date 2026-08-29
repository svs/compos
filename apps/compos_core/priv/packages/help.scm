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
;;;   M-.     help-goto-source   — the source of the name at point (or click it)
;;;   C-h k   describe-key       — press a key, read what it does
;;;   C-h m   describe-mode      — this buffer's mode and its keys
;;;   C-h b   describe-bindings  — every binding, local first
;;;   C-h a   apropos            — search the editor by words
;;;   M-x describe-buffer-locals — this buffer's own variables and their values

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

;; The facts about a page's subject go on one line, not one paragraph
;; each: what runs it, where it applies, what it belongs to.
(define (help--meta items)
  (let ((said (filter (lambda (x) (not (equal? x ""))) items)))
    (if (null? said) "" (string-append (string-join said " · ") "\n\n"))))

;; A name in a help page is a button, the way it is in Emacs: the reader
;; clicks it and lands on the definition. The button is an ordinary
;; markdown link with an editor href — the client never navigates, it
;; hands the href to preview-follow-link!, which calls the handler below.
;; VERB says what the page describes. One name can be a function and a
;; command at once, and the reader wants the definition this page is about.
(define (help--link name &optional verb)
  ;; the name rides in the href, and a name can hold a parenthesis
  ;; (paredit--key-( is a command): percent-encode it, or the link ends
  ;; in the middle of the name and the page shows its own markdown
  (string-append "[" (help--kbd name) "](compos:" (or verb "def") "/"
                 (url-encode name) ")"))

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
    ;; Opening a new help page starts in its reading view. Later runtime
    ;; reapplies preserve this mode membership exactly as the user left it.
    (unless (minor-mode-on? *help-buffer* "preview-mode")
      (enable-minor-mode! *help-buffer* "preview-mode"))
    (goto-char! 0)
    *help-buffer*))

;; A real mode, so a restored *Help* comes back rendered and read-only
;; instead of showing its own markdown source.
(mode-icon! "help-mode" "")

(define-mode "help-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      ;; the buffer has no ".md" to read a renderer from — it says so
      (buffer-set-local! buf 'preview-renderer "markdown")
      (when (minor-mode-on? buf "preview-mode")
        (preview-mode--apply! buf))
      (buffer-set-read-only! buf #t)
      (local-set-key* buf "q" "quit-window")
      ;; the name at point, in the file that defines it — the keyboard
      ;; half of the links the page draws
      (local-set-key* buf "M-." "help-goto-source"))))

(mode-doc! "help-mode"
  "A help page: markdown, rendered. `q` closes it, `C-c C-v` shows the source.")

;;; --- the pages -----------------------------------------------------------------

;; a key can contain a backtick (`C-``), and one backtick ends a code span.
;; A longer fence with padding carries it.
(define (help--kbd k)
  ;; a "|" ends the cell even inside a code span, and one backtick ends
  ;; the span. The switcher binds both, and each one broke its own row.
  (let ((k (string-join (string-split k "|") "\\|")))
    (if (string-index k "`")
        (string-append "`` " k " ``")
        (string-append "`" k "`"))))

;; one row per command, not per key: a mode that binds every printable
;; character to one command filled the page with the same row sixty times
(define (help--by-command rows)
  (let loop ((rs (sort rows)) (order '()) (by '()))
    (if (null? rs)
        (map (lambda (c) (cons c (reverse (cdr (assoc c by))))) (reverse order))
        (let* ((r (car rs))
               (k (car r))
               (c (cadr r))
               (hit (assoc c by)))
          (loop (cdr rs)
                (if hit order (cons c order))
                (if hit
                    (map (lambda (p)
                           (if (equal? (car p) c) (cons c (cons k (cdr p))) p))
                         by)
                    (cons (list c k) by)))))))

;; a long run of single characters reads as a range, the way Emacs writes it
(define (help--key-cell keys)
  (let* ((singles (filter (lambda (k) (= (string-length k) 1)) keys))
         (chords (filter (lambda (k) (not (= (string-length k) 1))) keys))
         (run (if (> (length singles) 4)
                  (list (string-append (help--kbd (car singles)) " .. "
                                       (help--kbd (car (reverse singles)))))
                  (map help--kbd singles))))
    (string-join (append run (map help--kbd chords)) " ")))

(define (help--key-rows keys)
  (map (lambda (g)
         (string-append "| " (help--key-cell (cdr g)) " | " (help--link (car g) "cmd")
                        " | " (help--cell (command-doc (car g))) " |"))
       (help--by-command keys)))

(define (help--key-table title keys empty)
  (if (null? keys)
      (string-append "## " title "\n\n" empty "\n")
      (string-append "## " title "\n\n"
                     "| keys | command | what it does |\n"
                     "| --- | --- | --- |\n"
                     (string-join (help--key-rows keys) "\n")
                     "\n")))

;;; --- buffer locals -------------------------------------------------------------
;;; A buffer's locals are its state: the mode, the renderer, a chat's
;;; identity, a list's rows. The keys answered "what can I press here";
;;; the locals answer "what does this buffer know".

;; the value column says what a value IS, not everything it holds. A
;; transcript is thousands of entries, and a help page is a page.
(define help--local-width 60)

(define (help--clip s)
  (let ((one (string-join (string-split s "\n") " ")))
    (if (> (string-length one) help--local-width)
        (string-append (substring one 0 help--local-width) "...")
        one)))

(define (help--local-value v)
  (cond
    ((equal? v #t) "#t")
    ((equal? v #f) "#f")
    ((null? v) "()")
    ((string? v) (help--clip (value->string v)))
    ((number? v) (number->string v))
    ((symbol? v) (string-append "'" (symbol->string v)))
    ((pair? v)
     (if (<= (length v) 4)
         (help--clip (value->string v))
         (string-append "(" (number->string (length v)) " items)")))
    (else (help--clip (value->string v)))))

;; help--kbd is the safe code span: it escapes the "|" that ends a cell
;; and the backtick that ends the span
(define (help--locals-table buf)
  (let ((ls (buffer-locals buf)))
    (if (null? ls)
        "This buffer sets no locals.\n"
        (string-append
          "| name | value |\n| --- | --- |\n"
          (string-join
            (map (lambda (p)
                   (string-append
                     "| " (help--kbd (symbol->string (car p)))
                     " | " (help--kbd (help--local-value (cadr p))) " |"))
                 ls)
            "\n")
          "\n"))))

(define (help--minor-modes buf)
  (let ((ms (or (buffer-local buf 'minor-modes) '())))
    (if (null? ms) "" (string-append "minor modes `" (string-join ms "` `") "`"))))

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
          "group `" (group-label g) "` ("
          (number->string (length (group-buffers g))) " buffers, companion "
          (group-noise g) ")"
          (let ((m (group-meta g))) (if m (string-append ". " m) ""))))))

(define (help--mode-markdown buf mode)
  (let ((doc (mode-doc mode)))
    (string-append
      "# " mode "\n\n"
      (if doc (string-append doc "\n\n") "")
      (help--meta (list (string-append "`" buf "`")
                        (if (buffer-read-only? buf) "read-only" "")
                        (help--minor-modes buf)
                        (help--group-line buf)))
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

(domain! 'help)
(effects! '(write))

(define-command "describe-buffer-locals" "Show this buffer's local variables and their values"
  (lambda ()
    ;; read the buffer BEFORE the page opens, the way describe-mode does
    (let* ((buf (if (equal? (current-buffer) *help-buffer*)
                    (or (buffer-local *help-buffer* 'help-from) (current-buffer))
                    (current-buffer)))
           (mode (or (buffer-local buf 'mode-name) "fundamental-mode")))
      (help-doc! "locals"
        (string-append
          "# Buffer locals\n\n"
          "Buffer `" buf "`, mode `" mode "`. "
          "Read one value with `(buffer-local \"" buf "\" 'name)`.\n\n"
          (help--locals-table buf)
          "\n---\n\n"
          "`M-x` runs a command by name · `q` closes this page\n"))
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
;;; commands. The page groups the same hits the agent reads into one section
;;; per kind. Each hit is one line: the name, how to call it, what it does,
;;; then the owner and effects in a quiet trailer.

;; one hit -> (SECTION LEAD CALL DOC). SECTION heads the group. LEAD is
;; the name the reader scans for. CALL is extra call syntax, "" when the
;; section heading already says how to call the kind.
(define (help--apropos-row h)
  (let ((kind (plist-get h 'kind))
        (doc (or (plist-get h 'doc) "")))
    (cond
      ((equal? kind "recipe")
       (list "Recipes" (plist-get h 'task) (plist-get h 'run) ""))
      ((equal? kind "command")
       (list "Commands" (plist-get h 'name)
             (or (plist-get h 'key) "") doc))
      ((equal? kind "key")
       (list "Keys" (plist-get h 'name) (plist-get h 'runs)
             (command-doc (plist-get h 'runs))))
      ((equal? kind "variable") (list "Settings" (plist-get h 'name) "" doc))
      ((equal? kind "component")
       (list "Components" (plist-get h 'qualified-name)
             (or (plist-get h 'use) "") doc))
      ((equal? kind "mode")
       (list "Modes" (plist-get h 'name) "" doc))
      ((equal? kind "internal")
       (list "Internal primitives" (plist-get h 'name) "" doc))
      ;; a query that matched nothing comes back as the closest names
      (else (list (if (plist-get h 'note) "Closest names" "Functions")
                  (or (plist-get h 'sig) (plist-get h 'name)) "" doc)))))

;; a code span keeps its text verbatim — no table, so no pipe escapes
(define (help--line s) (string-join (string-split s "\n") " "))

(define (help--code s)
  (if (equal? s "") "" (string-append "`" (help--line s) "`")))

;; the owner and effects close the line — they qualify the hit, the
;; reader does not scan for them
(define (help--apropos-meta h)
  (let ((owner (or (plist-get h 'package) "core"))
        (fx (string-join (or (plist-get h 'effects) '()) ", ")))
    (string-append " *(" (help--cell owner)
                   (if (equal? fx "") "" (string-append " · " (help--cell fx)))
                   ")*")))

(define (help--apropos-item h)
  (let* ((r (help--apropos-row h))
         (call (nth 2 r))
         (doc (nth 3 r)))
    (string-append
      "- **" (help--code (nth 1 r)) "**"
      (if (equal? call "") "" (string-append " " (help--code call)))
      (if (equal? doc "") "" (string-append " — " (help--cell doc)))
      (help--apropos-meta h))))

;; one line under a heading says how to call the kind, once, instead of a
;; call column that repeats "M-x" down the page
(define (help--apropos-hint section)
  (cond ((equal? section "Commands")
         "`M-x` runs a command by name. The key after a name also runs it.\n\n")
        ((equal? section "Functions") "Call a function from Scheme.\n\n")
        ((equal? section "Modes")
         "`M-x` with the mode's name turns it on in this buffer.\n\n")
        (else "")))

;; ((SECTION HIT ...) ...) in the order each section first appears, so
;; the section with the best-ranked hit stays on top
(define (help--apropos-groups hits)
  (let loop ((hs hits) (order '()) (by '()))
    (if (null? hs)
        (map (lambda (s) (cons s (reverse (cdr (assoc s by)))))
             (reverse order))
        (let* ((h (car hs))
               (s (car (help--apropos-row h)))
               (g (assoc s by)))
          (loop (cdr hs)
                (if g order (cons s order))
                (if g
                    (map (lambda (p)
                           (if (equal? (car p) s) (cons s (cons h (cdr p))) p))
                         by)
                    (cons (list s h) by)))))))

;; HEAD is the heading marker for the group titles — "##" on the apropos
;; page, "###" when the hits sit under a page's own section
(define (help--apropos-list hits &optional head)
  (let ((head (or head "##")))
    (string-join
      (map (lambda (g)
             (string-append
               head " " (car g) "\n\n"
               (help--apropos-hint (car g))
               (string-join (map help--apropos-item (cdr g)) "\n")
               "\n"))
           (help--apropos-groups hits))
      "\n")))

(define (apropos-page query &optional filters)
  (let ((hits (apply apropos (cons query (or filters '())))))
    (help-doc! (string-append "apropos " query)
      (string-append
        "# apropos `" query "`\n\n"
        (if (null? hits)
            "Nothing matched, and no name is close.\n"
            (string-append (number->string (length hits)) " hits.\n\n"
                           (help--apropos-list hits)))
        "\n---\n\n"
        "`C-h b` lists every binding · `M-x` runs a command by name "
        "· `q` closes this page\n"))))

(define-command "apropos"
  "Search the whole editor by words or intent; literal hits rank before cached semantic hits"
  (lambda ()
    (minibuffer-read "Apropos (words): " (history-items 'apropos)
      (lambda (query)
        (history-push! 'apropos query)
        (apropos-page query)))))
(catalog-meta! 'command "apropos" 'domain 'discovery 'effects '(read external spend))

(define-command "apropos-rebuild-embeddings"
  "Clear and rebuild the OpenAI embedding cache for the current catalog"
  (lambda () (message (apropos-rebuild-embeddings!))))
(catalog-meta! 'command "apropos-rebuild-embeddings"
  'domain 'discovery 'effects '(write external spend))

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
      "## " (help--link name "cmd") " — a command\n\n"
      (help--cell (command-doc name)) "\n\n"
      (help--meta (list (string-append "`M-x " name "`")
                        (if (equal? k "") "" (string-append "bound to " (help--kbd k))))))))

(define (help--function-section e)
  (string-append
    "## " (help--link (car e)) " — a function\n\n"
    "`" (help--cell (nth 2 e)) "`\n\n"
    (help--cell (nth 1 e)) "\n\n"))

(define (help--mode-section name doc)
  (string-append "## " (help--link name "mode") " — a mode\n\n" doc "\n\n"
                 "`M-x " name "` turns it on in this buffer.\n\n"))

;; A word that matches nothing is prose, not a name — most words in a diff
;; or a mail are. The page says nothing about it and goes straight to the
;; buffer, instead of opening with a heading that reports a dead end.
;; A few hits from each section, in the order the sections rank. Ranking
;; puts every recipe ahead of the functions, so a flat cap fills the page
;; with recipes and never names a function. The page promises the closest
;; matches, which means a spread.
(define (help--apropos-spread hits per-section)
  (reverse
    (fold (lambda (out g)
            (fold (lambda (acc h) (cons h acc))
                  out
                  (help--take (cdr g) per-section)))
          '() (help--apropos-groups hits))))

(define (help--apropos-section name)
  (let ((hits (help--apropos-spread (apropos name) 3)))
    (if (null? hits)
        ""
        (string-append "## `" name "` — the closest matches\n\n"
                       (help--apropos-list hits "###") "\n"))))

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
      (help--meta (list (string-append "`" buf "` in `" mode "`")
                        (if (buffer-read-only? buf) "read-only" "")
                        (help--minor-modes buf)
                        (help--group-line buf)))
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
(catalog-meta! 'function "apropos-page" 'domain 'discovery 'effects '(read external spend))

;;; --- describe-key: press the key, read the page --------------------------------
;;; `C-h k` answers the question a keyboard asks: "what does THIS do?".
;;; The command arms a one-shot capture, the dispatcher hands the next
;;; complete sequence back, and the page names the command, prints its
;;; docstring and says which map answered — local or global.

(domain! 'help)
(effects! '(write))

;; which map answered: a local binding shadows a global one, and the
;; reader must know which one they changed if they rebind it
(define (help--key-source buf keys)
  (cond ((assoc keys (local-keys buf)) "local to this buffer")
        ((assoc keys (global-keys)) "global, in every buffer")
        (else "")))

;; The page is about one key, so the key is the title and the command is
;; the lead. Everything else is one line under it.
(define (help--key-markdown buf seq)
  (let* ((keys (string-join seq " "))
         (mode (or (buffer-local buf 'mode-name) "fundamental-mode"))
         (cmd (key-binding seq))
         (where (string-append "pressed in `" buf "` (`" mode "`)")))
    (string-append
      "# " (help--kbd keys) "\n\n"
      (cond
        ((string? cmd)
         (string-append
           "**" (help--link cmd "cmd") "** — " (help--cell (command-doc cmd)) "\n\n"
           (help--meta (list (string-append "`M-x " cmd "`")
                             (help--key-source buf keys)
                             where))))
        ((equal? cmd 'prefix)
         (string-append "A prefix. Press the rest of the sequence to reach "
                        "a command.\n\n"
                        (help--meta (list where))))
        (else (string-append "No command runs this key.\n\n"
                             (help--meta (list where)))))
      "---\n\n"
      "`C-h b` lists every binding · `M-.` opens the source "
      "· `q` closes this page\n")))

;; the capture hands the sequence back through (last-keys) — a raw command
;; because the reader runs it with a key, never by name
(define-command--raw "describe-key--page"
  (lambda ()
    (let ((buf (current-buffer))
          (seq (last-keys)))
      (help-doc! (string-join seq " ") (help--key-markdown buf seq))
      (buffer-set-local! *help-buffer* 'help-from buf))))

(define-command "describe-key"
  "Show what one key does: press the key, read its page"
  (lambda ()
    (message "Describe key: ")
    (capture-key! "describe-key--page")))

(global-set-key "C-h k" "describe-key")

;;; --- the source behind the name ------------------------------------------------
;;; Emacs makes every name in a help page a button and sends the click to
;;; find-function, which reads the file the symbol was loaded from. Ours is
;;; the same idea with the parts this editor already has: the page draws a
;;; markdown link, the client hands the href back, and scheme-ide finds the
;;; defining form. `M-.` asks the same question about the name at point.

(define (help--goto-source name &optional kind)
  (let ((hit (and (boundp 'scheme-ide--find-def)
                  (scheme-ide--find-def name kind))))
    (cond
      (hit
       (when (boundp 'lsp--push-marker!) (lsp--push-marker!))
       ;; the page is a popup over the frame: keep it open and it covers
       ;; the code the reader asked for
       (when (equal? (current-buffer) *help-buffer*) (run-command "quit-window"))
       (if (equal? (car hit) 'buffer)
           (switch-to-buffer! (cadr hit))
           (visit (cadr hit)))
       (goto-char! (caddr hit))
       (message (string-append "Definition of " name)))
      ((primitive-doc name)
       (message (string-append name " is a primitive — " (primitive-doc name))))
      (else (message (string-append "No definition of " name))))))

(on-preview-link! "def" help--goto-source)
(on-preview-link! "cmd" (lambda (name) (help--goto-source name 'command)))
(on-preview-link! "mode" (lambda (name) (help--goto-source name 'mode)))

(define-command "help-goto-source"
  "Open the source of the name at point, in the file that defines it"
  (lambda ()
    (let ((name (help--symbol-at)))
      (if name
          (help--goto-source name)
          (message "No name at point")))))

(public! 'help--goto-source
  "(help--goto-source NAME) — open the file that defines NAME, at the definition")
