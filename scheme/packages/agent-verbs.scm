;;; agent-verbs.scm --- one call for the jobs agents do in many small calls.
;;;
;;; The chat logs show which calls agents chain, round after round. Each
;;; verb here does one such chain in one call. (agent-call-chains) counts
;;; the chains again from the logs, so the next ones can follow.

(domain! 'code)
(effects! '(read))

(define (agent-verbs--abs root rel)
  (if (string-prefix? "/" rel) rel
      (string-append (if (string-suffix? "/" root) root (string-append root "/")) rel)))

(define (agent-verbs--take l n) (if (> (length l) n) (list-head l n) l))

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

(define (code-find-read buf text)
  "(code-find-read BUF TEXT) - find the definition whose name or signature holds TEXT and read it, in one call: (ROW SOURCE OTHERS). ROW is the outline row, OTHERS the names of the other hits; #f when nothing matches."
  (let ((rows (code-find buf text)))
    (cond ((string? rows) rows)
          ((null? rows) #f)
          (else (list (car rows) (code-read buf (nth 0 (car rows)))
                      (map (lambda (r) (list (nth 0 r) (nth 2 r))) (cdr rows)))))))

(define (buffer-tail buf &optional lines)
  "(buffer-tail BUF [LINES]) - the last LINES lines of BUF, 20 by default, and its line count: (lines N text TEXT). For a log, a process or a shell buffer you check."
  (let* ((all (string-split (buffer-text buf) "\n")) (n (length all)) (k (min n (or lines 20))))
    (list 'lines n 'text (string-join (list-tail all (- n k)) "\n"))))

(domain! 'files)
(effects! '(write))

(define (file-edit! path old new)
  "(file-edit! PATH OLD NEW) - replace the one place OLD is in the file PATH by NEW, save, and answer the edited lines, in one call. It opens the file when no buffer holds it and closes it after. A buffer with unsaved work of the user is edited but not saved; the answer says so. OLD must be in the file once, else the answer says why and nothing changes."
  (let* ((known (buffer-known? path))
         (buf (or known (visit path (buffer-group (current-buffer)))))
         (dirty (and known (buffer-modified? buf)))
         (res (buffer-replace! buf old new))
         (ok (and (string? res) (string-prefix? "edited" res))))
    (when (and ok (not dirty)) (with-current-buffer buf (lambda () (buffer-save!))))
    (unless known (buffer-kill! buf))
    (list 'path path 'saved (and ok (not dirty)) 'unsaved-user-work (and dirty #t) 'result res)))

(domain! 'todo)
(effects! '(write))

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

(domain! 'chat)
(effects! '(write execute external))

(define (shell-job! topic cmd note &optional dir)
  "(shell-job! TOPIC CMD NOTE [DIR]) - run a long shell command in the background and wake this chat with its output when it ends, in one call; answer the listener id. TOPIC gets job: in front when it has no prefix, so it is private to this chat. Write CMD so its output is the answer."
  (let ((topic (if (string-contains? topic ":") topic (string-append "job:" topic))))
    (let ((l (agent-listen! (list 'topic topic 'kind 'done) note)))
      (shell-command->string cmd (or dir (default-directory))
        (lambda (out) (event-publish! topic 'done out)))
      l)))

(domain! 'chat)
(effects! '(read))

(define agent-verbs--core
  '("list" "let" "let*" "lambda" "define" "map" "filter" "for-each" "if" "when" "cond" "and" "or" "not" "begin" "string-append" "length" "list-head" "list-tail" "assoc" "plist-get" "equal?" "null?" "reverse" "apply" "format" "substring" "substring-bytes" "string-length" "string-index" "string-prefix?" "string-suffix?" "string-contains?" "member" "unless" "set!" "cons" "append" "string-split" "string-join" "with-current-buffer" "with-frame-windows" "default-directory" "chat-parallel-map" "monotonic-ms" "chat-context" "apropos" "describe-function" "skill" "message" "git-root"))

(define (agent-verbs--heads code)
  (let loop ((ms (re-find* "\\(([a-z][a-z0-9*<>?!-]+)" code)) (acc '()))
    (if (null? ms) (reverse acc)
        (let ((h (substring-bytes code (+ (car (car ms)) 1) (cadr (car ms)))))
          (loop (cdr ms) (if (or (member h acc) (member h agent-verbs--core) (not (string-contains? h "-")) (string-contains? h "--")) acc (cons h acc)))))))

(define (agent-verbs--calls path)
  (let ((out '()))
    (for-each (lambda (m)
                (for-each (lambda (b)
                            (when (and (pair? b) (equal? (car b) "tool-use") (>= (length b) 4)
                                       (string-contains? (nth 2 b) "eval-scheme"))
                              (set! out (cons (nth 3 b) out))))
                          (or (plist-get m 'blocks) '())))
              (or (plist-get (chat-log-read path) 'record) '()))
    (reverse out)))

(define (agent-verbs--count items n)
  (let loop ((l (sort items)) (acc '()))
    (cond ((pair? l)
           (loop (cdr l) (if (and (pair? acc) (equal? (cadr (car acc)) (car l)))
                             (cons (list (+ 1 (car (car acc))) (car l)) (cdr acc))
                             (cons (list 1 (car l)) acc))))
          (else (agent-verbs--take (reverse (sort acc)) n)))))

(define (agent-call-chains &optional chats n)
  "(agent-call-chains [CHATS] [N]) - which editor calls agents chain from one eval to the next, from the newest CHATS chat logs (100 by default): (ms MS calls C single ((COUNT NAME) ...) pairs ((COUNT \"A -> B\") ...)), the N most frequent, 40 by default. A pair high on the list is a job that wants one call. Slow on many chats: call it from a task."
  (let* ((t0 (monotonic-ms)) (fs (agent-verbs--take (reverse (chat-log-files)) (or chats 100)))
         (single '()) (pairs '()) (calls 0))
    (for-each (lambda (f)
                (let ((prev '()))
                  (for-each (lambda (code)
                              (let ((hs (agent-verbs--heads code)))
                                (set! calls (+ calls 1))
                                (set! single (cons hs single))
                                (for-each (lambda (a) (for-each (lambda (b) (unless (equal? a b) (set! pairs (cons (string-append a " -> " b) pairs)))) hs)) prev)
                                (set! prev hs)))
                            (agent-verbs--calls f))))
              fs)
    (list 'ms (- (monotonic-ms) t0) 'calls calls
          'single (agent-verbs--count (apply append single) (or n 40))
          'pairs (agent-verbs--count pairs (or n 40)))))

(provide 'agent-verbs)
