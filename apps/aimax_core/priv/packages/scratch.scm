;;; scratch.scm --- one ordinary scratch buffer beside any buffer.
;;;
;;; `C-c s` is deliberately global: a scratch is editor furniture, not a
;;; writing-mode feature.  The owner stays visible while its plain text
;;; scratch opens in the other window.  A scratch follows its owner's group
;;; and LLM session settings, but does not inherit presentation modes.

(domain! 'buffers)
(effects! '(write))

(define (scratch--label owner)
  (let* ((leaf (cadr (path-split owner)))
         (name (if (equal? leaf "") owner leaf))
         (n (string-byte-length name)))
    (if (and (> n 1)
             (string-prefix? "*" name)
             (string-suffix? "*" name))
        (substring-bytes name 1 (- n 1))
        name)))

(define (scratch--name owner)
  ;; Keep the full identity: two README.md buffers need different notes.
  (string-append "*scratch:" owner "*"))

(define (scratch--legacy owner)
  ;; Writing mode used to own scratch buffers.  Adopt either its persisted
  ;; pointer or its deterministic old name so existing prose is never copied,
  ;; renamed, or lost during the move to the global command.
  (let ((saved (buffer-local owner 'writing-scratch))
        (derived (string-append "*writing:" owner "*")))
    (cond ((and saved (buffer-exists? saved)) saved)
          ((buffer-exists? derived) derived)
          (else #f))))

(define (scratch--for owner)
  (let ((saved (buffer-local owner 'scratch-buffer))
        (legacy (scratch--legacy owner)))
    (cond ((and saved (buffer-exists? saved)) saved)
          (legacy legacy)
          (else (scratch--name owner)))))

(define (scratch--inherit-llm! owner scratch)
  (buffer-set-local! scratch 'llm-model (buffer-local owner 'llm-model))
  (buffer-set-local! scratch 'chat-presets (buffer-local owner 'chat-presets))
  (when (minor-mode-on? owner "llm-mode")
    (unless (minor-mode-on? scratch "llm-mode")
      (enable-minor-mode! scratch "llm-mode"))))

(define (scratch--prepare! owner scratch)
  (let ((existed (buffer-exists? scratch)))
    (unless (buffer-exists? scratch)
      (buffer-create scratch)
      (buffer-append! scratch
        (string-append "# Scratch — " (scratch--label owner) "\n\n")))
    (let ((already-managed
            (and existed
                 (equal? (buffer-local scratch 'scratch-owner) owner))))
      ;; A legacy writing scratch becomes an ordinary, unrendered text buffer
      ;; on first use. Disabling its old presentation preserves the text.
      (unless already-managed
        (when (minor-mode-on? scratch "writing-mode")
          (disable-minor-mode! scratch "writing-mode"))
        (buffer-set-local! scratch 'render-mode #f)
        (buffer-set-local! scratch 'preview-renderer #f)
        (buffer-set-local! scratch 'visual-line-mode #f)))
    (let ((group (or (buffer-group owner) (group-ensure! owner))))
      (buffer-set-local! owner 'scratch-buffer scratch)
      (buffer-set-local! scratch 'scratch-owner owner)
      (buffer-set-local! scratch 'scratch-buffer scratch)
      (buffer-set-local! scratch 'group group))
    (scratch--inherit-llm! owner scratch)))

(define (scratch--focus! buffer)
  (let ((shown (window-showing buffer)))
    (if shown
        (select-window! shown)
        (select-window! (display-buffer-other-window! buffer)))))

(define-command "scratch-buffer"
  "Toggle between this buffer and its plain scratch buffer"
  (lambda ()
    (let* ((here (current-buffer))
           (owner (buffer-local here 'scratch-owner)))
      (if owner
          (if (buffer-exists? owner)
              (scratch--focus! owner)
              (message "This scratch buffer's owner no longer exists"))
          (let ((scratch (scratch--for here)))
            (scratch--prepare! here scratch)
            (scratch--focus! scratch)
            (unless (buffer-local scratch 'mode-name) (set-mode! "text-mode"))
            (end-of-buffer!))))))

(global-set-key "C-c s" "scratch-buffer")

(category! 'buffers)
