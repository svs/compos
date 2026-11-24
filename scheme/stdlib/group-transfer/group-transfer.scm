;;; group-transfer.scm --- ship a group to another daemon: export, import, send.
;;;
;;; A group's data is spread out: its record lives in the desktop, its
;;; config and chats in its home folder, its members in the buffer list.
;;; Shipping a group is rare, so nothing moves for it. group-export gathers
;;; the pieces into one folder, group-import! makes a new group from that
;;; folder, and group-send does both across ssh.
;;;
;;; The group's buffers travel whole: the checkpoint and the history log of
;;; every buffer the layout names or the group holds. The import adopts them
;;; as dormant buffers of the new group, with the sender's home folder
;;; rewritten to the receiver's, and the layout comes back with its stacks
;;; and points. What stays behind: the id (the import makes a new one), live
;;; agent sessions (a chat travels as its .chat transcript), and the
;;; settings in group-transfer-local-settings.
;;;
;;; The folder:
;;;   NAME.group/manifest.scm   (group-export 1 name N color C noise M meta NOTE
;;;                              settings PLIST cwd DIR members ((rel|abs PATH) ...)
;;;                              home HOME layout LAYOUT buffers (ID ...))
;;;   NAME.group/home/          a copy of the group's home: group.scm, chats/
;;;   NAME.group/buffers/       ID.etf, the checkpoint of each buffer
;;;   NAME.group/docs/          ID.loro, its text and history

