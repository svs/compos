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
    (".md" "text-mode") (".txt" "text-mode") (".org" "text-mode")))

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
    (list (list 'change (lambda (q) (isearch-update q backward)))
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

(define (buffer-candidates)
  (map (lambda (b)
         (list b (let ((p (buffer-path b))) (if p p ""))))
       (filter (lambda (b) (not (equal? b (current-buffer)))) (buffer-list))))

(define-command "switch-to-buffer"
  (lambda ()
    (minibuffer-read "Switch to buffer: " (buffer-candidates)
      (lambda (name) (switch-to-buffer! name)))))

(define-command "kill-buffer"
  (lambda ()
    (minibuffer-read "Kill buffer: " (buffer-list)
      (lambda (name)
        (buffer-kill! name)
        (switch-to-buffer! "*scratch*")))))

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
    (switch-to-buffer! "*shell*")
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

;;; --- M-x and eval ----------------------------------------------------------

(define-command "execute-extended-command"
  (lambda ()
    (minibuffer-read "M-x "
      (map (lambda (c) (list c (key-for-command c))) (command-names))
      (lambda (cmd) (run-command cmd)))))

(define-command "eval-expression"
  (lambda ()
    (minibuffer-read "Eval: " '()
      (lambda (src) (message (value->string (eval-string src)))))))

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

(global-set-key "C-x 2" "split-window-below")
(global-set-key "C-x 3" "split-window-right")
(global-set-key "C-x 0" "delete-window")
(global-set-key "C-x 1" "delete-other-windows")
(global-set-key "C-x o" "other-window")

(message "editor.scm loaded")
