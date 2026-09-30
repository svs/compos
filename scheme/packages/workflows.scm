;;; workflows.scm --- workflows: Scheme handlers over the event log, run by the core exactly once.
;;;
;;; A workflow is a name, the topics it listens to, and a handler. The core
;;; (Compos.Core.Workflow, one supervised process each) owns everything that
;;; makes it safe: its position in the log, the quiet gap, one batch at a
;;; time, retries with backoff, parking a batch that keeps failing, and the
;;; commit. This file holds only what an application writes, and the words
;;; it writes it in.
;;;
;;; The core calls (workflow--run NAME EVENTS) on the workflow's own lane,
;;; never on the one keystrokes wait on. The events are grouped by the
;;; workflow's key and each group goes to the handler: (HANDLE KEY EVENTS).
;;;
;;; Two kinds of step. Inference answers questions and returns values:
;;; yes?, pick, extract, ask-model. Code acts on the values with emit! and
;;; once!. Inside a batch those two write nothing yet: the core commits what
;;; they collected, with the workflow's new position, in one transaction.
;;; So a batch that fails, times out or is rewound leaves nothing behind,
;;; and one that succeeds lands exactly once. A model call is observed on
;;; obs:llm at once, whatever becomes of the batch.
;;;
;;; docs/EVENT BUS.md has the design and worked examples; events-demo.scm
;;; is a scene you can drive.

