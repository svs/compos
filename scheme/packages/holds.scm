;;; holds.scm --- long jobs declare a hold; hot reloads wait for the holds.
;;;
;;; A drive-eval run, a mix test or a teaching pass breaks when a hot reload
;;; lands in the middle of it. Such work takes a hold while it runs, and
;;; the reloads read the holds. Chats coordinate through this state, never
;;; through messages: a queued "go" goes stale, a hold dies with its owner.
;;;
;;; - An agent's save of source the daemon hot-reloads (.ex, .heex, .scm
;;;   under the watched roots) is refused while a reload hold is open. The
;;;   user's own save is never blocked; it only warns.
;;; - reload-file refuses an agent the same way.
;;; - A test hold is exclusive: one mix test at a time. shell-job! takes it.
;;; - release! publishes holds/released, so a chat that waits listens for
;;;   that event instead of polling.

(domain! 'system)
(effects! '(read))

(defvar '*holds* '())
(defvar '*holds--serial* 0)

(define holds-exclusive-kinds '(test))

(define (holds--owner-live? owner)
  (cond ((not owner) #f)
        ((equal? owner "user") #t)
        ((string? owner)
         (or (buffer-known? owner)
             (and (boundp 'todo--live-chat) (todo--live-chat owner) #t)))
        (else (and (ignore-errors (lambda () (task-alive? owner))) #t))))

(define (holds--owner-name owner)
  (cond ((not (string? owner)) "a task")
        ((buffer-known? owner) owner)
        ((and (boundp 'todo--live-chat) (todo--live-chat owner)))
        (else owner)))

(define (holds--age since)
  (let ((s (max 0 (- (current-time) since))))
    (cond ((< s 60) (string-append (number->string s) "s"))
          ((< s 3600) (string-append (number->string (quotient s 60)) "m"))
          (else (string-append (number->string (quotient s 3600)) "h")))))

(define (holds--live)
  (filter (lambda (h) (holds--owner-live? (plist-get h 'owner))) *holds*))

(define (holds--show h)
  (list 'id (plist-get h 'id) 'kind (plist-get h 'kind) 'why (plist-get h 'why)
        'owner (holds--owner-name (plist-get h 'owner)) 'age (holds--age (plist-get h 'since))))

;;;###autoload
(define (holds &optional kind)
  "(holds [KIND]) - the open holds, oldest first, each (id ID kind KIND why WHY owner CHAT age AGE); KIND keeps one kind. A hold whose owner chat or task is gone is not open."
  (map holds--show
       (filter (lambda (h) (or (not kind) (eq? kind (plist-get h 'kind)))) (holds--live))))

(define (holds-text hs)
  "one line naming the holds HS, as holds answers them: owner (kind: why, age); ..."
  (string-join (map (lambda (h) (string-append (plist-get h 'owner) " (" (symbol->string (plist-get h 'kind))
                                                ": " (plist-get h 'why) ", " (plist-get h 'age) ")"))
                    hs)
               "; "))

(define (holds--agent?)
  (let ((a (current-edit-author))) (and (string? a) (string-prefix? "agent:" a))))

(define (holds--repo)
  (let ((p (compos-priv-dir)))
    (and (string? p) (string-contains? p "/_build/")
         (string-append (car (string-split p "/_build/")) "/"))))

(define (holds-reloadable? path)
  "#t when a save of PATH hot-reloads into the daemon: .ex, .heex or .scm under the watched roots, a test file left out"
  (and (string? path)
       (let* ((parts (string-split path "/")) (base (car (reverse parts)))
              (repo (holds--repo)) (home (string-append (compos-config-dir) "/")))
         (and (or (string-suffix? ".ex" base) (string-suffix? ".heex" base) (string-suffix? ".scm" base))
              (not (string-suffix? "-test.scm" base))
              (not (string-prefix? "." base))
              (not (string-prefix? "#" base))
              (null? (filter (lambda (x) (member x parts))
                             '("tests" "_build" "deps" "node_modules" "target" ".git"
                               "buffers" "chats" "worktree-daemons" "grammars")))
              (or (string-prefix? home path)
                  (and repo (string-prefix? repo path)
                       (let ((rel (substring path (string-length repo) (string-length path))))
                         (or (string-prefix? "scheme/" rel)
                             (string-prefix? "apps/compos_core/priv/" rel)
                             (and (string-prefix? "apps/" rel) (string-contains? rel "/lib/"))))))))))

(define (holds-reload-refusal &optional path)
  "#f when a reload may go now; else why it must wait: the open reload holds. With PATH, #f too when PATH does not hot-reload"
  (let ((hs (holds 'reload)))
    (and (pair? hs)
         (or (not path) (holds-reloadable? path))
         (string-append "a reload hold is open: " (holds-text hs)
                        ". A reload now lands in that work. Wait for the release: (agent-listen! '(topic \"holds\" kind released) NOTE), then try again. (holds) lists them"))))

(public! 'holds "(holds [KIND]) — the open holds: long work (a drive-eval run, a mix test) that a hot reload would break; each with its owner chat, why and age")
(public! 'holds-reloadable? "(holds-reloadable? PATH) — #t when a save of PATH hot-reloads into the running daemon")
(public! 'holds-reload-refusal "(holds-reload-refusal [PATH]) — #f when a reload may go now, else why it waits: the open reload holds")

(domain! 'system)
(effects! '(write))

(define (holds--me)
  (let ((chat (and (boundp 'llm-tool-buffer) (llm-tool-buffer))))
    (if (and (string? chat) (buffer-known? chat)) (chat-stable-id! chat) "user")))

;;;###autoload
(define (hold! kind why &optional owner)
  "(hold! KIND WHY [OWNER]) - declare long work that a hot reload would break, and answer the hold's id; end it with (release! ID). KIND is a symbol: 'reload makes agent saves of reloadable source and reload-file wait; 'test is one mix test, and only one owner holds it at a time. OWNER is the agent's chat by default (else \"user\"), or a task; the hold dies with it."
  (let* ((owner (or owner (holds--me)))
         (r (with-scheme-lock 'holds
              (lambda ()
                (set! *holds* (holds--live))
                (let ((other (filter (lambda (h) (and (eq? kind (plist-get h 'kind))
                                                      (not (equal? owner (plist-get h 'owner)))))
                                     *holds*)))
                  (if (and (memq kind holds-exclusive-kinds) (pair? other))
                      (list 'refused (map holds--show other))
                      (begin
                        (set! *holds--serial* (+ 1 *holds--serial*))
                        (let ((id (string-append "hold-" (number->string *holds--serial*))))
                          (set! *holds* (append *holds* (list (list 'id id 'kind kind 'why why 'owner owner
                                                                    'since (current-time)))))
                          id))))))))
    (if (string? r) r
        (error (string-append "hold!: a " (symbol->string kind) " hold is open: " (holds-text (cadr r))
                              ". Wait for the release: (agent-listen! '(topic \"holds\" kind released) NOTE)")))))

;;;###autoload
(define (release! id)
  "(release! ID) - end the hold ID and publish holds/released, which wakes the chats that wait; #t when it was open"
  (let ((gone (with-scheme-lock 'holds
                (lambda ()
                  (let ((h (filter (lambda (h) (equal? id (plist-get h 'id))) *holds*)))
                    (set! *holds* (filter (lambda (h) (not (equal? id (plist-get h 'id)))) (holds--live)))
                    h)))))
    (when (pair? gone)
      (event-publish! "holds" 'released
                      (list 'id id 'kind (plist-get (car gone) 'kind) 'why (plist-get (car gone) 'why)
                            'open (length *holds*))))
    (pair? gone)))

(public! 'hold! "(hold! KIND WHY [OWNER]) — declare long work a hot reload would break ('reload, or 'test for one mix test at a time); answers the id for release!")
(public! 'release! "(release! ID) — end a hold and wake the chats that wait on holds/released")

;; An agent's save of reloadable source waits for the reload holds. The
;; user's save goes through: it warns and names the holders.
(defwrite-rule! 'reload-waits-for-holds
  (lambda (path source) (holds-reload-refusal path)) #t
  (lambda (path source)
    (and source
         (let ((why (holds-reload-refusal path)))
           (cond ((not why) #f)
                 ((holds--agent?) #t)
                 (else (message (string-append "saved while a reload hold is open: "
                                               (holds-text (holds 'reload))))
                       #f))))))

(provide 'holds)
