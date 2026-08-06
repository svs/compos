;;; editor.scm --- the editor, in Scheme.
;;;
;;; The Elixir core knows nothing about what keys mean or what commands do.
;;; Everything here is userland: redefine any of it from init.scm or M-:.

;;; --- editing commands ------------------------------------------------------

(define-command "forward-char" (lambda () (forward-char!)))
(define-command "backward-char" (lambda () (backward-char!)))
(define-command "next-line" (lambda () (next-line!)))
(define-command "previous-line" (lambda () (previous-line!)))
(define-command "beginning-of-line" (lambda () (beginning-of-line!)))
(define-command "end-of-line" (lambda () (end-of-line!)))
(define-command "beginning-of-buffer" (lambda () (beginning-of-buffer!)))
(define-command "end-of-buffer" (lambda () (end-of-buffer!)))

(define-command "newline" (lambda () (insert! "\n")))
(define-command "delete-backward-char" (lambda () (delete-char! -1)))
(define-command "delete-char" (lambda () (delete-char! 1)))

(define-command "kill-line"
  (lambda ()
    (let ((killed (kill-line!)))
      (if (equal? killed "") #f (kill-push! killed)))))

(define-command "yank" (lambda () (insert! (kill-top))))

(define-command "undo"
  (lambda ()
    (if (not (undo!)) (message "No further undo information"))))

;;; --- minibuffer --------------------------------------------------------------
;;; The minibuffer is a real buffer (" *minibuf*"): point motion, kill/yank,
;;; undo and M-DEL all work in prompts for free via the global keymap. Only
;;; prompt-specific behavior is bound here, in its local keymap.

(define-command "minibuffer-confirm" (lambda () (minibuffer-confirm!)))
(define-command "minibuffer-confirm-input" (lambda () (minibuffer-confirm-input!)))
(define-command "minibuffer-cancel" (lambda () (minibuffer-cancel!)))
(define-command "minibuffer-complete" (lambda () (minibuffer-complete!)))
(define-command "minibuffer-next-candidate" (lambda () (minibuffer-next!)))
(define-command "minibuffer-previous-candidate" (lambda () (minibuffer-prev!)))
(define-command "minibuffer-delete-backward" (lambda () (minibuffer-del!)))

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

(define *auto-mode-alist*
  '((".scm" "scheme-mode") (".el" "scheme-mode")
    (".ex" "elixir-mode") (".exs" "elixir-mode")
    (".json" "json-mode") (".rs" "rust-mode")
    (".html" "html-mode") (".htm" "html-mode")
    (".md" "text-mode") (".txt" "text-mode") (".org" "org-mode")))

(define (auto-mode path)
  (for-each
    (lambda (entry)
      (if (string-suffix? (car entry) path)
          (set-mode! (cadr entry))))
    *auto-mode-alist*))

(define-mode "text-mode" (lambda () #t))
(define-mode "scheme-mode" (lambda () #t))   ; scheme grammar pending

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
(define-command "revert-buffer"
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

(define-command "preview-mode"
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

(define-command "forward-sexp" (lambda () (ts-goto 'forward)))
(define-command "backward-sexp" (lambda () (ts-goto 'backward)))
(define-command "backward-up-list" (lambda () (ts-goto 'up)))
(define-command "down-list" (lambda () (ts-goto 'down)))

;;; --- word motion & editing ---------------------------------------------------

(define (delete-between! s e)
  (set-mark! e)
  (goto-char! s)
  (delete-region!)
  (set-mark! #f))

(define-command "forward-word" (lambda () (forward-word!)))
(define-command "backward-word" (lambda () (backward-word!)))

(define-command "kill-word"
  (lambda ()
    (let ((s (point)))
      (let ((e (forward-word!)))
        (if (> e s)
            (begin
              (kill-push! (buffer-substring s e))
              (delete-between! s e)))))))

(define-command "backward-kill-word"
  (lambda ()
    (let ((e (point)))
      (let ((s (backward-word!)))
        (if (< s e)
            (begin
              (kill-push! (buffer-substring s e))
              (delete-between! s e)))))))

(define-command "transpose-chars"
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

(define-command "yank"
  (lambda ()
    (set! *yank-index* 0)
    (set! *yank-start* (point))
    (insert! (kill-top))))

(define-command "yank-pop"
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

(define-command "completion-at-point"
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

(define-command "indent-for-tab" (lambda () (insert! "  ")))

;;; --- scrolling (viewport) ------------------------------------------------------

(define (move-lines n mover)
  (let loop ((i 0))
    (if (< i n)
        (begin (mover) (loop (+ i 1))))))

(define-command "scroll-up-command"
  (lambda () (move-lines (- (window-rows) 2) next-line!)))

(define-command "scroll-down-command"
  (lambda () (move-lines (- (window-rows) 2) previous-line!)))

(define-command "recenter-top-bottom" (lambda () (recenter!)))

(define-command "display-line-numbers-mode"
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

(define-command "toggle-window-animations"
  (lambda ()
    (set! *window-animations* (not *window-animations*))
    (set-face-attribute! 'chrome 'anim (if *window-animations* "140ms" "0ms"))
    (message (if *window-animations*
                 "Window animations on"
                 "Window animations off"))))

(define-command "back-to-indentation"
  (lambda ()
    (beginning-of-line!)
    (let loop ()
      (let ((p (point)))
        (if (and (< p (buffer-size (current-buffer)))
                 (equal? (buffer-substring p (+ p 1)) " "))
            (begin (forward-char!) (loop)))))))

(define-command "goto-line"
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

(define-command "set-mark-command"
  (lambda ()
    (set-mark! (point))
    (message "Mark set")))

(define-command "kill-region"
  (lambda ()
    (let ((text (region-text)))
      (if (equal? text "")
          (message "The region is empty")
          (begin
            (kill-push! text)
            (delete-region!)
            (set-mark! #f))))))

(define-command "copy-region-as-kill"
  (lambda ()
    (let ((text (region-text)))
      (if (equal? text "")
          (message "The region is empty")
          (begin
            (kill-push! text)
            (set-mark! #f)
            (message "Copied"))))))

(define-command "exchange-point-and-mark"
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

(define-command "isearch-forward" (lambda () (isearch #f)))
(define-command "isearch-backward" (lambda () (isearch #t)))

;;; --- files & buffers -------------------------------------------------------

(define-command "save-buffer"
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

(define-command "find-file"
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

(define-command "switch-to-buffer"
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

(define-command "kill-buffer"
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

(define-command "popup-toggle"
  (lambda ()
    (if (popup-open?)
        (begin
          (delete-window-id! *popup-window*)
          (set! *popup-window* #f))
        (if *popup-buffer*
            (popup-show *popup-buffer*)
            (message "No popup buffer yet")))))

;; q in special buffers: close the popup, or fall back to the MRU buffer
(define-command "quit-window"
  (lambda ()
    (if (and (popup-open?) (equal? (active-window) *popup-window*))
        (begin
          (delete-window-id! *popup-window*)
          (set! *popup-window* #f))
        (let ((others (buffer-candidates)))
          (if (null? others)
              (message "Nothing to quit to")
              (switch-to-buffer! (car (car others))))))))

(define-command "view-messages" (lambda () (display-buffer "*messages*")))

(define-command "scroll-other-window"
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

(define-command "shell"
  (lambda ()
    (if (not (process-running? "*shell*"))
        (start-process! "*shell*" *shell-command*))
    (display-buffer "*shell*")
    (buffer-set-local! "*shell*" 'mode-name "Shell")
    (end-of-buffer!)))

(define-command "newline-or-send"
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
(define-command "llm-pipe-region"
  (lambda ()
    (minibuffer-read "LLM instruction: " '()
      (lambda (instr)
        (llm-on-region instr
          (lambda (result)
            (buffer-create "*llm*")
            (buffer-append! "*llm*" (string-append "\n;; " instr "\n" result "\n"))
            (message "LLM done -> *llm*")))))))

;; region -> LLM -> replaced in place
(define-command "llm-replace-region"
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

;; a real mode so desktop restore can rebuild the local keys
(define-mode "chat-mode"
  (lambda ()
    (local-set-key "C-c RET" "chat-send")
    (local-set-key "C-c m" "chat-set-model")))

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

(define-command "chat"
  (lambda ()
    (chat-ensure!)
    (switch-to-buffer! *chat-buffer*)
    (set-mode! "chat-mode")
    (end-of-buffer!)))

;; tools when the tools package is loaded and chat-use-tools is on
(define (chat-llm prompt handler)
  (if (and (boundp (quote chat-use-tools)) chat-use-tools)
      (llm-with-tools prompt handler)
      (llm prompt handler)))

(define-command "chat-send"
  (lambda ()
    (let ((convo (buffer-text *chat-buffer*)))
      (buffer-append! *chat-buffer* (chat-reply-marker))
      (end-of-buffer!)
      (message "LLM thinking...")
      (chat-llm (string-append
             "You are the assistant in an editor chat buffer. The transcript "
             "follows; reply to the last user turn only, in markdown.\n\n"
             convo)
           (lambda (reply)
             (buffer-append! *chat-buffer*
               (string-append
                 (if (equal? (string-trim reply) "")
                     "(no reply — the model returned no text; its tool calls are traced in *messages*)"
                     reply)
                 (chat-prompt-marker)))
             (end-of-buffer!)
             (message "Reply ready")
             (chat-maybe-title!))))))

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

(define-command "chat-set-model"
  (lambda ()
    (minibuffer-read (string-append "Model (now " (llm-model) "): ")
      *llm-models*
      (lambda (m)
        (set-llm-model! m)
        (message (string-append "LLM model: " m))))))

;; send the region to the chat buffer as context, then open it
(define-command "chat-send-region"
  (lambda ()
    (let ((text (region-text)))
      (if (equal? text "")
          (message "No region")
          (begin
            (run-command "chat")
            (insert! (string-append "```\n" text "\n```\n"))
            (message "Region added to chat"))))))

;; C-c q : ask from anywhere. The prompt becomes a normal *chat* turn, the
;; chat opens as a bottom popup, and the conversation continues there —
;; follow-ups with C-c RET, tool loop as in chat-send, C-` dismisses.
(add-display-rule! "*chat*" 'popup)
(add-display-rule! "*llm:" 'popup)

;; start a fresh conversation (the old one keeps its titled buffer)
(define-command "chat-new"
  (lambda ()
    (set! *chat-buffer* "*chat*")
    (chat-ensure! #t)
    (run-command "chat")))

(define-command "llm-ask"
  (lambda ()
    (minibuffer-read "Ask LLM: " (history-items 'llm-ask)
      (lambda (prompt)
        (history-push! 'llm-ask prompt)
        (chat-ensure!)
        (display-buffer *chat-buffer*)
        (set-mode! "chat-mode")
        (end-of-buffer!)
        (insert! prompt)
        (run-command "chat-send")))))

(global-set-key "C-c c" "chat")
(global-set-key "C-c r" "chat-send-region")
(global-set-key "C-c q" "llm-ask")

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

(define-command "execute-extended-command"
  (lambda ()
    (minibuffer-read "M-x "
      (map (lambda (c) (list c (key-for-command c)))
           (history-order 'M-x (command-names)))
      (lambda (cmd)
        (history-push! 'M-x cmd)
        (run-command cmd)))))

(define-command "eval-expression"
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

(define-command "eval-last-sexp"
  (lambda ()
    (let* ((p (eval-skip-ws-back (point)))
           (s (last-sexp-start p)))
      (if (< s p)
          (echo-value (eval-region (current-buffer) s p))
          (message "No sexp before point")))))

(define-command "eval-buffer"
  (lambda () (echo-value (eval-buffer (current-buffer)))))

(define-command "eval-region"
  (lambda ()
    (if (mark)
        (echo-value (eval-region (current-buffer) (region-beginning) (region-end)))
        (message "No region — set the mark first (C-SPC)"))))

;; hot-reload a Scheme file into the live session (stdlib included)
(define-command "load-file"
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

(define-command "keyboard-quit"
  (lambda ()
    (set-mark! #f)
    (message "Quit")))

;;; --- tiling windows --------------------------------------------------------

(define-command "split-window-below" (lambda () (split-window! 'v)))
(define-command "split-window-right" (lambda () (split-window! 'h)))
(define-command "delete-window"
  (lambda () (if (not (delete-window!)) (message "Attempt to delete sole window"))))
(define-command "delete-other-windows" (lambda () (delete-other-windows!)))
(define-command "other-window" (lambda () (other-window!)))

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
(global-set-key "M-:" "eval-expression")
(global-set-key "C-x C-e" "eval-last-sexp")

(global-set-key "C-x 2" "split-window-below")
(global-set-key "C-x 3" "split-window-right")
(global-set-key "C-x 0" "delete-window")
(global-set-key "C-x 1" "delete-other-windows")
(global-set-key "C-x o" "other-window")

(message "editor.scm loaded")
