;;; drive-eval.scm --- replay real chat tasks and score models on rounds, time and success.
;;;
;;; (drive-eval) gives each case to a fresh chat, once a model, one run
;;; after another, and waits for the turn end. A case is a task a user
;;; really asked: its source is the prompt from the chat log, its start
;;; state is a fixture (a scratch buffer, a file in /tmp, a test group) or
;;; none, and its check reads the end state and the reply. A row says
;;; success, rounds (the model replies of the turn), tool calls, wall ms
;;; from the send to the turn end, and the chat-perf steps of the turn.
;;; The table goes to *drive-eval*, the rows to *drive-eval-rows*, and the
;;; event drive-eval done carries the first line. (drive-eval-mine) lists
;;; more candidate tasks from the chat logs.
;;;
;;; *drive-eval-cases* are one-step tasks. *drive-eval-hard-cases* are
;;; harness tasks of several steps, each with a check a skipped step fails:
;;; (drive-eval '(haiku opus) 'hard 3).

(domain! 'chat)
(effects! '(read))

(define *drive-eval-models*
  '((haiku "claude-code" "haiku")
    (sonnet "claude-code" "sonnet")
    (opus "claude-code" "opus")
    ;; a fourth item names the preset the chat starts on
    (haiku-driver "claude-code" "haiku" "Driver")
    (deepseek-driver "opencode-go" "opencode-go/deepseek-v4.1-flash" "Driver")))

(define drive-eval-timeout-s 300)

(define *drive-eval-rows* '())

(define (drive-eval--has? text part)
  (and (string? text) (string? part) (string-contains? text part)))

(define (drive-eval--package-of name)
  (let ((hit (filter (lambda (r) (equal? (plist-get r 'name) name)) (apropos name))))
    (and (pair? hit) (plist-get (car hit) 'package))))

;; the first whole number in TEXT, or #f
(define (drive-eval--number text)
  (let ((m (and (string? text) (re-match "[0-9]+" text))))
    (and (pair? m) (string->number (car m)))))

;; the names a fixture's side state takes from its buffer: "*drive-eval:move:haiku*"
;; gives the tag move-haiku, the file /tmp/drive-eval-move-haiku.txt and the
;; group drive-eval-move-haiku
(define (drive-eval--tag fb)
  (string-join (string-split (substring fb 12 (- (string-length fb) 1)) ":") "-"))
(define (drive-eval--file fb) (string-append "/tmp/drive-eval-" (drive-eval--tag fb) ".txt"))
(define (drive-eval--group fb) (string-append "drive-eval-" (drive-eval--tag fb)))

;; (NAME SOURCE FIXTURE PROMPT CHECK [HOOKS]): PROMPT takes the fixture
;; buffer name; CHECK takes the fixture text at the end, or #f, the reply
;; and the fixture buffer name; HOOKS is a plist of 'setup and 'cleanup,
;; each called with the fixture buffer name.
(define *drive-eval-cases*
  (list
    (list 'setting "what is this 6kb limit we keep hitting on evals?" #f
          (lambda (b) "What is the current value of the setting tool-result-max-bytes? Answer with the number only.")
          (lambda (text reply . _) (drive-eval--has? reply (number->string tool-result-max-bytes))))
    (list 'package "what does app-dismiss do?" #f
          (lambda (b) "Which package defines the function app-dismiss? Answer with the package name only.")
          (lambda (text reply . _) (drive-eval--has? reply (drive-eval--package-of "app-dismiss"))))
    (list 'count "how many windows in this group?" "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta"
          (lambda (b) (string-append "How many lines does the buffer " b " hold? Answer with the number only."))
          (lambda (text reply . _) (drive-eval--has? reply "7")))
    (list 'quote "bring the quote back from the buffer" "Notes from the call.\nQuote: ship small, ship often\nNext steps: none.\n"
          (lambda (b) (string-append "The buffer " b " holds one line that starts with Quote:. Reply with the words after Quote: only."))
          (lambda (text reply . _) (drive-eval--has? reply "ship small, ship often")))
    (list 'logo "we need to update the logo in the README." "# compos\n\n![logo](images/old-logo.png)\n\nAn editor on the BEAM.\n"
          (lambda (b) (string-append "In the buffer " b ", change the logo image to images/compos-logo.png. Edit the buffer only; it is not a file."))
          (lambda (text reply . _) (equal? text "# compos\n\n![logo](images/compos-logo.png)\n\nAn editor on the BEAM.\n")))
    (list 'check "see these cardboard todos check which are done" "- [ ] write the copy\n- [ ] ship the build\n- [ ] tell the team\n"
          (lambda (b) (string-append "In the buffer " b ", the item ship the build is done. Change its [ ] to [x] and change nothing else."))
          (lambda (text reply . _) (equal? text "- [ ] write the copy\n- [x] ship the build\n- [ ] tell the team\n")))))

(define drive-eval--needle-text
  (string-join
    (let loop ((i 1) (acc '()))
      (if (> i 40)
          (reverse acc)
          (loop (+ i 1) (cons (string-append "item " (number->string i) (if (= i 27) " needle" "")) acc))))
    "\n"))

;; Harness cases: several steps each, and a check that a skipped step
;; fails. Sources are the task kinds users ask (the chat logs hold too few
;; haiku failures to mine).
(define *drive-eval-hard-cases*
  (list
    ;; 6 rounds for haiku on 2026-11-09; the trailing newline makes a
    ;; split on newlines count 8
    (list 'lines "how many lines in BUF" "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\n"
          (lambda (b) (string-append "How many lines does the buffer " b " hold? Answer with the number only."))
          (lambda (text reply . _) (equal? (drive-eval--number reply) 7)))
    ;; the obvious search answers a byte offset or a 0-based index
    (list 'line-of "which line has it" drive-eval--needle-text
          (lambda (b) (string-append "Which line number of the buffer " b " holds the word needle? Lines count from 1. Answer with the number only."))
          (lambda (text reply . _) (equal? (drive-eval--number reply) 27)))
    ;; edit, save, and confirm on disk: a skipped save fails
    (list 'save "edit this line, save it and confirm" #f
          (lambda (b) (string-append "Open the file " (drive-eval--file b)
                                     ", change the line version = 1 to version = 2, save the file, and confirm that the file on disk says version = 2."))
          (lambda (text reply b) (equal? (read-file (drive-eval--file b)) "name = demo\nversion = 2\nmode = fast\n"))
          (list 'setup (lambda (b) (write-file! (drive-eval--file b) "name = demo\nversion = 1\nmode = fast\n"))
                'cleanup (lambda (b)
                           (let ((p (drive-eval--file b)))
                             (when (buffer-known? p) (buffer-kill! p))
                             (delete-file! p)))))
    ;; set a setting on one buffer, not globally and not in custom.scm
    (list 'local "set a setting and read it back" "some text\n"
          (lambda (b) (string-append "In the buffer " b ", set the buffer-local variable fill-column to 72, then read it back to confirm. Do not change it anywhere else and do not save a setting."))
          (lambda (text reply b) (equal? (buffer-local b 'fill-column) 72)))
    ;; move a buffer to another group and confirm the membership
    (list 'move "move this to another group" "notes for the move\n"
          (lambda (b) (string-append "Move the buffer " b " into the group named " (drive-eval--group b)
                                     ", then confirm that it is a member of that group and of no other."))
          (lambda (text reply b) (equal? (buffer-group b) (group-resolve-id (drive-eval--group b))))
          (list 'setup (lambda (b) (group-record-create! (drive-eval--group b)))
                'cleanup (lambda (b) (when (group-resolve-id (drive-eval--group b))
                                       (group-kill! (drive-eval--group b))))))
    ;; an edit and a count of its result: both must be right
    (list 'prune "drop the comment lines and count the rest" "# head\nalpha\n# note\nbeta\ngamma\n# end\ndelta\n"
          (lambda (b) (string-append "In the buffer " b ", delete every line that starts with #, then tell me how many lines are left. Answer with the number only."))
          (lambda (text reply . _) (and (equal? text "alpha\nbeta\ngamma\ndelta\n")
                                        (equal? (drive-eval--number reply) 4))))))

(define (drive-eval--tool-uses m)
  (length (filter (lambda (b) (and (pair? b) (equal? (car b) "tool-use")))
                  (or (plist-get m 'blocks) '()))))

;; the records of the last turn, oldest first; REC is newest first
(define (drive-eval--turn rec)
  (let loop ((rs rec) (acc '()))
    (cond ((null? rs) acc)
          ((equal? (plist-get (car rs) 'role) "user") acc)
          (else (loop (cdr rs) (cons (car rs) acc))))))

;; (ROUNDS TOOLS) of the last turn of a chat record
(define (drive-eval--count rec)
  (let ((said (filter (lambda (m) (equal? (plist-get m 'role) "assistant")) (drive-eval--turn rec))))
    (list (length said) (apply + (map drive-eval--tool-uses said)))))

(define (drive-eval-mine &optional n max-tools)
  (filter (lambda (x) x)
    (map (lambda (f)
           (let ((r (ignore-errors (lambda () (chat-log-read f)))))
             (and r
                  (let* ((ps (plist-get r 'prompts))
                         (p (if (pair? ps) (car ps) ps))
                         (rec (plist-get r 'record))
                         (k (if (list? rec) (apply + (map drive-eval--tool-uses rec)) 0)))
                    (and (string? p) (> k 0) (<= k (or max-tools 10)) (< (string-length p) 160)
                         (not (string-prefix? "drive-eval" (or (plist-get (plist-get r 'header) 'title) "")))
                         (list k p f))))))
         (let ((fs (reverse (chat-log-files))))
           (list-head fs (min (or n 300) (length fs)))))))

(public! 'drive-eval-mine
  "(drive-eval-mine [N MAX-TOOLS]) -- (TOOLS PROMPT PATH) for the newest N archived chats whose first prompt is short and took at most MAX-TOOLS tool calls: candidate drive-eval cases")

(domain! 'chat)
(effects! '(write external spend))

;; the results subagent-wait gives at the turn end, or #f after SECS.
;; wait-until stops at about 10 s whatever it is asked, so wait in steps
;; up to the deadline.
(define (drive-eval--await slug secs)
  (let ((box #f)
        (deadline (+ (monotonic-ms) (* 1000 secs))))
    (subagent-wait slug (lambda (v) (set! box (list v))))
    (let loop ()
      (cond (box (car box))
            ((>= (monotonic-ms) deadline) #f)
            (else (wait-until (lambda () box) (- deadline (monotonic-ms)) 50) (loop))))))

(define (drive-eval--hook c key fb)
  (let ((f (and (> (length c) 5) (plist-get (list-ref c 5) key))))
    (when f (ignore-errors (lambda () (f fb))))))

;; one case on one model:
;; (CASE MODEL OK ROUNDS TOOLS MS STOP-REASON STEPS REPLY)
;; STEPS is the chat-perf view of the turn, (LABEL MS) per round and tool
(define (drive-eval--run c m)
  (let* ((name (symbol->string (car c)))
         (label (symbol->string (car m)))
         (fixture (list-ref c 2))
         (fb (string-append "*drive-eval:" name ":" label "*"))
         (title (string-append "drive-eval " name " " label)))
    (when fixture
      (unless (buffer-known? fb) (buffer-create fb))
      (buffer-set-text! fb fixture))
    (drive-eval--hook c 'setup fb)
    (let* ((t0 (monotonic-ms))
           (slug (execute* ((list-ref c 3) fb)
                           (append
                             (list 'connector (cadr m) 'model (caddr m) 'notify #f
                                   'permission-mode 'auto 'title title)
                             (if (> (length m) 3) (list 'bundle (list-ref m 3)) '()))))
           (rs (drive-eval--await slug drive-eval-timeout-s))
           (ms (- (monotonic-ms) t0))
           (r (and (pair? rs) (car rs)))
           (buf (or (and r (plist-get r 'buffer)) title))
           (reply (or (and r (plist-get r 'text)) ""))
           (counts (if (buffer-known? buf) (drive-eval--count (chat-record buf)) '(0 0)))
           (steps (if (boundp 'agent-perf-turn) (agent-perf-turn slug) '()))
           (text (and fixture (buffer-known? fb) (buffer-text fb)))
           (bytes (if (buffer-known? buf)
                      (string-byte-length (prompt-parts-text (chat-prompt-parts buf)))
                      0))
           (ok (and r (ignore-errors (lambda () ((list-ref c 4) text reply fb))) #t)))
      (ignore-errors (lambda () (agent-kill! slug)))
      (when (buffer-known? buf) (buffer-kill! buf))
      (drive-eval--hook c 'cleanup fb)
      (when (and fixture (buffer-known? fb)) (buffer-kill! fb))
      (list (car c) (car m) ok (car counts) (cadr counts) ms
            (and r (plist-get r 'stop-reason)) steps reply bytes))))

(define (drive-eval--of rows label) (filter (lambda (r) (eq? (cadr r) label)) rows))
(define (drive-eval--fmt x) (number->string (/ (round (* 10 x)) 10)))

(define (drive-eval--median xs)
  (if (null? xs)
      0
      (let* ((s (sort xs)) (n (length s)))
        (if (= 1 (remainder n 2))
            (list-ref s (quotient n 2))
            (/ (+ (list-ref s (- (quotient n 2) 1)) (list-ref s (quotient n 2))) 2)))))

(define (drive-eval--passed rows)
  (string-append (number->string (length (filter (lambda (r) (list-ref r 2)) rows)))
                 "/" (number->string (length rows))))

(define (drive-eval--score rows)
  (string-append
    (drive-eval--passed rows) " ok, median "
    (drive-eval--fmt (drive-eval--median (map (lambda (r) (list-ref r 3)) rows))) " rounds, "
    (drive-eval--fmt (drive-eval--median (map (lambda (r) (list-ref r 4)) rows))) " tools, "
    (drive-eval--fmt (/ (drive-eval--median (map (lambda (r) (list-ref r 5)) rows)) 1000)) " s"))

;; the runs of one case on one model: passed/runs, then the medians
(define (drive-eval--cell rows)
  (string-append (drive-eval--passed rows) " "
                 (drive-eval--fmt (drive-eval--median (map (lambda (r) (list-ref r 3)) rows))) "r "
                 (drive-eval--fmt (drive-eval--median (map (lambda (r) (list-ref r 4)) rows))) "t "
                 (drive-eval--fmt (/ (drive-eval--median (map (lambda (r) (list-ref r 5)) rows)) 1000)) "s"))

(define (drive-eval--short label)
  (let ((p "mcp__compos__"))
    (if (string-contains? label p)
        (string-join (string-split label p) "")
        label)))

;; one failed run: its reply, and where its rounds and seconds went
(define (drive-eval--failure r)
  (let ((reply (string-trim (or (list-ref r 8) ""))))
    (string-append
      (symbol->string (car r)) " " (symbol->string (cadr r)) ": "
      (number->string (list-ref r 3)) "r " (drive-eval--fmt (/ (list-ref r 5) 1000)) "s, replied "
      (value->string (substring reply 0 (min 60 (string-length reply))))
      "\n    "
      (string-join (map (lambda (s) (string-append (drive-eval--short (car s)) " " (number->string (cadr s))))
                        (or (list-ref r 7) '()))
                   ", "))))

(define (drive-eval--text rows models cases)
  (let ((labels (map car models))
        (failed (filter (lambda (r) (not (list-ref r 2))) rows)))
    (string-append
      "drive-eval: "
      (string-join (map (lambda (l) (string-append (symbol->string l) " " (drive-eval--score (drive-eval--of rows l))
                                                     " prompt " (number->string (fold (lambda (acc r) (if (> (length r) 9) (max acc (list-ref r 9)) acc)) 0 (drive-eval--of rows l))) "B")) labels) "; ")
      "\n\n" (string-pad-right "case" 10)
      (string-join (map (lambda (l) (string-pad-right (symbol->string l) 22)) labels) "")
      "\n"
      (string-join
        (map (lambda (c)
               (string-append
                 (string-pad-right (symbol->string (car c)) 10)
                 (string-join
                   (map (lambda (l)
                          (let ((rs (filter (lambda (r) (and (eq? (car r) (car c)) (eq? (cadr r) l))) rows)))
                            (string-pad-right (if (pair? rs) (drive-eval--cell rs) "-") 22)))
                        labels)
                   "")))
             cases)
        "\n")
      "\n\npassed/runs, then medians. r: model replies in the turn; t: tool calls; s: send to turn end.\n"
      (if (null? failed)
          ""
          (string-append "\nFailures, with the steps of each turn (ms)\n"
                         (string-join (map drive-eval--failure failed) "\n") "\n")))))

(define (drive-eval--case x)
  (if (symbol? x)
      (or (assq x *drive-eval-cases*) (assq x *drive-eval-hard-cases*))
      x))

;; Run every case on every model REPS times, one run at a time, in a task,
;; so each time is its own. MODELS and CASES take names or whole entries;
;; CASES 'hard is the harness set.
(define drive-eval-results-file (string-append (getenv "HOME") "/.compos/drive-eval/results.txt"))

;; the table so far, after each run: into *drive-eval* and into
;; drive-eval-results-file, so a buffer on that file in auto-revert shows the
;; rows as they come. A report that throws never stops the run.
(define (drive-eval--progress! rows ms cs)
  (let ((text (or (ignore-errors (lambda () (drive-eval--text rows ms cs)))
                  "drive-eval: running")))
    (ignore-errors (lambda () (write-file! drive-eval-results-file text)))
    (ignore-errors (lambda ()
                     (unless (buffer-known? "*drive-eval*") (buffer-create "*drive-eval*"))
                     (buffer-set-text! "*drive-eval*" text)))
    text))

(define (drive-eval &optional models cases reps)
  (let* ((ms (map (lambda (x) (if (symbol? x) (assq x *drive-eval-models*) x)) (or models *drive-eval-models*)))
         (cs (cond ((eq? cases 'hard) *drive-eval-hard-cases*)
                   (cases (map drive-eval--case cases))
                   (else *drive-eval-cases*)))
         (n (or reps 1)))
    (task-run!
      (lambda ()
        (let ((done '()))
          (drive-eval--progress! '() ms cs)
          (for-each
            (lambda (c)
              (for-each
                (lambda (m)
                  (let loop ((i 0))
                    (when (< i n)
                      (set! done (cons (drive-eval--run c m) done))
                      (drive-eval--progress! (reverse done) ms cs)
                      (loop (+ i 1)))))
                ms))
            cs)
          (reverse done)))
      (lambda (ok? rows)
        (if (not ok?)
            (let ((why (string-append "drive-eval failed: " (value->string rows))))
              (message why)
              (event-publish! "drive-eval" 'done why))
            ;; the rows land first, and a report that throws still wakes the
            ;; listener: a silent callback looked like a dead run
            (let ((text (begin
                          (set! *drive-eval-rows* rows)
                          (or (ignore-errors (lambda () (drive-eval--text rows ms cs)))
                              "drive-eval: the report failed; the rows are in *drive-eval-rows*"))))
              (unless (buffer-known? "*drive-eval*") (buffer-create "*drive-eval*"))
              (buffer-set-text! "*drive-eval*" text)
              (ignore-errors (lambda () (write-file! drive-eval-results-file text)))
              (message (car (string-split text "\n")))
              (event-publish! "drive-eval" 'done (car (string-split text "\n"))))))
      (* 1000 (+ 60 (* drive-eval-timeout-s n (length ms) (length cs)))))))

(public! 'drive-eval
  "(drive-eval [MODELS CASES REPS]) -- give each case, a real chat task, to a fresh chat on each model REPS times and score passes, median rounds, tool calls and seconds; CASES 'hard is the harness set; the table goes to *drive-eval*, the event drive-eval done says the score")
