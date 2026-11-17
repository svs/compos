;;; agent-verbs.scm --- one call for the jobs agents do in many small calls.
;;;
;;; The chat logs show which calls agents chain, round after round. Each
;;; verb here does one such chain in one call. (agent-call-chains) counts
;;; the chains again from the logs, so the next ones can follow.

(require 'holds)

(domain! 'code)
(effects! '(read))

(define (agent-verbs--abs root rel)
  (if (string-prefix? "/" rel) rel
      (string-append (if (string-suffix? "/" root) root (string-append root "/")) rel)))

(define (agent-verbs--take l n) (if (> (length l) n) (list-head l n) l))

;;;###autoload
(define (code-find-read buf text)
  "(code-find-read BUF TEXT) - find the definition whose name or signature holds TEXT and read it, in one call: (ROW SOURCE OTHERS). BUF is a buffer, or a file path no buffer holds; the file is read without opening it. ROW is the outline row, OTHERS the line and name of the other hits; #f when nothing matches."
  (let* ((open (buffer-known? buf))
         (rows (if open (code-find buf text)
                   (let ((o (file-outline buf)))
                     (if (pair? o)
                         (filter (lambda (r) (string-contains? (string-append (nth 2 r) " " (nth 3 r)) text)) o)
                         o)))))
    (cond ((string? rows) rows)
          ((not (pair? rows)) #f)
          (else (list (car rows)
                      (if open (code-read buf (nth 0 (car rows))) (file-section buf (nth 0 (car rows))))
                      (map (lambda (r) (list (nth 0 r) (nth 2 r))) (cdr rows)))))))

(public! 'code-find-read "(code-find-read BUF TEXT) — find a definition by name and read its source, in one call; BUF is a buffer or a file path" 'code)

;;;###autoload
(define (project-search-sections root pattern &optional limit)
  "(project-search-sections ROOT PATTERN [LIMIT]) - search the project and read the definition or section around each hit, in one call: (matches N sections ((PATH LINE SECTION) ...)). LIMIT caps the sections, 8 by default; two hits in one section give it once."
  (let* ((hits (project-search-matches root pattern)) (n (or limit 8)))
    (let loop ((hs hits) (seen '()) (out '()))
      (if (or (null? hs) (>= (length out) n))
          (list 'matches (length hits) 'sections (reverse out))
          (let* ((h (car hs)) (path (agent-verbs--abs root (nth 1 h))) (line (nth 2 h))
                 (sec (file-section path line)) (key (string-append path "\n" (if (string? sec) sec ""))))
            (if (member key seen) (loop (cdr hs) seen out)
                (loop (cdr hs) (cons key seen) (cons (list path line sec) out))))))))

(public! 'project-search-sections "(project-search-sections ROOT PATTERN [LIMIT]) — search the project and read the section or definition around each hit, in one call: grep, then read the matching sections" 'code)

;;;###autoload
(define (buffer-tail buf &optional lines)
  "(buffer-tail BUF [LINES]) - the last LINES lines of BUF, 20 by default, and its line count: (lines N text TEXT). For a log, a process or a shell buffer you check."
  (let* ((all (string-split (buffer-text buf) "\n")) (n (length all)) (k (min n (or lines 20))))
    (list 'lines n 'text (string-join (list-tail all (- n k)) "\n"))))

(public! 'buffer-tail "(buffer-tail BUF [LINES]) — the last lines of a buffer and its line count: tail a log, a shell or a process buffer" 'buffers)

(domain! 'files)
(effects! '(write))

;;;###autoload
(define (file-edit! path old new)
  "(file-edit! PATH OLD NEW) - replace the one place OLD is in the file PATH by NEW, save, and answer the edited lines, in one call. It opens the file when no buffer holds it and closes it after. A buffer with unsaved work of the user is edited but not saved; the answer says so. OLD must be in the file once, else the answer says why and nothing changes."
  (let* ((known (buffer-known? path))
         (here (current-buffer))
         (buf (if known path (with-current-buffer here (lambda () (visit path (buffer-group here))))))
         (dirty (and known (buffer-modified? buf)))
         (res (buffer-replace! buf old new))
         (ok (and (string? res) (string-prefix? "edited" res))))
    (when (and ok (not dirty)) (with-current-buffer buf (lambda () (buffer-save!))))
    (unless known (buffer-kill! buf))
    (list 'path path 'saved (and ok (not dirty)) 'unsaved-user-work (and dirty #t)
          'result (if (and ok dirty) (string-append "edited, not saved: the buffer holds unsaved work of the user. " res) res))))

(public! 'file-edit! "(file-edit! PATH OLD NEW) — edit a file and save it, in one call: replace text in the file, save, answer the edited lines; opens and closes the buffer when no buffer holds it, never saves unsaved work of the user" 'files)

(domain! 'todo)
(effects! '(write))

;;;###autoload
(define (todo-move-to-group! id group &optional who)
  "(todo-move-to-group! ID GROUP [WHO]) - move a todo and every live chat of it (the assignee and its kept chats) to GROUP, a group name or id, in one call: (todo ID group NAME chats MOVED)."
  (let* ((t (todo-get id)) (g (todo--group-of group))
         (ids (let ((a (plist-get t 'assignee)) (cs (or (plist-get t 'chats) '())))
                (filter (lambda (x) (and (string? x) (string-prefix? "chat:" x)))
                        (if (and (string? a) (not (member a cs))) (cons a cs) cs))))
         (chats (filter (lambda (b) b) (map todo--live-chat ids))))
    (todo-update id (list 'group g 'by (or who todo-user)))
    (for-each (lambda (c) (buffer-move-to-group! c g)) chats)
    (list 'todo id 'group (group-name g) 'chats chats)))

(public! 'todo-move-to-group! "(todo-move-to-group! ID GROUP [WHO]) — move a todo and its chats to another group, in one call" 'todo)

(domain! 'chat)
(effects! '(write execute external))

;;;###autoload
(define (shell-job! topic cmd note &optional dir)
  "(shell-job! TOPIC CMD NOTE [DIR]) - run a long shell command in the background and wake this chat with its output when it ends, in one call; answer the listener id. TOPIC gets job: in front when it has no prefix, so it is private to this chat. Write CMD so its output is the answer. A mix test takes a test hold and a reload hold until it ends: one mix test at a time, and agent saves wait for it. While another chat's test runs, it refuses and names the holder; wait with (agent-listen! '(topic \"holds\" kind released) NOTE)."
  (let* ((topic (if (string-contains? topic ":") topic (string-append "job:" topic)))
         (why (string-append "mix test: " (if (> (string-length cmd) 80) (substring cmd 0 80) cmd)))
         (hs (if (string-contains? cmd "mix test")
                 (let ((t (hold! 'test why))) (list t (hold! 'reload why)))
                 '()))
         (l (agent-listen! (list 'topic topic 'kind 'done) note))
         (ok (ignore-errors
               (lambda ()
                 (shell-command->string cmd (or dir (default-directory))
                   (lambda (out) (for-each release! hs) (event-publish! topic 'done out)))
                 #t))))
    ;; a command that did not start leaves no hold behind
    (unless ok
      (for-each release! hs)
      (agent-unlisten! l)
      (error (string-append "shell-job!: the command did not start"
                            (let ((no (and (boundp 'decide-shell-command-verdict) (decide-shell-command-verdict cmd))))
                              (if (string? no) (string-append ": " no) "")))))
    l))

(public! 'shell-job! "(shell-job! TOPIC CMD NOTE [DIR]) — run a long shell command in the background and wake this chat with its output when it is done, in one call: listen, run, publish" 'chat)

(domain! 'chat)
(effects! '(read))

(define agent-verbs--core
  '("list" "let" "let*" "lambda" "define" "map" "filter" "for-each" "if" "when" "cond" "and" "or" "not" "begin" "string-append" "length" "list-head" "list-tail" "assoc" "plist-get" "equal?" "null?" "reverse" "apply" "format" "substring" "substring-bytes" "string-length" "string-index" "string-prefix?" "string-suffix?" "string-contains?" "member" "unless" "set!" "cons" "append" "string-split" "string-join" "with-current-buffer" "with-frame-windows" "default-directory" "chat-parallel-map" "monotonic-ms" "chat-context" "apropos" "describe-function" "skill" "message" "git-root"))

(define agent-verbs--wrappers '(list begin and or when unless if let let* letrec with-current-buffer with-frame-windows lambda for-each map filter apply cond))

(define (agent-verbs--form-heads f)
  (if (not (and (pair? f) (symbol? (car f)) (list? f))) '()
      (let ((h (car f)))
        (cond ((memq h '(let let* letrec))
               (let* ((rest (if (and (pair? (cdr f)) (symbol? (cadr f))) (cddr f) (cdr f)))
                      (binds (if (and (pair? rest) (list? (car rest))) (car rest) '()))
                      (body (if (pair? rest) (cdr rest) '())))
                 (append (apply append (map (lambda (bd) (if (and (list? bd) (= (length bd) 2)) (agent-verbs--form-heads (cadr bd)) '())) binds))
                         (apply append (map agent-verbs--form-heads body)))))
              ((memq h '(quote quasiquote)) '())
              ((eq? h 'cond) (apply append (map (lambda (c) (if (list? c) (apply append (map agent-verbs--form-heads c)) '())) (cdr f))))
              ((memq h '(lambda)) (apply append (map agent-verbs--form-heads (if (pair? (cdr f)) (cddr f) '()))))
              ((memq h agent-verbs--wrappers) (apply append (map agent-verbs--form-heads (cdr f))))
              ((member (symbol->string h) agent-verbs--core) '())
              (else (list (symbol->string h)))))))

(define (agent-verbs--heads code)
  (let ((forms (scheme-read code)))
    (if (or (not (pair? forms)) (pair? (filter (lambda (f) (and (pair? f) (memq (car f) '(define define-command define-minor-mode deftest)))) forms))) '()
        (let loop ((l (apply append (map agent-verbs--form-heads forms))) (acc '()))
          (cond ((null? l) (reverse acc))
                ((member (car l) acc) (loop (cdr l) acc))
                (else (loop (cdr l) (cons (car l) acc))))))))

(define (agent-verbs--turns path)
  (let ((turns '()) (cur '()))
    (for-each (lambda (m)
                (let ((bs (or (plist-get m 'blocks) '())))
                  (when (and (equal? (plist-get m 'role) "user") (pair? (filter (lambda (x) (and (pair? x) (equal? (car x) "text"))) bs)))
                    (when (pair? cur) (set! turns (cons (reverse cur) turns)))
                    (set! cur '()))
                  (for-each (lambda (x)
                              (when (and (pair? x) (equal? (car x) "tool-use") (>= (length x) 4)
                                         (string-contains? (nth 2 x) "eval-scheme"))
                                (let* ((j (json-parse (nth 3 x))) (c (and (pair? j) (plist-get j 'code))))
                                  (when (string? c) (set! cur (cons c cur))))))
                            bs)))
              (or (plist-get (chat-log-read path) 'record) '()))
    (when (pair? cur) (set! turns (cons (reverse cur) turns)))
    (reverse turns)))

(define (agent-verbs--count items n)
  (let loop ((l (sort items)) (acc '()))
    (cond ((pair? l)
           (loop (cdr l) (if (and (pair? acc) (equal? (cadr (car acc)) (car l)))
                             (cons (list (+ 1 (car (car acc))) (car l)) (cdr acc))
                             (cons (list 1 (car l)) acc))))
          (else (agent-verbs--take (reverse (sort acc)) n)))))

;;;###autoload
(define (agent-call-chains &optional chats n)
  "(agent-call-chains [CHATS] [N]) - which editor calls agents chain from one eval to the next inside one user turn, from the newest CHATS chat logs (100 by default): (ms MS evals E turns T single ((COUNT NAME) ...) pairs ((COUNT \"A -> B\") ...)), the N most frequent, 15 by default. A call is the head of a top-level form of the eval; an eval that defines is left out. A pair high on the list is a job that wants one call. Slow on many chats: call it from a task."
  (let* ((t0 (monotonic-ms)) (fs (agent-verbs--take (reverse (chat-log-files)) (or chats 100)))
         (single '()) (pairs '()) (evals 0) (turns 0))
    (for-each (lambda (f)
                (for-each (lambda (turn)
                            (let ((prev '()))
                              (set! turns (+ turns 1))
                              (for-each (lambda (code)
                                          (let ((hs (agent-verbs--heads code)))
                                            (when (pair? hs)
                                              (set! evals (+ evals 1))
                                              (set! single (cons hs single))
                                              (for-each (lambda (a) (for-each (lambda (x) (unless (equal? a x) (set! pairs (cons (string-append a " -> " x) pairs)))) hs)) prev)
                                              (set! prev hs))))
                                        turn)))
                          (agent-verbs--turns f)))
              fs)
    (list 'ms (- (monotonic-ms) t0) 'evals evals 'turns turns
          'single (agent-verbs--count (apply append single) (or n 15))
          'pairs (agent-verbs--count pairs (or n 15)))))

(public! 'agent-call-chains "(agent-call-chains [CHATS] [N]) — which editor calls agents chain call after call, counted from the chat logs: the jobs that want one call" 'chat)

(provide 'agent-verbs)
