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
;;;   C-h m   describe-mode      — this buffer's mode and its keys
;;;   C-h b   describe-bindings  — every binding, local first

(define *help-buffer* "*Help*")
(add-display-rule! *help-buffer* 'popup)

;;; --- the mechanism -------------------------------------------------------------

;; markdown in a table cell: "|" ends the cell and "*" starts an italic,
;; and docstrings contain both ("the *ibuffer* listing")
(define (help--cell s)
  (string-join (string-split (string-join (string-split s "|") "\\|") "*") "\\*"))

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

(global-set-key "C-h m" "describe-mode")
(global-set-key "C-h b" "describe-bindings")

(category! 'help)
(public! 'help-doc!
  "(help-doc! TITLE MARKDOWN) — open MARKDOWN as a rendered, read-only page in *Help*")
(public! 'mode-doc! "(mode-doc! MODE DOC) — what a mode is for; describe-mode prints it")
(public! 'local-keys "(local-keys BUF) — ((KEYS COMMAND) ...) for BUF's own bindings")
