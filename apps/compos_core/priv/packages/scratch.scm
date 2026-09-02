;;; scratch.scm --- one ordinary scratch buffer beside any buffer.
;;;
;;; `C-c s` is deliberately global: a scratch is editor furniture, not a
;;; writing-mode feature. The source stays visible while its plain text scratch
;;; opens in the other window. A grouped scratch belongs to the group, and every
;;; work buffer in that group shares it. It inherits session settings from the
;;; buffer that opened it, but it does not inherit presentation modes.

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
  ;; A group is the durable identity. An ungrouped buffer still keeps its full
  ;; identity, so two README.md buffers cannot receive the same notes.
  (let ((group (buffer-group owner)))
    (string-append "*scratch:"
                   (if group (group-display-name group) owner)
                   "*")))

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
  (let* ((group (buffer-group owner))
         (shared (and group (group-buffer-as group 'scratch)))
         (saved (buffer-local owner 'scratch-buffer))
         (legacy (scratch--legacy owner)))
    (cond ((and shared (buffer-exists? shared)) shared)
          ((and saved (buffer-exists? saved)) saved)
          (legacy legacy)
          (else (scratch--name owner)))))

(define (scratch--inherit-llm! owner scratch)
  (buffer-set-local! scratch 'llm-model (buffer-local owner 'llm-model))
  (buffer-set-local! scratch 'chat-presets (buffer-local owner 'chat-presets))
  (buffer-set-local! scratch 'workspace-isolation-choice
    (buffer-local owner 'workspace-isolation-choice))
  (when (minor-mode-on? owner "llm-mode")
    (unless (minor-mode-on? scratch "llm-mode")
      (enable-minor-mode! scratch "llm-mode"))))

;; A mode that changes its owner's model or presets — code-mode — must reach
;; the scratch buffer that already inherited the old ones. `C-c s` inherits
;; on every use, so this only matters for a scratch that is already open.
(define (scratch-refresh-llm! owner)
  (let ((scratch (scratch--for owner)))
    (when (and scratch (buffer-exists? scratch))
      (scratch--inherit-llm! owner scratch))))

(define (scratch--attach-group! from scratch group)
  (buffer-add-group-as! scratch group 'scratch)
  ;; Clear the short-lived duplicate from development hot loads. Membership
  ;; and the role above are the single durable ownership record.
  (buffer-set-local! scratch 'scratch-group-id #f)
  (buffer-set-local! scratch 'scratch-from from)
  (buffer-set-local! scratch 'scratch-owner #f)
  (buffer-set-local! scratch 'scratch-buffer scratch)
  ;; The group owns one scratch. Work buffers point to it for layouts and
  ;; mode refreshes. Chats reach it through their group, not a private link.
  (for-each
    (lambda (member)
      (cond ((chat-buffer? member)
             (when (equal? (buffer-local member 'scratch-buffer) scratch)
               (buffer-set-local! member 'scratch-buffer #f)))
            ((not (equal? member scratch))
             (buffer-set-local! member 'scratch-buffer scratch))))
    (group-buffers group))
  scratch)

;; A scratch is a Morg note that belongs to a group, so scratch-mode runs
;; morg-mode's own setup instead of copying it, and mode-parent! tells every
;; morg test that a scratch is one of its buffers.
(mode-doc! "scratch-mode"
  "The group's scratch. It is a Morg note: `TAB` folds a heading or a block, `C-c C-c` runs a block, `C-c C-n` and `C-c C-p` walk the headings, `C-c C-f` and `C-c C-b` walk the siblings, and `M-n` and `M-p` walk the links. It belongs to the group, and it is never a file.")

(define-derived-mode "scratch-mode" "morg-mode" (lambda () #t))

;; scratch-mode is what a new scratch starts in, and that is the whole of
;; it. A scratch that already has a mode keeps it: M-x morg-mode in a scratch
;; means plain morg, and nothing here may take that back.
(define (scratch--set-mode! scratch)
  (unless (buffer-local scratch 'mode-name)
    (with-current-buffer scratch (lambda () (set-mode! "scratch-mode")))))

(define (scratch--prepare! owner scratch)
  (let ((existed (buffer-exists? scratch)))
    (unless (buffer-exists? scratch)
      (buffer-create scratch)
      (buffer-append! scratch
        (string-append "# Scratch — " (scratch--label owner) "\n\n")))
    ;; set-mode! is current-buffer based, and a mode belongs to the buffer,
    ;; not to a window: give a new scratch its mode without displaying it.
    (scratch--set-mode! scratch)
    (let* ((group (or (buffer-group owner) (group-ensure! owner)))
           (already-managed
             (and existed
                  (equal? (buffer-group-role scratch group) "scratch"))))
      ;; A legacy writing scratch becomes an ordinary, unrendered text buffer
      ;; on first use. Disabling its old presentation preserves the text.
      (unless already-managed
        (when (minor-mode-on? scratch "writing-mode")
          (disable-minor-mode! scratch "writing-mode"))
        (buffer-set-local! scratch 'render-mode #f)
        (buffer-set-local! scratch 'preview-renderer #f)
        (buffer-set-local! scratch 'visual-line-mode #f))
      (scratch--attach-group! owner scratch group))
    (scratch--inherit-llm! owner scratch)))

(define (scratch--return-buffer scratch group)
  (let ((from (buffer-local scratch 'scratch-from)))
    (if (and from (buffer-exists? from) (buffer-in-group? from group))
        from
        (let ((members
                (filter (lambda (name) (not (equal? name scratch)))
                        (group-buffers-mru group))))
          (and (pair? members) (car members))))))

(define (scratch--focus! buffer)
  (let ((shown (window-showing buffer)))
    (if shown
        (select-window! shown)
        (select-window! (display-buffer-other-window! buffer)))))

;; Establish the ordinary two-buffer workspace without taking focus from the
;; owner. Modes call this when the scratch is part of their initial layout;
;; the interactive toggle selects the returned buffer afterwards.
(define (scratch-open-beside! owner)
  (let ((scratch (scratch-ensure! owner)))
    (display-buffer-other-window! scratch)
    scratch))

;; OWNER's scratch, ready but not displayed. A mode that declares a layout
;; names the scratch in it; the layout engine is what shows it.
(define (scratch-ensure! owner)
  (let ((scratch (scratch--for owner)))
    (scratch--prepare! owner scratch)
    scratch))

(define-command "scratch-buffer"
  "Toggle between this buffer and its plain scratch buffer"
  (lambda ()
    (let* ((here (current-buffer))
           (membership (buffer-group here))
           (group (and membership
                       (equal? (buffer-group-role here membership) "scratch")
                       membership))
           (legacy-owner (buffer-local here 'scratch-owner)))
      (cond (group
             (let ((back (scratch--return-buffer here group)))
               (if back
                   (scratch--focus! back)
                   (message "This scratch buffer's group has no other buffer"))))
            (legacy-owner
             (if (buffer-exists? legacy-owner)
                 (scratch--focus! legacy-owner)
                 (message "This scratch buffer's owner no longer exists")))
            (else
              (let ((scratch (scratch-open-beside! here)))
                (scratch--focus! scratch)
                (end-of-buffer!)))))))

(define-key "mode-specific-map" "s" "scratch-buffer")

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
  (scratch--set-mode! scratch)
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
                  (end-of-buffer!)))))))))

(define-key "project-prefix-map" "s" "project-scratch")

;; A renamed group scratch keeps its role. Move each work-buffer pointer and
;; return pointer so `C-c s` keeps toggling. The same applies to the way back
;; out of a project scratch.
(on-buffer-renamed!
  (lambda (old new)
    (for-each
      (lambda (b)
        (when (equal? (buffer-local b 'scratch-buffer) old)
          (buffer-set-local! b 'scratch-buffer new))
        (when (equal? (buffer-local b 'scratch-from) old)
          (buffer-set-local! b 'scratch-from new)))
      (buffer-list))
    (buffer-set-local! new 'scratch-buffer
      (if (equal? (buffer-local new 'scratch-buffer) old)
          new
          (buffer-local new 'scratch-buffer)))
    (for-each
      (lambda (b)
        (when (equal? (buffer-local b 'project-scratch-from) old)
          (buffer-set-local! b 'project-scratch-from new)))
      (buffer-list))))

;; Desktop restore and hot reload can expose the old one-hop owner relation.
;; The scratch role already names the group, so migrate without renaming or
;; copying its text.
(for-each
  (lambda (scratch)
    (let ((group (buffer-group scratch))
          (owner (buffer-local scratch 'scratch-owner)))
      (when (and group
                 (equal? (buffer-group-role scratch group) "scratch"))
        (scratch--attach-group!
          (cond ((and owner (buffer-exists? owner)) owner)
                ((buffer-local scratch 'scratch-from)
                 (buffer-local scratch 'scratch-from))
                (else scratch))
          scratch group))))
  (buffer-list))

;; The blank pane of a sealed group: its scratch, made from its most
;; recent work member when the group has none yet. A group with no work
;; member has no blank pane; the layout stays short.
(define (group-blank-buffer group)
  (let ((shared (group-buffer-as group 'scratch)))
    (cond ((and shared (buffer-known? shared)) shared)
          (else
            (let ((members (filter group-work-buffer? (group-user-buffers-mru group))))
              (and (pair? members) (scratch-ensure! (car members))))))))

;; a layout's blank pane (editor.scm window-fill-blank): in a group, the
;; group's scratch; out of one, none
(set! window-fill-blank
  (lambda ()
    (let ((g (frame-group)))
      (and g (group-blank-buffer g)))))

(category! 'buffers)
(public! 'group-blank-buffer
  "(group-blank-buffer GROUP) — GROUP's scratch buffer, the blank pane a layout fills when the members run out; #f for a group with no work member")
(public! 'scratch-ensure!
  "(scratch-ensure! SOURCE) — SOURCE's group scratch buffer, prepared but not displayed")
(public! 'scratch-refresh-llm!
  "(scratch-refresh-llm! OWNER) — push OWNER's model and presets to its open scratch buffer")
(effects! '(pure))
(public! 'project-scratch-name
  "(project-scratch-name ROOT) — the name of that project's scratch buffer")
