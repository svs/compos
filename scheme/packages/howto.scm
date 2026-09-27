;;; howto.scm --- "how do I ...?": task recipes for people, and the manual.
;;;
;;; A recipe in recipes.scm answers an agent: task -> expression. A howto
;;; answers a person: task -> the keys and commands that do it, in words.
;;;
;;; A howto names a command as {{COMMAND}}, or {{MODE:COMMAND}} for a key
;;; that works in one mode only. The page draws the key that runs the
;;; command NOW, from the live keymaps, and links the name so a click runs
;;; it. A howto never spells a binding itself: when the user moves a key,
;;; the page follows. The package test fails when a howto names a command
;;; that does not exist, so a howto cannot go stale in silence.
;;;
;;; The same text is the manual: (write-manual! DIR) renders every howto,
;;; every command, and every global key into Markdown files. The files in
;;; docs/manual come out of a stock boot (bin/docs), not out of a hand.
;;;
;;;   C-h h   how-do-i       — pick a task, read how to do it
;;;   C-h ?   help-for-help  — every help command, with its key
;;;
;;; A package adds its own howtos next to its commands:
;;;
;;;   (defhowto! "Mail" "archive a thread"
;;;     "In the mail list, press {{notmuch-mode:notmuch-archive}}.")

(domain! 'learning)
(effects! '(read))

;; ((TOPIC TITLE BODY) ...), in the order the howtos were defined
(define *howtos* '())

(define (howto--plain body)
  ;; the body with each {{REF}} as its command name, for search
  (howto--expand body (lambda (ref) (howto--ref-command ref))))

(define (defhowto! topic title body)
  (set! *howtos*
    (append (filter (lambda (h) (not (equal? (cadr h) title))) *howtos*)
            (list (list topic title body))))
  (catalog-register! 'howto title (howto--plain body)
    'topic topic 'domain 'learning 'effects '(read))
  title)

(public! 'defhowto!
  "(defhowto! TOPIC TITLE BODY) — register a task recipe for people; BODY is Markdown that names commands as {{COMMAND}} or {{MODE:COMMAND}}"
  'learning)

(define (howtos) *howtos*)
(define (howto-titles) (map cadr *howtos*))
(define (howto-get title)
  (let loop ((hs *howtos*))
    (cond ((null? hs) #f)
          ((equal? (cadr (car hs)) title) (car hs))
          (else (loop (cdr hs))))))

;; the topics in the order their first howto was defined
(define (howto-topics)
  (reverse
    (fold (lambda (acc h) (if (member (car h) acc) acc (cons (car h) acc)))
          '() *howtos*)))

(define (howtos-in topic)
  (filter (lambda (h) (equal? (car h) topic)) *howtos*))

;;; --- {{REF}} expansion ---------------------------------------------------------

;; Replace each {{REF}} in TEXT with (RENDER REF). An unclosed {{ stays as
;; it is.
(define (howto--expand text render)
  (let ((parts (string-split text "{{")))
    (apply string-append
      (cons (car parts)
            (map (lambda (p)
                   (let ((kv (string-split p "}}")))
                     (if (null? (cdr kv))
                         (string-append "{{" p)
                         (string-append (render (car kv))
                                        (string-join (cdr kv) "}}")))))
                 (cdr parts))))))

;; the {{REF}}s of TEXT, in order
(define (howto--refs text)
  (let ((acc '()))
    (howto--expand text (lambda (ref) (set! acc (cons ref acc)) ""))
    (reverse acc)))

;; "Dired:dired-rename" -> ("Dired" "dired-rename"); "find-file" -> (#f "find-file")
(define (howto--ref-parts ref)
  (let ((ps (string-split ref ":")))
    (if (null? (cdr ps))
        (list #f ref)
        (list (car ps) (string-join (cdr ps) ":")))))

(define (howto--ref-command ref) (cadr (howto--ref-parts ref)))

;;; --- keys ------------------------------------------------------------------------

(define (howto--keys-for rows command)
  (map car (filter (lambda (r) (equal? (cadr r) command)) rows)))

(define (howto--tersest keys)
  (if (null? keys) "" (car (keymap--tersest keys))))

;; The key that runs COMMAND in MODE: the mode's own map, then its parents.
(define (howto--mode-key mode command)
  (let loop ((maps (keymap--chain (mode-keymap mode))))
    (if (null? maps)
        ""
        (let ((keys (howto--keys-for (keymap--rows (keymap--flatten (cadr (car maps))))
                                     command)))
          (if (pair? keys) (howto--tersest keys) (loop (cdr maps)))))))

;; The key for REF. A plain ref reads the global map only: the page must
;; not change with the buffer the reader happens to stand in.
(define (howto--ref-key ref global)
  (let* ((parts (howto--ref-parts ref))
         (mode (car parts))
         (command (cadr parts)))
    (if mode
        (howto--mode-key mode command)
        (howto--tersest (howto--keys-for global command)))))

;;; --- rendering -------------------------------------------------------------------

;; FLAVOR 'page draws links a click follows; 'file draws plain Markdown for
;; a file that a reader opens outside the editor.
(define (howto--render-ref ref global flavor)
  (let* ((command (howto--ref-command ref))
         (key (howto--ref-key ref global))
         (known (and (command-fn command) #t)))
    (cond
      ((not known) (string-append "`M-x " command "`"))
      ((equal? flavor 'page)
       (if (equal? key "")
           (string-append "[`M-x " command "`](compos:run/" (url-encode command) ")")
           (string-append (help--kbd key)
                          " ([`" command "`](compos:run/" (url-encode command) "))")))
      (else
       (if (equal? key "")
           (string-append "`M-x " command "`")
           (string-append (help--kbd key) " (`" command "`)"))))))

(define (howto--body-markdown h global flavor)
  (howto--expand (caddr h) (lambda (ref) (howto--render-ref ref global flavor))))

(define (howto--link title)
  (string-append "[" title "](compos:howto/" (url-encode title) ")"))

(define (howto-page-markdown title)
  (let ((h (howto-get title))
        (global (global-keys)))
    (string-append
      "# How do I " title "?\n\n"
      "*" (car h) "*\n\n"
      (howto--body-markdown h global 'page) "\n\n"
      (let ((others (filter (lambda (o) (not (equal? (cadr o) title)))
                            (howtos-in (car h)))))
        (if (null? others)
            ""
            (string-append "## Also in " (car h) "\n\n"
                           (string-join (map (lambda (o) (string-append "- " (howto--link (cadr o))))
                                             others)
                                        "\n")
                           "\n\n")))
      "---\n\n"
      "Click a command name to run it · `C-h h` asks another question "
      "· `C-h ?` lists every help command · `q` closes this page\n")))

(define (howto-index-markdown &optional hs heading)
  (let ((hs (if (equal? hs #f) *howtos* hs)))
    (string-append
      "# " (or heading "How do I ...?") "\n\n"
      (if (pair? hs)
          (string-append
            "Each task opens a short page. The page names the keys that do the task, "
            "and a click on a command name runs it.\n\n"
            (string-join
              (map (lambda (topic)
                     (let ((in (filter (lambda (h) (equal? (car h) topic)) hs)))
                       (string-append
                         "## " topic "\n\n"
                         (string-join (map (lambda (h) (string-append "- " (howto--link (cadr h)))) in)
                                      "\n")
                         "\n")))
                   (filter (lambda (t) (pair? (filter (lambda (h) (equal? (car h) t)) hs)))
                           (howto-topics)))
              "\n"))
          "No task matches those words. `C-h a` searches every name in the editor.\n")
      "\n---\n\n"
      "`C-h a` searches every name · `C-h ?` lists every help command "
      "· `q` closes this page\n")))

;; the howtos whose title, topic, and commands hold every word of QUERY
(define (howto-search query)
  (let ((words (string-split (string-downcase (string-trim query)) " ")))
    (filter (lambda (h)
              (let ((text (string-downcase
                            (string-append (car h) " " (cadr h) " " (howto--plain (caddr h))))))
                (howto--every? (lambda (w) (or (equal? w "") (string-contains? text w))) words)))
            *howtos*)))

(define (howto--every? pred xs)
  (cond ((null? xs) #t)
        ((pred (car xs)) (howto--every? pred (cdr xs)))
        (else #f)))

(define (howto-show! title)
  (help-doc! (string-append "how do I " title) (howto-page-markdown title)))

(define (howto-answer! input)
  (let ((q (string-trim (or input ""))))
    (cond ((equal? q "") (help-doc! "how do I" (howto-index-markdown)))
          ((howto-get q) (howto-show! q))
          (else
            (let ((hits (howto-search q)))
              (if (and (pair? hits) (null? (cdr hits)))
                  (howto-show! (cadr (car hits)))
                  (help-doc! (string-append "how do I " q)
                    (howto-index-markdown hits (string-append "How do I " q "?")))))))))

;;; --- commands --------------------------------------------------------------------

(define-command "how-do-i"
  "Pick a task and read how to do it; an empty answer lists every task"
  (lambda ()
    (minibuffer-read "How do I: "
      (map (lambda (h) (list (cadr h) (car h))) *howtos*)
      howto-answer!)))

(define (help-for-help-markdown)
  (let* ((global (global-keys))
         (row (lambda (command what)
                (string-append "| " (howto--render-ref command global 'page)
                               " | " what " |"))))
    (string-append
      "# Help\n\n"
      "Every question below has a command. The key is beside it, and a click on "
      "the name runs it. `C-g` cancels any prompt.\n\n"
      "## Start here\n\n"
      "| Command | What it answers |\n|---|---|\n"
      (string-join
        (list (row "how-do-i" "How do I do a task? Pick one from a list of recipes.")
              (row "help-with-tutorial" "Teach me the editor, step by step.")
              (row "setup-welcome" "What is this editor? The short version.")
              (row "execute-extended-command" "Run any command by its name.")
              (row "command-palette" "Find an action by what it does."))
        "\n")
      "\n\n## Where am I\n\n"
      "| Command | What it answers |\n|---|---|\n"
      (string-join
        (list (row "contextual-help" "What is here: the name at point, this buffer, its keys.")
              (row "describe-mode" "What does this mode do, and what are its keys?")
              (row "describe-buffer-locals" "What are this buffer's own settings?")
              (row "view-messages" "What did the editor just say?"))
        "\n")
      "\n\n## Keys and names\n\n"
      "| Command | What it answers |\n|---|---|\n"
      (string-join
        (list (row "describe-key" "What does this key do?")
              (row "describe-bindings" "Which keys work here?")
              (row "keys" "Show every key, and let me change one.")
              (row "apropos" "What is the name for this? Search by words.")
              (row "describe-variable" "What is this setting, and what is its value?")
              (row "help-goto-source" "Where is this name defined? Open its source."))
        "\n")
      "\n\n## Tasks\n\n"
      (string-join
        (map (lambda (topic)
               (string-append "**" topic "**: "
                              (string-join (map (lambda (h) (howto--link (cadr h)))
                                                (howtos-in topic))
                                           " · ")))
             (howto-topics))
        "\n\n")
      "\n\n---\n\n`q` closes this page\n")))

(define-command "help-for-help"
  "List every help command with its key, and every task recipe"
  (lambda () (help-doc! "help" (help-for-help-markdown))))

(define-key "help-map" "h" "how-do-i")
(define-key "help-map" "?" "help-for-help")
(define-key "help-map" "C-h" "help-for-help")

;;; --- links -----------------------------------------------------------------------

;; compos:howto/TITLE opens that howto
(define (howto--follow-howto title)
  (if (howto-get title)
      (howto-show! title)
      (message (string-append "No howto named " title))))

;; compos:run/COMMAND runs a command from a help page. A link in any other
;; buffer does nothing: a web page or a chat reply must not run a command
;; by a click. The command runs in the window the reader came from.
(define (howto--follow-run command)
  (cond
    ((not (equal? (current-buffer) *help-buffer*))
     (message "A run link works only on a help page"))
    ((not (command-fn command))
     (message (string-append "No command named " command)))
    (else
      (let ((w (buffer-local *help-buffer* 'help-from-window)))
        (when w (ignore-errors (lambda () (select-window! w)))))
      (run-command command))))

(add-hook! (list 'preview-link "howto") howto--follow-howto)
(add-hook! (list 'preview-link "run") howto--follow-run)

;;; --- the manual ------------------------------------------------------------------

(define (manual--header title)
  (string-append
    "# " title "\n\n"
    "<!-- Generated by (write-manual! DIR) in scheme/packages/howto.scm. "
    "Do not edit: change the source and run bin/docs. -->\n\n"))

(define (manual-howto-markdown)
  (let ((global (global-keys)))
    (string-append
      (manual--header "How do I ...?")
      "Each section is one task. Inside the editor, `C-h h` asks for a task and "
      "opens its page. The keys here are the stock keys.\n\n"
      (string-join
        (map (lambda (topic)
               (string-append
                 "## " topic "\n\n"
                 (string-join
                   (map (lambda (h)
                          (string-append "### How do I " (cadr h) "?\n\n"
                                         (howto--body-markdown h global 'file) "\n"))
                        (howtos-in topic))
                   "\n")))
             (howto-topics))
        "\n"))))

;; a command worth a row: it says what it does, and a person can run it
(define (manual--listed-command? name)
  (and (not (equal? (command-doc name) ""))
       (not (string-contains? name "--"))
       (not (string-prefix? "transient:" name))))

;; The packages the manual leaves out. The suite loads the opt-in apps,
;; and bin/docs names them here, so the manual describes the stock boot.
(define *manual-exclude* '())

;; command name -> (DOMAIN PACKAGE), read from the catalog in one pass
(define (manual--command-domains)
  (fold (lambda (acc e)
          (if (equal? (catalog--get e 'kind) "command")
              (let ((d (catalog--get e 'domain)))
                (cons (list (catalog--get e 'name)
                            (if (or (not d) (equal? d "") (equal? d "unknown")) "other" d)
                            (catalog--get e 'package))
                      acc))
              acc))
        '() (catalog)))

(define (manual--excluded? name domain-of)
  (let ((d (assoc name domain-of)))
    (and d (member (caddr d) *manual-exclude*) #t)))

;; command name -> its tersest global key, from the global rows in one pass
(define (manual--global-key-index)
  (fold (lambda (acc r)
          (let ((cell (assoc (cadr r) acc)))
            (if cell
                (cons (list (cadr r) (cons (car r) (cadr cell))) acc)
                (cons (list (cadr r) (list (car r))) acc))))
        '() (global-keys)))

(define (manual-commands-markdown)
  (let* ((domain-of (manual--command-domains))
         (key-of (manual--global-key-index))
         (rows (map (lambda (n)
                      (let ((d (assoc n domain-of))
                            (k (assoc n key-of)))
                        (list (if d (cadr d) "other") n
                              (if k (howto--tersest (cadr k)) ""))))
                    (sort (filter (lambda (n) (and (manual--listed-command? n)
                                                   (not (manual--excluded? n domain-of))))
                                  (command-names)))))
         (domains (sort (fold (lambda (acc r) (if (member (car r) acc) acc (cons (car r) acc)))
                              '() rows))))
    (string-append
      (manual--header "Commands")
      "Every command that has a docstring, by domain. `M-x NAME` runs a command. "
      "The key column shows the stock global key; a mode can add its own keys.\n\n"
      (string-join
        (map (lambda (d)
               (string-append
                 "## " d "\n\n| Command | Key | What it does |\n|---|---|---|\n"
                 (string-join
                   (map (lambda (r)
                          (string-append "| `" (cadr r) "` | "
                                         (if (equal? (caddr r) "") "" (help--kbd (caddr r)))
                                         " | " (help--cell (command-doc (cadr r))) " |"))
                        (filter (lambda (r) (equal? (car r) d)) rows))
                   "\n")
                 "\n"))
             domains)
        "\n"))))

;; a sorted list without its repeated neighbours
(define (manual--uniq xs)
  (reverse (fold (lambda (acc x) (if (and (pair? acc) (equal? (car acc) x)) acc (cons x acc)))
                 '() xs)))

(define (manual-keys-markdown)
  (let* ((domain-of (manual--command-domains))
         (rows (manual--uniq (sort (filter (lambda (r) (and (not (string-prefix? "keymap:" (cadr r)))
                                              (not (equal? (cadr r) "self-insert-command"))
                                              (not (manual--excluded? (cadr r) domain-of))))
                             (global-keys))))))
    (string-append
      (manual--header "Global keys")
      "Every key in the global map, except the keys that insert their own character. A mode map can shadow a key "
      "in its own buffers. `C-h b` shows the keys in force in one buffer.\n\n"
      "| Key | Command | What it does |\n|---|---|---|\n"
      (string-join
        (map (lambda (r)
               (string-append "| " (help--kbd (car r)) " | `" (cadr r) "` | "
                              (help--cell (or (command-doc (cadr r)) "")) " |"))
             rows)
        "\n")
      "\n")))

(define (manual-readme-markdown)
  (string-append
    (manual--header "The Compos manual")
    "The editor writes these files from its own registries, so they describe "
    "the code that runs.\n\n"
    "- [How do I ...?](HOW-DO-I.md): task recipes, by topic.\n"
    "- [Commands](COMMANDS.md): every documented command, by domain.\n"
    "- [Global keys](KEYS.md): every key in the global map.\n\n"
    "Inside the editor, `C-h ?` lists every help command, and `C-h h` opens a task.\n"))

(define (write-manual! dir &optional exclude)
  (set! *manual-exclude* (or exclude '()))
  (make-directory! dir)
  (for-each (lambda (f)
              (write-file! (string-append dir "/" (car f)) ((cadr f))))
            (list (list "README.md" manual-readme-markdown)
                  (list "HOW-DO-I.md" manual-howto-markdown)
                  (list "COMMANDS.md" manual-commands-markdown)
                  (list "KEYS.md" manual-keys-markdown)))
  dir)

(public! 'write-manual!
  "(write-manual! DIR [EXCLUDE]) — write the generated manual (howtos, commands, keys) as Markdown files into DIR, leaving out the packages named in EXCLUDE"
  'learning)
(catalog-meta! 'function "write-manual!" 'effects '(write))

;; the howtos that name a command no one defined: ((TITLE REF) ...)
(define (howto-broken-refs)
  (apply append
    (map (lambda (h)
           (map (lambda (ref) (list (cadr h) ref))
                (filter (lambda (ref) (not (command-fn (howto--ref-command ref))))
                        (howto--refs (caddr h)))))
         *howtos*)))

;; the {{MODE:COMMAND}} refs whose mode binds no key to the command
(define (howto-unbound-mode-refs)
  (apply append
    (map (lambda (h)
           (map (lambda (ref) (list (cadr h) ref))
                (filter (lambda (ref)
                          (and (car (howto--ref-parts ref))
                               (equal? (howto--ref-key ref '()) "")))
                        (howto--refs (caddr h)))))
         *howtos*)))

(category! 'learning)

;;; ================================================================================
;;; The stock howtos. Write each one to ASD-STE100: short sentences, active
;;; voice, one word for one thing. Name a command, never a key.
;;; ================================================================================

;;; --- Getting started -------------------------------------------------------------

(defhowto! "Getting started" "run a command by its name"
  "Press {{execute-extended-command}} and type a part of the name. The list gets shorter as you type. Each row shows the key of the command and what the command does. Press `RET` to run the selected command.

Every action in the editor is a command. When you forget a key, you can always use its name.

To search by what a command does, use {{command-palette}}. It also finds task recipes.")

(defhowto! "Getting started" "cancel what I started"
  "Press {{keyboard-quit}}. It closes a prompt, stops a key sequence, and clears the mark. Press it again if one press is not enough.")

(defhowto! "Getting started" "undo a change"
  "Press {{undo}}. Each press takes back one more change. The editor keeps the undo history of each buffer.")

(defhowto! "Getting started" "learn the editor step by step"
  "Press {{help-with-tutorial}}. The tutorial is a buffer that you edit while you read it. The editor keeps your place when you leave, and the tutorial opens there next time.

{{setup-welcome}} shows the short version on one page.")

(defhowto! "Getting started" "find out what a key does"
  "Press {{describe-key}}, then press the key. A page opens. It names the command, says what the command does, and says which keymap binds the key.

{{describe-bindings}} lists every key that works in this buffer. {{describe-mode}} shows the keys of this buffer's mode only.")

(defhowto! "Getting started" "get help about what is here"
  "Press {{contextual-help}}. The page describes the name at point, this buffer, its mode, and its keys.

In a list (buffers, files, chats, mail), press `?` to show the keys of the list.")

(defhowto! "Getting started" "find the name of something"
  "Press {{apropos}} and type some words. The page lists the commands, settings, functions, and recipes that match. Click a name to open its source.")

;;; --- Files -----------------------------------------------------------------------

(defhowto! "Files" "open a file"
  "Press {{find-file}} and type a path. The list shows the files in the directory as you type. Press `RET` to open the selected file. A new path makes a new buffer, and {{save-buffer}} writes it to disk.

{{find-file-other-window}} opens the file in the other window.")

(defhowto! "Files" "save a file"
  "Press {{save-buffer}}. To save the buffer under a new name, use {{write-file}}.

When the file changed on disk after you opened it, the editor asks before it writes. {{revert-buffer}} reads the file from disk again and discards your edits.")

(defhowto! "Files" "browse a directory"
  "Press {{dired}} and choose a directory. Dired lists its files.

- {{Dired:dired-visit}} opens the file at point.
- {{Dired:dired-up}} opens the parent directory.
- {{Dired:dired-rename}} renames or moves a file.
- {{Dired:dired-copy}} copies a file.
- {{Dired:dired-mkdir}} makes a directory.
- {{Dired:list-mark}} marks a file. A command then acts on every marked file.")

(defhowto! "Files" "find a file in my project"
  "Press {{project-find-file}} and type a part of the name. The list holds the files of the project that git does not ignore.

A project is a directory under version control. {{project-switch-project}} goes to another project.")

(defhowto! "Files" "search the text of my project"
  "Press {{project-ripgrep}} and type the text. The list shows each match. Move through the list to preview a match, and press `RET` to go to it.")

(defhowto! "Files" "mark a place to come back to"
  "Press {{bookmark-set}} and give the bookmark a name. {{bookmark-jump}} goes back to it later, also after a restart. {{bookmark-bmenu-list}} lists every bookmark.")

;;; --- Editing ---------------------------------------------------------------------

(defhowto! "Editing" "select, cut, copy, and paste"
  "Press {{set-mark-command}} to start a selection, then move point. The region is the text between the mark and point.

- {{kill-region}} cuts the region.
- {{copy-region-as-kill}} copies the region.
- {{kill-line}} cuts from point to the end of the line.
- {{yank}} pastes the last text you cut or copied.
- {{yank-pop}}, after a paste, replaces it with the text you cut before that.")

(defhowto! "Editing" "search in a buffer"
  "Press {{isearch-forward}} and type. Point moves to the next match as you type. Press the same key again for the next match. Press `RET` to stop at the match, or {{keyboard-quit}} to go back to where you started.

{{isearch-backward}} searches toward the start of the buffer.")

(defhowto! "Editing" "replace text"
  "Press {{query-replace}}. Type the text to find, then the new text. At each match, press `y` to replace it or `n` to skip it.

{{replace-string}} replaces every match with no questions.")

(defhowto! "Editing" "go to a line"
  "Press {{goto-line}} and type the line number.

{{beginning-of-buffer}} goes to the start, and {{end-of-buffer}} goes to the end. {{imenu}} goes to a definition in this buffer by its name.")

(defhowto! "Editing" "make the text larger or smaller"
  "Press {{text-scale-increase}} or {{text-scale-decrease}}. The change applies to this buffer only. {{text-scale-reset}} gives the buffer the normal size again.")

;;; --- Buffers and windows ---------------------------------------------------------

(defhowto! "Buffers and windows" "switch to another buffer"
  "Press {{ibuffer-prompt}} and type a part of the buffer name. Press `RET` to show it.

{{previous-buffer}} goes back to the buffer you used before. {{ibuffer}} lists every buffer by group.")

(defhowto! "Buffers and windows" "close a buffer"
  "Press {{kill-buffer}} and choose the buffer. The current buffer is the default. When the buffer has unsaved changes, the editor asks first.")

(defhowto! "Buffers and windows" "split the screen"
  "Press {{split-window-right}} for two windows side by side, or {{split-window-below}} for one above the other.

- {{other-window}} moves to the next window.
- {{delete-window}} closes this window. The buffer stays open.
- {{delete-other-windows}} keeps this window only.
- {{window-layout}} arranges the visible buffers in a layout that you choose.")

(defhowto! "Buffers and windows" "get back the windows I had"
  "Press {{winner-previous}}. Each press restores an earlier arrangement of windows and buffers. {{winner-next}} goes forward again.")

(defhowto! "Buffers and windows" "read the other window without leaving this one"
  "Press {{scroll-other-window}} to scroll the other window down, and {{scroll-other-window-down}} to scroll it up. Point stays in this window.")

;;; --- Groups ----------------------------------------------------------------------

(defhowto! "Groups" "keep the buffers of one task together"
  "A group is the set of buffers for one task, with the window arrangement you left. Press {{group-new}} to make a group and enter it. The files you open while you are in a group go into that group.

{{group-add}} puts the current buffer in a group. {{group-move}} moves it to another group.")

(defhowto! "Groups" "switch to another task"
  "Press {{group-switch}} and choose a group. The editor shows its buffers in the windows you left them in.

{{group-switch-last}} goes back to the group you came from.")

(defhowto! "Groups" "rename or close a group"
  "Press {{group-rename}} to give the current group a new name. {{group-kill}} kills every buffer in the current group.")

;;; --- Agents and chat -------------------------------------------------------------

(defhowto! "Agents and chat" "ask the agent about my work"
  "Press {{chat}}. The chat of the current group opens. Type your question after the prompt and press {{chat-mode:agent-send}}.

The agent can read the buffers of the group, so you do not paste them. {{chat-companion-ask}} asks the chat without leaving the buffer you are in.")

(defhowto! "Agents and chat" "start a new chat"
  "Press {{chat-new}}. With a prefix argument, it asks which group the chat belongs to.

{{chat-list}} lists every chat, and finds a chat by a word that somebody said in it.")

(defhowto! "Agents and chat" "give the agent a part of a file"
  "Select the text, then press {{chat-send-region}}. The chat gets the region as context.")

(defhowto! "Agents and chat" "stop the agent"
  "In the chat, press {{chat-mode:chat-abort}}. The reply in progress stops, and the transcript keeps what arrived.

{{chat-reset}} clears the transcript and starts again.")

(defhowto! "Agents and chat" "choose the model"
  "In a chat, press {{chat-mode:chat-set-model}} to choose the model of that chat. {{llm-configure}} opens the complete setup: backend, model, effort, and saved presets.

{{chat-set-permission-mode}} changes when the agent asks before it acts. {{chat-cost}} shows what the chat has cost.")

(defhowto! "Agents and chat" "answer the agent when it asks for permission"
  "When the agent wants to use a tool, the chat asks you.

- {{chat-mode:agent-permission-allow}} allows it once.
- {{chat-mode:agent-permission-always}} allows it and stops asking for that tool.
- {{chat-mode:agent-permission-deny}} refuses.")

;;; --- Web, mail, and feeds --------------------------------------------------------

(defhowto! "Web, mail, and feeds" "read a web page"
  "Press {{browse}} and type a URL or some search words. The page opens as readable text in a buffer.

- {{browse-mode:browse-follow}} follows the link at point.
- {{browse-mode:browse-next-link}} moves to the next link.
- {{browse-mode:browse-back}} goes back.
- {{browse-mode:browse-open-external}} opens the page in your real browser.

{{browse-history}} lists every page you read.")

(defhowto! "Web, mail, and feeds" "read my mail"
  "Press {{notmuch}} to see the mailboxes, or {{mail}} for the three-pane view. The mail comes from notmuch, so notmuch must index it first.

In the mail list, {{notmuch-mode:notmuch-archive}} archives a thread, and {{notmuch-mode:notmuch-reply}} replies.")

(defhowto! "Web, mail, and feeds" "follow a news feed"
  "Press {{feeds-subscribe}} and give a feed URL or a page that has one. {{feeds}} lists the new items of every feed.")

;;; --- Customizing -----------------------------------------------------------------

(defhowto! "Customizing" "change a setting"
  "Press {{customize}} and choose the setting. Type the new value. The editor saves it in `~/.compos/custom.scm`, so it stays after a restart.

{{customize-set-variable}} changes a setting for this session only.")

(defhowto! "Customizing" "change the colours"
  "Press {{load-theme}}. Move through the list to preview each theme. Press `RET` to keep one.")

(defhowto! "Customizing" "bind a key to a command"
  "Press {{keys-bind}}, choose the command, then type the key, for example `C-c z`. The binding applies everywhere and stays after a restart.

{{keys}} lists every key. In that list, {{keys-mode:keys-rebind}} gives the command on the row another key, and {{keys-mode:keys-revert}} takes back your edit.")

(defhowto! "Customizing" "add my own code"
  "Put Scheme in `~/.compos/init.scm`. The editor runs it at each start, after the bundled packages.

To try an expression now, press {{eval-expression}}. In a Scheme buffer, {{eval-last-sexp}} runs the expression before point. {{reload-file}} loads a changed package into the running editor.")

;;; --- Setup and sharing -----------------------------------------------------------

(defhowto! "Setup and sharing" "set up the AI models"
  "Press {{setup-ai-guide}}. It explains models, chats, and agents, then walks through a real reply. {{setup-inference}} detects local commands and registered keys; it cannot check a login. For a guided OpenRouter key setup, use {{setup-bot}}.")

(defhowto! "Setup and sharing" "share a link to a buffer"
  "Press {{copy-buffer-link}}. The link names this buffer and this line. A person who opens it gets the editor at that place.")

(defhowto! "Setup and sharing" "restart the editor"
  "Press {{restart-daemon}}. The editor saves your buffers, windows, and groups, then restarts. They come back after the restart.

A change to a Scheme or Elixir source file does not need a restart: the editor reloads it when you save it.")

(defhowto! "Setup and sharing" "see what the editor said"
  "Press {{view-messages}}. The buffer lists every message that the echo area showed, with errors first in their colour.")
