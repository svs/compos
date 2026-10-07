;;; group-config.scm -- a group's config: one file, <group-home>/group.scm.
;;;
;;; Everything a group sets lives in that file and nowhere else:
;;;
;;;     (group-defaults!
;;;       'cwd "~/docs/Recruiting-Business"
;;;       'llm "RECRUITING")              ; a preset's name, or a bundle plist
;;;
;;;     (group-on-chat                    ; once on each chat that joins
;;;       (lambda (buf) (chat-presets-set! buf '(ats))))
;;;
;;; The file runs once per group: the first time the group is asked for its
;;; config, and again whenever the file changes. Its defaults land in the
;;; group's settings, which hold only what the file said: a key the file
;;; drops goes back to its default. The commands that change a default
;;; (group-cwd, group-llm) write the file and load it again.
;;;
;;; A chat runs the group-on-chat hooks ONCE, when it first joins the group.
;;; chat-load-config runs them again on one chat; group-reload-config loads
;;; the file again into every buffer of the group.

;; a group's config may name an llm-config bundle
(require 'llm-config)

(domain! 'buffers)
(effects! '(write execute))

(define (group-config-file g)
  (string-append (group-home-dir g) "/group.scm"))

;; the keys the file owns even when it does not name them: without the
;; file, each of them is #f, its default
(define *group-config-keys* '(cwd llm skills-dir))

;; (ID MTIME KEYS HOOKS) per group: what its file said when it last loaded
(define *group-configs* (if (boundp '*group-configs*) *group-configs* '()))

;; (ID DEFAULTS HOOKS) while a group's file runs, else #f
(define *group-config-loading* #f)

;; #t while group-config-set! writes a file, so the save hook leaves it be
(define *group-config-writing* #f)

;; A group chat wears chat-mode only after it is created, so its name has to
;; answer for it: the config has to reach the buffer before that.
(define (group-config-chat? buf)
  (or (chat-buffer? buf) (string-prefix? "*chat:" buf)))

;; the group whose config this buffer has already run, or #f. It is one of
;; chat-identity-locals, so a chat still knows after a restart.
(define (group-config-loaded buf)
  (and buf (buffer-known? buf) (buffer-local buf 'group-config-loaded)))

(define (group-config--state id)
  (let ((hit (assoc id *group-configs*))) (and hit (cdr hit))))

(define (group-config--put! id mtime keys hooks)
  (set! *group-configs*
        (cons (list id mtime keys hooks)
              (filter (lambda (e) (not (equal? (car e) id))) *group-configs*))))

(define (group-config--each plist f)
  (let loop ((xs plist))
    (when (and (pair? xs) (pair? (cdr xs)))
      (f (car xs) (cadr xs))
      (loop (cddr xs)))))

(define (group-config--keys plist)
  (let ((ks '()))
    (group-config--each plist (lambda (k v) (set! ks (cons k ks))))
    (reverse ks)))

(define (group-config--value key v)
  (if (and (member key '(cwd skills-dir)) (string? v)) (expand-path v) v))

;;; What the file says. Both only collect while a group's file runs.

(define (group-defaults! &rest plist)
  (if (not *group-config-loading*)
      (message "group-defaults! belongs in a group's group.scm")
      (set! *group-config-loading*
            (list (car *group-config-loading*)
                  (append (cadr *group-config-loading*) plist)
                  (caddr *group-config-loading*))))
  #t)

(define (group-on-chat fn)
  (if (not *group-config-loading*)
      (message "group-on-chat belongs in a group's group.scm")
      (set! *group-config-loading*
            (list (car *group-config-loading*)
                  (cadr *group-config-loading*)
                  (append (caddr *group-config-loading*) (list fn)))))
  #t)

;; Run G's file and put what it says on the group. A file that fails keeps
;; what loaded last, and is tried again when it changes.
(define (group-config-load! g)
  (let* ((id (group-resolve-id g))
         (path (and id (group-config-file id))))
    (and id
         (let* ((mtime (file-mtime path))
                (old (group-config--state id))
                (result
                  (if (file-exists? path)
                      (begin
                        (set! *group-config-loading* (list id '() '()))
                        (let* ((r (eval-string-safe (read-file path)))
                               (got *group-config-loading*))
                          (set! *group-config-loading* #f)
                          (if (equal? (car r) 'ok) (list 'ok (cadr got) (caddr got)) r)))
                      (list 'ok '() '()))))
           (cond
             ((not (equal? (car result) 'ok))
              (message (string-append (group-name id) " group.scm: "
                                      (value->string (cadr result))))
              (group-config--put! id mtime (if old (cadr old) '()) (if old (caddr old) '()))
              #f)
             (else
               (let* ((defaults (cadr result))
                      (keys (group-config--keys defaults)))
                 (for-each (lambda (k) (unless (member k keys) (group-setting-set! id k #f)))
                           (append *group-config-keys* (if old (cadr old) '())))
                 (group-config--each defaults
                   (lambda (k v) (group-setting-set! id k (group-config--value k v))))
                 (group-config--put! id mtime keys (caddr result))
                 (when (boundp 'skills-group-forget!) (skills-group-forget! id))
                 #t)))))))

;; load G's file when it changed since it last loaded -> G's id
(define (group-config-ensure! g)
  (let ((id (and g (group-resolve-id g))))
    (when id
      (let ((old (group-config--state id)))
        (unless (and old (equal? (car old) (file-mtime (group-config-file id))))
          (group-config-load! id))))
    id))

(define (group-config-hooks g)
  (let ((s (and g (group-config--state (group-resolve-id g)))))
    (if s (caddr s) '())))

;;; Writing the file. One (group-defaults! ...) form holds the defaults;
;;; the rest of the file is the user's and stays as written.

(define (group-config--unquote v)
  (if (and (pair? v) (equal? (car v) 'quote) (pair? (cdr v))) (cadr v) v))

(define (group-config--find forms)
  (let loop ((fs (if (pair? forms) forms '())))
    (cond ((null? fs) #f)
          ((and (pair? (car fs)) (equal? (car (car fs)) 'group-defaults!)) (car fs))
          (else (loop (cdr fs))))))

(define (group-config--with plist key value)
  (let ((kept '()))
    (group-config--each plist
      (lambda (k v) (unless (equal? k key) (set! kept (append kept (list k v))))))
    (if value (append kept (list key value)) kept)))

(define (group-config--literal v)
  (if (or (pair? v) (null? v) (symbol? v))
      (string-append "'" (value->string v))
      (value->string v)))

(define (group-config--defaults-text plist)
  (let ((lines '()))
    (group-config--each plist
      (lambda (k v)
        (set! lines (append lines (list (string-append "\n" "  " "'"
                                                       (symbol->string k) " "
                                                       (group-config--literal v)))))))
    (string-append "(group-defaults!" (apply string-append lines) ")")))

(define (group-config--template id)
  (string-append ";; " (group-name id) " -- this group's config. Saving it loads it."
                 "\n" "\n"))

;; Write KEY into G's group.scm (#f takes it out) and load the file again.
(define (group-config-set! g key value)
  (let* ((id (group-resolve-id g))
         (path (and id (group-config-file id))))
    (and id
         (begin
           (make-directory! (group-home-dir id))
           (let* ((known (buffer-known? path))
                  (buf (visit path id))
                  (text (buffer-text buf))
                  (forms (if (equal? (string-trim text) "") '() (scheme-read text))))
             (cond
               ((and known (buffer-modified? buf))
                (message (string-append (abbreviate-file-name path) " has unsaved changes: save it first"))
                #f)
               ((not (or (pair? forms) (null? forms)))
                (unless known (buffer-kill! buf))
                (message (string-append (abbreviate-file-name path) " does not read"))
                #f)
               (else
                 (let* ((old (group-config--find forms))
                        (plist (group-config--with
                                 (if old (map group-config--unquote (cdr old)) '()) key value))
                        (form (group-config--defaults-text plist)))
                   (cond (old (code-sexp-replace! buf "(group-defaults!" form))
                         ((equal? (string-trim text) "")
                          (buffer-append! buf (string-append (group-config--template id) form "\n")))
                         (else (buffer-append! buf (string-append "\n" form "\n"))))
                   (set! *group-config-writing* #t)
                   (with-current-buffer buf (lambda () (buffer-save!)))
                   (set! *group-config-writing* #f)
                   (unless known (buffer-kill! buf))
                   (group-config-load! id)))))))))

;; Run G's group-on-chat hooks on the chat BUF. #t when every one ran.
(define (group-config-run! buf id)
  (let ((failed (filter (lambda (fn)
                          (not (ignore-errors
                                 (lambda () (with-current-buffer buf (lambda () (fn buf))) #t))))
                        (group-config-hooks id))))
    (buffer-set-local! buf 'group-config-loaded id)
    (when (boundp 'agent-update-modeline!) (agent-update-modeline! buf))
    (when (pair? failed)
      (message (string-append (group-name id) " group.scm: " (number->string (length failed))
                              " group-on-chat hook failed")))
    (null? failed)))

;; Run the group's chat hooks on BUF whether or not they ran there before.
(define (group-config-apply! buf)
  (let ((id (and buf (buffer-known? buf) (group-resolve-id (buffer-group buf)))))
    (and id
         (group-config-chat? buf)
         (begin (group-config-ensure! id) (group-config-run! buf id)))))

;;; The group's working directory.
;;;
;;; A group is a quasi-application: its own buffers, its own home, and its
;;; own working directory. That directory belongs to the group, not to any
;;; buffer in it -- the 'cwd setting when it differs from where the group
;;; was founded, the group's origin otherwise. It outlives every buffer
;;; that borrows it, and a restart.
;;;
;;; A buffer takes it only when nothing on the buffer already answers: a
;;; file buffer's directory is its file's, and stays that way.

(define (group-cwd-slash dir)
  (if (string-suffix? dir "/") dir (string-append dir "/")))

(define (group-cwd g)
  (let* ((id (group-resolve-id g))
         (record (and id (group-record-by-id id)))
         (dir (and record (group-config-ensure! id) (or (group-setting id 'cwd)
                              (group-record-origin record)))))
    (and (string? dir) (file-directory? dir) (group-cwd-slash dir))))

;; Mirrors the cond in buffer-directory: a buffer takes the group's directory
;; only when nothing fixes it already. dired answers with the directory it
;; lists and a file buffer with its file's -- neither is ours to move. The
;; companion branch is not a rival: 'chat-directory IS the per-buffer cwd,
;; and it is what we write.
(define (buffer-takes-cwd? buf)
  (and buf (buffer-known? buf)
       (not (dired-buffer? buf))
       (not (buffer-path buf))
       (not (string-prefix? "/" buf))))

;; Hand the group's directory to one buffer. A buffer with an agent on it
;; moves the agent too; anything else just learns where it works.
(define (group-cwd-apply! buf)
  (let ((dir (and (buffer-takes-cwd? buf) (group-cwd (buffer-group buf)))))
    (cond
      ((not dir) #f)
      ((and (boundp 'chat-cwd-target?) (chat-cwd-target? buf))
       (car (chat-cwd-move! buf dir)))
      (else (buffer-set-local! buf 'default-directory dir) 'set))))

;; every buffer in G that takes a directory -> how many took it
(define (group-cwd-push! g)
  (let ((id (group-resolve-id g)) (n 0))
    (when id
      (for-each (lambda (buf)
                  (when (and (equal? id (group-resolve-id (buffer-group buf)))
                             (group-cwd-apply! buf))
                    (set! n (+ n 1))))
                (buffer-list)))
    n))

;; Write it into the group's file, and hand it to every buffer already in
;; the group: (COUNT DIR),
;; or (no-group "") / (no-such-directory DIR).
(define (group-cwd-set! g dir)
  (let ((id (group-resolve-id g))
        (dir (and (string? dir)
                  (expand-path (normalize-file-input (string-trim dir))))))
    (cond
      ((not id) (list 'no-group ""))
      ((not (and dir (file-directory? dir)))
       (list 'no-such-directory (or dir "")))
      (else (group-config-set! id 'cwd (abbreviate-file-name dir))
            (list (group-cwd-push! id) (group-cwd-slash dir))))))

(define (group-cwd-note id status dir)
  (cond
    ((equal? status 'no-group) "no group here")
    ((equal? status 'no-such-directory) (string-append "no such directory: " dir))
    (else (string-append (group-name id) ": " (abbreviate-file-name dir)
                         " -- " (number->string status)
                         (if (equal? status 1) " buffer" " buffers")))))

;; The seam. groups.scm calls this as a buffer joins a group, and the wake
;; hook below catches a buffer that comes back with its group already on it.
;; A chat that has run this group's config keeps whatever it holds now: the
;; group reaches into a chat once, and never again on its own.
(define (group-configure-buffer! buf)
  (let ((id (and buf (buffer-known? buf) (group-resolve-id (buffer-group buf)))))
    (when id
      ;; the directory is a group property, not a script, but it reaches in
      ;; on the same terms: once, on the join, and never again on its own.
      (unless (equal? (buffer-local buf 'group-cwd-loaded) id)
        (buffer-set-local! buf 'group-cwd-loaded id)
        (group-cwd-apply! buf))
      (unless (equal? (group-config-loaded buf) id)
        (group-config-apply! buf))))
  buf)

(add-hook! 'buffer-woken-hook 'group-configure-buffer!)

(define-command "chat-load-config" "Run this group's chat hooks on this chat again"
  (lambda ()
    (let* ((buf (current-buffer))
           (id (group-resolve-id (buffer-group buf))))
      (cond
        ((not id) (message "no group here"))
        ((not (group-config-chat? buf)) (message "not a chat"))
        ((group-config-apply! buf)
         (message (string-append (group-name id) ": ran "
                                 (number->string (length (group-config-hooks id)))
                                 " chat hooks from group.scm")))
        (else #f)))))

(define-command "group-reload-config" "Load this group's group.scm again into every buffer in it"
  (lambda ()
    (let ((id (group-resolve-id (or (buffer-group (current-buffer)) (frame-group)))))
      (if (not id)
          (message "no group here")
          (let ((loaded (group-config-load! id))
                (moved (group-cwd-push! id))
                (n 0))
            (for-each
              (lambda (buf)
                (when (and (equal? id (group-resolve-id (buffer-group buf)))
                           (group-config-apply! buf))
                  (set! n (+ n 1))))
              (buffer-list))
            (message
              (string-append
                (group-name id) ": "
                (cond ((not (file-exists? (group-config-file id))) "no group.scm, defaults only, ")
                      (loaded "loaded group.scm, ")
                      (else "group.scm failed, the last good config stays, "))
                (number->string n) (if (equal? n 1) " chat, " " chats, ")
                (number->string moved) (if (equal? moved 1) " buffer moved" " buffers moved"))))))))

(define-command "group-cwd" "Set this group's working directory, and move its buffers there"
  (lambda ()
    (let ((id (group-resolve-id (or (buffer-group (current-buffer)) (frame-group)))))
      (if (not id)
          (message "no group here")
          (read-file-name-initial "Group working directory: "
            (or (group-cwd id) (buffer-directory (current-buffer)))
            (lambda (input)
              (let ((r (group-cwd-set! id input)))
                (message (group-cwd-note id (car r) (cadr r))))))))))

(define-command "group-config" "Open this group's group.scm"
  (lambda ()
    (let ((id (group-resolve-id (or (buffer-group (current-buffer)) (frame-group)))))
      (if (not id)
          (message "no group here")
          (begin
            (make-directory! (group-home-dir id))
            (let ((buf (visit (group-config-file id) id)))
              (when (equal? (buffer-text buf) "")
                (buffer-append! buf (string-append (group-config--template id) "(group-defaults!)\n")))
              (switch-to-buffer! buf)))))))

;; Saving a group's group.scm loads it. A changed directory moves the
;; group's buffers; the rest reaches the next chat that joins.
(define (group-config-saved!)
  (let ((path (buffer-path (current-buffer))))
    (when (and (not *group-config-writing*)
               (string? path) (string-contains? path "group.scm"))
      (for-each
        (lambda (id)
          (when (equal? path (group-config-file id))
            (let ((before (group-cwd id)))
              (when (group-config-load! id)
                (unless (equal? before (group-cwd id)) (group-cwd-push! id))
                (message (string-append (group-name id) ": loaded group.scm"))))))
        (group-ids)))))

(add-hook! 'after-save-hook 'group-config-saved!)

(category! 'buffers)
(public! 'group-config-file
  "(group-config-file G) -> <group-home>/group.scm, the one file that configures G")
(public! 'group-defaults!
  "(group-defaults! KEY VALUE ...) -- in group.scm: the group's settings, e.g. 'cwd DIR 'llm PRESET-OR-BUNDLE 'skills-dir DIR")
(catalog-meta! 'function "group-defaults!" 'domain 'buffers 'effects '(write))
(public! 'group-on-chat
  "(group-on-chat FN) -- in group.scm: run (FN BUF) once on each chat that joins the group")
(catalog-meta! 'function "group-on-chat" 'domain 'buffers 'effects '(write))
(public! 'group-config-set!
  "(group-config-set! G KEY VALUE) -- write KEY into G's group.scm, #f takes it out, and load the file")
(catalog-meta! 'function "group-config-set!" 'domain 'buffers 'effects '(write))
(public! 'group-config-load!
  "(group-config-load! G) -- run G's group.scm and put its settings on G; #f when it fails")
(catalog-meta! 'function "group-config-load!" 'domain 'buffers 'effects '(write execute))
(public! 'group-config-ensure!
  "(group-config-ensure! G) -- load G's group.scm when it changed since it last loaded")
(catalog-meta! 'function "group-config-ensure!" 'domain 'buffers 'effects '(write execute))
(public! 'group-config-hooks
  "(group-config-hooks G) -> the group-on-chat functions G's file gave")
(catalog-meta! 'function "group-config-hooks" 'domain 'buffers 'effects '(read))
(catalog-meta! 'function "group-config-file" 'domain 'buffers 'effects '(read))
(public! 'group-config-loaded
  "(group-config-loaded BUF) -> the group whose chat hooks BUF has run, or #f")
(catalog-meta! 'function "group-config-loaded" 'domain 'buffers 'effects '(read))
(public! 'group-config-apply!
  "(group-config-apply! BUF) -- run BUF's group chat hooks on it, first time or not")
(catalog-meta! 'function "group-config-apply!" 'domain 'buffers 'effects '(write execute))
(public! 'group-configure-buffer!
  "(group-configure-buffer! BUF) -- give BUF its group's directory and chat hooks the first time it joins")
(catalog-meta! 'function "group-configure-buffer!" 'domain 'buffers 'effects '(write execute))
(public! 'group-cwd
  "(group-cwd G) -> the directory G and its buffers work in, or #f")
(catalog-meta! 'function "group-cwd" 'domain 'buffers 'effects '(read))
(public! 'group-cwd-set!
  "(group-cwd-set! G DIR) -- set it and move every buffer in G: (COUNT DIR)")
(catalog-meta! 'function "group-cwd-set!" 'domain 'buffers 'effects '(write))
(public! 'group-cwd-apply!
  "(group-cwd-apply! BUF) -- give BUF its group's directory, agent and all")
(catalog-meta! 'function "group-cwd-apply!" 'domain 'buffers 'effects '(write))
(public! 'group-cwd-push!
  "(group-cwd-push! G) -> how many buffers in G took its directory")
(catalog-meta! 'function "group-cwd-push!" 'domain 'buffers 'effects '(write))
(public! 'buffer-takes-cwd?
  "(buffer-takes-cwd? BUF) -> #t when nothing on BUF already fixes its directory")
(catalog-meta! 'function "buffer-takes-cwd?" 'domain 'buffers 'effects '(read))
(catalog-meta! 'command "group-cwd" 'domain 'buffers 'effects '(write))
(catalog-meta! 'command "group-config" 'domain 'buffers 'effects '(write display))
(catalog-meta! 'command "chat-load-config" 'domain 'buffers 'effects '(write execute))
(catalog-meta! 'command "group-reload-config" 'domain 'buffers 'effects '(write execute))
