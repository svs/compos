;;; editor.scm --- the editor, in Scheme.
;;;
;;; The Elixir core knows nothing about what keys mean or what commands do.
;;; Everything here is userland: redefine any of it from init.scm or M-:.

;;; --- public API registry -----------------------------------------------------
;;; The supported surface, curated: name + one-line doc. Everything else in
;;; the global namespace is implementation detail — callable, but private by
;;; convention. The LLM's apropos-api searches this registry by default, so
;;; the model discovers a documented API instead of hundreds of internals.
;;; Declare yours next to its definition: (public! 'my-fn "what it does").

(define *public-api* '())

(define (public! name doc)
  (set! *public-api*
    (cons (list (symbol->string name) doc)
          (remove (lambda (e) (equal? (car e) (symbol->string name)))
                  *public-api*))))

(define (public-api) (reverse *public-api*))

;;; --- editing commands ------------------------------------------------------

(define-command "forward-char" "Move point one character forward"
  (lambda () (forward-char!)))
(define-command "backward-char" "Move point one character backward"
  (lambda () (backward-char!)))
(define-command "next-line" "Move point down one line" (lambda () (next-line!)))
(define-command "previous-line" "Move point up one line" (lambda () (previous-line!)))
(define-command "beginning-of-line" "Move point to the beginning of the line"
  (lambda () (beginning-of-line!)))
(define-command "end-of-line" "Move point to the end of the line"
  (lambda () (end-of-line!)))
(define-command "beginning-of-buffer" "Move point to the beginning of the buffer"
  (lambda () (beginning-of-buffer!)))
(define-command "end-of-buffer" "Move point to the end of the buffer"
  (lambda () (end-of-buffer!)))

(define-command "newline" "Insert a newline at point" (lambda () (insert! "\n")))
(define-command "delete-backward-char" "Delete the character before point"
  (lambda () (delete-char! -1)))
(define-command "delete-char" "Delete the character after point"
  (lambda () (delete-char! 1)))

(define-command "kill-line" "Kill text from point to end of line"
  (lambda ()
    (let ((killed (kill-line!)))
      (if (equal? killed "") #f (kill-push! killed)))))

(define-command "yank" "Reinsert the last killed text at point"
  (lambda () (insert! (kill-top))))

(define-command "undo" "Undo the last change"
  (lambda ()
    (if (not (undo!)) (message "No further undo information"))))

;;; --- minibuffer --------------------------------------------------------------
;;; The minibuffer is a real buffer (" *minibuf*"): point motion, kill/yank,
;;; undo and M-DEL all work in prompts for free via the global keymap. Only
;;; prompt-specific behavior is bound here, in its local keymap.

(define-command "minibuffer-confirm" "Accept the selected minibuffer candidate"
  (lambda () (minibuffer-confirm!)))
(define-command "minibuffer-confirm-input" "Accept the minibuffer input exactly as typed"
  (lambda () (minibuffer-confirm-input!)))
(define-command "minibuffer-cancel" "Cancel the minibuffer prompt"
  (lambda () (minibuffer-cancel!)))
(define-command "minibuffer-complete" "Complete the minibuffer input"
  (lambda () (minibuffer-complete!)))
(define-command "minibuffer-next-candidate" "Select the next minibuffer candidate"
  (lambda () (minibuffer-next!)))
(define-command "minibuffer-previous-candidate" "Select the previous minibuffer candidate"
  (lambda () (minibuffer-prev!)))
(define-command "minibuffer-delete-backward" "Delete the character before point"
  (lambda () (minibuffer-del!)))

(let ((mb (minibuffer-buffer)))
  (local-set-key* mb "RET" "minibuffer-confirm")
  (local-set-key* mb "M-RET" "minibuffer-confirm-input")
  (local-set-key* mb "C-g" "minibuffer-cancel")
  (local-set-key* mb "TAB" "minibuffer-complete")
  (local-set-key* mb "C-n" "minibuffer-next-candidate")
  (local-set-key* mb "<down>" "minibuffer-next-candidate")
  (local-set-key* mb "C-p" "minibuffer-previous-candidate")
  (local-set-key* mb "<up>" "minibuffer-previous-candidate")
  (local-set-key* mb "DEL" "minibuffer-delete-backward"))

;;; --- hooks (Emacs-style, all Scheme) ----------------------------------------

(define *hooks* '())

(define (add-hook! hook fn) (set! *hooks* (cons (list hook fn) *hooks*)))

(define (run-hooks hook)
  (for-each (lambda (h) (if (equal? (car h) hook) ((cadr h)))) *hooks*))

;;; --- modes ------------------------------------------------------------------
;;; A major mode = mode-name buffer-local + a setup fn (local keys, vars).
;;; The registry, auto-mode-alist, everything: userland.

(define *mode-setups* '())

(define (define-mode name setup)
  (set! *mode-setups* (cons (list name setup) *mode-setups*))
  ;; every mode is an M-x command, like Emacs
  (define-command name (lambda () (set-mode! name))))

(define (set-mode! name)
  (buffer-set-local! (current-buffer) 'mode-name name)
  (let ((m (assoc name *mode-setups*)))
    (if m ((cadr m))))
  (run-hooks (string->symbol (string-append name "-hook"))))

;;; --- minor modes --------------------------------------------------------------
;;; A minor mode = its name in the buffer-local 'minor-modes list + an
;;; idempotent setup fn taking the buffer. Desktop restore re-runs the
;;; setup (restore-minor-modes!) after locals come back, the same way
;;; set-mode! re-runs major-mode setup — so setup fns must rebuild
;;; presentation from the locals they find, never stack hooks twice.

(define *minor-mode-setups* '())   ; (name setup teardown)

(define (register-minor-mode! name setup &optional teardown)
  (set! *minor-mode-setups*
    (cons (list name setup teardown) *minor-mode-setups*)))

(define (minor-mode-on? buf name)
  (let ((ms (buffer-local buf 'minor-modes)))
    (if (and ms (member name ms)) #t #f)))

(define (enable-minor-mode! buf name)
  (let ((cur (or (buffer-local buf 'minor-modes) '())))
    (unless (member name cur)
      (buffer-set-local! buf 'minor-modes (cons name cur))))
  (let ((m (assoc name *minor-mode-setups*)))
    (if m ((cadr m) buf))))

(define (disable-minor-mode! buf name)
  (buffer-set-local! buf 'minor-modes
    (remove (lambda (n) (equal? n name))
            (or (buffer-local buf 'minor-modes) '())))
  (let ((m (assoc name *minor-mode-setups*)))
    (if (and m (caddr m)) ((caddr m) buf))))

(define (toggle-minor-mode! name)
  (let ((buf (current-buffer)))
    (if (minor-mode-on? buf name)
        (begin (disable-minor-mode! buf name) #f)
        (begin (enable-minor-mode! buf name) #t))))

(define (restore-minor-modes! buf)
  (for-each
    (lambda (name)
      (let ((m (assoc name *minor-mode-setups*)))
        (if m ((cadr m) buf))))
    (or (buffer-local buf 'minor-modes) '())))

(define *auto-mode-alist*
  '((".scm" "scheme-mode") (".el" "scheme-mode")
    (".ex" "elixir-mode") (".exs" "elixir-mode")
    (".json" "json-mode") (".rs" "rust-mode")
    (".html" "html-mode") (".htm" "html-mode")
    (".md" "text-mode") (".txt" "text-mode") (".org" "org-mode")
    (".chat" "chat-mode")))

(define (auto-mode path)
  (for-each
    (lambda (entry)
      (if (string-suffix? (car entry) path)
          (set-mode! (cadr entry))))
    *auto-mode-alist*))

(define-mode "text-mode" (lambda () #t))
(define-mode "scheme-mode" (lambda () #t))   ; scheme grammar pending

;;; --- context providers --------------------------------------------------------
;;; A mode can explain what the user is looking at: (register-context-provider!
;;; "notmuch-mode" fn) where fn takes the buffer name and returns a short
;;; description or #f. chat-send and agent-send prepend the visible windows'
;;; contexts, so "this" in a chat means the thing selected in the other window.

(define *context-providers* '())   ; ((mode-name fn) ...)

(define (register-context-provider! mode fn)
  (set! *context-providers*
    (cons (list mode fn)
          (filter (lambda (e) (not (equal? (car e) mode))) *context-providers*))))

(define (buffer-context buf)
  (let ((p (assoc (or (buffer-local buf 'mode-name) "") *context-providers*)))
    (and p ((cadr p) buf))))

;; contexts of every visible buffer except EXCLUDE (the chat itself),
;; deduped; "" when no provider speaks up
(define (editor-context exclude)
  (let loop ((ws (window-list)) (seen '()) (acc '()))
    (if (null? ws)
        (string-join (reverse acc) "\n")
        (let ((buf (cadr (car ws))))
          (if (or (equal? buf exclude) (member buf seen))
              (loop (cdr ws) seen acc)
              (let ((ctx (buffer-context buf)))
                (loop (cdr ws) (cons buf seen)
                      (if ctx (cons ctx acc) acc))))))))

;; the paragraph chat/agent sends prepend when a context provider fires
(define (editor-context-preamble exclude)
  (let ((ctx (editor-context exclude)))
    (if (equal? ctx "")
        ""
        (string-append
          "[Editor context — what the user is looking at right now:\n" ctx
          "\nWhen the user says \"this\" they mean the item above.]\n\n"))))

(define (ts-mode lang)
  (lambda () (buffer-set-local! (current-buffer) 'ts-lang lang)))

(define-mode "html-mode" (lambda () #t))

;; preview-mode: render the buffer instead of showing its source.
;; Renderer picked by *preview-renderers* (extension -> renderer); the
;; frontend knows "html" and "markdown". Add your own:
;;   (set! *preview-renderers* (cons '(".rst" "markdown") *preview-renderers*))
(define *preview-renderers*
  '((".html" "html") (".htm" "html") (".svg" "html")
    (".md" "markdown") (".markdown" "markdown") (".org" "markdown")
    (".txt" "markdown")))

(define (preview-renderer-for name)
  (let loop ((rs *preview-renderers*))
    (if (null? rs)
        #f
        (if (string-suffix? (car (car rs)) name)
            (cadr (car rs))
            (loop (cdr rs))))))

;; revert-buffer: re-read the file from disk (discards buffer edits).
;; Kill + re-visit so modes, hooks and fontification re-apply cleanly.
(define-command "revert-buffer" "Re-read the current buffer's file from disk"
  (lambda ()
    (let* ((buf (current-buffer))
           (path (buffer-path buf))
           (p (point)))
      (if (not path)
          (message "Buffer is not visiting a file")
          (begin
            (buffer-kill! buf)
            (visit path)
            (goto-char! (min p (buffer-size (current-buffer))))
            (message "Reverted"))))))

(define-command "preview-mode" "Toggle rendered preview of the current buffer"
  (lambda ()
    (if (buffer-local (current-buffer) 'render-mode)
        (begin
          (buffer-set-local! (current-buffer) 'render-mode #f)
          (message "Preview off"))
        (let ((r (preview-renderer-for (current-buffer))))
          (if r
              (begin
                (buffer-set-local! (current-buffer) 'render-mode r)
                (message (string-append "Preview on (" r ") — C-c C-v toggles")))
              (message "No preview renderer for this buffer"))))))

(define-mode "elixir-mode" (ts-mode "elixir"))
(define-mode "json-mode" (ts-mode "json"))
(define-mode "rust-mode" (ts-mode "rust"))

;;; --- sexp / structural navigation (tree-sitter) ------------------------------

(define (ts-goto op)
  (let ((p (ts-nav op)))
    (if p (goto-char! p) (message "No structural navigation here"))))

(define-command "forward-sexp" "Move forward across one balanced expression"
  (lambda () (ts-goto 'forward)))
(define-command "backward-sexp" "Move backward across one balanced expression"
  (lambda () (ts-goto 'backward)))
(define-command "backward-up-list" "Move backward out of one level of parentheses"
  (lambda () (ts-goto 'up)))
(define-command "down-list" "Move forward down one level of parentheses"
  (lambda () (ts-goto 'down)))

;;; --- word motion & editing ---------------------------------------------------

(define (delete-between! s e)
  (set-mark! e)
  (goto-char! s)
  (delete-region!)
  (set-mark! #f))

(define-command "forward-word" "Move point forward one word" (lambda () (forward-word!)))
(define-command "backward-word" "Move point backward one word"
  (lambda () (backward-word!)))

(define-command "kill-word" "Kill characters forward to the end of a word"
  (lambda ()
    (let ((s (point)))
      (let ((e (forward-word!)))
        (if (> e s)
            (begin
              (kill-push! (buffer-substring s e))
              (delete-between! s e)))))))

(define-command "backward-kill-word" "Kill characters backward to the start of a word"
  (lambda ()
    (let ((e (point)))
      (let ((s (backward-word!)))
        (if (< s e)
            (begin
              (kill-push! (buffer-substring s e))
              (delete-between! s e)))))))

(define-command "transpose-chars" "Interchange characters around point"
  (lambda ()
    (if (= (point) (buffer-size (current-buffer))) (backward-char!))
    (if (> (point) 0)
        (let ((p (point)))
          (let ((s (backward-char!)))
            (goto-char! p)
            (let ((e (forward-char!)))
              (let ((a (buffer-substring s p))
                    (b (buffer-substring p e)))
                (delete-between! s e)
                (insert! (string-append b a)))))))))

;;; --- yank / yank-pop ----------------------------------------------------------

(define *yank-start* 0)
(define *yank-index* 0)

(define-command "yank" "Reinsert the last killed text at point"
  (lambda ()
    (set! *yank-index* 0)
    (set! *yank-start* (point))
    (insert! (kill-top))))

(define-command "yank-pop" "Replace just-yanked text with an earlier kill"
  (lambda ()
    (if (or (equal? (last-command) "yank") (equal? (last-command) "yank-pop"))
        (let ((n (kill-ring-size)))
          (if (> n 0)
              (begin
                (delete-between! *yank-start* (point))
                (set! *yank-index* (if (= (+ *yank-index* 1) n) 0 (+ *yank-index* 1)))
                (insert! (kill-nth *yank-index*)))))
        (message "Previous command was not a yank"))))

;;; --- completion framework (capf) ---------------------------------------------
;;; A completion source is a closure of no arguments returning either
;;;   #f                                — source has nothing here
;;;   (list start end candidates)      — region to replace + candidates,
;;;                                       each a string or (label hint) pair
;;; Sources are tried in order; first non-#f wins (Emacs capf semantics).
;;; An LSP client is just another source returning the same shape.
;;; Buffer-local sources: (buffer-set-local! buf 'capf-sources (list fn ...))

(define *capf-sources* '())

(define (add-capf! fn)
  (set! *capf-sources* (cons fn *capf-sources*)))

(define (capf-sources)
  (let ((local (buffer-local (current-buffer) 'capf-sources)))
    (if local (append local *capf-sources*) *capf-sources*)))

(define-command "completion-at-point" "Perform completion on the text around point"
  (lambda ()
    (let loop ((sources (capf-sources)))
      (if (null? sources)
          (begin
            (completion-dismiss!)
            (message "No completions here"))
          (let ((r ((car sources))))
            (if r
                (completion-show! (car r) (cadr r) (caddr r))
                (loop (cdr sources))))))))

;; dabbrev: complete the word before point from words in this buffer
(define (capf-dabbrev)
  (let ((e (point)))
    (let ((s (backward-word!)))
      (goto-char! e)
      (if (and (< s e) (> e s))
          (let ((prefix (buffer-substring s e)))
            (let ((words (buffer-words prefix)))
              (if (null? words)
                  #f
                  (list s e (map (lambda (w) (list w "dabbrev")) words)))))
          #f))))

(add-capf! capf-dabbrev)

;;; --- misc editing --------------------------------------------------------------

(define-command "indent-for-tab" "Indent by inserting two spaces"
  (lambda () (insert! "  ")))

;;; --- scrolling (viewport) ------------------------------------------------------

(define (move-lines n mover)
  (let loop ((i 0))
    (if (< i n)
        (begin (mover) (loop (+ i 1))))))

(define-command "scroll-up-command" "Scroll text upward nearly a full screen"
  (lambda () (move-lines (- (window-rows) 2) next-line!)))

(define-command "scroll-down-command" "Scroll text downward nearly a full screen"
  (lambda () (move-lines (- (window-rows) 2) previous-line!)))

(define-command "recenter-top-bottom" "Recenter point in the window"
  (lambda () (recenter!)))

(define-command "display-line-numbers-mode" "Toggle line numbers in the current buffer"
  (lambda ()
    (let ((cur (buffer-local (current-buffer) 'line-numbers)))
      (if (equal? cur "off")
          (begin
            (buffer-set-local! (current-buffer) 'line-numbers "on")
            (message "Line numbers enabled"))
          (begin
            (buffer-set-local! (current-buffer) 'line-numbers "off")
            (message "Line numbers disabled"))))))

;; window split/resize animations — CSS falls back to 140ms when the
;; chrome face doesn't say otherwise; this flips it to 0ms and back
(define *window-animations* #t)

(define-command "toggle-window-animations" "Toggle window split and resize animations"
  (lambda ()
    (set! *window-animations* (not *window-animations*))
    (set-face-attribute! 'chrome 'anim (if *window-animations* "140ms" "0ms"))
    (message (if *window-animations*
                 "Window animations on"
                 "Window animations off"))))

(define-command "back-to-indentation" "Move point to the first non-space on this line"
  (lambda ()
    (beginning-of-line!)
    (let loop ()
      (let ((p (point)))
        (if (and (< p (buffer-size (current-buffer)))
                 (equal? (buffer-substring p (+ p 1)) " "))
            (begin (forward-char!) (loop)))))))

(define-command "goto-line" "Go to a line number read from the minibuffer"
  (lambda ()
    (minibuffer-read "Goto line: " '()
      (lambda (s)
        (let ((n (string->number s)))
          (if (number? n)
              (begin
                (goto-char! 0)
                (let loop ((i 1))
                  (if (< i n)
                      (begin (next-line!) (loop (+ i 1)))))
                (beginning-of-line!))
              (message "Not a number")))))))

;;; --- mark & region ---------------------------------------------------------

(define-command "set-mark-command" "Set the mark where point is"
  (lambda ()
    (set-mark! (point))
    (message "Mark set")))

(define-command "kill-region" "Kill the text between point and mark"
  (lambda ()
    (let ((text (region-text)))
      (if (equal? text "")
          (message "The region is empty")
          (begin
            (kill-push! text)
            (delete-region!)
            (set-mark! #f))))))

(define-command "copy-region-as-kill" "Save the region as if killed, but don't kill it"
  (lambda ()
    (let ((text (region-text)))
      (if (equal? text "")
          (message "The region is empty")
          (begin
            (kill-push! text)
            (set-mark! #f)
            (message "Copied"))))))

(define-command "exchange-point-and-mark" "Exchange positions of point and mark"
  (lambda ()
    (if (not (exchange-point-and-mark!))
        (message "No mark set in this buffer"))))

;;; --- isearch ---------------------------------------------------------------
;;; Incremental: each keystroke re-searches from the origin. The current match
;;; is shown as the region (mark at match start, point at match end).
;;; RET accepts, C-g restores point. (C-s-repeat needs minibuffer keymaps: TODO.)

(define *isearch-origin* 0)

(define (isearch-update query backward)
  (if (equal? query "")
      (begin (set-mark! #f) (goto-char! *isearch-origin*))
      (let ((m (if backward
                   (buffer-search-backward query *isearch-origin*)
                   (buffer-search query *isearch-origin*))))
        (if m
            (if backward
                (begin (set-mark! (cadr m)) (goto-char! (car m)))
                (begin (set-mark! (car m)) (goto-char! (cadr m))))
            (message (string-append "Failing I-search: " query))))))

(define (isearch backward)
  (set! *isearch-origin* (point))
  (minibuffer-read* (if backward "I-search backward: " "I-search: ") '()
    (list (list 'change (lambda (q)
                          (with-window-buffer
                            (lambda () (isearch-update q backward)))))
          (list 'confirm (lambda (q) (set-mark! #f)))
          (list 'cancel (lambda ()
                          (set-mark! #f)
                          (goto-char! *isearch-origin*))))))

(define-command "isearch-forward" "Do incremental search forward"
  (lambda () (isearch #f)))
(define-command "isearch-backward" "Do incremental search backward"
  (lambda () (isearch #t)))

;;; --- files & buffers -------------------------------------------------------

(define-command "save-buffer" "Save the current buffer to its file"
  (lambda ()
    (run-hooks 'before-save-hook)
    (let ((path (buffer-save!)))
      (if path
          (begin
            (run-hooks 'after-save-hook)
            (message (string-append "Wrote " path)))
          (message "Buffer has no file")))))

;; Filename completion — pure Scheme over list-dir/string primitives.
;; A completion fn maps input -> (list new-input candidates).
;; Emacs' double-slash rule: "~/foo//etc" means "/etc" — typing an absolute
;; path over the default-directory prefill just works.
(define (normalize-file-input input)
  (let ((i (string-rindex input "//")))
    (if i
        (substring input (+ i 1) (string-length input))
        input)))

(define (path-split input)
  (let ((idx (string-rindex input "/")))
    (if idx
        (list (substring input 0 (+ idx 1))
              (substring input (+ idx 1) (string-length input)))
        (list "" input))))

;; (file-complete input selected) -> (list new-input candidates)
;; selected: a candidate the user arrowed onto — inserted into the path,
;; directories auto-descend and list their contents.
(define (file-complete input0 selected)
  (if selected
      ;; insert the arrowed-onto candidate verbatim: directories descend to
      ;; their listing, files complete to themselves — no further chaining
      (let ((parts (path-split (normalize-file-input input0))))
        (let ((ni (string-append (car parts) selected)))
          (if (string-suffix? "/" selected)
              (list ni (list-dir ni))
              (list ni (list selected)))))
      (let ((input (normalize-file-input input0)))
        (let ((parts (path-split input)))
          (let ((dir (car parts))
                (base (cadr parts)))
            (let ((entries (list-dir dir)))
              (let ((matches (filter (lambda (e) (string-prefix? base e)) entries)))
                (if (null? matches)
                    (list input entries)
                    (let ((ni (string-append dir (common-prefix matches))))
                      (if (and (null? (cdr matches))
                               (string-suffix? "/" (car matches)))
                          ;; unique directory: descend and list (stop there —
                          ;; don't chain-complete into a lone file)
                          (list ni (list-dir ni))
                          (list ni matches)))))))))))

;; live listing while typing (vertico-style) — but only re-list when the
;; DIRECTORY part changes; basename narrowing is the core's display filter.
;; Re-listing big directories on every keystroke stats thousands of files.
(define *file-nav-dir* #f)

(define (file-nav-change inp)
  (let ((dir (car (path-split (normalize-file-input inp)))))
    (if (equal? dir *file-nav-dir*)
        #t
        (begin
          (set! *file-nav-dir* dir)
          (minibuffer-set-candidates! (list-dir dir))))))

(define (visit path0)
  (let ((path (normalize-file-input path0)))
    (if (file-directory? path)
        (dired-open path)
        (begin
          (switch-to-buffer! (find-file path))
          (auto-mode path)
          (run-hooks 'find-file-hook)))))

(define-command "find-file" "Visit a file, prompting with filename completion"
  (lambda ()
    (let ((dd (default-directory)))
      (set! *file-nav-dir* dd)
      (minibuffer-read* "Find file: " (list-dir dd)
        (list (list 'complete file-complete)
              (list 'change file-nav-change)
              (list 'initial dd)
              (list 'confirm visit))))))

;; MRU-ordered, current excluded: first candidate = the buffer you just
;; left, so C-x b RET toggles between two buffers (Emacs buffer ring)
(define (buffer-candidates)
  (map (lambda (b)
         (list b (let ((p (buffer-path b))) (if p p ""))))
       (filter (lambda (b) (not (equal? b (current-buffer)))) (buffer-list-mru))))

(define-command "switch-to-buffer" "Switch to another buffer in the current window"
  (lambda ()
    (let ((cands (buffer-candidates)))
      (minibuffer-read
        (if (null? cands)
            "Switch to buffer: "
            (string-append "Switch to buffer (default " (car (car cands)) "): "))
        cands
        (lambda (name)
          (if (not (equal? name ""))
              (switch-to-buffer! name)))))))

(define-command "kill-buffer" "Kill a buffer, defaulting to the current one"
  (lambda ()
    (let ((cur (current-buffer)))
      ;; current buffer is the default: first candidate, RET kills it
      (minibuffer-read (string-append "Kill buffer (default " cur "): ")
        (cons (list cur "current") (buffer-candidates))
        (lambda (name)
          (let ((target (if (equal? name "") cur name)))
            (buffer-kill! target)
            (if (equal? target cur)
                ;; land on the most recently used other buffer
                (let ((others (filter (lambda (b) (not (equal? b target)))
                                      (buffer-list-mru))))
                  (switch-to-buffer!
                    (if (null? others) "*scratch*" (car others)))))
            (message (string-append "Killed " target))))))))

;;; --- display-buffer & popups (popper) ----------------------------------------
;;; *display-buffer-alist*: (pattern action) rules; pattern is a substring
;;; match on the buffer name; actions: 'same | 'popup (bottom side window).
;;; The popup window is popper-style: one at a time, C-` toggles it.

(define *display-buffer-alist*
  '(("*shell*" popup) ("*messages*" popup) ("*llm*" popup)))

(define (add-display-rule! pattern action)
  (set! *display-buffer-alist*
    (cons (list pattern action) *display-buffer-alist*)))

(define (display-action-for name)
  (let loop ((rules *display-buffer-alist*))
    (if (null? rules)
        'same
        (if (string-contains? name (car (car rules)))
            (cadr (car rules))
            (loop (cdr rules))))))

(define *popup-window* #f)
(define *popup-buffer* #f)

(define (window-exists? id)
  (assoc id (window-list)))

;; a leftover popup that became the sole window (C-x 1 from inside it)
;; is not a popup anymore — treat it as closed so display-buffer splits
(define (popup-open?)
  (and *popup-window*
       (window-exists? *popup-window*)
       (not (null? (cdr (window-list))))))

(define (popup-show name)
  (set! *popup-buffer* name)
  (if (popup-open?)
      (begin
        (select-window! *popup-window*)
        (switch-to-buffer! name))
      (begin
        (split-window! 'v 0.7)          ; bottom ~30% side window
        (other-window!)
        (set! *popup-window* (active-window))
        (switch-to-buffer! name))))

(define (display-buffer name)
  (if (equal? (display-action-for name) 'popup)
      (popup-show name)
      (switch-to-buffer! name)))

(define-command "popup-toggle" "Toggle the bottom popup window"
  (lambda ()
    (if (popup-open?)
        (begin
          (delete-window-id! *popup-window*)
          (set! *popup-window* #f))
        (if *popup-buffer*
            (popup-show *popup-buffer*)
            (message "No popup buffer yet")))))

;; q in special buffers: close the popup, or fall back to the MRU buffer
(define-command "quit-window" "Close the popup or fall back to the previous buffer"
  (lambda ()
    (if (and (popup-open?) (equal? (active-window) *popup-window*))
        (begin
          (delete-window-id! *popup-window*)
          (set! *popup-window* #f))
        (let ((others (buffer-candidates)))
          (if (null? others)
              (message "Nothing to quit to")
              (switch-to-buffer! (car (car others))))))))

(define-command "view-messages" "Display the *messages* buffer"
  (lambda () (display-buffer "*messages*")))

(define-command "scroll-other-window" "Scroll the next window up nearly a full screen"
  (lambda ()
    (let ((wins (window-list)))
      (if (null? (cdr wins))
          (message "No other window")
          (let loop ((ws wins))
            (if (equal? (car (car ws)) (active-window))
                (let ((next (if (null? (cdr ws)) (car wins) (car (cdr ws)))))
                  (scroll-window! (car next) (- (window-rows) 2)))
                (loop (cdr ws))))))))

;;; --- shell (comint) --------------------------------------------------------
;;; RET in a process buffer sends the current line to the process (deleting
;;; it first — the pty echo brings it back); RET elsewhere is just a newline.

;; Comint contract: processes run with TERM=dumb and are expected to degrade
;; (bash does automatically; zsh needs zle/prompt padding off — the flags
;; below, or the classic `[[ $TERM == dumb ]] && unsetopt zle prompt_cr
;; prompt_sp` in your zshrc). fish refuses dumb terminals — it belongs in
;; term-mode (real terminal emulator pane), not comint.
;; Override *shell-command* in your init.scm.
(define *shell-command* "exec /bin/zsh -f -i +o zle +o prompt_cr +o prompt_sp")

(define-command "shell" "Run an inferior shell in the *shell* buffer"
  (lambda ()
    (if (not (process-running? "*shell*"))
        (start-process! "*shell*" *shell-command*))
    (display-buffer "*shell*")
    (buffer-set-local! "*shell*" 'mode-name "Shell")
    (end-of-buffer!)))

(define-command "newline-or-send" "Send input to the process, or insert a newline"
  (lambda ()
    (if (process-running? (current-buffer))
        ;; comint: input = text after the process mark. Typed input STAYS in
        ;; the buffer (pty echo is off) — nothing flickers or disappears.
        (let ((pm (process-mark (current-buffer)))
              (eob (end-of-buffer!)))
          (let ((input (buffer-substring pm eob)))
            (insert! "\n")
            (process-send! (current-buffer) (string-append input "\n"))))
        (insert! "\n"))))

;;; --- LLM pipes (gptel) -----------------------------------------------------
;;; (llm prompt handler) is the async primitive; everything here is
;;; composition. Handlers are ordinary closures — build your own pipelines.

(define (llm-on-region instruction handler)
  (let ((text (region-text)))
    (if (equal? text "")
        (message "No region — set the mark first (C-SPC)")
        (begin
          (message "LLM thinking...")
          (llm (string-append instruction
                              "\n\nReturn ONLY the result, no commentary.\n\n"
                              text)
               handler)))))

;; M-| : region -> LLM -> *llm* buffer
(define-command "llm-pipe-region" "Pipe the region through the LLM into *llm*"
  (lambda ()
    (minibuffer-read "LLM instruction: " '()
      (lambda (instr)
        (llm-on-region instr
          (lambda (result)
            (buffer-create "*llm*")
            (buffer-append! "*llm*" (string-append "\n;; " instr "\n" result "\n"))
            (message "LLM done -> *llm*")))))))

;; region -> LLM -> replaced in place
(define-command "llm-replace-region" "Transform the region in place with the LLM"
  (lambda ()
    (minibuffer-read "Transform region: " '()
      (lambda (instr)
        (llm-on-region instr
          (lambda (result)
            (delete-region!)
            (insert! result)
            (set-mark! #f)
            (message "Region transformed")))))))

(global-set-key "M-|" "llm-pipe-region")

;;; --- chat buffer (gptel-style) -------------------------------------------------
;;; *chat* is an ordinary editable buffer. Type after the "### You" marker,
;;; press C-c RET, and the whole buffer becomes the conversation context.

(define *chat-buffer* "*chat*")

(define (chat-prompt-marker) "\n### You\n")
(define (chat-reply-marker) "\n### Assistant\n")

;; a real mode so desktop restore can rebuild the local keys. A chat that
;; carries the block model ('agent-saved-mark) is a rich companion surface:
;; it opts into the same native renderer as agent threads, RET sends, and
;; a stale "⋯ thinking" from before a restart is swept away.
(define-mode "chat-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (local-set-key "C-c RET" "chat-send")
      (local-set-key "C-c m" "chat-set-model")
      (local-set-key "C-c $" "chat-cost")
      (local-set-key "C-c b" "chat-set-backend")
      (local-set-key "C-c C-k" "chat-reset")
      (local-set-key "C-c C-s" "chat-save")
      ;; an agent-backed chat needs the thread keys back after restore
      ;; (the runtime itself does not survive — agent-send revives it)
      (when (and (buffer-local buf 'agent-slug)
                 (boundp (quote agent-install-keys!)))
        (agent-install-keys! buf))
      ;; legacy: pre-group companions carried a 'companion-of pointer —
      ;; upgrade both ends to the 'group tag (idempotent, so desktop
      ;; restore migrates old sessions by itself)
      (let ((doc (buffer-local buf 'companion-of)))
        (when (and doc (not (buffer-local buf 'group)))
          (let ((g (or (and (buffer-exists? doc) (buffer-local doc 'group))
                       doc)))
            (buffer-set-local! buf 'group g)
            (when (and (buffer-exists? doc)
                       (not (buffer-local doc 'group)))
              (buffer-set-local! doc 'group g)))))
      (when (buffer-local buf 'agent-saved-mark)
        (buffer-set-local! buf 'render-mode "agent")
        (buffer-set-local! buf 'agent-marker-bytes
          (string-byte-length *chat-input-marker*))
        ;; the modeline states the backend: connector for agent-backed
        ;; chats, "companion · model" for the API lane. An agent-backed
        ;; chat also sheds stale permission/waiting cards on restore —
        ;; the runtime they belonged to did not survive the restart
        ;; (agent-mode-setup! does the same for *agent:* buffers)
        (if (buffer-local buf 'agent-slug)
            (begin
              (agent-update-modeline! buf)
              (agent-block-drop-kind! buf "permission")
              (agent-block-drop-kind! buf "waiting"))
            (buffer-set-local! buf 'modeline-info
              (string-append "companion · " (llm-model))))
        (chat-clear-waiting! buf)
        (local-set-key "RET" "chat-send")
        (local-set-key "S-RET" "newline")
        (local-set-key "C-c C-v" "chat-toggle-view")
        ;; a restored point can land inside the marker — typing/pasting
        ;; there corrupts the input boundary (bytes end up pre-marker)
        (chat-snap-to-input!)))))

;; adopt the most recent titled chat after a daemon restart
;; (unless fresh — chat-new wants a brand new conversation)
(define (chat-ensure! &optional fresh)
  (if (not (buffer-exists? *chat-buffer*))
      (let ((chats (if fresh
                       '()
                       (append
                         (filter (lambda (b) (string-prefix? "*llm:" b))
                                 (buffer-list-mru))
                         (filter (lambda (b) (string-prefix? "*llm:" b))
                                 (buffer-list))))))
        (if (null? chats)
            (begin
              (buffer-create *chat-buffer*)
              (buffer-append! *chat-buffer*
                (string-append ";; ai-max chat · " (llm-model)
                               " · C-c RET sends · C-c m switches model"
                               (chat-prompt-marker))))
            (set! *chat-buffer* (car chats))))))

(define-command "chat" "Open the LLM chat buffer"
  (lambda ()
    (chat-ensure!)
    (switch-to-buffer! *chat-buffer*)
    (set-mode! "chat-mode")
    (end-of-buffer!)))

;; the native tool loop is Anthropic-only — on an openai:/openrouter: model
;; a chat quietly runs tool-less instead of erroring, so any default model
;; from ai-config just works
(define (chat-tools-usable?)
  (not (or (string-prefix? "openai:" (llm-model))
           (string-prefix? "openrouter:" (llm-model)))))

;; tools when the tools package is loaded and chat-use-tools is on; presets
;; and cost tracking apply to plain chats exactly like rich ones
(define (chat-llm buf prompt handler)
  (if (and (boundp (quote chat-use-tools)) chat-use-tools (chat-tools-usable?))
      (llm-tools prompt *llm-system*
                 (append (llm-tool-specs) (chat-extra-specs buf))
                 llm-tool-call handler
                 (lambda (u) (chat-usage-note! buf u)))
      (llm prompt handler)))

;; the per-send system preamble: a grouped chat points the model at the
;; group's work buffers (pull context — the tools read live buffers, so it
;; is never stale); with tools off the documents are pushed inline instead
(define (chat-preamble buf)
  (let* ((g (buffer-group buf))
         (docs (if g (group-docs g) '()))
         (tools? (and (boundp (quote chat-use-tools)) chat-use-tools)))
    (string-append
      (editor-context-preamble buf)
      (chat-preamble-body g docs tools?))))

(define (chat-preamble-body g docs tools?)
  (cond
      ((null? docs)
       (string-append
         "You are the assistant in an editor chat buffer. The transcript "
         "follows; reply to the last user turn only, in markdown.\n\n"))
      ((null? (cdr docs))
       ;; one document: the writing-companion voice
       (let ((doc (car docs)))
         (string-append
           "You are the user's writing companion in a side chat. They are "
           "writing in the editor buffer named \"" doc "\"."
           (if tools?
               (string-append
                 " Never guess its contents: call read-doc with that buffer "
                 "name before commenting, and change it with edit-doc "
                 "(exact unique old string -> new string; it edits the live "
                 "buffer, never the file). Match the document's voice and "
                 "make the smallest edit that does the job.")
               (string-append
                 "\n\nThe document right now:\n\n" (buffer-text doc)))
           "\n\nThe chat transcript follows; reply to the last user turn "
           "only, in markdown.\n\n")))
      (else
       ;; several buffers: enumerate the group, let the tools pull content
       (string-append
         "You are the user's companion in a side chat for their buffer "
         "group \"" g "\". The group's buffers:\n"
         (fold (lambda (acc d)
                 (string-append acc "- \"" d "\""
                   (let ((m (buffer-local d 'mode-name)))
                     (if m (string-append " (" m ")") ""))
                   "\n"))
               "" docs)
         (if tools?
             (string-append
               "Never guess their contents: call read-doc with a buffer "
               "name before commenting, and change one with edit-doc "
               "(exact unique old string -> new string; it edits the live "
               "buffer, never the file). Make the smallest edit that does "
               "the job.")
             (fold (lambda (acc d)
                     (string-append acc "\n\"" d "\" right now:\n\n"
                                    (buffer-text d) "\n"))
                   "" docs))
         "\n\nThe chat transcript follows; reply to the last user turn "
         "only, in markdown.\n\n"))))

;; sends from whichever chat buffer it is invoked in (chat-mode-local key);
;; rich companion surfaces take the block path, plain chats the markdown one
(define-command "chat-send" "Send the current chat input to the LLM"
  (lambda ()
    (let ((buf (current-buffer)))
      (cond ((buffer-local buf 'agent-slug)
             ;; agent-backed chat: the thread machinery owns the turn
             ;; (streaming, tool cards, permissions, revive-on-dead)
             (run-command "agent-send"))
            ((buffer-local buf 'agent-saved-mark)
             (chat-send-rich! buf))
            (else (chat-send-plain! buf))))))

;;; --- chat backends -------------------------------------------------------------
;;; A chat can ride an ACP agent (claude-code, codex — subscription billing)
;;; instead of the metered API: the buffer stays the same conversation, a
;;; thread binds to it by slug, and the agent's MCP servers come from the
;;; chat's presets plus the editor's own tool proxy. C-c b switches.

(define (chat-attach-agent! buf connector)
  (let ((slug (or (buffer-local buf 'agent-slug) (agent-next-slug))))
    (buffer-set-local! buf 'agent-slug slug)
    (buffer-set-local! buf 'agent-connector connector)
    (let ((mark (or (buffer-local buf 'agent-saved-mark)
                    ;; plain chat: give it the marker structure threads use
                    (let ((m (buffer-size buf)))
                      (buffer-append! buf *chat-input-marker*)
                      (buffer-set-local! buf 'agent-marker-bytes
                        (string-byte-length *chat-input-marker*))
                      (buffer-set-local! buf 'render-mode "agent")
                      m))))
      (buffer-set-local! buf 'agent-saved-mark mark)
      (agent-install-keys! buf)
      (agent-update-modeline! buf)
      (agent-start! slug
        (append (list 'buffer buf 'mark mark)
                (agent-resolve-config
                  (list 'connector connector
                        'presets (if (boundp (quote chat-presets-of))
                                     (chat-presets-of buf)
                                     '())))))
      slug)))

;; a chat saved as a file IS a revivable conversation: the plain-chat
;; transcript is its own format (### You / ### Assistant, whole buffer =
;; context), and .chat files open straight into chat-mode. Rich block
;; chats flatten to that plain form on save.
(define-command "chat-save" "Save this chat as a .chat file (revivable)"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (not (or (chat-buffer? buf) (buffer-local buf 'agent-saved-mark)))
          (message "not a chat buffer")
          (minibuffer-read "Save chat to: " '()
            (lambda (path0)
              (let ((path (expand-path
                            (if (string-suffix? ".chat" path0)
                                path0
                                (string-append path0 ".chat")))))
                (write-file! path
                  (if (buffer-local buf 'agent-saved-mark)
                      ;; flatten the block transcript to the plain format
                      (let loop ((ts (reverse (chat-turns buf))) (acc ""))
                        (if (null? ts)
                            (string-append acc (chat-prompt-marker))
                            (loop (cdr ts)
                                  (string-append acc
                                    (if (equal? (car (car ts)) "user")
                                        (chat-prompt-marker)
                                        (chat-reply-marker))
                                    (cadr (car ts)) "\n"))))
                      (buffer-text buf)))
                (message (string-append "Saved — (visit \"" path
                                        "\") revives it")))))))))

;; wipe the conversation, keep the surface: group, model, backend and keys
;; survive; rich chats get their meta card back, plain chats their banner
(define-command "chat-reset" "Reset this chat: clear the transcript, start fresh"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (not (or (chat-buffer? buf) (buffer-local buf 'agent-saved-mark)))
          (message "not a chat buffer")
          (let ((rich? (buffer-local buf 'agent-saved-mark))
                (g (buffer-group buf)))
            (overlay-clear! buf "all")
            (buffer-set-hidden! buf '())
            (for-each (lambda (k) (buffer-set-local! buf k #f))
                      (list 'chat-turns 'agent-blocks 'agent-overlays
                            'agent-folds 'agent-queued 'chat-cost
                            'chat-last-usage 'agent-saved-mark))
            (buffer-delete-range! buf 0 (buffer-size buf))
            (if rich?
                (group-chat-init! buf (or g buf))
                (buffer-append! buf
                  (string-append ";; ai-max chat · " (llm-model)
                                 " · C-c RET sends · C-c m switches model"
                                 (chat-prompt-marker))))
            (set-mode! "chat-mode")
            (end-of-buffer!)
            (message "Chat reset"))))))

(define-command "chat-set-backend" "Power this chat by the API or an agent connector"
  (lambda ()
    (let ((buf (current-buffer)))
      (if (not (equal? (buffer-local buf 'mode-name) "chat-mode"))
          (message "not a chat buffer")
          (minibuffer-read "Backend: "
            (cons (list "api" "direct API — metered, cached, cheap lane")
                  (map (lambda (c) (list c "ACP agent — rides your subscription"))
                       (connector-names)))
            (lambda (choice)
              (cond ((equal? choice "") #f)
                    ((equal? choice "api")
                     (let ((slug (buffer-local buf 'agent-slug)))
                       (when slug (agent-kill! slug))
                       (buffer-set-local! buf 'agent-slug #f)
                       (message "chat backend: api")))
                    (else
                      (chat-attach-agent! buf choice)
                      (message (string-append "chat backend: " choice
                                " — subscription billing, editor tools via MCP"))))))))))

;; the reply appends by name, and point only follows when the user is
;; still in the chat — a companion must not yank point in the document
(define (chat-send-plain! buf)
  (let ((convo (buffer-text buf)))
    (buffer-append! buf (chat-reply-marker))
    (end-of-buffer!)
    (message "LLM thinking...")
    (chat-llm buf (string-append (chat-preamble buf) convo)
         (lambda (reply)
           (buffer-append! buf
             (string-append
               (if (equal? (string-trim reply) "")
                   "(no reply — the model returned no text; its tool calls are traced in *messages*)"
                   reply)
               (chat-prompt-marker)))
           (when (equal? (current-buffer) buf)
             (end-of-buffer!))
           (message (chat-ready-message buf))
           (when (equal? buf "*chat*")
             (chat-maybe-title!))))))

;;; --- rich chat transcript (the agent thread design) ---------------------------
;;; A companion chat maintains the exact locals the native agent renderer
;;; reads — render-mode "agent", 'agent-blocks byte ranges, 'agent-saved-mark
;;; + 'agent-marker-bytes for the ╰─ you ▸ input region — so it inherits the
;;; serif prose, user cards, and tool cards wholesale. No runtime behind it:
;;; the mark lives in 'agent-saved-mark, the conversation in 'chat-turns.
;;; Buffer layout: [help][transcript … mark][╰─ you ▸ ][input].

(define *chat-input-marker* "\n╰─ you ▸ ")

(define (chat-mark buf) (or (buffer-local buf 'agent-saved-mark) 0))

(define (chat-blocks-push! buf start end kind meta)
  (buffer-set-local! buf 'agent-blocks
    (cons (append (list start end kind) meta)
          (or (buffer-local buf 'agent-blocks) '()))))

(define (chat-blocks-drop! buf kind)
  (buffer-set-local! buf 'agent-blocks
    (filter (lambda (b) (not (equal? (car (cdr (cdr b))) kind)))
            (or (buffer-local buf 'agent-blocks) '()))))

;; append at the mark — after every recorded range, so stored offsets
;; never shift; the input region past the marker slides along
(define (chat-render! buf text)
  (let ((start (chat-mark buf)))
    (buffer-insert! buf start text)
    (buffer-set-local! buf 'agent-saved-mark
      (+ start (string-byte-length text)))
    start))

(define (chat-input buf)
  (substring-bytes (buffer-text buf)
                   (+ (chat-mark buf) (string-byte-length *chat-input-marker*))
                   (buffer-size buf)))

(define (chat-clear-input! buf)
  (let ((start (+ (chat-mark buf) (string-byte-length *chat-input-marker*))))
    (buffer-delete-range! buf start (- (buffer-size buf) start))))

;; the conversation the LLM sees — decoupled from buffer text, which now
;; also holds tool cards and help
(define (chat-turns buf) (or (buffer-local buf 'chat-turns) '()))

(define (chat-turn-push! buf role text)
  (buffer-set-local! buf 'chat-turns
    (cons (list role text) (chat-turns buf))))

(define (chat-transcript buf)
  (let loop ((ts (reverse (chat-turns buf))) (acc ""))
    (if (null? ts)
        acc
        (loop (cdr ts)
              (string-append acc
                (if (equal? (car (car ts)) "user") "### You\n" "### Assistant\n")
                (car (cdr (car ts))) "\n\n")))))

(define (chat-show-waiting! buf)
  (let ((start (chat-render! buf "⋯ thinking\n")))
    (chat-blocks-push! buf start (chat-mark buf) "waiting" '())
    (buffer-set-local! buf 'chat-waiting (list start (chat-mark buf)))))

(define (chat-clear-waiting! buf)
  (let ((w (buffer-local buf 'chat-waiting)))
    (when w
      (buffer-delete-range! buf (car w) (- (car (cdr w)) (car w)))
      (buffer-set-local! buf 'agent-saved-mark
        (- (chat-mark buf) (- (car (cdr w)) (car w))))
      (chat-blocks-drop! buf "waiting")
      (buffer-set-local! buf 'chat-waiting #f))))

(define (chat-ellipsize s n)
  (if (> (string-length s) n) (string-append (substring s 0 n) " …") s))

;; every tool call becomes a card: header + trimmed result body, closed
;; "done" immediately (the loop is synchronous per call)
(define (chat-tool-dispatch buf)
  (lambda (name args)
    ;; first sign of life ends the waiting line — before any block lands,
    ;; so its deletion can never shift recorded offsets
    (chat-clear-waiting! buf)
    (let* ((hstart (chat-render! buf (string-append "\n▸ " name "\n")))
           (bstart (chat-mark buf))
           (result (llm-tool-call name args))
           (shown (chat-ellipsize
                    (string-trim (if (string? result) result (value->string result)))
                    400)))
      (unless (equal? shown "")
        (chat-render! buf (string-append shown "\n")))
      (chat-blocks-push! buf hstart (chat-mark buf) "tool"
        (list (number->string hstart) name "tool" "done" bstart))
      result)))

;; presets (packages/mcp.scm) add MCP tool specs per chat; usage lands in
;; buffer-locals so every chat knows what it cost (persists with the chat)
(define (chat-extra-specs buf)
  (if (boundp (quote chat-extra-tool-specs))
      (chat-extra-tool-specs buf)
      '()))

(define (chat-usage-note! buf u)
  (let ((cost (custom--plist-get u 'cost)))
    (buffer-set-local! buf 'chat-last-usage u)
    (when cost
      (let ((total (+ (or (buffer-local buf 'chat-cost) 0) cost)))
        (buffer-set-local! buf 'chat-cost total)
        (when (buffer-local buf 'agent-saved-mark)
          (buffer-set-local! buf 'modeline-info
            (string-append "companion · " (llm-model) " · " (format-usd total))))))))

(define (chat-ready-message buf)
  (let ((u (buffer-local buf 'chat-last-usage)))
    (string-append "Reply ready"
      (if (and u (custom--plist-get u 'cost))
          (string-append " · " (format-usd (custom--plist-get u 'cost))
                         " (chat total " (format-usd (or (buffer-local buf 'chat-cost) 0)) ")")
          ""))))

(define (chat-llm-rich buf prompt handler)
  (if (and (boundp (quote chat-use-tools)) chat-use-tools (chat-tools-usable?))
      (llm-tools prompt *llm-system*
                 (append (llm-tool-specs) (chat-extra-specs buf))
                 (chat-tool-dispatch buf) handler
                 (lambda (u) (chat-usage-note! buf u)))
      (llm prompt handler)))

(define (chat-send-rich! buf)
  (let ((input (string-trim (chat-input buf))))
    (if (equal? input "")
        (message "Say something first")
        (begin
          (chat-clear-input! buf)
          (chat-turn-push! buf "user" input)
          (let ((start (chat-render! buf
                         (string-append "\n╰─ you ▸ " input "\n\n"))))
            (chat-blocks-push! buf start (chat-mark buf) "user" (list input)))
          (chat-show-waiting! buf)
          (message "LLM thinking...")
          (chat-llm-rich buf
            (string-append (chat-preamble buf) (chat-transcript buf))
            (lambda (reply)
              (chat-clear-waiting! buf)
              (let ((text (if (equal? (string-trim reply) "")
                              "(no reply — the model returned no text)"
                              reply)))
                (chat-turn-push! buf "assistant" text)
                (let ((start (chat-render! buf (string-append text "\n"))))
                  (chat-blocks-push! buf start (chat-mark buf) "prose" '())))
              (message (chat-ready-message buf))))))))

(define-command "chat-toggle-view" "Toggle between rich and plain chat transcript"
  (lambda ()
    (let* ((buf (current-buffer))
           (rich? (equal? (buffer-local buf 'render-mode) "agent")))
      (buffer-set-local! buf 'render-mode (if rich? #f "agent"))
      (message (if rich? "plain transcript" "rich transcript")))))

;;; --- chat titles -------------------------------------------------------------
;;; The first reply names the chat: a cheap llm call summarises the
;;; conversation and the buffer becomes e.g. "*llm:org mode font change*".
;;; There is no rename primitive, so retitle = copy text + mode into the
;;; new name, repoint windows, kill the old buffer.

(define *chat-auto-title* #t)   ; tests switch this off

(define (chat-title->name title)
  (let* ((clean (string-trim
                  (re-replace-all " +"
                    (re-replace-all "[^a-z0-9 -]" (string-downcase title) "")
                    " ")))
         (short (if (> (string-length clean) 40)
                    (substring clean 0 40)
                    clean)))
    (string-append "*llm:" short "*")))

(define (chat-retitle! old new)
  (if (and (buffer-exists? old) (not (buffer-exists? new)))
      (let ((was (active-window)))
        (buffer-create new)
        (buffer-append! new (buffer-text old))
        ;; group membership, presets, and spend must survive the rename
        (let ((g (buffer-group old)))
          (when g (buffer-set-local! new 'group g)))
        (for-each
          (lambda (k)
            (let ((v (buffer-local old k)))
              (when v (buffer-set-local! new k v))))
          '(chat-presets chat-cost chat-last-usage chat-turns))
        (for-each
          (lambda (w)
            (if (equal? (cadr w) old)
                (begin
                  (select-window! (car w))
                  (switch-to-buffer! new)
                  (set-mode! "chat-mode")
                  (end-of-buffer!))))
          (window-list))
        (if (equal? *popup-buffer* old) (set! *popup-buffer* new))
        (if (equal? *chat-buffer* old) (set! *chat-buffer* new))
        (buffer-kill! old)
        (if (window-exists? was) (select-window! was)))))

(define (chat-maybe-title!)
  (if (and *chat-auto-title* (equal? *chat-buffer* "*chat*"))
      (let ((convo (buffer-text *chat-buffer*)))
        (llm (string-append
               "Give a 3-6 word title for this conversation. Reply with ONLY "
               "the title: lower case, no punctuation, no quotes.\n\n" convo)
             (lambda (title)
               (chat-retitle! "*chat*" (chat-title->name title)))))))

;; Models offered by C-c m / M-x chat-set-model. Override in your
;; ~/.aimax/ai-config.scm:  (set! *llm-models* (list "openai:gpt-5.6-luna" ...))
;; Provider prefix routes the request (llm.ex): openai:/openrouter:/bare=anthropic.
(define *llm-models*
  (list "openai:gpt-5.6-luna"
        "openrouter:anthropic/claude-sonnet-5"
        "claude-sonnet-5"
        "claude-opus-5"
        "claude-haiku-4-5-20251001"))

(define-command "chat-set-model" "Choose the LLM model from the minibuffer"
  (lambda ()
    (minibuffer-read (string-append "Model (now " (llm-model) "): ")
      *llm-models*
      (lambda (m)
        (set-llm-model! m)
        (when (buffer-local (current-buffer) 'agent-saved-mark)
          (buffer-set-local! (current-buffer) 'modeline-info
            (string-append "companion · " m)))
        (message (string-append "LLM model: " m))))))

;; send the region to the chat buffer as context, then open it
(define-command "chat-send-region" "Add the region to the chat buffer as context"
  (lambda ()
    (let ((text (region-text)))
      (if (equal? text "")
          (message "No region")
          (begin
            (run-command "chat")
            (insert! (string-append "```\n" text "\n```\n"))
            (message "Region added to chat"))))))

;;; --- buffer groups: work buffers + one chat, tied by a tag --------------------
;;; A group is nothing but a shared buffer-local: every member — code, doc,
;;; AND the chat — carries 'group "name". The group is stored nowhere else;
;;; (group-buffers g) derives it on demand. So membership persists with the
;;; locals (desktop restore included), a killed buffer simply leaves the
;;; set, and the chat is found by role (chat-mode member), not by pointer.
;;; C-c w from a work buffer groups it by itself and opens the group chat
;;; on the right; C-c g joins a named group; C-c q talks to the group chat.
;;; The "*chat:" names avoid the "*chat*"/"*llm:" popup rules on purpose.

(define (buffer-group b)
  (or (buffer-local b 'group)
      ;; legacy: a pre-group companion pointer doubles as a group tag
      (buffer-local b 'companion-of)))

(define (group-buffers g)
  (filter (lambda (b) (equal? (buffer-group b) g)) (buffer-list)))

;; members in MRU order; buffers never visited this session trail behind
(define (group-buffers-mru g)
  (let ((mru (filter (lambda (b) (equal? (buffer-group b) g))
                     (buffer-list-mru))))
    (append mru (remove (lambda (b) (member b mru)) (group-buffers g)))))

(define (group-names)
  (fold (lambda (acc b)
          (let ((g (buffer-group b)))
            (if (and g (not (member g acc))) (append acc (list g)) acc)))
        '() (append (buffer-list-mru) (buffer-list))))

(define (chat-buffer? b)
  (equal? (buffer-local b 'mode-name) "chat-mode"))

(define (group-docs g) (remove chat-buffer? (group-buffers-mru g)))

(define (window-showing name)
  (let ((ws (filter (lambda (w) (equal? (cadr w) name)) (window-list))))
    (if (null? ws) #f (car (car ws)))))

;; a buffer with no group founds one named after itself
(define (group-ensure! b)
  (or (buffer-group b)
      (begin (buffer-set-local! b 'group b) b)))

;; a fresh group chat is a rich surface from birth: help on top (a "meta"
;; card in the agent design), then the ╰─ you ▸ input region
(define (group-chat-init! buf g)
  (let ((help (string-append
                "companion · " g "\n"
                "RET sends · C-c w hops to the document · "
                "C-c m model · C-c C-v plain view\n"
                "it reads the live buffers before it speaks, "
                "and edits them in place when you ask\n")))
    (buffer-append! buf help)
    (chat-blocks-push! buf 0 (string-byte-length help) "meta" '())
    (buffer-set-local! buf 'agent-saved-mark (string-byte-length help))
    (buffer-append! buf *chat-input-marker*)))

(define (group-chat-name g) (string-append "*chat:" g "*"))

;; the group's chat = its most recently used chat-mode member; created on
;; demand already tagged, so a killed chat is simply remade next time
(define (group-chat g)
  (let ((chats (filter chat-buffer? (group-buffers-mru g))))
    (if (pair? chats)
        (car chats)
        (let ((buf (group-chat-name g)))
          (unless (buffer-exists? buf)
            (buffer-create buf)
            (group-chat-init! buf g))
          (buffer-set-local! buf 'group g)
          buf))))

;; ensure the two-pane layout (work left, group chat right) and select the
;; chat window; returns the chat buffer name
(define (group-chat-show! g)
  (let ((buf (group-chat g)))
    (let ((w (window-showing buf)))
      (if w
          (select-window! w)
          (begin
            (delete-other-windows!)
            (split-window! 'h 0.6)
            (other-window!)
            (switch-to-buffer! buf))))
    (set-mode! "chat-mode")
    (end-of-buffer!)
    buf))

;; legacy entry point kept for scripts: DOC's companion = its group's chat
(define (chat-companion-show! doc)
  (group-chat-show! (group-ensure! doc)))

;; ask the group without leaving the current buffer: the minibuffer prompt
;; becomes a group-chat turn, point stays put, the reply lands on the right
(define (group-ask! g)
  (minibuffer-read (string-append "Ask " g ": ") (history-items 'companion-ask)
    (lambda (prompt)
      (history-push! 'companion-ask prompt)
      (let ((back (active-window)))
        (group-chat-show! g)
        (insert! prompt)
        (run-command "chat-send")
        (when (window-exists? back)
          (select-window! back))))))

;; C-c g : join (or found) a named group — read the code, the doc, and
;; chat about them all in one place
(define-command "group-add" "Join or found a named buffer group"
  (lambda ()
    (let ((buf (current-buffer)))
      (minibuffer-read "Group: " (group-names)
        (lambda (g)
          (if (equal? (string-trim g) "")
              (message "Group needs a name")
              (begin
                (buffer-set-local! buf 'group g)
                (message (string-append buf " joined group " g)))))))))

(define-command "group-remove" "Remove the current buffer from its group"
  (lambda ()
    (let* ((buf (current-buffer)) (g (buffer-group buf)))
      (if g
          (begin
            (buffer-set-local! buf 'group #f)
            (buffer-set-local! buf 'companion-of #f)
            (message (string-append buf " left group " g)))
          (message "Not in a group")))))

(define-command "group-list" "List the current buffer's group members"
  (lambda ()
    (let ((g (buffer-group (current-buffer))))
      (if g
          (message (string-append g ": "
                     (string-join (group-buffers-mru g) " · ")))
          (message "Not in a group")))))

;; make an existing conversation a group's chat: pick a buffer, join its
;; group (founding one named after it if it has none)
(define-command "chat-adopt" "Make this chat the companion of a chosen buffer"
  (lambda ()
    (let ((chat (current-buffer)))
      (minibuffer-read "Companion for buffer: "
        (filter (lambda (b) (not (equal? b chat))) (buffer-list-mru))
        (lambda (doc)
          (if (not (buffer-exists? doc))
              (message (string-append "No buffer " doc))
              (let ((g (group-ensure! doc)))
                (buffer-set-local! chat 'group g)
                (delete-other-windows!)
                (switch-to-buffer! doc)
                (split-window! 'h 0.6)
                (other-window!)
                (switch-to-buffer! chat)
                (set-mode! "chat-mode")
                (end-of-buffer!)
                (message (string-append chat " now accompanies " g)))))))))

;; C-c w toggles sides: in a work buffer it opens (or refocuses) the group
;; chat, grouping the buffer by itself first if needed; in the chat it hops
;; to the group's most recent work buffer; in a groupless chat it adopts
(define-command "chat-companion" "Toggle between a work buffer and its group chat"
  (lambda ()
    (let* ((cur (current-buffer))
           (g (buffer-group cur)))
      (cond ((and (chat-buffer? cur) g)
             (let ((docs (group-docs g)))
               (if (null? docs)
                   (message (string-append "Group " g " has no work buffers"))
                   (let ((w (window-showing (car docs))))
                     (if w
                         (select-window! w)
                         (switch-to-buffer! (car docs)))))))
            ((chat-buffer? cur) (run-command "chat-adopt"))
            (else (group-chat-show! (group-ensure! cur)))))))

;; C-c RET in a work buffer: talk to the group chat without leaving it.
;; (In chat buffers the chat-mode local C-c RET = chat-send wins.)
(define-command "chat-companion-ask" "Ask the group chat without leaving this buffer"
  (lambda ()
    (let ((cur (current-buffer)))
      (if (chat-buffer? cur)
          (run-command "chat-send")
          (group-ask! (group-ensure! cur))))))

;; C-c q : ask from anywhere. In a grouped buffer (its chat included) the
;; prompt becomes a turn in the group's one chat; ungrouped, it goes to
;; the global *chat* bottom popup — follow-ups with C-c RET, C-` dismisses.
(add-display-rule! "*chat*" 'popup)
(add-display-rule! "*llm:" 'popup)
(add-display-rule! "*llm-costs*" 'popup)

;;; --- llm cost inspection -----------------------------------------------------
;;; Every request is priced (models.dev catalog, cached in ~/.aimax/llmdb.json,
;;; refreshed daily) and recorded in ~/.aimax/llm-usage.jsonl; each chat also
;;; sums its own spend in the 'chat-cost buffer-local.

(define-command "chat-cost" "Show what this chat has cost"
  (lambda ()
    (let ((c (buffer-local (current-buffer) 'chat-cost))
          (u (buffer-local (current-buffer) 'chat-last-usage)))
      (if (not c)
          (message "No priced requests in this chat yet")
          (message
            (string-append "This chat: " (format-usd c)
              (if u
                  (string-append " · last turn "
                    (number->string (custom--plist-get u 'input)) "→"
                    (number->string (custom--plist-get u 'output)) " tokens"
                    (let ((tc (custom--plist-get u 'cost)))
                      (if tc (string-append " (" (format-usd tc) ")") "")))
                  "")))))))

(define-command "llm-costs" "Show LLM spend by day and model (the usage ledger)"
  (lambda ()
    (let ((rows (llm-cost-report))
          (buf "*llm-costs*"))
      (buffer-create buf)
      (buffer-delete-range! buf 0 (string-byte-length (buffer-text buf)))
      (buffer-append! buf
        (fold (lambda (acc r)
                (string-append acc
                  (custom--plist-get r 'day) "  "
                  (format-usd (custom--plist-get r 'cost)) "  "
                  (number->string (custom--plist-get r 'requests)) " reqs  "
                  (number->string (custom--plist-get r 'input)) "→"
                  (number->string (custom--plist-get r 'output)) "  "
                  (custom--plist-get r 'model) "\n"))
              "LLM spend · ledger ~/.aimax/llm-usage.jsonl · per-chat: C-c $\n\n"
              rows))
      (switch-to-buffer! buf))))

;; start a fresh conversation (the old one keeps its titled buffer)
(define-command "chat-new" "Start a fresh chat conversation"
  (lambda ()
    (set! *chat-buffer* "*chat*")
    (chat-ensure! #t)
    (run-command "chat")))

(define-command "llm-ask" "Ask the LLM from anywhere via the minibuffer"
  (lambda ()
    (let ((g (buffer-group (current-buffer))))
      (if g
          (group-ask! g)
          (minibuffer-read "Ask LLM: " (history-items 'llm-ask)
            (lambda (prompt)
              (history-push! 'llm-ask prompt)
              (chat-ensure!)
              (display-buffer *chat-buffer*)
              (set-mode! "chat-mode")
              (end-of-buffer!)
              (insert! prompt)
              (run-command "chat-send")))))))

(global-set-key "C-c c" "chat")
(global-set-key "C-c r" "chat-send-region")
(global-set-key "C-c q" "llm-ask")
(global-set-key "C-c w" "chat-companion")
(global-set-key "C-c g" "group-add")
(global-set-key "C-c RET" "chat-companion-ask")

;;; --- minibuffer history (vertico-style: last-used first) --------------------
;;; The candidate ranking in the core is a stable sort, so passing
;;; candidates history-first keeps them first among equal matches — the
;;; empty prompt shows pure recency, typing re-ranks fuzzily within it.

(define *minibuffer-history* '())   ; ((key (item ...)) ...), most recent first
(define *minibuffer-history-max* 50)

(define (history-items key)
  (let ((e (assoc key *minibuffer-history*)))
    (if e (cadr e) '())))

(define (take-n lst n)
  (if (or (null? lst) (= n 0))
      '()
      (cons (car lst) (take-n (cdr lst) (- n 1)))))

(define (history-push! key item)
  (let ((items (cons item (filter (lambda (x) (not (equal? x item)))
                                  (history-items key)))))
    (set! *minibuffer-history*
      (cons (list key (take-n items *minibuffer-history-max*))
            (filter (lambda (e) (not (equal? (car e) key)))
                    *minibuffer-history*)))))

;; reorder candidates so remembered ones lead, in recency order
(define (history-order key candidates)
  (let ((hist (filter (lambda (h) (member h candidates)) (history-items key))))
    (append hist (filter (lambda (c) (not (member c hist))) candidates))))

;;; --- M-x and eval ----------------------------------------------------------

;; marginalia: each candidate carries its keybinding and docstring
(define (command-annotation c)
  (let ((key (key-for-command c))
        (doc (command-doc c)))
    (cond ((equal? key "") doc)
          ((equal? doc "") key)
          (else (string-append key " · " doc)))))

(define-command "execute-extended-command"
  "Run a command by name, with its keybinding and doc alongside"
  (lambda ()
    (minibuffer-read "M-x "
      (map (lambda (c) (list c (command-annotation c)))
           (history-order 'M-x (command-names)))
      (lambda (cmd)
        (history-push! 'M-x cmd)
        (run-command cmd)))))

(define-command "eval-expression" "Evaluate a Scheme expression from the minibuffer"
  (lambda ()
    (minibuffer-read "Eval: " '()
      (lambda (src) (message (value->string (eval-string src)))))))

;;; --- live eval: the editor is its own REPL -----------------------------------

(define (echo-value v) (message (string-append "=> " (value->string v))))

(define (char-before i)
  (if (> i 0) (buffer-substring (- i 1) i) #f))

(define (eval-skip-ws-back i)
  (if (member (char-before i) '(" " "\n" "\t"))
      (eval-skip-ws-back (- i 1))
      i))

;; matching opener for the closer just before i (naive about escaped quotes)
(define (sexp-open-before i depth in-str)
  (if (= i 0) 0
      (let ((c (char-before i)))
        (cond
          (in-str (sexp-open-before (- i 1) depth (not (equal? c "\""))))
          ((equal? c "\"") (sexp-open-before (- i 1) depth #t))
          ((equal? c ")") (sexp-open-before (- i 1) (+ depth 1) #f))
          ((equal? c "(") (if (= depth 1) (- i 1)
                              (sexp-open-before (- i 1) (- depth 1) #f)))
          (else (sexp-open-before (- i 1) depth #f))))))

(define (atom-start i)
  (if (or (= i 0) (member (char-before i) '(" " "\n" "\t" "(" ")")))
      i
      (atom-start (- i 1))))

(define (last-sexp-start p)
  (if (equal? (char-before p) ")")
      (sexp-open-before p 0 #f)
      (atom-start p)))

(define-command "eval-last-sexp" "Evaluate sexp before point and echo the value"
  (lambda ()
    (let* ((p (eval-skip-ws-back (point)))
           (s (last-sexp-start p)))
      (if (< s p)
          (echo-value (eval-region (current-buffer) s p))
          (message "No sexp before point")))))

(define-command "eval-buffer" "Evaluate the current buffer as Scheme"
  (lambda () (echo-value (eval-buffer (current-buffer)))))

(define-command "eval-region" "Evaluate the region as Scheme"
  (lambda ()
    (if (mark)
        (echo-value (eval-region (current-buffer) (region-beginning) (region-end)))
        (message "No region — set the mark first (C-SPC)"))))

;; hot-reload a Scheme file into the live session (stdlib included)
(define-command "load-file" "Load a Scheme file into the live session"
  (lambda ()
    (let ((dd (default-directory)))
      (set! *file-nav-dir* dd)
      (minibuffer-read* "Load file: " (list-dir dd)
        (list (list 'complete file-complete)
              (list 'change file-nav-change)
              (list 'initial dd)
              (list 'confirm
                (lambda (path)
                  (load path)
                  (message (string-append "Loaded " path)))))))))

(define-command "keyboard-quit" "Quit the current operation and clear the mark"
  (lambda ()
    (set-mark! #f)
    (message "Quit")))

;;; --- tiling windows --------------------------------------------------------

(define-command "split-window-below" "Split the window in two, one above the other"
  (lambda () (split-window! 'v)))
(define-command "split-window-right" "Split the window in two, side by side"
  (lambda () (split-window! 'h)))
(define-command "delete-window" "Delete the selected window"
  (lambda () (if (not (delete-window!)) (message "Attempt to delete sole window"))))
(define-command "delete-other-windows" "Make the selected window the only one"
  (lambda () (delete-other-windows!)))

;; landing in a rich chat/agent window puts point in its input region —
;; the transcript is for reading, the prompt is where typing goes
(define (chat-snap-to-input!)
  (let ((buf (current-buffer)))
    (when (equal? (buffer-local buf 'render-mode) "agent")
      (let ((mark (or (buffer-local buf 'agent-saved-mark) 0))
            (mb (or (buffer-local buf 'agent-marker-bytes) 0)))
        (when (< (point) (+ mark mb))
          (end-of-buffer!))))))

(define-command "other-window" "Select another window in cyclic order"
  (lambda ()
    (other-window!)
    (chat-snap-to-input!)))

;; Cmd-arrows (s- = super) are geometric windmove: window-rects gives each
;; leaf's normalized frame rectangle, and the neighbor in DIR is the nearest
;; window past the active edge whose span contains the active center — so
;; motion follows what's on screen, not the split tree's shape.
(define (window-in-direction dir)
  (let* ((rs (window-rects))
         (me (let find ((l rs))
               (cond ((null? l) #f)
                     ((equal? (car (car l)) (active-window)) (car l))
                     (else (find (cdr l)))))))
    (and me
         (let* ((mx (list-ref me 2)) (my (list-ref me 3))
                (cx (+ mx (/ (list-ref me 4) 2)))
                (cy (+ my (/ (list-ref me 5) 2)))
                (eps 0.000001))
           (let loop ((l rs) (best #f) (bestd 999))
             (if (null? l)
                 best
                 (let* ((r (car l))
                        (x (list-ref r 2)) (y (list-ref r 3))
                        (w (list-ref r 4)) (h (list-ref r 5))
                        (d (cond ((equal? dir 'left)
                                  (and (<= (+ x w) (+ mx eps)) (<= y cy) (< cy (+ y h))
                                       (- mx (+ x w))))
                                 ((equal? dir 'right)
                                  (and (>= (+ x eps) (+ mx (list-ref me 4))) (<= y cy) (< cy (+ y h))
                                       (- x (+ mx (list-ref me 4)))))
                                 ((equal? dir 'up)
                                  (and (<= (+ y h) (+ my eps)) (<= x cx) (< cx (+ x w))
                                       (- my (+ y h))))
                                 (else
                                  (and (>= (+ y eps) (+ my (list-ref me 5))) (<= x cx) (< cx (+ x w))
                                       (- y (+ my (list-ref me 5))))))))
                   (if (and d (< d bestd))
                       (loop (cdr l) r d)
                       (loop (cdr l) best bestd)))))))))

(define (windmove! dir)
  (let ((w (window-in-direction dir)))
    (if w
        (begin (select-window! (car w))
               (chat-snap-to-input!))
        (message (string-append "No window " (symbol->string dir))))))

(define-command "windmove-left" "Select the window to the left"
  (lambda () (windmove! 'left)))
(define-command "windmove-right" "Select the window to the right"
  (lambda () (windmove! 'right)))
(define-command "windmove-up" "Select the window above"
  (lambda () (windmove! 'up)))
(define-command "windmove-down" "Select the window below"
  (lambda () (windmove! 'down)))

;; Cmd-Shift-arrows: carry the buffer over — swap this pane's buffer with
;; the directional neighbor's and follow it (Emacs windmove-swap-states)
(define (window-swap! dir)
  (let ((nb (window-in-direction dir)))
    (if nb
        (let ((mine (current-buffer)))
          (switch-to-buffer! (cadr nb))
          (select-window! (car nb))
          (switch-to-buffer! mine)
          (chat-snap-to-input!))
        (message (string-append "No window " (symbol->string dir))))))

(define-command "window-swap-left" "Swap this window's buffer leftward and follow it"
  (lambda () (window-swap! 'left)))
(define-command "window-swap-right" "Swap this window's buffer rightward and follow it"
  (lambda () (window-swap! 'right)))
(define-command "window-swap-up" "Swap this window's buffer upward and follow it"
  (lambda () (window-swap! 'up)))
(define-command "window-swap-down" "Swap this window's buffer downward and follow it"
  (lambda () (window-swap! 'down)))

;; S-<left>/<right>: walk buffer history — S-<left> goes to the buffer you
;; just left (MRU), pressing again goes deeper; S-<right> walks back. The
;; list freezes for the duration of a run (yank-pop's last-command trick),
;; else each switch would reorder MRU and the walk would toggle forever.
(define *buffer-cycle-ring* '())
(define *buffer-cycle-pos* 0)

(define (buffer-cycle! dir)
  (unless (member (last-command) '("next-buffer" "previous-buffer"))
    (set! *buffer-cycle-ring*
      (cons (current-buffer)
            (filter (lambda (b) (and (not (string-prefix? " " b))
                                     (not (equal? b (current-buffer)))))
                    (buffer-list-mru))))
    (set! *buffer-cycle-pos* 0))
  (let ((n (length *buffer-cycle-ring*)))
    (if (< n 2)
        (message "No other buffer")
        (begin
          (set! *buffer-cycle-pos* (modulo (+ *buffer-cycle-pos* dir) n))
          (switch-to-buffer! (list-ref *buffer-cycle-ring* *buffer-cycle-pos*))))))

(define-command "previous-buffer" "Switch to the previously used buffer (again = deeper)"
  (lambda () (buffer-cycle! 1)))
(define-command "next-buffer" "Walk back toward the most recently used buffer"
  (lambda () (buffer-cycle! -1)))

;; the UI reports clicks; which window gets focus and what that means
;; (chat focuses its input) is policy
(define (mouse-select-window! id)
  (select-window! id)
  (chat-snap-to-input!))

;; system clipboard: paste lands on the kill ring too (Emacs interprogram-paste)
(define (clipboard-paste! text)
  (kill-push! text)
  (insert! text))

;;; --- default keymap --------------------------------------------------------

(global-set-key "C-f" "forward-char")
(global-set-key "C-b" "backward-char")
(global-set-key "C-n" "next-line")
(global-set-key "C-p" "previous-line")
(global-set-key "C-a" "beginning-of-line")
(global-set-key "C-e" "end-of-line")
(global-set-key "M-<" "beginning-of-buffer")
(global-set-key "M->" "end-of-buffer")
(global-set-key "<left>" "backward-char")
(global-set-key "<right>" "forward-char")
(global-set-key "<up>" "previous-line")
(global-set-key "<down>" "next-line")
(global-set-key "<home>" "beginning-of-line")
(global-set-key "<end>" "end-of-line")

(global-set-key "RET" "newline-or-send")
(global-set-key "DEL" "delete-backward-char")
(global-set-key "C-d" "delete-char")
(global-set-key "C-k" "kill-line")
(global-set-key "C-y" "yank")
(global-set-key "C-/" "undo")
(global-set-key "C-_" "undo")
(global-set-key "C-x u" "undo")
(global-set-key "C-g" "keyboard-quit")

(global-set-key "M-f" "forward-word")
(global-set-key "M-b" "backward-word")
(global-set-key "M-d" "kill-word")
(global-set-key "M-DEL" "backward-kill-word")
(global-set-key "C-t" "transpose-chars")
(global-set-key "M-y" "yank-pop")
(global-set-key "TAB" "indent-for-tab")
(global-set-key "M-g g" "goto-line")
(global-set-key "M-g M-g" "goto-line")
(global-set-key "M-m" "back-to-indentation")
(global-set-key "C-c C-v" "preview-mode")
(global-set-key "C-`" "popup-toggle")
(global-set-key "C-M-v" "scroll-other-window")
(global-set-key "C-v" "scroll-up-command")
(global-set-key "M-v" "scroll-down-command")
(global-set-key "<next>" "scroll-up-command")
(global-set-key "<prior>" "scroll-down-command")
(global-set-key "C-l" "recenter-top-bottom")
(global-set-key "C-M-i" "completion-at-point")
(global-set-key "M-/" "completion-at-point")
(global-set-key "C-M-f" "forward-sexp")
(global-set-key "C-M-b" "backward-sexp")
(global-set-key "C-M-u" "backward-up-list")
(global-set-key "C-M-d" "down-list")

(global-set-key "C-SPC" "set-mark-command")
(global-set-key "C-w" "kill-region")
(global-set-key "M-w" "copy-region-as-kill")
(global-set-key "C-x C-x" "exchange-point-and-mark")
(global-set-key "C-s" "isearch-forward")
(global-set-key "C-r" "isearch-backward")

(global-set-key "C-x C-f" "find-file")
(global-set-key "C-x C-s" "save-buffer")
(global-set-key "C-x b" "switch-to-buffer")
(global-set-key "C-x k" "kill-buffer")

(global-set-key "M-x" "execute-extended-command")
(global-set-key "M-<" "beginning-of-buffer")
(global-set-key "M->" "end-of-buffer")
(global-set-key "M-:" "eval-expression")
(global-set-key "C-x C-e" "eval-last-sexp")

(global-set-key "C-x 2" "split-window-below")
(global-set-key "C-x 3" "split-window-right")
(global-set-key "C-x 0" "delete-window")
(global-set-key "C-x 1" "delete-other-windows")
(global-set-key "C-x o" "other-window")
(global-set-key "s-<left>" "windmove-left")
(global-set-key "s-<right>" "windmove-right")
(global-set-key "s-<up>" "windmove-up")
(global-set-key "s-<down>" "windmove-down")
(global-set-key "s-S-<left>" "window-swap-left")
(global-set-key "s-S-<right>" "window-swap-right")
(global-set-key "s-S-<up>" "window-swap-up")
(global-set-key "s-S-<down>" "window-swap-down")
(global-set-key "S-<left>" "previous-buffer")
(global-set-key "S-<right>" "next-buffer")
(global-set-key "C-x <left>" "previous-buffer")
(global-set-key "C-x <right>" "next-buffer")

;;; --- the public API ----------------------------------------------------------
;;; The supported, documented surface — what apropos-api shows the LLM (and
;;; anyone) by default. One line each; keep it curated, not exhaustive.

;; buffers
(public! 'buffer-list "All buffer names")
(public! 'buffer-list-mru "Buffer names, most recently used first")
(public! 'buffer-exists? "(buffer-exists? NAME) -> bool")
(public! 'buffer-text "(buffer-text NAME) -> the buffer's full text")
(public! 'buffer-size "(buffer-size NAME) -> size in bytes")
(public! 'buffer-create "(buffer-create NAME) — create if missing")
(public! 'buffer-kill! "(buffer-kill! NAME) — kill a buffer; repoint its windows first")
(public! 'buffer-append! "(buffer-append! NAME TEXT) — append; the usual way to add text")
(public! 'buffer-insert! "(buffer-insert! NAME BYTE-POS TEXT)")
(public! 'buffer-delete-range! "(buffer-delete-range! NAME BYTE-POS BYTE-LEN)")
(public! 'buffer-path "(buffer-path NAME) -> file path or #f")
(public! 'buffer-modified? "(buffer-modified? NAME) -> unsaved changes?")
(public! 'buffer-local "(buffer-local NAME KEY) -> buffer-local value or #f")
(public! 'buffer-set-local! "(buffer-set-local! NAME KEY VALUE) — locals persist with the desktop")
(public! 'current-buffer "Name of the buffer point is in")
(public! 'switch-to-buffer! "(switch-to-buffer! NAME) — show in the active window")
(public! 'visit "(visit PATH) — open a file (Emacs find-file)")
(public! 'buffer-save! "Save the current buffer to its file")

;; point, region, editing (current buffer)
(public! 'point "Point as a byte offset")
(public! 'buffer-point "(buffer-point NAME) — a named buffer's point as a byte offset")
(public! 'json-parse "(json-parse STR) — JSON to Scheme: objects become plists with symbol keys, null becomes #f; #f on bad input")
(public! 'register-context-provider! "(register-context-provider! MODE FN) — FN buf -> description of what the user is looking at, or #f; chat/agent sends prepend it")
(public! 'editor-context "(editor-context EXCLUDE-BUF) — visible-window contexts from registered providers, \"\" if none")
(public! 'goto-char! "(goto-char! BYTE-POS)")
(public! 'insert! "(insert! TEXT) at point")
(public! 'delete-char! "(delete-char! N) — negative deletes backward")
(public! 'region-text "Text between mark and point (\"\" when no mark)")
(public! 'set-mark! "(set-mark! BYTE-POS or #f)")
(public! 'buffer-substring "(buffer-substring START END) of the current buffer")
(public! 'line-text "Text of the current line")
(public! 'end-of-buffer! "Move point to the end")
(public! 'beginning-of-buffer! "Move point to the start")

;; windows
(public! 'window-list "((id buffer-name) ...) for every window")
(public! 'active-window "Id of the selected window")
(public! 'select-window! "(select-window! ID)")
(public! 'split-window! "(split-window! 'h|'v [RATIO]) — ratio = first pane's share")
(public! 'delete-window-id! "(delete-window-id! ID)")
(public! 'delete-other-windows! "Make the active window the only one")
(public! 'other-window! "Select the next window")
(public! 'display-buffer "(display-buffer NAME) — honors display rules (popups)")
(public! 'add-display-rule! "(add-display-rule! SUBSTRING 'popup|'same)")

;; interaction
(public! 'message "(message TEXT) — echo area")
(public! 'minibuffer-read "(minibuffer-read PROMPT CANDIDATES HANDLER) — async; HANDLER gets the choice")

;; commands, keys, modes, hooks
(public! 'define-command "(define-command NAME [DOC] THUNK) — register an M-x command; DOC shows in M-x")
(public! 'run-command "(run-command NAME) — invoke any M-x command")
(public! 'command-names "All M-x command names")
(public! 'command-doc "(command-doc NAME) -> the command's docstring (\"\" if none)")
(public! 'key-for-command "(key-for-command NAME) -> its global keybinding (\"\" if none)")
(public! 'global-set-key "(global-set-key KEYS COMMAND-NAME), e.g. \"C-c x\"")
(public! 'local-set-key "(local-set-key KEYS COMMAND-NAME) in the current buffer")
(public! 'define-mode "(define-mode NAME SETUP) — major mode; SETUP must rebuild from locals")
(public! 'set-mode! "(set-mode! NAME) on the current buffer")
(public! 'add-hook! "(add-hook! 'name-hook FN)")
(public! 'overlay-set! "(overlay-set! NAME TAG ((START END FACE) ...)) — replaces TAG's ranges")
(public! 'overlay-clear! "(overlay-clear! NAME TAG)")

;; llm, chat, companion
(public! 'llm "(llm PROMPT HANDLER) — async completion; HANDLER gets the text")
(public! 'llm-model "Current model id")
(public! 'set-llm-model! "(set-llm-model! ID) — provider prefix routes: openai:/openrouter:/bare=anthropic")
(public! 'buffer-group "(buffer-group NAME) -> the buffer's group tag or #f")
(public! 'group-buffers "(group-buffers G) -> names of the buffers tagged 'group G")
(public! 'group-chat "(group-chat G) — find or create G's chat buffer; returns its name")
(public! 'group-chat-show! "(group-chat-show! G) — open/focus G's chat pane; returns its name")
(public! 'chat-companion-show! "(chat-companion-show! DOC) — open/focus DOC's companion chat; returns its name")

(message "editor.scm loaded")
