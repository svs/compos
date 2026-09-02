;;; writing.scm — prose composition plus an explicit writing workspace.
;;;
;;; writing-mode is buffer-local and layout-neutral: it supplies typography,
;;; wrapping, margins, prose movement, and word count. writing-layout owns the
;;; companion scratch, group, panes, and LLM configuration. `C-c s` remains the
;;; generic editor scratch command.
;;;
;;; M-x writing-mode toggles composition. M-x writing-layout opens the
;;; companion workspace. `write` composes both. Knobs live in 'writing.

(domain! 'writing)
(effects! '(write))

(defgroup 'writing "Distraction-free writing.")

;; Re-apply presentation and layout separately: neither one implies the other.
(define (writing--refresh! _v)
  (for-each
    (lambda (buf)
      (when (minor-mode-on? buf "writing-mode")
        (writing--apply! buf))
      (when (minor-mode-on? buf "writing-layout")
        (writing--layout-apply! buf)))
    (buffer-list)))

(defcustom 'writing-measure "62ch"
  "Column width of the centered text measure (any CSS length)."
  'group 'writing 'type 'string 'set writing--refresh!)

(defcustom 'writing-font-family "Spectral, Georgia, serif"
  "Font family for writing-mode buffer text."
  'group 'writing 'type 'string 'set writing--refresh!)

(defcustom 'writing-font-size ""
  "Font size for writing-mode buffer text (any CSS size). Empty means the default face's size."
  'group 'writing 'type 'string 'set writing--refresh!)

(defcustom 'writing-line-height "1.9"
  "Line height for writing-mode buffer text."
  'group 'writing 'type 'string 'set writing--refresh!)

(defcustom 'writing-wpm 220
  "Reading speed (words per minute) behind the modeline's read-time."
  'group 'writing 'type 'number 'set writing--refresh!)

(defcustom 'writing-model ""
  "Model for writing commands. Empty means the editor's default model."
  'group 'writing 'type 'string 'set writing--refresh!)

(defcustom 'writing-presets '()
  "Additional tool presets for the writing scratch. The required `compos` preset is always enabled. Set a symbol list such as '(web) in ~/.compos/ai-config.scm."
  'group 'writing 'type 'list 'set writing--refresh!)

(defcustom 'writing-instructions
  (string-append
    "Help the user write clear prose. Preserve their voice and intent. "
    "Discuss choices before a large rewrite. Return only requested prose "
    "when the user asks for finished text. Load the markdown-editing skill "
    "before the first Markdown document edit.")
  "Standing instructions for completion, rewrite, and writing chat commands."
  'group 'writing 'type 'string 'set writing--refresh!)

;;; --- pasted images ----------------------------------------------------------

(define (clipboard-image-extension mime)
  (cond ((equal? mime "image/jpeg") ".jpg")
        ((equal? mime "image/gif") ".gif")
        ((equal? mime "image/webp") ".webp")
        ((equal? mime "image/svg+xml") ".svg")
        ((equal? mime "image/avif") ".avif")
        (else ".png")))

(define (clipboard-image-destination path)
  (if (re-match "[ \\t]" path)
      (string-append "<" path ">")
      path))

;; The picture is written where the writer chose, but the link is written
;; relative to the document. An absolute path names this disk only: the same
;; file read from another checkout, or on GitHub, finds no picture. A path
;; that leaves the project stays absolute, because no relative link reaches it.
(define (clipboard-image--parts path)
  (filter (lambda (part) (not (equal? part "")))
          (string-split path "/")))

(define (clipboard-image--relative dir full)
  (let loop ((d (clipboard-image--parts dir))
             (f (clipboard-image--parts full)))
    (if (and (pair? d) (pair? f) (equal? (car d) (car f)))
        (loop (cdr d) (cdr f))
        (string-join (append (map (lambda (up) "..") d) f) "/"))))

(define (clipboard-image-link doc full)
  (let ((dir (and (string? doc) (not (equal? doc "")) (car (path-split doc)))))
    (cond ((not (string? dir)) full)
          ((string-prefix? dir full)
           (substring full (string-length dir) (string-length full)))
          (else
            (let ((root (git-root dir)))
              (if (and (string? root)
                       (string-prefix? (string-append root "/") dir)
                       (string-prefix? (string-append root "/") full))
                  (clipboard-image--relative dir full)
                  full))))))

(define (clipboard-image-save! buf data full)
  (let* ((dir (car (path-split full)))
         (shown-dir (if (and (> (string-length dir) 1)
                             (string-suffix? "/" dir))
                        (substring dir 0 (- (string-length dir) 1))
                        dir)))
    (if (file-directory? dir)
        (begin
          (write-file! full (base64-decode data))
          (with-current-buffer buf
            (lambda ()
              (insert! (string-append "![image]("
                                      (clipboard-image-destination
                                        (clipboard-image-link (buffer-path buf) full))
                                      ")"))))
          (message (string-append "Saved pasted image to " full)))
        (y-or-n
          (string-append "Create directory " shown-dir "?")
          (lambda ()
            (make-directory! dir)
            (clipboard-image-save! buf data full))
          (lambda () (message "Pasted image was not saved"))))))

(define (clipboard-image-default-path buf mime)
  (let* ((suffix (clipboard-image-extension mime))
         (path (buffer-path buf))
         (dir (if (and (string? path) (not (equal? path "")))
                  (car (path-split path))
                  (default-directory))))
    (let loop ((n 1))
      (let ((candidate (string-append dir "image_"
                                      (number->string n) suffix)))
        (if (file-exists? candidate)
            (loop (+ n 1))
            candidate)))))

(define (writing-image-paste! kind data mime)
  (if (not (equal? kind "image"))
      #f
      (let* ((buf (current-buffer))
             (initial (clipboard-image-default-path buf mime)))
        (read-file-name-initial "Save pasted image: " initial
          (lambda (path)
            (if (equal? path "")
                (message "Pasted image was not saved")
                (clipboard-image-save! buf data (expand-path path)))))
        #t)))

;; morg-mode and the writing minor mode share the stock Markdown image policy.
;; ~/.compos/init.scm loads after this package, so a user handler registered
;; there runs first and may consume or pass through each paste.
(add-paste-hook! "writing-mode" 'writing-image writing-image-paste!)
(add-paste-hook! "morg-mode" 'writing-image writing-image-paste!)

;;; --- workspace ---------------------------------------------------------------

;; The document's own presets, remembered once. writing-mode saves the look
;; it repaints and nothing else, so the workspace keeps this one itself. The
;; value rides inside a list: a document with no presets must still read as
;; remembered, and an empty list is not #f.
(define (writing--remember-presets! buf)
  (unless (buffer-local buf 'writing-saved-presets)
    (buffer-set-local! buf 'writing-saved-presets
      (list (or (buffer-local buf 'chat-presets) '())))))

(define (writing--saved-presets buf)
  (let ((saved (buffer-local buf 'writing-saved-presets)))
    (if saved (car saved) '())))

(define (writing--configured-presets buf)
  ;; Rebuild from the pre-writing value on every refresh.  That makes removing
  ;; a preset from writing-presets take effect immediately instead of leaving
  ;; behind the value installed by the previous refresh. `compos` is the
  ;; scratch's bridge to its grouped document, so it is intrinsic rather than
  ;; a default that customization can accidentally remove.
  (let* ((required '(compos))
         (requested
           (append required
                   (filter (lambda (preset) (not (member preset required)))
                           writing-presets)))
         (base (writing--saved-presets buf)))
    (append requested
            (filter (lambda (preset) (not (member preset requested))) base))))

(define (writing--workspace! buf)
  (let ((group (group-ensure! buf)))
    (buffer-set-local! buf 'group group)
    (buffer-set-local! buf 'writing-model writing-model)
    (buffer-set-local! buf 'writing-instructions writing-instructions)
    group))

(define (writing--configure-scratch! buf scratch)
  ;; The document is the finished surface; the scratch is the LLM session.
  ;; Keep all session knobs where M-o actually runs.
  (let* ((model (if (equal? writing-model "")
                    (buffer-local buf 'llm-model)
                    writing-model))
         (presets (writing--configured-presets buf))
         (changed (or (not (equal? model (buffer-local scratch 'llm-model)))
                      (not (equal? presets
                                   (buffer-local scratch 'chat-presets))))))
    (when (and changed (boundp (quote llm-mode-reset-runtime!)))
      ;; Model and MCP changes take effect by resuming the same native Codex
      ;; thread through a fresh local runtime.
      (llm-mode-reset-runtime! scratch #t))
    (buffer-set-local! scratch 'llm-model model)
    (buffer-set-local! scratch 'chat-presets presets))
  (buffer-set-local! scratch 'writing-instructions writing-instructions)
  (unless (minor-mode-on? scratch "llm-mode")
    (enable-minor-mode! scratch "llm-mode")))



;;; --- word count ---------------------------------------------------------------

;; change-hook registry keyed by buffer NAME in global state (org pattern):
;; rules outlive buffer kill + recreate, so re-enabling must not stack
(define *writing-hooks* '())

(define (writing--ensure-hook! buf)
  (unless (assoc buf *writing-hooks*)
    (set! *writing-hooks*
      (cons (list buf
                  (on-change! buf
                    (lambda (pos inserted deleted source)
                      (writing--update-count! buf))))
            *writing-hooks*))))

(define (writing--remove-hook! buf)
  (let ((hit (assoc buf *writing-hooks*)))
    (if hit
        (begin
          (remove-on-change! (cadr hit))
          (set! *writing-hooks*
            (remove (lambda (h) (equal? (car h) buf)) *writing-hooks*))))))

(define (writing--update-count! buf)
  (if (minor-mode-on? buf "writing-mode")
      (let ((words (count-words buf)))
        (buffer-set-local! buf 'modeline-info
          (if (= words 0)
              "0 words"
              (string-append
                (number->string words) " words · "
                (number->string
                  (max 1 (quotient (+ words (- writing-wpm 1)) writing-wpm)))
                " min"))))))

;;; --- enable / disable -----------------------------------------------------------

(define (writing--saved buf key)
  (let ((hit (assoc key (or (buffer-local buf 'writing-saved) '()))))
    (if hit (cadr hit) #f)))

(define (writing--apply! buf)
  ;; This fn is the one funnel for enable, refresh, and desktop restore.
  ;; A chat renders its transcript, not a markdown preview (preview-mode
  ;; has the same rule). A chat buffer refuses the mode: restore the
  ;; locals that a past enable changed, then drop the mode from
  ;; 'minor-modes so a stale desktop entry heals on the next restore.
  (if (equal? (buffer-local buf 'mode-name) "chat-mode")
      (begin
        (when (buffer-local buf 'writing-saved)
          (writing--teardown! buf))
        (buffer-set-local! buf 'minor-modes
          (remove (lambda (n) (equal? n "writing-mode"))
                  (or (buffer-local buf 'minor-modes) '()))))
      (writing--present! buf)))

(define (writing--present! buf)
  (when (boundp 'preview-heal!) (preview-heal! buf))
  ;; remember what we clobber, once — the saved alist persists, and the
  ;; restore path re-runs this fn, which must not re-save writing's own look
  (let ((entering? (not (buffer-local buf 'writing-saved))))
  (when entering?
    (buffer-set-local! buf 'writing-saved
      (list (list 'face-remap (or (buffer-local buf 'face-remap) '()))
            (list 'style (or (buffer-local buf 'style) #f))
            (list 'line-numbers (or (buffer-local buf 'line-numbers) #f))
            (list 'render-mode (or (buffer-local buf 'render-mode) #f))
            (list 'preview-renderer (or (buffer-local buf 'preview-renderer) #f))
            (list 'preview-mode (minor-mode-on? buf "preview-mode"))
            (list 'visual-line-mode (or (buffer-local buf 'visual-line-mode) #f)))))
  ;; writing-mode changes the current buffer's presentation only. It never
  ;; creates a group, scratch, LLM session, or window layout.
  ;; The preview is the writing surface. Markdown remains the buffer text,
  ;; so every ordinary edit, save, undo, and future narrowing command keeps
  ;; its normal editor semantics.
  (buffer-set-local! buf 'preview-renderer "rows")
  ;; The first entry chooses the writing surface. A reload only reapplies
  ;; the modes the user left on, so source view remains source view.
  (if entering?
      (enable-minor-mode! buf "preview-mode")
      (when (minor-mode-on? buf "preview-mode")
        (preview-mode--apply! buf)))
  ;; the mode, not only its local: the dashboard names it, and M-x
  ;; visual-line-mode toggles what writing turned on
  (enable-minor-mode! buf "visual-line-mode")
  (face-remap-in! buf 'default
    (list 'family writing-font-family
          'size writing-font-size
          'line-height writing-line-height))
  ;; pseudo-face: emits --writing-measure on .buf; the stylesheet's
  ;; .window.writing rules read it
  (face-remap-in! buf 'writing (list 'measure writing-measure))
  (buffer-set-local! buf 'line-numbers "off")
  (buffer-set-local! buf 'window-class "writing")
  
  
  ;; Platform-native prose movement. With visual-line-mode on, the line
  ;; commands read the wrap map the client measured and stop at the
  ;; visual row; without one they stop at the source line.
  
  
  
  (writing--ensure-hook! buf)
  (writing--update-count! buf))
  ;; last word: the rows agree with the mode list, and the drawn page keeps
  ;; its own look over writing's typography
  (when (boundp 'preview-heal!) (preview-heal! buf))
  (when (and (buffer-local buf 'preview-rows) (boundp 'preview--rows-look!))
    (preview--rows-look! buf)))

(define (writing--teardown! buf)
  (let ((preview-was-on? (writing--saved buf 'preview-mode))
        (saved-render (writing--saved buf 'render-mode)))
  (writing--remove-hook! buf)
  (buffer-set-local! buf 'face-remap (or (writing--saved buf 'face-remap) '()))
  (buffer-set-local! buf 'style (writing--saved buf 'style))
  ;; the saved remap predates a scale set while writing; the local wins
  (when (boundp 'text-scale-sync!) (text-scale-sync! buf))
  (buffer-set-local! buf 'line-numbers (writing--saved buf 'line-numbers))
  (buffer-set-local! buf 'preview-renderer (writing--saved buf 'preview-renderer))
  (buffer-set-local! buf 'visual-line-mode (writing--saved buf 'visual-line-mode))
  (unless (writing--saved buf 'visual-line-mode)
    (buffer-set-local! buf 'minor-modes
      (remove (lambda (n) (equal? n "visual-line-mode"))
              (or (buffer-local buf 'minor-modes) '()))))
  (buffer-set-local! buf 'window-class #f)
  (buffer-set-local! buf 'modeline-info #f)
  (buffer-set-local! buf 'writing-saved #f)
  (if preview-was-on?
      (begin
        (unless (minor-mode-on? buf "preview-mode")
          (enable-minor-mode! buf "preview-mode"))
        (preview-mode--apply! buf))
      (when (minor-mode-on? buf "preview-mode")
        (disable-minor-mode! buf "preview-mode")))
  ;; Membership restores first because its setup and teardown derive this
  ;; local. The saved presentation remains authoritative after they run.
  ;; "rows" is a renderer name, never a render mode: a stale save of it is #f
  (buffer-set-local! buf 'render-mode (if (equal? saved-render "rows") #f saved-render))))

(register-minor-mode! "writing-mode" writing--apply! writing--teardown!)

(minor-mode-keys! "writing-mode"
  '(
    ("S-<left>" "cua-select-backward")
    ("S-<right>" "cua-select-forward")
    ("S-<up>" "cua-select-up")
    ("S-<down>" "cua-select-down")
    ("M-<left>" "backward-word")
    ("M-<right>" "forward-word")
    ("M-S-<left>" "cua-select-backward-word")
    ("M-S-<right>" "cua-select-forward-word")
    ("s-<left>" "beginning-of-line")
    ("s-<right>" "end-of-line")
    ("s-<up>" "beginning-of-buffer")
    ("s-<down>" "end-of-buffer")
    ("s-S-<left>" "cua-select-line-start")
    ("s-S-<right>" "cua-select-line-end")
    ("s-S-<up>" "cua-select-buffer-start")
    ("s-S-<down>" "cua-select-buffer-end")
    ("S-<home>" "cua-select-line-start")
    ("S-<end>" "cua-select-line-end")
    ("C-S-<left>" "cua-select-backward-word")
    ("C-S-<right>" "cua-select-forward-word")
    ("C-S-<home>" "cua-select-buffer-start")
    ("C-S-<end>" "cua-select-buffer-end")
    ("s-a" "cua-select-all")))

;;; --- writing-layout ---------------------------------------------------------
;;; `write` presents the document, its writing scratch, and the group chat
;;; as three panes: left, middle, and right.

(define (writing--layout-apply! buf)
  (writing--remember-presets! buf)
  (let* ((group (writing--workspace! buf))
         (scratch (scratch-ensure! buf))
         (chat (group-chat group)))
    (buffer-set-local! buf 'writing-chat-buffer chat)
    (unless (equal? (buffer-local chat 'mode-name) "chat-mode")
      (with-current-buffer chat (lambda () (set-mode! "chat-mode"))))
    (writing--configure-scratch! buf scratch)))

(register-minor-mode! "writing-layout" writing--layout-apply!
  (lambda (buf) #t))

(define-mode-layout! "writing-layout"
  (list 'h *window-third* 'self 'scratch-buffer 'writing-chat-buffer))

(define-command "writing-layout" "Open the writing workspace layout"
  (lambda ()
    (unless (minor-mode-on? (current-buffer) "writing-layout")
      (enable-minor-mode! (current-buffer) "writing-layout"))
    (run-command "reset-layout")))

(define-command "write" "Enter the writing workspace"
  (lambda ()
    ;; When invoked from the companion chat, return to its group's document.
    (let* ((here (current-buffer))
           (chat? (equal? (buffer-local here 'mode-name) "chat-mode"))
           (g (buffer-local here 'group))
           (docs (if (and g chat?) (group-docs g) '()))
           ;; A chat is never the writing document. When the group has no
           ;; document, stop instead of putting writing-mode on the chat.
           (doc (cond ((pair? docs) (car docs))
                      (chat? #f)
                      (else here))))
      (if doc
          (begin
            (switch-to-buffer! doc)
            (unless (minor-mode-on? doc "writing-mode")
              (enable-minor-mode! doc "writing-mode"))
            (run-command "writing-layout"))
          (message "This chat's group has no document")))))

(define-command "writing-mode" "Toggle writing mode in the current buffer"
  (lambda ()
    (if (equal? (buffer-local (current-buffer) 'mode-name) "chat-mode")
        (message "writing-mode does not apply to a chat buffer")
        (if (toggle-minor-mode! "writing-mode")
            (message "Writing mode enabled")
            (message "Writing mode disabled")))))

(mode-doc! "writing-mode"
  "Layout-neutral prose presentation: typography, wrapping, margins, prose movement, and word count.")

(catalog-meta! 'mode "writing-mode" 'domain 'writing 'effects '(write))
(mode-doc! "writing-layout"
  "The explicit writing workspace: group, companion scratch, panes, and LLM configuration.")

(catalog-meta! 'command "writing-layout" 'domain 'windows 'effects '(write display))
(catalog-meta! 'command "write" 'domain 'writing 'effects '(write))

(effects! '(read))

(define-command "count-words" "Display the number of words in the buffer"
  (lambda ()
    (message (string-append "Buffer has "
                            (number->string (count-words (current-buffer)))
                            " words"))))

(category! 'writing)
;; the rest of this file is writing-- internals; the surface is its commands,
;; which apropos searches with their docstrings
(public! 'count-words "(count-words BUF) — how many words a buffer holds")
