;;; prompt-editor.scm --- every section of a chat's system prompt, as an app.
;;;
;;; M-x prompt-editor lists the sections the chat of this group can get:
;;; the prompt files, the parts that modes and code make, and the prompt
;;; of every preset, also the presets the chat does not hold. Moving the
;;; point shows the section's text beside the list. e edits its file,
;;; t turns the section on or off for the chat, p adds or removes the
;;; preset that brings it, v shows the whole composed prompt, r gives a
;;; started conversation the current sections.

(domain! 'chat)
(effects! '(pure))

(define *prompt-editor-id* "prompt-editor")
(define *prompt-editor-mode* "prompt-editor-mode")
(define *prompt-editor-detail-mode* "prompt-editor-detail-mode")

;; (KEY COMMAND LABEL [TONE]): the keymaps, the keys cards and the
;; action bar all come from this table.
(define prompt-editor-verbs
  '(("e" "prompt-editor-edit" "Edit file")
    ("t" "prompt-editor-toggle" "On / off" "good")
    ("p" "prompt-editor-preset" "Add / remove preset")
    ("v" "prompt-editor-view" "Whole prompt")
    ("r" "prompt-editor-refresh-chat" "Refresh chat")
    ("g" "prompt-editor-revert" "Read again")))

(define (prompt-editor--keys-card extra)
  (append (map (lambda (v) (list (car v) (string-downcase (caddr v)))) prompt-editor-verbs) extra))

;;; ---------------------------------------------------------------- data

(define (prompt-editor--preset-name id)
  "the preset a section named preset:NAME comes from, else #f"
  (and (string-prefix? "preset:" id)
       (string->symbol (substring id 7 (string-length id)))))

(effects! '(read))
(define (prompt-editor--preset-file name)
  (let ((path (string-append (compos-priv-dir) "/presets/" (symbol->string name) ".md")))
    (and (file-exists? path) path)))

(define (prompt-editor--file id)
  "the file a section is read from, or #f when code makes it"
  (let ((pf (assoc id (prompt-files)))
        (pn (prompt-editor--preset-name id)))
    (cond (pf (cadr pf))
          (pn (prompt-editor--preset-file pn))
          (else #f))))

(define (prompt-editor--kind chat id)
  (cond ((assoc id (prompt-files)) "file")
        ((prompt-editor--preset-name id) "preset")
        ((assoc id (prompt-buffer-parts chat)) "mode")
        (else "code")))

(define (prompt-editor--row chat id text held?)
  (let ((off (member id (prompt-disabled-parts chat))))
    (list 'id id 'text text 'kind (prompt-editor--kind chat id)
          'file (prompt-editor--file id)
          'held held? 'on (and held? (not off))
          'bytes (string-byte-length text))))

(define (prompt-editor-sections chat)
  "(prompt-editor-sections CHAT) -- every section CHAT gets or can get, in send order, then the presets it does not hold"
  (let* ((src (chat-prompt-source-parts chat))
         (held (map (lambda (p) (prompt-editor--row chat (car p) (cadr p) #t)) src))
         (more (filter (lambda (p) (not (assoc (car p) src)))
                       (preset-prompt-parts (map car *chat-presets*)))))
    (append held (map (lambda (p) (prompt-editor--row chat (car p) (cadr p) #f)) more))))

(define (prompt-editor-section chat id)
  "(prompt-editor-section CHAT ID) -- the section ID of CHAT, or #f"
  (find (lambda (r) (equal? (plist-get r 'id) id)) (prompt-editor-sections chat)))

;;; ------------------------------------------------------------- listing

(define (prompt-editor--listing) (list-mode-group-buffer *prompt-editor-mode*))

(define (prompt-editor--chat)
  "the chat the app works on: the listing's, else the one of this group"
  (let ((l (prompt-editor--listing)))
    (or (and (buffer-known? l)
             (let ((c (buffer-local-value 'prompt-editor-chat l))) (and c (buffer-known? c) c)))
        (llm-preset-target))))

(define (prompt-editor--state r)
  (cond ((plist-get r 'on) (list "on" "good"))
        ((plist-get r 'held) (list "off" "bad"))
        (else (list "not held" "warn"))))

(define (prompt-editor--rows buf)
  (let ((chat (buffer-local-value 'prompt-editor-chat buf)))
    (if (and chat (buffer-known? chat)) (prompt-editor-sections chat) '())))

(define (prompt-editor--cells buf r)
  (list (plist-get r 'id) (car (prompt-editor--state r)) (plist-get r 'kind)
        (number->string (plist-get r 'bytes))))

(define (prompt-editor--columns buf)
  (list (list "SECTION" #f 'style 'title)
        (list "STATE" 10 'style (lambda (buf r) (list 'badge (cadr (prompt-editor--state r)))))
        (list "SOURCE" 8 'style 'dim)
        (list "BYTES" 7 'style 'dim)))

(define (prompt-editor--list-imenu buf)
  (map (lambda (r off)
         (list (with-current-buffer buf (lambda () (line-number-at-pos off)))
               "section" (plist-get r 'id)
               (string-append (car (prompt-editor--state r)) " · " (plist-get r 'kind)
                              " · " (number->string (plist-get r 'bytes)) " bytes")))
       (prompt-editor--rows buf) (list-offsets buf)))

(define (prompt-editor--title buf)
  (let* ((chat (buffer-local-value 'prompt-editor-chat buf))
         (on (filter (lambda (r) (plist-get r 'on)) (prompt-editor--rows buf))))
    (string-append "Prompt of " (or chat "no chat") "   "
                   (number->string (length on)) " on · "
                   (number->string (fold (lambda (n r) (+ n (plist-get r 'bytes))) 0 on)) " bytes")))

(effects! '(write display))
(define-list-mode! *prompt-editor-mode*
  (list
    'doc (string-append
           "The sections of a chat's system prompt, in the order it gets them, then the presets it does not hold. "
           "Moving the point shows the section beside the list. e or RET edits its file, t turns it on or off for the chat, "
           "p adds or removes the preset that brings it, v shows the whole prompt, r refreshes a started conversation, "
           "g reads again, / narrows, q quits. The same keys work on the page.")
    'buffer "*prompt-editor*"
    'transient #f
    'selection-face "select"
    'selection-trim 1
    'rows prompt-editor--rows
    'key (lambda (buf r) (plist-get r 'id))
    'markable? (lambda (buf r) #f)
    'columns prompt-editor--columns
    'cells prompt-editor--cells
    'layouts (list (list 'name 'narrow 'max-cols (lambda (buf) 44)
                         'columns (lambda (buf) (let ((c (prompt-editor--columns buf))) (list (car c) (cadr c))))
                         'cells (lambda (buf r) (let ((c (prompt-editor--cells buf r))) (list (car c) (cadr c)))))
                   (list 'name 'wide 'default #t))
    'preview (lambda (buf r) (prompt-editor-show-detail! r))
    'title prompt-editor--title
    'noun "section"
    'footer (lambda (buf) (prompt-editor--keys-card '(("/" "filter") ("q" "quit"))))
    'keys (append (map (lambda (v) (list (car v) (cadr v))) prompt-editor-verbs)
                  '(("RET" "prompt-editor-edit") ("q" "quit-window")))))

;;; -------------------------------------------------------------- detail

(define-mode *prompt-editor-detail-mode* (lambda () (buffer-set-read-only! (current-buffer) #t)))
(mode-keys! *prompt-editor-detail-mode* (map (lambda (v) (list (car v) (cadr v))) prompt-editor-verbs))
(mode-doc! *prompt-editor-detail-mode*
  "One prompt section: its state in the chat, where it comes from and its text. e edits its file, t turns it on or off, p adds or removes its preset, v shows the whole prompt, r refreshes the chat, g reads again; C-` walks the pages you opened.")
(detail-name! *prompt-editor-detail-mode*
  (lambda (buf) (string-append "*prompt:" (or (buffer-local-value 'prompt-editor-section buf) buf) "*")))
(app-detail-keys! *prompt-editor-mode* *prompt-editor-detail-mode*)

(effects! '(pure))
(define (prompt-editor-detail-buffer r) (string-append "*prompt-editor:" (plist-get r 'id) "*"))

(define (prompt-editor--source-line r)
  (let ((kind (plist-get r 'kind)) (file (plist-get r 'file)))
    (cond (file (string-append file ". e edits it."))
          ((equal? kind "preset") "The preset's prompt is set in code with preset-prompt!; it has no file.")
          ((equal? kind "mode") "A mode of the chat adds it with prompt-part-set!; it has no file.")
          (else "Code makes it when the prompt is composed; it has no file."))))

(define (prompt-editor--page-blocks r)
  (let ((st (prompt-editor--state r)))
    (list
      (component 'ui/title (list 'text (plist-get r 'id) 'badge (car st) 'tone (cadr st)))
      (component 'ui/meta (list 'segs (list (list "" (plist-get r 'kind))
                                            '("c-sep" "  ·  ")
                                            (list "c-dim" (string-append (number->string (plist-get r 'bytes)) " bytes")))))
      (component 'ui/actions
        (list 'actions (map (lambda (v) (if (pair? (cdddr v))
                                            (list (cadr v) (caddr v) (car v) (cadddr v))
                                            (list (cadr v) (caddr v) (car v))))
                            prompt-editor-verbs)))
      (component 'ui/group
        (list 'title "Source"
              'body (list (list 'tag "c-group" 'class "c-prose" 'text (prompt-editor--source-line r)))))
      (component 'ui/group
        (list 'title "Text"
              'body (list (component 'ui/quote (list 'text (plist-get r 'text))))))
      (list 'tag "c-group" 'class "c-dim" 'text "end"))))

(effects! '(write))
(define (prompt-editor--render-page! buf r)
  (buffer-set-read-only! buf #f)
  (anchor-page! buf (prompt-editor--page-blocks r))
  (buffer-set-local! buf 'footer-line-blocks
    (list (component 'ui/keys-bar
            (list 'main (prompt-editor--keys-card '(("C-`" "next page") ("M-RET" "keep")))))))
  (buffer-set-read-only! buf #t))

(define (prompt-editor--claim! buf role)
  (let ((g (and (boundp 'group-here) (group-here))))
    (when (and g (not (equal? (buffer-group buf) g))) (buffer-move-to-group! buf g))
    (app-claim! buf *prompt-editor-id* role)))

(effects! '(write display))
(define (prompt-editor-show-detail! r)
  "(prompt-editor-show-detail! SECTION) -- draw SECTION's page and show it beside the listing"
  (when r
    (let ((buf (prompt-editor-detail-buffer r)))
      (unless (buffer-known? buf)
        (buffer-create buf)
        (with-current-buffer buf (lambda () (set-mode! *prompt-editor-detail-mode*)))
        (desktop-skip! buf 'render-blocks)
        (desktop-skip! buf 'footer-line-blocks))
      (prompt-editor--claim! buf 'detail)
      (buffer-set-local! buf 'prompt-editor-section (plist-get r 'id))
      (prompt-editor--render-page! buf r)
      (display-buffer-detail! buf (prompt-editor--listing)))))

(effects! '(write))
(define (prompt-editor--redraw! id)
  (let ((l (prompt-editor--listing)) (chat (prompt-editor--chat)))
    (when (buffer-known? l) (list-refresh! l))
    (let ((r (and chat (prompt-editor-section chat id))))
      (when r
        (let ((buf (prompt-editor-detail-buffer r)))
          (when (buffer-known? buf) (prompt-editor--render-page! buf r)))))))

;;; ------------------------------------------------------------- actions
;; One function per verb takes the chat and the section. Both keys reach
;; it through prompt-editor--at: the page's own section, else the row.

(effects! '(read))
(define (prompt-editor--at)
  (let ((id (buffer-local-value 'prompt-editor-section (current-buffer)))
        (chat (prompt-editor--chat)))
    (or (and id chat (prompt-editor-section chat id))
        (let ((l (prompt-editor--listing))) (and (buffer-known? l) (list-current l))))))

(effects! '(write))
(define (prompt-editor-toggle! chat id)
  "(prompt-editor-toggle! CHAT ID) -- turn section ID on or off in CHAT's prompt"
  (let ((off (prompt-disabled-parts chat)))
    (chat-prompt-sections-set! chat
      (if (member id off) (filter (lambda (n) (not (equal? n id))) off) (cons id off)))
    (prompt-editor--redraw! id)
    (if (member id (prompt-disabled-parts chat)) "off" "on")))

(define (prompt-editor-preset-toggle! chat id)
  "(prompt-editor-preset-toggle! CHAT ID) -- add the preset of section ID to CHAT, or remove it"
  (let ((p (prompt-editor--preset-name id)))
    (chat-preset-toggle! chat p)
    (prompt-editor--redraw! id)
    (if (member p (chat-presets-of chat)) "preset added" "preset removed")))

(define (prompt-editor--act f)
  (let ((r (prompt-editor--at)) (chat (prompt-editor--chat)))
    (cond ((not chat) (message "No chat in this group"))
          ((not r) (message "No section here"))
          (else (f chat r)))))

(effects! '(write display))
(define-command "prompt-editor-edit" "Edit the file of the prompt section at point"
  (lambda ()
    (prompt-editor--act
      (lambda (chat r)
        (if (plist-get r 'file)
            (find-file-other-window (plist-get r 'file))
            (message (prompt-editor--source-line r)))))))

(define-command "prompt-editor-toggle" "Turn the prompt section at point on or off for the chat"
  (lambda ()
    (prompt-editor--act
      (lambda (chat r)
        (if (not (plist-get r 'held))
            (message "The chat does not hold this preset; p adds it")
            (message (string-append (plist-get r 'id) ": "
                                    (prompt-editor-toggle! chat (plist-get r 'id)))))))))

(define-command "prompt-editor-preset" "Add the preset of the section at point to the chat, or remove it"
  (lambda ()
    (prompt-editor--act
      (lambda (chat r)
        (if (not (prompt-editor--preset-name (plist-get r 'id)))
            (message "This section is not a preset's")
            (message (string-append (plist-get r 'id) ": "
                                    (prompt-editor-preset-toggle! chat (plist-get r 'id)))))))))

(define-command "prompt-editor-view" "Show the chat's whole system prompt"
  (lambda ()
    (let ((chat (prompt-editor--chat)))
      (if chat
          (prompt-report-anchors! (help-doc! "system prompt" (chat-prompt-report chat)))
          (message "No chat in this group")))))

(define-command "prompt-editor-refresh-chat" "Give the chat's started conversation the current sections"
  (lambda ()
    (let ((chat (prompt-editor--chat)))
      (if chat
          (begin (chat-refresh-prompt! chat) (message (string-append chat ": prompt refreshed")))
          (message "No chat in this group")))))

(define-command "prompt-editor-revert" "Read the sections again"
  (lambda ()
    (let ((r (prompt-editor--at)))
      (if r (prompt-editor--redraw! (plist-get r 'id))
          (let ((l (prompt-editor--listing))) (when (buffer-known? l) (list-refresh! l)))))))

;;; ---------------------------------------------------------- the way in

;;;###autoload
(define-command "prompt-editor" "List the sections of this chat's system prompt, with the presets' prompts"
  (lambda ()
    (let ((chat (llm-preset-target)))
      (if (not chat)
          (message "No chat here: open one with M-x chat first")
          (let ((buf (prompt-editor--listing)))
            (buffer-create buf)
            (prompt-editor--claim! buf 'list)
            (buffer-set-local! buf 'prompt-editor-chat chat)
            (with-current-buffer buf (lambda () (set-mode! *prompt-editor-mode*)))
            (buffer-set-local! buf 'imenu-index-function 'prompt-editor--list-imenu)
            (list-refresh! buf)
            (app-open! buf)
            (prompt-editor-show-detail! (list-current buf))
            buf)))))

(effects! '(read))
(public! 'prompt-editor-sections "(prompt-editor-sections CHAT) -- every prompt section CHAT gets or can get, as plists: id text kind file held on bytes")
(public! 'prompt-editor-section "(prompt-editor-section CHAT ID) -- the section ID of CHAT, or #f")
(effects! '(write))
(public! 'prompt-editor-toggle! "(prompt-editor-toggle! CHAT ID) -- turn section ID on or off in CHAT's prompt")
(public! 'prompt-editor-preset-toggle! "(prompt-editor-preset-toggle! CHAT ID) -- add the preset of section ID to CHAT, or remove it")
(effects! '(write display))
(public! 'prompt-editor-show-detail! "(prompt-editor-show-detail! SECTION) -- show SECTION's page beside the listing")

(provide 'prompt-editor)