(domain! 'buffers)
(effects! '(write))

(defcustom 'group-transfer-local-settings '(browser-profile subagents frame)
  "Group settings that only mean something on the machine that set them. group-export leaves them out."
  'group 'groups 'type 'list)

(defcustom 'group-transfer-peer-socket "~/.local/state/compos/sock"
  "Where group-send finds the other daemon's socket, as a path on that machine."
  'group 'groups 'type 'string)

(define (group-transfer--strip plist drop)
  (let loop ((p (if (pair? plist) plist '())) (out '()))
    (cond ((or (null? p) (null? (cdr p))) (reverse out))
          ((member (car p) drop) (loop (cddr p) out))
          (else (loop (cddr p) (cons (cadr p) (cons (car p) out)))))))

(define (group-transfer--current)
  (group-resolve-id (or (buffer-group (current-buffer)) (frame-group))))

;; a member is a file: relative to the group's cwd when it is under it, so
;; it lands in the cwd the other machine gives the group
(define (group-transfer--member cwd b)
  (let ((path (buffer-path b)))
    (and (string? path) (not (chat-buffer? b)) (file-exists? path)
         (if (and (string? cwd) (string-prefix? cwd path) (> (string-length path) (string-length cwd)))
             (list 'rel (substring path (string-length cwd) (string-length path)))
             (list 'abs (abbreviate-file-name path))))))

(define (group-transfer--name-of path)
  (let ((parts (filter (lambda (s) (not (equal? s ""))) (string-split path "/"))))
    (if (pair? parts) (car (last-pair parts)) path)))

(define (group-export g &optional dir)
  "(group-export G [DIR]) -- write group G as the folder DIR/NAME.group, by default under <compos-home>/exports; answers its path"
  (let* ((id (group-resolve-id g))
         (record (and id (group-record-by-id id))))
    (if (not record)
        (error (string-append "group-export: no group " (value->string g)))
        (let* ((name (group-record-name record))
               (root (expand-path (or dir (string-append (compos-home) "/exports"))))
               (out (string-append root "/" (group-home-slug name) ".group"))
               (cwd (group-cwd id))
               (members (filter (lambda (m) m)
                                (map (lambda (b) (group-transfer--member cwd b)) (group-buffers id))))
               (meta (group-record-meta record))
               (layout (group-layout id))
               (home (group-home-dir id)))
          (when (file-exists? out)
            (error (string-append "group-export: " out " already exists")))
          (make-directory! out)
          (when (file-directory? home)
            (copy-file! home (string-append out "/home")))
          (let ((ids (buffer-store-export! (group-transfer--buffer-ids id layout) out)))
            (write-file! (string-append out "/manifest.scm")
                         (string-append ";; a compos group, written by group-export\n"
                                        (format "~s" (list 'group-export 1
                                                            'name name
                                                            'color (group-record-color record)
                                                            'noise (group-record-noise record)
                                                            'meta (and (string? meta) meta)
                                                            'settings (group-transfer--strip (group-record-settings record)
                                                                                             group-transfer-local-settings)
                                                            'cwd (and cwd (abbreviate-file-name cwd))
                                                            'members members
                                                            'home (group-transfer--home)
                                                            'layout layout
                                                            'buffers ids))
                                        "\n")))
          out))))

;; the sender's home folder, with its slash: the import rewrites it
(define (group-transfer--home)
  (let ((h (expand-path "~")))
    (if (string-suffix? "/" h) h (string-append h "/"))))

;; every buffer id the layout names, and every buffer the group holds
(define (group-transfer--buffer-ids id layout)
  (let ((from-layout (apply append (map (lambda (w) (or (plist-get w 'buffers) '()))
                                        (group-transfer--windows layout))))
        (members (filter string?
                         (map cadr (buffer-read-many (group-known-buffers id) '(id) '())))))
    (append from-layout members)))

(define (group-transfer--windows layout)
  (if (pair? layout)
      (apply append (map (lambda (p) (or (plist-get p 'windows) '()))
                         (or (plist-get layout 'panes) '())))
      '()))

(define (group-transfer--plist-set plist key value)
  (let loop ((p plist) (out '()) (done #f))
    (cond ((or (null? p) (null? (cdr p)))
           (if done (reverse out) (append (reverse out) (list key value))))
          ((eq? (car p) key) (loop (cddr p) (cons value (cons key out)) #t))
          (else (loop (cddr p) (cons (cadr p) (cons (car p) out)) done)))))

;; the layout with each buffer id replaced by the one here; an id that did
;; not come over leaves its stack, and a window left with none goes
(define (group-transfer--relayout layout remap rehome)
  (let ((window
          (lambda (w)
            (let ((ids (filter string? (map remap (or (plist-get w 'buffers) '()))))
                  (pt (plist-get w 'point)))
              (and (pair? ids)
                   (let ((w (group-transfer--plist-set w 'buffers ids)))
                     (if (and (pair? pt) (string? (car pt)))
                         (group-transfer--plist-set w 'point (cons (rehome (car pt)) (cdr pt)))
                         w)))))))
    (group-transfer--plist-set
      layout 'panes
      (map (lambda (p)
             (group-transfer--plist-set p 'windows
                                        (filter (lambda (w) w) (map window (or (plist-get p 'windows) '())))))
           (or (plist-get layout 'panes) '())))))

(define (group-transfer--free-name name)
  (let loop ((n 1))
    (let ((try (if (= n 1) name (string-append name " <" (number->string n) ">"))))
      (if (group-record-by-name try) (loop (+ n 1)) try))))

;; the exported home goes into the new group's home; group.scm replaces the
;; one the new record may have made, every other entry is copied as it is
(define (group-transfer--copy-home! from to)
  (make-directory! to)
  (for-each
    (lambda (entry)
      (let* ((name (if (string-suffix? "/" entry) (substring entry 0 (- (string-length entry) 1)) entry))
             (src (string-append from "/" name))
             (dst (string-append to "/" name)))
        (cond ((equal? name "group.scm") (write-file! dst (read-file src)))
              ;; the tasks come in through todo-adopt-file!, under the new group's id
              ((equal? name "todos.md") #f)
              ((file-exists? dst) #f)
              (else (copy-file! src dst)))))
    (directory-files from)))

(define (group-import! path &optional cwd into)
  "(group-import! PATH [CWD INTO]) -- make a new group from the folder group-export wrote, or fill the group INTO; CWD replaces the exported working directory; answers (id ID name NAME opened N tasks N buffers N layout BOOL skipped (PATH ...) missing (PATH ...))"
  (let* ((dir (expand-path path))
         (forms (scheme-read (read-file (string-append dir "/manifest.scm"))))
         (m (and (pair? forms) (car forms))))
    (if (not (and (pair? m) (eq? (car m) 'group-export)))
        (error (string-append "group-import!: " dir " holds no group-export manifest"))
        (let* ((plist (cddr m))
               (old (and into (group-resolve-id into)))
               (name (if old (group-name old) (group-transfer--free-name (plist-get plist 'name))))
               (id (or old (group-record-create! name)))
               (opened 0) (tasks 0) (adopted 0) (laid #f) (skipped '()) (missing '()))
          (when (and into (not old))
            (error (string-append "group-import!: no group " (value->string into))))
          (unless old
            (when (plist-get plist 'color) (group-record-update! id 'color (plist-get plist 'color)))
            (when (plist-get plist 'noise) (group-record-update! id 'noise (plist-get plist 'noise)))
            (when (plist-get plist 'meta) (group-record-update! id 'meta (plist-get plist 'meta)))
            (let loop ((s (or (plist-get plist 'settings) '())))
              (when (and (pair? s) (pair? (cdr s)))
                (group-setting-set! id (car s) (cadr s))
                (loop (cddr s)))))
          (when (file-directory? (string-append dir "/home"))
            (group-transfer--copy-home! (string-append dir "/home") (group-home-dir id))
            (group-config-load! id)
            (let ((todos (string-append dir "/home/todos.md")))
              ;; a group filled again already holds its tasks
              (when (and (not old) (file-exists? todos))
                (set! tasks (todo-adopt-file! todos id)))))
          (let ((want (or cwd (plist-get plist 'cwd))))
            (when (and (not old) (string? want) (file-directory? (expand-path want)))
              (group-cwd-set! id want)))
          ;; the buffers come back dormant in this group, the home rewritten
          (let* ((from (plist-get plist 'home))
                 (to (group-transfer--home))
                 (rehome (lambda (s) (if (and (string? from) (string-prefix? from s))
                                         (string-append to (substring s (string-length from) (string-length s)))
                                         s)))
                 (map-rows (if (file-directory? (string-append dir "/buffers"))
                               (buffer-store-adopt! dir id from to)
                               '()))
                 (remap (lambda (uid) (let ((row (assoc uid map-rows))) (and row (cadr row)))))
                 (layout (plist-get plist 'layout)))
            (set! adopted (length (filter (lambda (r) (list-ref r 3)) map-rows)))
            (when (pair? layout)
              (let ((l (group-transfer--relayout layout remap rehome)))
                (when (panes-layout? l)
                  (group-layout-set! id l)
                  (set! laid #t)))))
          (let ((base (group-cwd id)))
            (for-each
              (lambda (mem)
                (let ((full (cond ((eq? (car mem) 'abs) (expand-path (cadr mem)))
                                  (base (string-append base (cadr mem)))
                                  (else #f))))
                  (cond ((not (and full (file-exists? full)))
                         (set! missing (cons (cadr mem) missing)))
                        ;; one buffer, one group: a file open in another group stays there
                        ((and (buffer-known? full) (buffer-group full)
                              (not (equal? (group-resolve-id (buffer-group full)) id)))
                         (set! skipped (cons full skipped)))
                        ((and (buffer-known? full) (equal? (group-resolve-id (buffer-group full)) id)) #f)
                        (else (buffer-add-group! (find-file full) id)
                              (set! opened (+ opened 1))))))
              (or (plist-get plist 'members) '())))
          (list 'id id 'name name 'opened opened 'tasks tasks 'buffers adopted 'layout laid
                'skipped (reverse skipped) 'missing (reverse missing))))))

;; the socket path as the other end's shell reads it: nc runs in the home
;; folder, and a quoted ~ would not expand
(define (group-transfer--socket-arg sock)
  (if (string-prefix? "~/" sock) (substring sock 2 (string-length sock)) sock))

(define (group-send g host &optional into)
  "(group-send G HOST [INTO]) -- export group G, copy it to HOST with rsync and import it in the compos there, into the group INTO there when given; answers what that import answered. It blocks: run it in a task"
  (let* ((stamp (number->string (current-time)))
         (out (group-export g (string-append (compos-home) "/tmp/group-send-" stamp)))
         (name (group-transfer--name-of out))
         (remote-dir (string-append "compos-imports/" stamp))
         (made (remote-sh host (string-append "mkdir -p " remote-dir))))
    (if (not (eq? made #t))
        (error (string-append "group-send: " (value->string made)))
        ;; a big group outlasts the shell's time limit: the copy runs with a
        ;; callback, and the line it ends with says how it went
        (let ((copied (app-await
                        (lambda (k)
                          (shell-command->string
                            (string-append "log=$(rsync -a --partial '" out "' '" host ":" remote-dir "/' 2>&1); "
                                           "echo rsync-exit=$?; printf '%s\\n' \"$log\" | tail -5")
                            (compos-home) k)))))
          (if (not (string-contains? (value->string copied) "rsync-exit=0"))
              (error (string-append "group-send: rsync failed: " (value->string copied)))
              (peer-eval (string-append host ":" (group-transfer--socket-arg group-transfer-peer-socket))
                         (string-append "(group-import! \"~/" remote-dir "/" name "\" #f "
                                        (if into (format "~s" into) "#f") ")")))))))

(define-command "group-export" "Write this group as a folder another compos can import"
  (lambda ()
    (let ((id (group-transfer--current)))
      (if (not id)
          (message "No group here")
          (message (string-append "Exported " (group-name id) " to " (group-export id)))))))

(define-command "group-import" "Make a new group from a folder group-export wrote"
  (lambda ()
    (read-file-name "Import group from: "
      (lambda (path)
        (let ((r (group-import! path)))
          (message (string-append "Imported " (plist-get r 'name) ": "
                                  (number->string (plist-get r 'opened)) " files, "
                                  (number->string (length (plist-get r 'missing))) " missing")))))))

(define-command "group-send" "Send this group to the compos on another machine"
  (lambda ()
    (let ((id (group-transfer--current)))
      (if (not id)
          (message "No group here")
          (read-string "Send group to host: "
            (lambda (host)
              (message (string-append "Sending " (group-name id) " to " host " ..."))
              (task-run! (lambda () (group-send id host))
                (lambda (ok? value)
                  (message (if ok?
                               (string-append "Sent " (group-name id) " to " host ": " (value->string value))
                               (string-append "group-send to " host " failed: " (value->string value))))))))))))

(public! 'group-export "(group-export G [DIR]) -- write group G as the folder DIR/NAME.group, by default under <compos-home>/exports; answers its path")
(public! 'group-import! "(group-import! PATH [CWD INTO]) -- make a new group from the folder group-export wrote, or fill the group INTO; answers (id ID name NAME opened N tasks N buffers N layout BOOL skipped (PATH ...) missing (PATH ...))")
(effects! '(write external execute))
(public! 'group-send "(group-send G HOST [INTO]) -- export group G with its layout and buffers, rsync it to HOST and import it in the compos there, into the group INTO there when given; blocks, run it in a task")
(catalog-meta! 'command "group-send" 'domain 'buffers 'effects '(write external execute))

(provide 'group-transfer)
