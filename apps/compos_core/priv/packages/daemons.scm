;;; daemons.scm — daemon registry and same-tab switching
;;;
;;; A daemon owns complete workspaces. The browser frame can move between
;;; daemons, but a workspace never has two daemon owners.

(package! 'daemons 'sessions)

(define *daemons-buffer* "*daemons*")
(define *workspaces-buffer* "*workspaces*")

(define (daemon--valid-entry? entry)
  (and (pair? entry)
       (string? (plist-get entry 'name))
       (string? (plist-get entry 'url))))

(define (daemon-registry-entries)
  (let* ((text (read-file (daemon-registry-path)))
         (value (and text (json-parse text))))
    (if (or (null? value) (pair? value))
        (filter daemon--valid-entry? value)
        '())))

(define (daemon--write! entries)
  (write-file! (daemon-registry-path)
               (string-append (json-encode entries) "\n")))

(define (daemon--find url entries)
  (let ((hits (filter (lambda (entry)
                        (equal? (plist-get entry 'url) url))
                      entries)))
    (if (pair? hits) (car hits) #f)))

(define (daemon--without url entries)
  (filter (lambda (entry) (not (equal? (plist-get entry 'url) url)))
          entries))

(category! 'sessions)
(effects! '(write external))

(define (daemon-register! name url location)
  (if (not (or (string-prefix? "http://" url)
               (string-prefix? "https://" url)))
      (error "daemon URL must use http or https" url)
      (let* ((entries (daemon-registry-entries))
             (old (daemon--find url entries))
             (entry (list 'name name 'url url
                          'location location
                          'workspace (and old (plist-get old 'workspace))
                          'workspace-project (and old (plist-get old 'workspace-project))
                          'workspace-name (and old (plist-get old 'workspace-name))
                          'workspaces (or (and old (plist-get old 'workspaces)) '()))))
        (daemon--write! (cons entry (daemon--without url entries)))
        entry)))

(define (daemon--buffer-workspace buf)
  (or (buffer-local buf 'workspace-root)
      (buffer-group buf)
      (let ((root (buffer-project-root buf)))
        (if (equal? root "") #f root))))

(define (daemon--context-label workspace)
  (string-append (daemon-name) " · workspace "
                 (or workspace "none")))

(define (daemon-register-current! workspace)
  (let* ((url (editor-url))
         (entries (daemon-registry-entries))
         (old (daemon--find url entries))
         (target (or workspace (and old (plist-get old 'workspace))))
         (same-workspace? (and old
                               (equal? target (plist-get old 'workspace))))
         (entry (list 'name (daemon-name) 'url url
                      'location "local"
                      'workspace target
                      'workspace-project
                      (and same-workspace? (plist-get old 'workspace-project))
                      'workspace-name
                      (and same-workspace? (plist-get old 'workspace-name))
                      'workspaces (or (and old (plist-get old 'workspaces)) '()))))
    (daemon--write! (cons entry (daemon--without url entries)))
    entry))

(define (daemon-workspace-owner workspace)
  (let ((owners
          (filter (lambda (entry)
                    (member workspace (or (plist-get entry 'workspaces) '())))
                  (daemon-registry-entries))))
    (if (pair? owners) (car owners) #f)))

(define (daemon-claim-workspace! workspace)
  (let ((owner (daemon-workspace-owner workspace))
        (url (editor-url)))
    (cond
      ((and owner (not (equal? (plist-get owner 'url) url)))
       (error "workspace belongs to another daemon"
              workspace (plist-get owner 'name)))
      (else
        (let* ((current (daemon-register-current! workspace))
               (entries (daemon-registry-entries))
               (claimed (list
                          'name (plist-get current 'name)
                          'url url
                          'location (plist-get current 'location)
                          'workspace workspace
                          'workspace-project (plist-get current 'workspace-project)
                          'workspace-name (plist-get current 'workspace-name)
                          'workspaces
                          (cons workspace
                                (remove (lambda (item) (equal? item workspace))
                                        (or (plist-get current 'workspaces) '()))))))
          (daemon--write!
            (cons claimed (daemon--without url entries)))
          url)))))

(define (daemon-release-workspace! workspace)
  (let ((entries
          (map
            (lambda (entry)
              (list 'name (plist-get entry 'name)
                    'url (plist-get entry 'url)
                    'location (plist-get entry 'location)
                    'workspace (if (equal? (plist-get entry 'workspace) workspace)
                                   #f
                                   (plist-get entry 'workspace))
                    'workspace-project
                    (if (equal? (plist-get entry 'workspace) workspace)
                        #f
                        (plist-get entry 'workspace-project))
                    'workspace-name
                    (if (equal? (plist-get entry 'workspace) workspace)
                        #f
                        (plist-get entry 'workspace-name))
                    'workspaces
                    (remove (lambda (item) (equal? item workspace))
                            (or (plist-get entry 'workspaces) '()))))
            (daemon-registry-entries))))
    (daemon--write! entries)
    #t))

(define (daemon-assign-workspace! name url location workspace)
  (let* ((entries (daemon-registry-entries))
         (old (daemon--find url entries))
         (entry (list 'name name 'url url 'location location
                      'workspace workspace
                      'workspace-project (and old (plist-get old 'workspace-project))
                      'workspace-name (and old (plist-get old 'workspace-name))
                      'workspaces
                      (cons workspace
                            (remove (lambda (item) (equal? item workspace))
                                    (or (and old (plist-get old 'workspaces)) '()))))))
    (daemon--write! (cons entry (daemon--without url entries)))
    entry))

(define (daemon-name-workspace! workspace project name)
  (let ((entries
          (map
            (lambda (entry)
              (if (equal? workspace (plist-get entry 'workspace))
                  (list 'name (plist-get entry 'name)
                        'url (plist-get entry 'url)
                        'location (plist-get entry 'location)
                        'workspace (plist-get entry 'workspace)
                        'workspace-project project
                        'workspace-name name
                        'workspaces (plist-get entry 'workspaces))
                  entry))
            (daemon-registry-entries))))
    (daemon--write! entries)
    (when (and (boundp (quote daemon-workspace-root))
               (equal? workspace (daemon-workspace-root))
               (boundp (quote daemon-set-workspace-label!)))
      (daemon-set-workspace-label! project name))
    name))

(define (daemon--compos-workspace? workspace)
  (and (string? workspace)
       (file-directory? workspace)
       (file-exists? (string-append workspace "/mix.exs"))
       (file-directory? (string-append workspace "/apps/compos_core"))))

(define (daemon--workspace-id entry)
  (let ((name (or (plist-get entry 'name) "workspace")))
    (if (string-prefix? "worktree-" name)
        (substring name 9 (string-length name))
        name)))

;; A registry entry is durable, but its process is not. Start a local
;; worktree daemon and wait for its port before a browser leaves this daemon.
(define (daemon-ensure-workspace! workspace)
  (let ((owner (daemon-workspace-owner workspace)))
    (cond
      ((not owner) #f)
      ((equal? (plist-get owner 'url) (editor-url)) (editor-url))
      ((daemon--compos-workspace? workspace)
       (let* ((project (plist-get owner 'workspace-project))
              (name (plist-get owner 'workspace-name))
              (info (daemon-provision-workspace!
                      workspace (daemon--workspace-id owner)))
              (url (car info))
              (home (cadr info)))
         (daemon-assign-workspace! (plist-get owner 'name) url home workspace)
         (when (and project name)
           (daemon-name-workspace! workspace project name))
         url))
      (else (plist-get owner 'url)))))

(define (daemon--ensure-entry! entry)
  (let ((workspace (plist-get entry 'workspace)))
    (or (and workspace (daemon-ensure-workspace! workspace))
        (plist-get entry 'url))))

(define (daemon--rows buf)
  (let* ((url (editor-url))
         (entries (daemon-registry-entries))
         (current (or (daemon--find url entries)
                      (daemon-register-current! #f))))
    (cons current (daemon--without url entries))))

(define (daemon--status entry)
  (if (equal? (plist-get entry 'url) (editor-url)) "current" "known"))

(define (daemon--cells buf entry)
  (let ((current? (equal? (daemon--status entry) "current")))
    (list (if current? (list "●" "success") "")
          (if current?
              (list (plist-get entry 'name) "font-lock-keyword-face")
              (plist-get entry 'name))
          (or (plist-get entry 'location) "")
          (or (plist-get entry 'workspace) "")
          (daemon--status entry)
          (plist-get entry 'url))))

(define (daemon--meta buf)
  (let* ((current (daemon--find (editor-url) (daemon-registry-entries)))
         (workspace (and current (plist-get current 'workspace))))
    (string-append "CURRENT  " (daemon--context-label workspace) " · "
                   (number->string (length (daemon-registry-entries)))
                   " known · one workspace has one owner")))

(define (workspace--unique paths)
  (let loop ((rest paths) (seen '()))
    (cond ((null? rest) (reverse seen))
          ((or (not (string? (car rest))) (member (car rest) seen))
           (loop (cdr rest) seen))
          (else (loop (cdr rest) (cons (car rest) seen))))))

(define (workspace--rows-from entries)
  (if (null? entries)
      '()
      (let* ((entry (car entries))
             (paths (workspace--unique
                      (cons (plist-get entry 'workspace)
                            (or (plist-get entry 'workspaces) '()))))
             (rows
               (map (lambda (path)
                      (list 'workspace path
                            'project (or (plist-get entry 'workspace-project) "")
                            'name (or (plist-get entry 'workspace-name) "")
                            'daemon (plist-get entry 'name)
                            'url (plist-get entry 'url)
                            'location (plist-get entry 'location)))
                    paths)))
        (append rows (workspace--rows-from (cdr entries))))))

(define (workspace--rows buf)
  (workspace--rows-from (daemon-registry-entries)))

(define (workspace--cells buf row)
  (list
    (list (if (equal? (plist-get row 'url) (editor-url)) "●" "") "success")
    (list (or (plist-get row 'project) "") "dim")
    (list (or (plist-get row 'name) "") "font-lock-keyword-face")
    (or (plist-get row 'daemon) "")
    (plist-get row 'workspace)
    (or (plist-get row 'location) "")
    (plist-get row 'url)))

(define (daemon-arrived!)
  (let* ((workspace (daemon--buffer-workspace (current-buffer)))
         (entry (and workspace (daemon-workspace-owner workspace))))
    (daemon-register-current! workspace)
    (when (and entry (plist-get entry 'workspace-project)
               (plist-get entry 'workspace-name)
               (boundp (quote daemon-set-workspace-label!)))
      (daemon-set-workspace-label! (plist-get entry 'workspace-project)
                                   (plist-get entry 'workspace-name)))
    (message (daemon--context-label workspace))))

(define-command "daemon-visit" "Switch this browser tab to the daemon at point"
  (lambda ()
    (let ((entry (list-current (current-buffer))))
      (when entry
        (if (equal? (plist-get entry 'url) (editor-url))
            (message "this tab already uses that daemon")
            (let ((url (daemon--ensure-entry! entry)))
              (navigate-url!
                (string-append url
                  (if (string-contains? url "?") "&" "?")
                  "daemon-switch=1"))))))))

(define-command "daemons-refresh" "Refresh the daemon list"
  (lambda () (list-refresh! *daemons-buffer*)))

(define-command "daemons" "List daemons and switch this browser tab"
  (lambda ()
    (daemon-register-current! (daemon--buffer-workspace (current-buffer)))
    (list-mode-show! "daemons-mode")))

(define-command "workspace-open-tab" "Open the workspace at point in a new browser tab"
  (lambda ()
    (let ((row (list-current (current-buffer))))
      (if row
          (let ((url (or (daemon-ensure-workspace!
                           (plist-get row 'workspace))
                         (plist-get row 'url))))
            (tab-open url)
            (message (string-append "opened workspace "
                                    (or (plist-get row 'project) "") " / "
                                    (or (plist-get row 'name) "")
                                    " in a new tab")))
          (message "no workspace on this line")))))

(define-command "workspaces-refresh" "Refresh the workspace list"
  (lambda () (list-refresh! *workspaces-buffer*)))

(define-command "workspaces" "List workspaces and open one in a new browser tab"
  (lambda ()
    (daemon-register-current! (daemon--buffer-workspace (current-buffer)))
    (list-mode-show! "workspaces-mode")))

(mode-icon! "daemons-mode" "")

(define-list-mode! "daemons-mode"
  (list
    'doc (string-append
           "Every known daemon and its last workspace. RET switches this "
           "browser tab. Each daemon restores its own frame and desktop.")
    'buffer *daemons-buffer*
    'rows daemon--rows
    'columns (lambda (buf)
               (list (list "" 1) (list "daemon" 18)
                     (list "location" 12) (list "workspace" 28)
                     (list "status" 8) (list "url" #f)))
    'cells daemon--cells
    'title (lambda (buf)
             (let* ((current (daemon--find (editor-url) (daemon-registry-entries)))
                    (workspace (and current (plist-get current 'workspace))))
               (string-append "Daemons  ·  " (daemon--context-label workspace))))
    'meta daemon--meta
    'total (lambda (buf) (length (daemon-registry-entries)))
    'no-marks #t
    'footer (lambda (buf)
              '(("RET" "switch tab") ("/" "filter")
                ("g" "refresh") ("q" "quit")))
    'key (lambda (buf entry) (plist-get entry 'url))
    'noun "daemon"
    'keys '(("RET" "daemon-visit") ("g" "daemons-refresh")
            ("q" "quit-window"))))

(mode-icon! "workspaces-mode" "")

(define-list-mode! "workspaces-mode"
  (list
    'doc (string-append
           "Every workspace owned by a known daemon. RET opens its daemon in "
           "a new browser tab. The new tab restores only that workspace context.")
    'buffer *workspaces-buffer*
    'rows workspace--rows
    'columns (lambda (buf)
               (list (list "" 1) (list "project" 18)
                     (list "workspace" 28) (list "daemon" 18)
                     (list "path" 42) (list "location" 18)
                     (list "url" #f)))
    'cells workspace--cells
    'title (lambda (buf) "Workspaces  ·  RET opens a new tab")
    'meta (lambda (buf)
            (string-append (number->string (length (workspace--rows buf)))
                           " workspaces · one daemon per workspace"))
    'total (lambda (buf) (length (workspace--rows buf)))
    'no-marks #t
    'footer (lambda (buf)
              '(("RET" "open new tab") ("/" "filter")
                ("g" "refresh") ("q" "quit")))
    'key (lambda (buf row) (plist-get row 'workspace))
    'noun "workspace"
    'keys '(("RET" "workspace-open-tab") ("g" "workspaces-refresh")
            ("q" "quit-window"))))

(define-key "ctl-x-map" "d" "daemons")
(define-key "ctl-x-map" "w" "workspaces")

(category! 'sessions)
(effects! '(write external))

(public! 'daemon-register!
  "(daemon-register! NAME URL LOCATION) — add or update one known daemon")
(public! 'daemon-registry-entries
  "(daemon-registry-entries) — read the shared daemon registry")
(public! 'daemon-workspace-owner
  "(daemon-workspace-owner WORKSPACE) — the owning daemon entry, or #f")
(public! 'daemon-claim-workspace!
  "(daemon-claim-workspace! WORKSPACE) — assign WORKSPACE to this daemon")
(public! 'daemon-release-workspace!
  "(daemon-release-workspace! WORKSPACE) — release WORKSPACE from its daemon")
(public! 'daemon-assign-workspace!
  "(daemon-assign-workspace! NAME URL LOCATION WORKSPACE) — assign a workspace to a specific daemon")
(public! 'daemon-name-workspace!
  "(daemon-name-workspace! WORKSPACE PROJECT NAME) — set the human project and workspace names")
(public! 'daemon-ensure-workspace!
  "(daemon-ensure-workspace! WORKSPACE) — start its local daemon and wait until it accepts connections")
(public! 'daemon-arrived!
  "(daemon-arrived!) — announce this daemon and the frame's restored workspace")
(public! 'daemons "M-x daemons or C-x d — switch this tab to another daemon")
(public! 'workspaces
  "M-x workspaces or C-x w — open a workspace in a new browser tab")

;; Every running daemon announces itself. All local daemon homes share this
;; registry unless COMPOS_DAEMON_REGISTRY gives them another file.
(daemon-register-current! #f)