(domain! 'system)
(effects! '(write))

;; NAME -> (handle FN group-by FN): what the core calls back into. It
;; survives a reload of this file.
(define *workflows* (if (boundp '*workflows*) *workflows* '()))

(effects! '(pure))

(define (seconds n)
  "(seconds N) — N seconds in milliseconds"
  (* n 1000))

(define (minutes n)
  "(minutes N) — N minutes in milliseconds"
  (* n 60000))

(define (workflow--fn f) (if (symbol? f) (symbol-value f) f))
(define (workflow--text v) (if (string? v) v (format "~s" v)))

(define (workflow--first-n xs n)
  (if (or (null? xs) (<= n 0)) '() (cons (car xs) (workflow--first-n (cdr xs) (- n 1)))))

;; ((KEY EVENT ...) ...), each KEY in the order it first appears
(define (workflow--group events key-fn)
  (let loop ((es events) (keys '()) (table '()))
    (if (null? es)
        (map (lambda (k) (cons k (reverse (alist-get table k)))) (reverse keys))
        (let* ((k (key-fn (car es))) (seen (alist-get table k)))
          (loop (cdr es)
                (if seen keys (cons k keys))
                (alist-put table k (cons (car es) (or seen '()))))))))

(define (event-topic e)
  "(event-topic E) — E's topic: the key a workflow groups by when it names none"
  (plist-get e 'topic))

;; the options define-workflow! passes on, as the core names them
(define workflow--options
  '((quiet quiet-ms) (max-wait max-wait-ms) (batch batch) (max-attempts max-attempts)
    (backoff backoff-ms) (max-backoff max-backoff-ms) (timeout timeout-ms) (from from)))

(define (workflow--spec opts)
  (append (list 'listen (plist-get opts 'listen))
          (apply append (map (lambda (o)
                               (let ((v (plist-get opts (car o))))
                                 (if (number? v) (list (cadr o) v) '())))
                             workflow--options))))

(effects! '(write))

(define (define-workflow! name &rest opts)
  "(define-workflow! NAME 'listen PATTERNS 'handle FN ['group-by FN] ['quiet MS] ['max-wait MS] ['batch N] ['max-attempts N] ['backoff MS] ['max-backoff MS] ['timeout MS] ['from SEQ]) — run (FN KEY EVENTS) on every new event of PATTERNS, grouped by (GROUP-BY EVENT). Exactly once for what FN writes with emit! and once!. A new workflow starts at the present, or at FROM. Give FN as a quoted name, so a reload changes what runs"
  (set! *workflows* (alist-put *workflows* name
                               (list 'handle (plist-get opts 'handle)
                                     'group-by (or (plist-get opts 'group-by) 'event-topic))))
  (workflow-define! name (workflow--spec opts))
  name)

;; the core's call, on the workflow's lane
(define (workflow--run name events)
  (let ((w (alist-get *workflows* name)))
    (unless w (error (string-append "no handler is defined for the workflow " name)))
    (let ((handle (workflow--fn (plist-get w 'handle)))
          (key (workflow--fn (plist-get w 'group-by))))
      (for-each (lambda (g) (handle (car g) (cdr g))) (workflow--group events key))
      #t)))

(define (once! key thunk)
  "(once! KEY THUNK) — run THUNK the first time KEY is asked and keep its value; later calls answer that value and run nothing. Inside a batch the key lands with the batch's commit. The value must print and read back"
  (let ((hit (workflow-once key)))
    (if hit
        (car hit)
        (let ((value (thunk)))
          (workflow-once-record! key value)
          value))))

(define (once-done? key)
  "(once-done? KEY) — #t when once! has recorded KEY"
  (and (workflow-once key) #t))

;;; Inference: questions a model answers, as values. Each one blocks, so a
;;; handler calls it; a handler runs on its workflow's lane. yes? and pick are typed;
;;; extract is the one free-text step. By default they ask decide (JEV,
;;; Laya, Haiku). 'model (host H model M) sends one to a local model
;;; instead: an Ollama host, or an OpenAI-shaped one whose host ends /v1.
;;;
;;; Every call is an event on obs:llm: the model, the milliseconds, the
;;; tokens, the prompt, the answer, and the event it was about. That is the
;;; trace from a model's answer back to the message it read.

(domain! 'decide)
(effects! '(read external spend))

(defcustom 'workflow-yes-threshold 0.5
  "yes? answers #t at this probability or above."
  'group 'workflows 'type 'number)

(defcustom 'workflow-extract-model "claude-haiku-4-5-20251001"
  "The model extract reads records with."
  'group 'workflows 'type 'string)

(defcustom 'workflow-decide-purpose 'fast
  "The decide purpose yes? and pick ask under, which picks the backend."
  'group 'workflows 'type 'symbol)

(defcustom 'workflow-model #f
  "The local model inference asks when a call names none, as (host H model M); #f asks decide."
  'group 'workflows 'type 'list)

;; micro-dollars per token, in and out, which is dollars per million: what
;; a call would have cost on Haiku
(define workflow-haiku-price '(1 5))

(effects! '(pure))

(define (event? x)
  "(event? X) — #t when X is an event of the log"
  (and (pair? x) (plist-get x 'seq) (plist-get x 'topic) #t))

(define (event-text x)
  "(event-text X) — what a model reads for X: an event's text, or its data printed; a string is itself"
  (cond ((string? x) x)
        ((event? x) (let ((d (plist-get x 'data)))
                      (or (and (pair? d) (plist-get d 'text)) (workflow--text d))))
        (else (workflow--text x))))

(define (workflow--label v) (cond ((string? v) v) ((symbol? v) (symbol->string v)) (else "")))

(define (workflow--clip s n)
  (let ((s (or s ""))) (if (> (string-length s) n) (substring s 0 n) s)))

(define (event-trace e)
  "(event-trace E) — the seq of the first event in E's chain of causes"
  (and (event? e) (or (plist-get (plist-get e 'data) 'trace) (plist-get e 'seq))))

(effects! '(write))

(define (emit! topic kind data &optional cause)
  "(emit! TOPIC KIND DATA [CAUSE]) — write an event that CAUSE, an event, caused; it carries CAUSE's seq and trace. Inside a batch it lands with the batch's commit"
  (workflow-emit! topic kind
                  (if (event? cause)
                      (append data (list 'cause (plist-get cause 'seq) 'trace (event-trace cause)))
                      data)))

(define (workflow--observe! model host ms in out prompt answer about)
  (event-log-append! "obs:llm" 'call
                     (list 'model model 'host host 'ms ms 'in (or in 0) 'out (or out 0)
                           'prompt (workflow--clip prompt 400) 'answer (workflow--clip answer 200)
                           'cause (and (event? about) (plist-get about 'seq))
                           'trace (event-trace about))))

(effects! '(read external spend))

;; (TEXT IN OUT) from a local model: Ollama's /api/chat, or /chat/completions on a /v1 host
(define (workflow--local-ask spec prompt max)
  (let* ((host (plist-get spec 'host))
         (model (plist-get spec 'model))
         (openai? (string-contains? host "/v1"))
         (said (list (list 'role "user" 'content prompt)))
         (reply (app-await
                 (lambda (k)
                   (*models-request*
                    host "POST" (if openai? "/chat/completions" "/api/chat")
                    (if openai?
                        (list 'model model 'messages said 'max_tokens max 'temperature 0)
                        (list 'model model 'messages said 'stream #f 'think #f 'keep_alive "30m"
                              'options (list 'num_predict max 'temperature 0)))
                    120 k))))
         (json (plist-get reply 'json)))
    (cond ((not (plist-get reply 'ok))
           (error (string-append model ": " (or (plist-get reply 'error) "no answer"))))
          (openai?
           (let ((usage (plist-get json 'usage)))
             (list (plist-get (plist-get (car (plist-get json 'choices)) 'message) 'content)
                   (plist-get usage 'prompt_tokens) (plist-get usage 'completion_tokens))))
          (else
           (list (plist-get (plist-get json 'message) 'content)
                 (plist-get json 'prompt_eval_count) (plist-get json 'eval_count))))))

(define (ask-model prompt about &rest opts)
  "(ask-model PROMPT ABOUT ['model SPEC] ['max N]) — a model's answer, as text, to PROMPT about ABOUT: an event or text. The call is observed on obs:llm"
  (let* ((spec (or (plist-get opts 'model) workflow-model))
         (full (string-append prompt "\n\n" (event-text about)))
         (t0 (monotonic-ms)))
    (if spec
        (let ((r (workflow--local-ask spec full (or (plist-get opts 'max) 256))))
          (workflow--observe! (plist-get spec 'model) (plist-get spec 'host) (- (monotonic-ms) t0)
                             (nth 1 r) (nth 2 r) full (car r) about)
          (or (car r) ""))
        (let ((text (app-await (lambda (k) (llm-with-model full workflow-extract-model k)))))
          (workflow--observe! workflow-extract-model "anthropic" (- (monotonic-ms) t0) #f #f full text about)
          (or text "")))))

;; one typed question to decide, observed like any other call
(define (workflow--decide about spec)
  (let* ((reply (decide (event-text about) (list 'q spec) 'purpose workflow-decide-purpose))
         (usage (or (plist-get reply 'usage) '(0 0 decide 0)))
         (row (assoc 'q (or (plist-get reply 'answers) '()))))
    (workflow--observe! (workflow--label (nth 2 usage)) "decide" (nth 3 usage) (nth 0 usage) (nth 1 usage)
                       (plist-get spec 'instructions) (workflow--text (and row (cadr row))) about)
    (and row (cadr row))))

(define (yes? question about &rest opts)
  "(yes? QUESTION ABOUT ['model SPEC]) — #t when a model answers yes to QUESTION about ABOUT, an event or text"
  (let ((spec (or (plist-get opts 'model) workflow-model)))
    (if spec
        (string-prefix? "y" (string-downcase (string-trim (ask-model (string-append question " Answer yes or no.")
                                                                       about 'model spec 'max 3))))
        (let ((a (workflow--decide about (decide-noul question))))
          (and a (number? (plist-get a 'noul)) (>= (plist-get a 'noul) workflow-yes-threshold))))))

;; the label of OPTIONS a local model's ANSWER names first, or "none". A
;; small model is not offered none: it takes the way out too often
(define (workflow--named answer labels)
  (let ((hit (filter (lambda (l) (string-contains? (string-downcase answer) l)) labels)))
    (if (pair? hit) (car hit) "none")))

(define (workflow--option-lines options)
  (string-join (map (lambda (o) (string-append (workflow--label (car o)) ": " (cadr o))) options) "\n"))

(define (workflow--criteria options)
  (append (apply append (map (lambda (o) (list (string->symbol (workflow--label (car o))) (cadr o))) options))
          (list 'none "none of these")))

(define (pick question options about &rest opts)
  "(pick QUESTION OPTIONS ABOUT ['model SPEC]) — the key of the option a model picks for ABOUT, or #f for none. OPTIONS is ((KEY DESCRIPTION) ...)"
  (let* ((spec (or (plist-get opts 'model) workflow-model))
         (labels (map (lambda (o) (workflow--label (car o))) options))
         (choice (if spec
                     (workflow--named (ask-model (string-append question " Answer with one word of: "
                                                               (string-join labels ", ") ".\n"
                                                               (workflow--option-lines options))
                                                about 'model spec 'max 6)
                                     labels)
                     (let ((a (workflow--decide about (decide-choice question (workflow--criteria options)))))
                       (workflow--label (and a (plist-get a 'choice))))))
         (hit (filter (lambda (o) (equal? (workflow--label (car o)) choice)) options)))
    (and (pair? hit) (car (car hit)))))

;; the reply without the code fences a model likes to add
(define (workflow--unfence text)
  (string-join (filter (lambda (l) (not (string-prefix? "```" (string-trim l))))
                       (string-split text "\n"))
               "\n"))

(define (extract instructions about fields &rest opts)
  "(extract INSTRUCTIONS ABOUT FIELDS ['model SPEC]) — the records a model reads out of ABOUT, a list of plists with the keys FIELDS; the empty list when there are none"
  (let* ((text (ask-model (string-append instructions
                                         "\n\nAnswer with a JSON array and nothing else. Each item is an object with the keys "
                                         (string-join (map symbol->string fields) ", ")
                                         ". Answer [] when there is nothing.")
                          about 'model (plist-get opts 'model) 'max 512))
         (parsed (json-parse (workflow--unfence text))))
    (if (list? parsed) parsed '())))


;;; the catalog

(domain! 'system)
(effects! '(pure))
(public! 'seconds "(seconds N) — N seconds in milliseconds")
(public! 'minutes "(minutes N) — N minutes in milliseconds")
(public! 'event-topic "(event-topic E) — E's topic, the key a workflow groups by when it names none")
(public! 'event? "(event? X) — #t when X is an event of the log")
(public! 'event-text "(event-text X) — what a model reads for an event, or a string")
(public! 'event-trace "(event-trace E) — the seq of the first event in E's chain of causes")
(effects! '(read))
(public! 'once-done? "(once-done? KEY) — #t when once! has recorded KEY")
(effects! '(write))
(public! 'define-workflow! "(define-workflow! NAME 'listen PATTERNS 'handle FN ...) — a Scheme handler over the event log that the core runs exactly once per batch")
(public! 'once! "(once! KEY THUNK) — run THUNK one time per KEY, whatever runs again")
(public! 'emit! "(emit! TOPIC KIND DATA [CAUSE]) — write an event caused by CAUSE; inside a batch it lands with the commit")
(domain! 'decide)
(effects! '(read external spend))
(public! 'ask-model "(ask-model PROMPT ABOUT ['model SPEC] ['max N]) — a model's answer as text, observed on obs:llm")
(public! 'yes? "(yes? QUESTION ABOUT ['model SPEC]) — a typed yes/no inference step, observed on obs:llm")
(public! 'pick "(pick QUESTION OPTIONS ABOUT ['model SPEC]) — a typed pick-one inference step; #f for none")
(public! 'extract "(extract INSTRUCTIONS ABOUT FIELDS ['model SPEC]) — the free-text inference step: records as plists")
