;;; drive-eval.scm --- replay real chat tasks and score models on rounds, time and success.
;;;
;;; (drive-eval) gives each case to a fresh chat, once a model, one run
;;; after another, and waits for the turn end. A case is a task a user
;;; really asked: its source is the prompt from the chat log, its start
;;; state is a fixture buffer or none, and its check reads the end state,
;;; the fixture text and the reply. A row says success, rounds (the model
;;; replies of the turn), tool calls, and wall ms from the send to the
;;; turn end. The table goes to *drive-eval*, the rows to
;;; *drive-eval-rows*, and the event drive-eval done carries the first
;;; line. (drive-eval-mine) lists more candidate tasks from the chat logs.

(domain! 'chat)
(effects! '(read))

(define *drive-eval-models*
  '((haiku "claude-code" "haiku")
    (sonnet "claude-code" "sonnet")
    (opus "claude-code" "opus")))

(define drive-eval-timeout-s 300)

(define *drive-eval-rows* '())

(define (drive-eval--has? text part)
  (and (string? text) (string? part) (string-contains? text part)))

(define (drive-eval--package-of name)
  (let ((hit (filter (lambda (r) (equal? (plist-get r 'name) name)) (apropos name))))
    (and (pair? hit) (plist-get (car hit) 'package))))

;; (NAME SOURCE FIXTURE PROMPT CHECK): PROMPT takes the fixture buffer
;; name; CHECK takes the fixture text at the end, or #f, and the reply.
(define *drive-eval-cases*
  (list
    (list 'setting "what is this 6kb limit we keep hitting on evals?" #f
          (lambda (b) "What is the current value of the setting tool-result-max-bytes? Answer with the number only.")
          (lambda (text reply) (drive-eval--has? reply (number->string tool-result-max-bytes))))
    (list 'package "what does app-dismiss do?" #f
          (lambda (b) "Which package defines the function app-dismiss? Answer with the package name only.")
          (lambda (text reply) (drive-eval--has? reply (drive-eval--package-of "app-dismiss"))))
    (list 'count "how many windows in this group?" "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta"
          (lambda (b) (string-append "How many lines does the buffer " b " hold? Answer with the number only."))
          (lambda (text reply) (drive-eval--has? reply "7")))
    (list 'quote "bring the quote back from the buffer" "Notes from the call.\nQuote: ship small, ship often\nNext steps: none.\n"
          (lambda (b) (string-append "The buffer " b " holds one line that starts with Quote:. Reply with the words after Quote: only."))
          (lambda (text reply) (drive-eval--has? reply "ship small, ship often")))
    (list 'logo "we need to update the logo in the README." "# compos\n\n![logo](images/old-logo.png)\n\nAn editor on the BEAM.\n"
          (lambda (b) (string-append "In the buffer " b ", change the logo image to images/compos-logo.png. Edit the buffer only; it is not a file."))
          (lambda (text reply) (equal? text "# compos\n\n![logo](images/compos-logo.png)\n\nAn editor on the BEAM.\n")))
    (list 'check "see these cardboard todos check which are done" "- [ ] write the copy\n- [ ] ship the build\n- [ ] tell the team\n"
          (lambda (b) (string-append "In the buffer " b ", the item ship the build is done. Change its [ ] to [x] and change nothing else."))
          (lambda (text reply) (equal? text "- [ ] write the copy\n- [x] ship the build\n- [ ] tell the team\n")))))

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

;; one case on one model: (CASE MODEL OK ROUNDS TOOLS MS STOP-REASON)
(define (drive-eval--run c m)
  (let* ((name (symbol->string (car c)))
         (label (symbol->string (car m)))
         (fixture (list-ref c 2))
         (fb (string-append "*drive-eval:" name ":" label "*"))
         (title (string-append "drive-eval " name " " label)))
    (when fixture
      (unless (buffer-known? fb) (buffer-create fb))
      (buffer-set-text! fb fixture))
    (let* ((t0 (monotonic-ms))
           (slug (execute* ((list-ref c 3) fb)
                           (list 'connector (cadr m) 'model (caddr m) 'notify #f
                                 'permission-mode 'auto 'title title)))
           (rs (drive-eval--await slug drive-eval-timeout-s))
           (ms (- (monotonic-ms) t0))
           (r (and (pair? rs) (car rs)))
           (buf (or (and r (plist-get r 'buffer)) title))
           (reply (or (and r (plist-get r 'text)) ""))
           (counts (if (buffer-known? buf) (drive-eval--count (chat-record buf)) '(0 0)))
           (text (and fixture (buffer-known? fb) (buffer-text fb)))
           (ok (and r ((list-ref c 4) text reply) #t)))
      (ignore-errors (lambda () (agent-kill! slug)))
      (when (buffer-known? buf) (buffer-kill! buf))
      (when (and fixture (buffer-known? fb)) (buffer-kill! fb))
      (list (car c) (car m) ok (car counts) (cadr counts) ms (and r (plist-get r 'stop-reason))))))

(define (drive-eval--of rows label) (filter (lambda (r) (eq? (cadr r) label)) rows))
(define (drive-eval--mean xs) (if (null? xs) 0 (/ (apply + xs) (length xs))))
(define (drive-eval--fmt x) (number->string (/ (round (* 10 x)) 10)))

(define (drive-eval--score rows)
  (string-append
    (number->string (length (filter (lambda (r) (list-ref r 2)) rows))) "/" (number->string (length rows)) " ok, "
    (drive-eval--fmt (drive-eval--mean (map (lambda (r) (list-ref r 3)) rows))) " rounds, "
    (drive-eval--fmt (drive-eval--mean (map (lambda (r) (list-ref r 4)) rows))) " tools, "
    (drive-eval--fmt (/ (drive-eval--mean (map (lambda (r) (list-ref r 5)) rows)) 1000)) " s"))

(define (drive-eval--cell r)
  (string-append (if (list-ref r 2) "ok " "NO ")
                 (number->string (list-ref r 3)) "r " (number->string (list-ref r 4)) "t "
                 (drive-eval--fmt (/ (list-ref r 5) 1000)) "s"))

(define (drive-eval--text rows models cases)
  (let ((labels (map car models)))
    (string-append
      "drive-eval: "
      (string-join (map (lambda (l) (string-append (symbol->string l) " " (drive-eval--score (drive-eval--of rows l)))) labels) "; ")
      "\n\n" (string-pad-right "case" 10)
      (string-join (map (lambda (l) (string-pad-right (symbol->string l) 20)) labels) "")
      "\n"
      (string-join
        (map (lambda (c)
               (string-append
                 (string-pad-right (symbol->string (car c)) 10)
                 (string-join
                   (map (lambda (l)
                          (let ((r (filter (lambda (r) (and (eq? (car r) (car c)) (eq? (cadr r) l))) rows)))
                            (string-pad-right (if (pair? r) (drive-eval--cell (car r)) "-") 20)))
                        labels)
                   "")))
             cases)
        "\n")
      "\n\nr: model replies in the turn; t: tool calls; s: send to turn end.\n")))

;; Run every case on every model, one run at a time, in a task, so each
;; time is its own. MODELS and CASES take names or whole entries.
(define (drive-eval &optional models cases)
  (let ((ms (map (lambda (x) (if (symbol? x) (assq x *drive-eval-models*) x)) (or models *drive-eval-models*)))
        (cs (map (lambda (x) (if (symbol? x) (assq x *drive-eval-cases*) x)) (or cases *drive-eval-cases*))))
    (task-run!
      (lambda ()
        (apply append (map (lambda (c) (map (lambda (m) (drive-eval--run c m)) ms)) cs)))
      (lambda (ok? rows)
        (if (not ok?)
            (let ((why (string-append "drive-eval failed: " (value->string rows))))
              (message why)
              (event-publish! "drive-eval" 'done why))
            (let ((text (drive-eval--text rows ms cs)))
              (set! *drive-eval-rows* rows)
              (unless (buffer-known? "*drive-eval*") (buffer-create "*drive-eval*"))
              (buffer-set-text! "*drive-eval*" text)
              (message (car (string-split text "\n")))
              (event-publish! "drive-eval" 'done (car (string-split text "\n"))))))
      (* 1000 (+ 60 (* drive-eval-timeout-s (length ms) (length cs)))))))

(public! 'drive-eval
  "(drive-eval [MODELS CASES]) -- give each case, a real chat task, to a fresh chat on each model and score success, rounds, tool calls and wall ms; the table goes to *drive-eval*, the event drive-eval done says the score")
