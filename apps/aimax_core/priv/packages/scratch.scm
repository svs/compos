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

;; A mode that changes its owner's model or presets — code-mode — must reach
;; the scratch buffer that already inherited the old ones. `C-c s` inherits
;; on every use, so this only matters for a scratch that is already open.
(define (scratch-refresh-llm! owner)
  (let ((scratch (buffer-local owner 'scratch-buffer)))
    (when (and scratch (buffer-exists? scratch))
      (scratch--inherit-llm! owner scratch))))

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

;;; --- the project's scratch ----------------------------------------------------
;;; A file has a scratch; so does the project around it. Notes about one file
;;; belong beside that file, and notes about the whole change belong in one
;;; place every file in the project can reach.
;;;
;;; The project scratch joins the group named by the project root — the same
;;; name the buffer switcher founds a project group with — so a chat in it
;;; sees every project buffer that group holds. `C-x p s` opens it from any
;;; file in the project, and again from inside it returns where you came from.

(define (project-scratch-name root)
  (string-append "*scratch:project " root "*"))

(define (project-scratch--label root)
  (if (boundp (quote project-name)) (project-name root) root))

;; the project this command means: the one this buffer belongs to, or — from
;; inside a project scratch — the one it already names
(define (project-scratch--root)
  (let* ((here (current-buffer))
         (own (buffer-local here 'project-scratch-root))
         (byfile (buffer-project-root here)))
    (cond (own own)
          ((not (equal? byfile "")) byfile)
          ((and (boundp (quote project-current)) (project-current)))
          (else #f))))

;; The model and presets come from the buffer the user opened it from, ONCE.
;; A project chat's identity must not change because the next visit happened
;; to start in a buffer with different presets.
(define (project-scratch--inherit-once! from scratch)
  (unless (buffer-local scratch 'chat-presets)
    (scratch--inherit-llm! from scratch)))

;; The project's open buffers join its group, so a chat in the scratch can
;; name them and edit them. This is the tagging C-RET already does when it
;; founds a project group (buffer-context-switch!): a buffer that belongs to
;; a group the user chose keeps it.
(define (project-scratch--tag! root)
  (for-each
    (lambda (b)
      (when (and (not (buffer-group b)) (equal? (buffer-project-root b) root))
        (buffer-set-local! b 'group root)))
    (buffer-list)))

(define (project-scratch--prepare! root from scratch)
  (unless (buffer-exists? scratch)
    (buffer-create scratch)
    (buffer-append! scratch
      (string-append "# Scratch — project " (project-scratch--label root) "\n\n")))
  (buffer-set-local! scratch 'project-scratch-root root)
  (buffer-set-local! scratch 'group root)
  (project-scratch--tag! root)
  ;; the way back: this scratch is reached from many buffers, so it
  ;; remembers the last one instead of owning one
  (when (and from (not (equal? from scratch)))
    (buffer-set-local! scratch 'project-scratch-from from))
  (project-scratch--inherit-once! from scratch))

(define-command "project-scratch"
  "Toggle between this buffer and its project's scratch buffer"
  (lambda ()
    (let* ((here (current-buffer))
           (back (buffer-local here 'project-scratch-from)))
      (cond
        ;; inside the project scratch: go back where the user came from
        ((and (buffer-local here 'project-scratch-root) back (buffer-exists? back))
         (scratch--focus! back))
        (else
          (let ((root (project-scratch--root)))
            (if (not root)
                (message "No project here — a project is a directory with .git")
                (let ((scratch (project-scratch-name root)))
                  (project-scratch--prepare! root here scratch)
                  (scratch--focus! scratch)
                  (unless (buffer-local scratch 'mode-name) (set-mode! "text-mode"))
                  (end-of-buffer!)))))))))

(global-set-key "C-x p s" "project-scratch")

;; A renamed scratch is still its owner's scratch: the link is the pointer,
;; not the name, so move the pointer and `C-c s` keeps toggling. The same
;; goes for the way back out of a project scratch.
(on-buffer-renamed!
  (lambda (old new)
    (let ((owner (buffer-local new 'scratch-owner)))
      (when (and owner (buffer-exists? owner)
                 (equal? (buffer-local owner 'scratch-buffer) old))
        (buffer-set-local! owner 'scratch-buffer new)))
    (buffer-set-local! new 'scratch-buffer
      (if (equal? (buffer-local new 'scratch-buffer) old)
          new
          (buffer-local new 'scratch-buffer)))
    (for-each
      (lambda (b)
        (when (equal? (buffer-local b 'project-scratch-from) old)
          (buffer-set-local! b 'project-scratch-from new)))
      (buffer-list))))

(category! 'buffers)
(public! 'scratch-refresh-llm!
  "(scratch-refresh-llm! OWNER) — push OWNER's model and presets to its open scratch buffer")
(effects! '(pure))
(public! 'project-scratch-name
  "(project-scratch-name ROOT) — the name of that project's scratch buffer")
