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

(defcustom 'writing-font-size "17px"
  "Font size for writing-mode buffer text (any CSS size)."
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
  "Additional tool presets for the writing scratch. The required `aimax` preset is always enabled. Set a symbol list such as '(web) in ~/.aimax/ai-config.scm."
  'group 'writing 'type 'list 'set writing--refresh!)

(defcustom 'writing-instructions
  (string-append
    "Help the user write clear prose. Preserve their voice and intent. "
    "Discuss choices before a large rewrite. Return only requested prose "
    "when the user asks for finished text.")
  "Standing instructions for completion, rewrite, and writing chat commands."
  'group 'writing 'type 'string 'set writing--refresh!)

;;; --- workspace ---------------------------------------------------------------

(define (writing--configured-presets buf)
  ;; Rebuild from the pre-writing value on every refresh.  That makes removing
  ;; a preset from writing-presets take effect immediately instead of leaving
  ;; behind the value installed by the previous refresh. `aimax` is the
  ;; scratch's bridge to its grouped document, so it is intrinsic rather than
  ;; a default that customization can accidentally remove.
  (let* ((required '(aimax))
         (requested
           (append required
                   (filter (lambda (preset) (not (member preset required)))
                           writing-presets)))
         (base (or (writing--saved buf 'chat-presets) '())))
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



(define (writing--select! mover)
  (unless (mark) (set-mark! (point)))
  (mover))

(define-command "writing-select-backward" "Extend the region one character left"
  (lambda () (writing--select! backward-char!)))

(define-command "writing-select-forward" "Extend the region one character right"
  (lambda () (writing--select! forward-char!)))

(define-command "writing-select-backward-word" "Extend the region one word left"
  (lambda () (writing--select! backward-word!)))

(define-command "writing-select-forward-word" "Extend the region one word right"
  (lambda () (writing--select! forward-word!)))

(define-command "writing-select-up" "Extend the region one visual line up"
  (lambda () (writing--select! previous-line!)))

(define-command "writing-select-down" "Extend the region one visual line down"
  (lambda () (writing--select! next-line!)))

(define-command "writing-select-line-start" "Extend the region to the start of the line"
  (lambda () (writing--select! beginning-of-line!)))

(define-command "writing-select-line-end" "Extend the region to the end of the line"
  (lambda () (writing--select! end-of-line!)))

(define-command "writing-select-buffer-start" "Extend the region to the start of the buffer"
  (lambda () (writing--select! beginning-of-buffer!)))

(define-command "writing-select-buffer-end" "Extend the region to the end of the buffer"
  (lambda () (writing--select! end-of-buffer!)))

(define-command "writing-select-all" "Select the entire buffer"
  (lambda ()
    (set-mark! 0)
    (end-of-buffer!)))

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
  ;; remember what we clobber, once — the saved alist persists, and the
  ;; restore path re-runs this fn, which must not re-save writing's own look
  (unless (buffer-local buf 'writing-saved)
    (buffer-set-local! buf 'writing-saved
      (list (list 'face-remap (or (buffer-local buf 'face-remap) '()))
            (list 'style (or (buffer-local buf 'style) #f))
            (list 'line-numbers (or (buffer-local buf 'line-numbers) #f))
            (list 'render-mode (or (buffer-local buf 'render-mode) #f))
            (list 'preview-renderer (or (buffer-local buf 'preview-renderer) #f))
            (list 'visual-line-mode (or (buffer-local buf 'visual-line-mode) #f)))))
  ;; writing-mode changes the current buffer's presentation only. It never
  ;; creates a group, scratch, LLM session, or window layout.
  ;; The preview is the writing surface. Markdown remains the buffer text,
  ;; so every ordinary edit, save, undo, and future narrowing command keeps
  ;; its normal editor semantics.
  ;; a chat buffer's render-mode is the chat UI itself ("agent") — the
  ;; markdown preview here erased it on every minor-mode restore. Writing
  ;; typography still applies; the render switch stays the chat's own.
  (unless (equal? (buffer-local buf 'mode-name) "chat-mode")
    (buffer-set-local! buf 'preview-renderer "markdown")
    (buffer-set-local! buf 'render-mode "markdown"))
  (buffer-set-local! buf 'visual-line-mode #t)
  (face-remap-in! buf 'default
    (list 'family writing-font-family
          'size writing-font-size
          'line-height writing-line-height))
  ;; pseudo-face: emits --writing-measure on .buf; the stylesheet's
  ;; .window.writing rules read it
  (face-remap-in! buf 'writing (list 'measure writing-measure))
  (buffer-set-local! buf 'line-numbers "off")
  (buffer-set-local! buf 'window-class "writing")
  (local-set-key* buf "S-<left>" "writing-select-backward")
  (local-set-key* buf "S-<right>" "writing-select-forward")
  (local-set-key* buf "S-<up>" "writing-select-up")
  (local-set-key* buf "S-<down>" "writing-select-down")
  (local-set-key* buf "M-<left>" "backward-word")
  (local-set-key* buf "M-<right>" "forward-word")
  (local-set-key* buf "M-S-<left>" "writing-select-backward-word")
  (local-set-key* buf "M-S-<right>" "writing-select-forward-word")
  ;; Platform-native prose movement. In Markdown preview the browser refines
  ;; line boundaries to the visual row; the Scheme commands are the logical
  ;; fallback used by the plain scratch buffer.
  (local-set-key* buf "s-<left>" "beginning-of-line")
  (local-set-key* buf "s-<right>" "end-of-line")
  (local-set-key* buf "s-<up>" "beginning-of-buffer")
  (local-set-key* buf "s-<down>" "end-of-buffer")
  (local-set-key* buf "s-S-<left>" "writing-select-line-start")
  (local-set-key* buf "s-S-<right>" "writing-select-line-end")
  (local-set-key* buf "s-S-<up>" "writing-select-buffer-start")
  (local-set-key* buf "s-S-<down>" "writing-select-buffer-end")
  (local-set-key* buf "S-<home>" "writing-select-line-start")
  (local-set-key* buf "S-<end>" "writing-select-line-end")
  (local-set-key* buf "C-S-<left>" "writing-select-backward-word")
  (local-set-key* buf "C-S-<right>" "writing-select-forward-word")
  (local-set-key* buf "C-S-<home>" "writing-select-buffer-start")
  (local-set-key* buf "C-S-<end>" "writing-select-buffer-end")
  (local-set-key* buf "s-a" "writing-select-all")
  (writing--ensure-hook! buf)
  (writing--update-count! buf))

(define (writing--teardown! buf)
  (writing--remove-hook! buf)
  (buffer-set-local! buf 'face-remap (or (writing--saved buf 'face-remap) '()))
  (buffer-set-local! buf 'style (writing--saved buf 'style))
  (buffer-set-local! buf 'line-numbers (writing--saved buf 'line-numbers))
  (buffer-set-local! buf 'render-mode (writing--saved buf 'render-mode))
  (buffer-set-local! buf 'preview-renderer (writing--saved buf 'preview-renderer))
  (buffer-set-local! buf 'visual-line-mode (writing--saved buf 'visual-line-mode))
  (buffer-set-local! buf 'window-class #f)
  (buffer-set-local! buf 'modeline-info #f)
  (local-unset-key* buf "S-<left>")
  (local-unset-key* buf "S-<right>")
  (local-unset-key* buf "S-<up>")
  (local-unset-key* buf "S-<down>")
  (local-unset-key* buf "M-<left>")
  (local-unset-key* buf "M-<right>")
  (local-unset-key* buf "M-S-<left>")
  (local-unset-key* buf "M-S-<right>")
  (local-unset-key* buf "s-<left>")
  (local-unset-key* buf "s-<right>")
  (local-unset-key* buf "s-<up>")
  (local-unset-key* buf "s-<down>")
  (local-unset-key* buf "s-S-<left>")
  (local-unset-key* buf "s-S-<right>")
  (local-unset-key* buf "s-S-<up>")
  (local-unset-key* buf "s-S-<down>")
  (local-unset-key* buf "S-<home>")
  (local-unset-key* buf "S-<end>")
  (local-unset-key* buf "C-S-<left>")
  (local-unset-key* buf "C-S-<right>")
  (local-unset-key* buf "C-S-<home>")
  (local-unset-key* buf "C-S-<end>")
  (local-unset-key* buf "s-a")
  (buffer-set-local! buf 'writing-saved #f))

(register-minor-mode! "writing-mode" writing--apply! writing--teardown!)

;;; --- writing-layout ---------------------------------------------------------
;;; `write` presents the document, its writing scratch, and the group chat
;;; as three panes: left, middle, and right.

(define (writing--layout-apply! buf)
  (let* ((group (writing--workspace! buf))
         (scratch (scratch-ensure! buf))
         (chat (group-chat group)))
    (buffer-set-local! buf 'writing-chat-buffer chat)
    (unless (equal? (buffer-local chat 'mode-name) "chat-mode")
      (with-current-buffer chat (lambda () (set-mode! "chat-mode"))))
    (writing--configure-scratch! buf scratch)))

(register-minor-mode! "writing-layout" writing--layout-apply!
  (lambda (buf) #t))

(define-mode-layout! "writing-layout" '(h 0.34 self scratch-buffer writing-chat-buffer))

(define-command "writing-layout" "Open the writing workspace layout"
  (lambda ()
    (unless (minor-mode-on? (current-buffer) "writing-layout")
      (enable-minor-mode! (current-buffer) "writing-layout"))
    (reset-layout)))

(define-command "write" "Enter the writing workspace"
  (lambda ()
    (unless (minor-mode-on? (current-buffer) "writing-mode")
      (enable-minor-mode! (current-buffer) "writing-mode"))
    (run-command "writing-layout")))

(define-command "writing-mode" "Toggle writing mode in the current buffer"
  (lambda ()
    (if (toggle-minor-mode! "writing-mode")
        (message "Writing mode enabled")
        (message "Writing mode disabled"))))

(mode-doc! "writing-mode"
  "Layout-neutral prose presentation: typography, wrapping, margins, prose movement, and word count.")

(catalog-meta! 'mode "writing-mode" 'domain 'writing 'effects '(write))
(mode-doc! "writing-layout"
  "The explicit writing workspace: group, companion scratch, panes, and LLM configuration.")

(catalog-meta! 'command "writing-layout" 'domain 'windows 'effects '(write))
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
