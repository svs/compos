;;; recall.scm --- Opus teaches Haiku: what worked once, recalled for the next prompt.

;; One store, one matcher. A recipe is a function fast-code learned
;; (<compos-home>/packages/learned.scm); a phrase is a row of
;; command-palette-learned. apropos finds both, and recall asks apropos.
;;
;; The teacher reads Opus's drive-eval chats, keeps the calls that did
;; the work (drive-eval-friction drops the dead ends), and asks a model to
;; write them as one function for any values. fast-learn! keeps it, so the
;; function is defined in the session, in the catalog and in the file.
;;
;; Recall puts the best match in front of the prompt as "last time this
;; worked". The model still checks the answer, so a stale recipe costs at
;; most the one call.

;; the recipes are fast-code's learned functions: loading it defines them
(require 'fast-code)

(domain! 'chat)
(effects! '(read))

(defcustom 'agent-recall 'driver
  "Which chats get a learned recipe in front of a prompt it matches: driver, the chats on the Driver preset; all; or off."
  'group 'chat 'type 'symbol)

(defcustom 'recall-candidates 4
  "How many apropos hits recall looks at for a learned recipe."
  'group 'chat 'type 'number)

(define (recall--driver? buf)
  (let ((ps (or (buffer-local buf 'chat-presets) '())))
    (and (list? ps)
         (any (lambda (p) (equal? (if (symbol? p) (symbol->string p) p) "driver")) ps))))

(define (recall-on? buf)
  "does BUF get recipes: its own 'agent-recall (on or off) wins, else the setting"
  (let ((own (buffer-local buf 'agent-recall)))
    (cond ((eq? own 'on) #t)
          ((eq? own 'off) #f)
          ((eq? agent-recall 'all) #t)
          ((eq? agent-recall 'driver) (recall--driver? buf))
          (else #f))))

(define (recall--learned-functions)
  (if (boundp 'fast-learned-names) (fast-learned-names) '()))

(define (recall--learned-commands)
  (if (boundp 'command-palette-learned)
      (filter string? (map (lambda (r) (and (pair? r) (pair? (cdr r)) (cadr r))) command-palette-learned))
      '()))

(define (recall-hits text)
  "the learned functions and learned palette commands apropos finds for TEXT, best first, as apropos hits"
  (let ((fns (recall--learned-functions))
        (cmds (recall--learned-commands)))
    (if (and (null? fns) (null? cmds))
        '()
        (let ((hs (apropos text)))
          (filter (lambda (h)
                    (let ((k (plist-get h 'kind)) (n (plist-get h 'name)))
                      (or (and (equal? k "function") (member n fns))
                          (and (equal? k "command") (member n cmds)))))
                  (list-head hs (min recall-candidates (length hs))))))))

(define (recall--source h)
  (let* ((n (plist-get h 'name))
         (row (and (boundp '*fast-learned*) (assoc n *fast-learned*))))
    (if (and row (equal? (plist-get h 'kind) "function"))
        (let ((block (cadr row)))
          ;; the define alone: the marker line and the public! stamp say nothing new
          (string-trim
            (car (string-split (string-join (cdr (string-split block "\n")) "\n") "\n(public! "))))
        (string-append "(run-command \"" n "\")"))))

(define (recall-note buf text)
  "the recipe note for TEXT in front of a prompt to BUF, or \"\""
  (if (not (and (string? text) (recall-on? buf)))
      ""
      (let ((hs (or (ignore-errors (lambda () (recall-hits text))) '())))
        (if (null? hs)
            ""
            (let ((h (car hs)))
              (string-append
                "[Last time this worked for a request like this one. "
                "It is defined now: call it with this request's values, then check that its answer fits. "
                "If it does not fit, work as usual.\n"
                (recall--source h) "]\n\n"))))))

(public! 'recall-on? "(recall-on? BUF) -- #t when BUF gets a learned recipe in front of its prompts: BUF's 'agent-recall, else the setting agent-recall")
(public! 'recall-hits "(recall-hits TEXT) -- the learned functions and learned palette commands apropos finds for TEXT, best first")
(public! 'recall-note "(recall-note BUF TEXT) -- the 'last time this worked' note for TEXT in front of a prompt to BUF, or an empty string")

;;; The teacher

(domain! 'chat)
(effects! '(write external spend))

(defcustom 'recall-teacher-model "claude-opus-5-5"
  "The model that turns a teacher's calls into one learned function."
  'group 'chat 'type 'string)

(define *recall-taught* '())

(define (recall--code call)
  ;; the code of an eval call: its input is JSON {"code": ...}
  (let ((j (ignore-errors (lambda () (json-parse (list-ref call 3))))))
    (and (pair? j) (plist-get j 'code))))

(define (recall--useful fr)
  "the eval calls of a friction list that did work, oldest first, as (CODE RESULT)"
  (filter (lambda (x) x)
    (map (lambda (c)
           (and (not (car c))
                (string-contains? (list-ref c 2) "eval-scheme")
                (let ((code (recall--code c)))
                  (and (string? code) (list code (drive-eval--clip (list-ref c 4) 300))))))
         fr)))

(define (recall-teacher-runs &optional teacher)
  "the teacher's archived drive-eval chats, the best of each case: ((CASE PROMPT CALLS) ...); CALLS are (CODE RESULT), dead ends dropped"
  (let* ((who (or teacher "opus"))
         (runs (filter (lambda (x) x)
                 (map (lambda (f)
                        (let* ((r (ignore-errors (lambda () (chat-log-read f))))
                               (title (or (and r (plist-get (plist-get r 'header) 'title)) ""))
                               (ws (string-split title " ")))
                          (and (string-prefix? "drive-eval " title) (>= (length ws) 3) (equal? (caddr ws) who)
                               ;; a reworded prompt (lines.r1) is held out: recall is measured on it
                               (not (string-contains? (cadr ws) "."))
                               (let* ((fr (or (ignore-errors (lambda () (drive-eval-friction (or (plist-get r 'record) '())))) '()))
                                      (ps (plist-get r 'prompts))
                                      (p (if (pair? ps) (car ps) ps))
                                      (calls (recall--useful fr)))
                                 (and (string? p) (pair? calls)
                                      (list (cadr ws) p calls (length fr)))))))
                      (chat-log-files))))
         (cases (fast-distinct (map car runs))))
    (map (lambda (c)
           (let ((best (fold (lambda (a x) (if (< (list-ref x 3) (list-ref a 3)) x a))
                             (car (filter (lambda (x) (equal? (car x) c)) runs))
                             (filter (lambda (x) (equal? (car x) c)) runs))))
             (list (car best) (cadr best) (caddr best))))
         cases)))

;; Real chats as a teacher: the first turn of a chat, when it ended in an
;; answer and the user's next message did not correct it. Its dead ends are
;; dropped like a drive-eval run's. A chat that opens with a source prompt of
;; *drive-eval-unseen-cases* never teaches: recall is measured on those.
(define recall--risky '("destroy" "external" "execute" "spend" "display" "unknown"))
(define recall--corrections '("didn't" "doesn't work" "not working" "wrong" "broken" "still" "undo" "revert"))

(define (recall--symbols x)
  (cond ((symbol? x) (list x))
        ((pair? x) (append (recall--symbols (car x)) (recall--symbols (cdr x))))
        (else '())))

(define (recall--safe? code)
  ;; a recipe is offered to later chats: one that sends, runs, spends or
  ;; deletes must not come from a chat the user watched
  (let ((forms (ignore-errors (lambda () (scheme-read code)))))
    (and (pair? forms)
         (not (any (lambda (s)
                     (let ((e (catalog-entry "function" (symbol->string s))))
                       (and e (any (lambda (x) (member x recall--risky)) (or (plist-get e 'effects) '())))))
                   (fast-distinct (recall--symbols forms)))))))

(define (recall--said m)
  (string-join (map cadr (filter (lambda (b) (and (pair? b) (equal? (car b) "text") (pair? (cdr b)) (string? (cadr b))))
                                 (or (plist-get m 'blocks) '())))
               "\n"))

(define (recall--first-turn rec)
  ;; REC oldest first: (TURN NEXT-USER-MESSAGE-OR-#f) after the first prompt
  (let loop ((ms (if (pair? rec) (cdr rec) '())) (acc '()))
    (cond ((null? ms) (list (reverse acc) #f))
          ((equal? (plist-get (car ms) 'role) "user") (list (reverse acc) (car ms)))
          (else (loop (cdr ms) (cons (car ms) acc))))))

(define (recall--chat-run f held)
  (let* ((r (ignore-errors (lambda () (chat-log-read f))))
         (title (or (and r (plist-get (plist-get r 'header) 'title)) ""))
         (ps (and r (plist-get r 'prompts)))
         (p (if (pair? ps) (car ps) ps)))
    (and (string? p) (<= (string-length p) 200)
         (not (string-prefix? "drive-eval" title))
         ;; another harness's runs (*hl:count:cc-haiku:2*) are not the user's
         (not (string-contains? p "*hl:"))
         (not (string-contains? p "*drive-eval"))
         (not (member (string-trim p) held))
         (let* ((ft (recall--first-turn (or (plist-get r 'record) '())))
                (turn (car ft))
                (next (cadr ft))
                (last-msg (and (pair? turn) (list-ref turn (- (length turn) 1))))
                (low (if next (string-downcase (recall--said next)) "")))
           (and last-msg
                (equal? (plist-get last-msg 'role) "assistant")
                (= 0 (drive-eval--tool-uses last-msg))
                (> (string-length (recall--said last-msg)) 0)
                (not (string-prefix? "no" low))
                (not (any (lambda (w) (string-contains? low w)) recall--corrections))
                (let* ((fr (or (ignore-errors (lambda () (drive-eval-friction turn))) '()))
                       (calls (recall--useful fr)))
                  (and (pair? calls) (<= (length calls) 8)
                       (any (lambda (c) (not (string-contains? (car c) "(apropos"))) calls)
                       (every (lambda (c) (recall--safe? (car c))) calls)
                       (list (car (string-split (last (string-split f "/")) ".")) p calls))))))))

(define (recall-chat-runs &optional n)
  "the first turns of the N newest chats (default 40) that ended well, as teacher runs ((NAME PROMPT CALLS) ...); never a drive-eval chat, never a source chat of the unseen set"
  (let ((held (if (boundp '*drive-eval-unseen-cases*) (map (lambda (c) (string-trim (cadr c))) *drive-eval-unseen-cases*) '()))
        (want (or n 40)))
    (let loop ((fs (reverse (chat-log-files))) (acc '()))
      (if (or (null? fs) (>= (length acc) want))
          (reverse acc)
          (let ((run (recall--chat-run (car fs) held)))
            ;; one teacher per prompt: the newest that ended well
            (loop (cdr fs) (if (and run (not (any (lambda (a) (equal? (cadr a) (cadr run))) acc))) (cons run acc) acc)))))))

(define (recall--teach-prompt prompt calls &optional problems)
  (string-append
    "An agent did this request in the compos editor, a Scheme editor, by running the calls below. Dead ends are removed.\n\n"
    "Request: " prompt "\n\nCalls, in order, each with what it answered:\n"
    (apply string-append
      (map (lambda (c) (string-append "\n" (car c) "\n;; => " (cadr c) "\n")) calls))
    "\nWrite ONE Scheme function that does this kind of request for any values, then ONE call to it with this request's values.\n"
    "- Form: (define (NAME PARAM ...) \"DOC\" BODY ...) then (NAME ARG ...).\n"
    "- NAME says what it does for any value. DOC says it for any value and names the parameters in capitals.\n"
    "- Every buffer name, file path, group, word or number the request gave is a parameter, never a literal in the body.\n"
    "- Use only the editor calls above and standard Scheme.\n"
    "- The function answers what the request asks for. When the request asks to confirm or check, the function reads the state back and answers it.\n"
    "- Answer the Scheme only, with no fence and no prose."
    (if problems (string-append "\n\nYour last answer was refused: " problems "\nFix every one.") "")))

(define (recall--with-buffers text thunk)
  ;; fast-accept refuses a call that names a buffer gone since the teacher's
  ;; run; a stand-in buffer lives only while the answer is checked
  (let* ((names (filter (lambda (s) (and (string-prefix? "*" s) (string-suffix? "*" s) (not (buffer-known? s))))
                        (or (ignore-errors (lambda () (fast-strings (cons 'begin (scheme-read text))))) '()))))
    (for-each buffer-create names)
    (let ((r (ignore-errors thunk)))
      (for-each (lambda (n) (when (buffer-known? n) (buffer-kill! n))) names)
      r)))

(define (recall--teach-one run)
  ;; runs in a task: the model call blocks
  (let loop ((tries 0) (problems #f))
    (let* ((text (app-await (lambda (k) (llm-with-model (recall--teach-prompt (cadr run) (caddr run) problems)
                                                         recall-teacher-model k (lambda (e) (k #f))))
                             ;; a teacher answer takes longer than the 20 s default
                             180))
           (r (if (string? text)
                  (or (recall--with-buffers (fast-unfence text) (lambda () (fast-learn! (fast-unfence text) (cadr run))))
                      (list 'no "fast-learn! failed"))
                  (list 'no "the model did not answer"))))
      (if (or (eq? (car r) 'ok) (>= tries 1))
          (list (car run) r text)
          (loop (+ tries 1) (cadr r))))))

(define (recall-teach! &optional teacher cases)
  "turn the teacher's best drive-eval run of each case into a learned function; TEACHER 'chats takes real chats instead, CASES then their count; the result goes to *recall-taught* and the event recall/taught"
  (let* ((chats? (eq? teacher 'chats))
         (runs (if chats?
                   #f
                   (filter (lambda (r) (or (not cases) (memq (string->symbol (car r)) cases)))
                           (recall-teacher-runs teacher))))
         (n (if chats? (or cases 40) (length runs))))
    (task-run!
      (lambda () (map recall--teach-one (or runs (recall-chat-runs n))))
      (lambda (ok? rows)
        (set! *recall-taught* (if ok? rows (list (list 'error rows))))
        (event-publish! "recall" 'taught
          (if ok?
              (string-join (map (lambda (x) (string-append (car x) ": " (value->string (cadr x)))) rows) "\n")
              (string-append "recall-teach! failed: " (value->string rows)))))
      (* 1000 60 (+ 4 (* 2 n))))
    n))

(public! 'recall-teacher-runs "(recall-teacher-runs [TEACHER]) -- the teacher's best archived drive-eval run of each case, dead ends dropped: ((CASE PROMPT ((CODE RESULT) ...)) ...)")
(public! 'recall-teach! "(recall-teach! [TEACHER CASES]) -- in a task, turn the teacher's runs (default opus) into learned functions; TEACHER 'chats learns from real chat logs, CASES then their count; the event recall/taught reports")
(public! 'recall-chat-runs "(recall-chat-runs [N]) -- the first turns of the N newest chats that ended well, as teacher runs, dead ends and risky calls dropped, never a source chat of *drive-eval-unseen-cases*")

(provide 'recall)
