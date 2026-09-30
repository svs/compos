;;; decide.scm --- unified typed-decision API over JEV, Laya, and LLM backends
;;;
;;; User config sets the chain and the purpose-to-model map:
;;;   (setq! decide-backends '(jev laya haiku))
;;;   (setq! decide-default '((default . haiku) (fast . jev)))
;;;
;;; Then just (decide STATE QUESTIONS).

(domain! 'decide)
(effects! '(read external execute spend))

;; ── Variables ──────────────────────────────────────────────

(defcustom 'decide-backends
  '(jev laya haiku)
  "Backends 'decide' tries in priority order. Set in ai-config.scm."
  'group 'decide)

(defcustom 'decide-default
  '((fast   . jev)
    (coding . "claude-sonnet-4-20250514"))
  "((purpose . backend-or-model-id) ...). No 'default' row: a purpose that names no model leaves the choice to the backend, and the LLM backend takes the session's fast preset from llm-models!. Pinning an id here made every unnamed call pay for a model nobody had chosen."
  'group 'decide)

;; ── Declaration ───────────────────────────────────────────
;; ai-config.scm declares the setup once, the way it registers an MCP
;; server: one form, and no variable is set by hand.
;;
;; Which model a job uses is not decide's business - that is the
;; llm-model-presets table.
;;
;;   (decide-config! '(jev laya))

(define (decide-config! backends)
  (customize-set! 'decide-backends backends)
  (list 'backends decide-backends))

;; Laya runs as a daemon now, and laya.scm owns it: the python, the
;; checkpoints, and the pipe that holds the weights between questions.
;; Nothing about it is configured twice.

;; ── Entry point ───────────────────────────────────────────

;; &rest is this interpreter's spelling of a rest parameter: a dotted
;; (state questions . opts) reads the dot and the name as two more fixed
;; parameters, so every option a caller passed went nowhere.
(define (decide state questions &rest opts)
  (let* ((backend (or (plist-get opts 'backend) 'auto))
         (purpose (plist-get opts 'purpose))
         (purpose-row (and purpose (assq purpose decide-default)))
         (purpose-val (and purpose-row (cdr purpose-row)))
         (model (or (plist-get opts 'model)
                    (and (string? purpose-val) purpose-val)
                    (let ((d (assq 'default decide-default)))
                      (and d (cdr d)))))
         (timeout (or (plist-get opts 'timeout) 30))
         (effective-backend
          (cond ((equal? backend 'auto)
                 (or (and (symbol? purpose-val) purpose-val)
                     (decide--first-live)))
                (else backend)))
         (fn (assq effective-backend
                    (list (list 'jev decide--call-jev)
                          (list 'laya decide--call-laya)
                          (list 'haiku decide--call-haiku)))))
    (unless fn
      (error (string-append "decide: unknown backend " (symbol->string effective-backend))))
    ;; assq answers (BACKEND FN), so the function is the second element:
    ;; cdr here is a list holding it, and calling that is calling a list
    ((cadr fn) state questions model timeout)))

;; decide, answering K instead of returning. The blocking form waits on its
;; backend through app-await, which looks every 50ms: a laya answer that
;; took 15ms arrived at 51. Here the backend's own continuation is K's, so
;; the answer lands the moment it is ready, and nothing waits on the lane.
;; A backend with no callback of its own runs the blocking form in a task.
(define (decide-async state questions k &rest opts)
  (let* ((backend (or (plist-get opts 'backend) 'auto))
         (timeout (or (plist-get opts 'timeout) 30))
         (effective (if (equal? backend 'auto) (decide--first-live) backend))
         (t0 (monotonic-ms)))
    (cond
      ((equal? effective 'laya)
       (laya-predict state questions #f
         (lambda (reply)
           (k (if (and reply (plist-get reply 'ok))
                  (decide--laya->standard (plist-get (plist-get reply 'json) 'result)
                                          (- (monotonic-ms) t0))
                  (list 'answers '() 'usage (list 0 0 'laya (- (monotonic-ms) t0))))))))
      (else
        (task-run! (lambda () (apply decide (append (list state questions) opts)))
          (lambda (ok? v) (k (if ok? v (list 'answers '() 'usage (list 0 0 effective 0))))))))))

(define (decide--first-live)
  (let loop ((bs decide-backends))
    (cond ((null? bs) 'jev)
          ;; jev lives in a user package, so the adapter is only reachable
          ;; when that package is loaded; unloaded, it would raise here.
          ((equal? (car bs) 'jev)
           (if (boundp 'jev-systemone) 'jev (loop (cdr bs))))
          ((equal? (car bs) 'laya)
           (if (laya-available?) 'laya (loop (cdr bs))))
          ((equal? (car bs) 'haiku)
           (if (llm-key "anthropic") 'haiku (loop (cdr bs))))
          (else (loop (cdr bs))))))

;; ── JEV backend ───────────────────────────────────────────

(define (decide--call-jev state questions model timeout)
  (let* ((t0 (monotonic-ms))
         (reply (jev-systemone state questions))
         (ms (- (monotonic-ms) t0)))
    (if reply
        (let ((usage (or (plist-get reply 'usage) '(0 0))))
          (list 'answers (decide--answers-from-jev reply)
                'usage (list (or (plist-get usage 'input_tokens) 0)
                             (or (plist-get usage 'output_tokens) 0)
                             'jev ms)))
        (list 'answers '() 'usage (list 0 0 'jev ms)))))

;; JEV answers a plist too - (urgent (noul 0.92 ...) other (...)) - so the
;; same pairing the daemon's reply needs applies here. Reading it as an
;; alist called car on the key symbol and raised out of the backend.
(define (decide--answers-from-jev reply)
  (let ((raw (plist-get reply 'answers)))
    (if (pair? raw) (decide--rows raw) '())))

;; ── Laya backend ──────────────────────────────────────────
;; One question over the daemon laya.scm keeps open. The first question
;; of a cold daemon waits for the weights; the rest pay nothing.

(define (decide--call-laya state questions model timeout)
  ;; The model decide carries is a chat model id, because that is what
  ;; decide-default holds. Laya answers from a checkpoint, which is
  ;; laya-model's business, so nothing about a chat model reaches it.
  ;; app-await answers the moment the daemon's continuation fires, so no
  ;; poll interval stands between the reply and the caller. It blocks, so
  ;; it runs inside a task and never on the editor lane.
  (let* ((t0 (monotonic-ms))
         (reply (task-await
                  (task-spawn
                    (lambda ()
                      (app-await (lambda (k) (laya-predict state questions #f k))
                                 timeout)))
                  (* timeout 1000)))
         (ms (- (monotonic-ms) t0)))
    (if (and reply (plist-get reply 'ok))
        (decide--laya->standard (plist-get (plist-get reply 'json) 'result) ms)
        (begin
          (when reply
            (message (string-append "decide: laya - "
                                    (or (plist-get reply 'error) "no answer"))))
          (list 'answers '() 'usage (list 0 0 'laya ms))))))

(define (decide--laya->standard result &optional ms)
  (let ((raw (if (pair? result) (plist-get result 'answers) '()))
        (usage (or (and (pair? result) (plist-get result 'usage)) '(0 0))))
    (list 'answers (decide--rows (if (pair? raw) raw '()))
          ;; the time rides along when the caller measured it
          'usage (append (list (or (plist-get usage 'input_tokens) 0)
                               (or (plist-get usage 'output_tokens) 0)
                               'laya)
                         (if ms (list ms) '())))))

;; The daemon answers JSON, so one question's answer is a plist pair and
;; not an alist cell: (KEY VALUE KEY VALUE ...) becomes ((KEY VALUE) ...).
(define (decide--rows plist)
  (if (or (null? plist) (null? (cdr plist)))
      '()
      (cons (list (car plist) (decide--normalize (cadr plist)))
            (decide--rows (cddr plist)))))

;; ── Haiku (LLM) backend ───────────────────────────────────

;; The completion arrives as a value, so no scratch buffer stands in for it
;; and no poll waits on a flag. The task carries the block off the lane.
;; The model fallback. It does not pin an id: llm-models! names one model
;; per job, so the fast preset moves every caller at once and no package
;; carries an id of its own. "claude-3-5-haiku-latest" was hard-coded here
;; and in decide-default, which is how a session configured for a different
;; fast model still paid for a model nobody had chosen.
(define (decide--fast-model)
  (or (ignore-errors (lambda () (llm-model-for 'fast)))
      "claude-3-5-haiku-latest"))

(define (decide--call-haiku state questions model timeout)
  (let* ((model-id (or model (decide--fast-model)))
         (prompt (decide--build-prompt state questions))
         (t0 (monotonic-ms))
         (text (task-await
                 (task-spawn
                   (lambda ()
                     (app-await (lambda (k) (llm-with-model prompt model-id k))
                                timeout)))
                 (* timeout 1000)))
         (ms (- (monotonic-ms) t0))
         (reply (if (string? text) (string-trim text) "")))
    (if (> (string-length reply) 0)
        (decide--parse-llm reply questions ms)
        (list 'answers '() 'usage (list 0 0 'haiku ms)))))

(define (decide--build-prompt state questions)
  (let ((qlines
         (string-join
          (map (lambda (pair)
                 (let ((k (car pair)) (spec (cdr pair)))
                   (format "- ~a: ~a (type: ~a, criteria: ~a)"
                           k
                           (or (plist-get spec 'instructions) "")
                           (or (plist-get spec 'type) "")
                           (or (plist-get spec 'criteria) "-"))))
               questions)
          "\n")))
    (string-append
     "Given this situation:\n\n"
     (if (string? state) state (json-encode state #t))
     "\n\nAnswer as a single JSON object with keys matching the questions.
For 'choice use the chosen string, for 'score use the number,
for 'noul use true or false.\n\nQuestions:\n" qlines "\n")))

(define (decide--parse-llm text questions ms)
  (let* ((start (string-index text "{"))
         (end (and start (string-rindex text "}")))
         (json-text (and start end (substring text start (+ end 1))))
         (parsed (and json-text (json-parse json-text))))
    (if (and parsed (pair? parsed))
        (list 'answers
              (map (lambda (pair)
                     (let* ((k (car pair))
                            (spec (cdr pair))
                            (sk (if (symbol? k) k (string->symbol k)))
                            (val (or (plist-get parsed sk)
                                     (plist-get parsed (string->symbol (string-downcase (symbol->string sk)))))))
                       (list k (decide--llm-val val spec))))
                   questions)
              'usage (list 0 0 'haiku ms))
        (list 'answers '() 'usage (list 0 0 'haiku ms)))))

(define (decide--llm-val val spec)
  ;; jev-noul and jev-choice write the type as a string ("noul"), so a
  ;; comparison against the symbol never matched and every LLM answer came
  ;; back #f at confidence 1.0 — a confident wrong answer, not an error.
  (let* ((raw (or (plist-get spec 'type) 'noul))
         (type (if (string? raw) (string->symbol raw) raw)))
    (list 'type raw
          'choice (and (equal? type 'choice) (if (string? val) val ""))
          'score (and (equal? type 'score) (if (number? val) val 0))
          'noul (and (member type '(noul noul?)) (if val 1.0 0.0))
          'confidence 1.0
          'action '(act_probability 1.0))))

;; ── Normalizer ────────────────────────────────────────────

(define (decide--normalize v)
  (if (pair? v)
      (let ((type (or (plist-get v 'type)
                      (and (plist-get v 'choice) 'choice)
                      (and (plist-get v 'score) 'score)
                      'noul)))
        (list 'type type
              'choice (plist-get v 'choice)
              'score (plist-get v 'score)
              'noul (plist-get v 'noul)
              'confidence (or (plist-get v 'confidence) 1.0)
              'action (or (plist-get v 'action) '(act_probability 1.0))))
      v))

;; ── Catalog ───────────────────────────────────────────────

;; ── Questions ─────────────────────────────────────────────────────
;; The three question shapes, owned here rather than by any one backend.
;; Packages used to build them with jev-choice and jev-noul, which binds
;; a caller to a user package that may not be loaded and routes past the
;; backend chain; these read the same and work on every backend.

(effects! '(pure))

(define (decide-noul instructions &optional criteria)
  (if criteria
      (list 'type "noul" 'instructions instructions 'criteria criteria)
      (list 'type "noul" 'instructions instructions)))

(define (decide-choice instructions criteria)
  (list 'type "choice" 'instructions instructions 'criteria criteria))

(define (decide-score instructions criteria)
  (list 'type "score" 'instructions instructions 'criteria criteria))

(effects! '(read external execute))

(category! 'decide)
(effects! '(pure))
(public! 'decide-noul "(decide-noul INSTRUCTIONS [CRITERIA]) — a yes/no question")
(public! 'decide-choice "(decide-choice INSTRUCTIONS CRITERIA) — a pick-one question; criteria is a plist of option -> description")
(public! 'decide-score "(decide-score INSTRUCTIONS CRITERIA) — a rated question; criteria is a list of level descriptions")
(effects! '(read external execute))

(public! 'decide
  "(decide STATE QUESTIONS [OPTS ...]) — typed decisions over JEV, Laya, or LLM. Returns (answers ((KEY VALUE) ...) usage (INPUT OUTPUT BACKEND ELAPSED-MS)).")
(public! 'decide-async
  "(decide-async STATE QUESTIONS K &rest OPTS) — decide, answering K the moment the backend does; never waits on the lane")
(public! 'decide-config!
  "(decide-config! '(BACKEND ...)) — declare the backend chain. Which model a job uses is llm-model-presets, not this.")
(public! 'decide-backends
  "Backends 'decide' tries in order.")
(public! 'decide-default
  "((purpose . backend-or-model) ...) purpose routing.")

;; ── Refusals ───────────────────────────────────────────────
;;
;; Every no the editor says to an agent is decided here, in one place:
;;
;; - The permission verbs. A tool call, a command or a shell line whose
;;   text names an act that cannot be taken back stops to ask, whatever
;;   the chat's stance. permit? in agent-permissions.scm asks
;;   permission-denied-verb?.
;; - The shell gate. The shell commands inside an eval-scheme payload.
;;   decide recognises what they are for, and decide-shell-policy says
;;   what each kind gets. No list of literal commands: a build is a build
;;   however it is spelled.
;; - The words of every refusal, (decide-refusal KIND [DETAIL]), so the
;;   agent reads one voice and is told what to do next.
;;
;; No key, no network, no answer: the shell gate opens. A classifier that
;; cannot be reached must never become a lock on the editor.

(effects! '(read))

(defcustom 'decide-allow-git #f
  "Let agents run every git command without asking: the ones that rewrite the work tree, and a push."
  'group 'decide)

(define *permission-deny-patterns*
  (list
        ;; Git that rewrites the work tree is a file write by another name:
        ;; it lands text the editor never saw, and it can lose an unsaved
        ;; buffer. Reading git, staging it, and committing it change no
        ;; working file, so they stay out of this list.
        "git[-_ ]+(checkout|restore|stash|clean|apply|pull|merge|rebase|revert)"
        "git[-_ ]+reset[-_ ]+--(hard|merge)"
        "send[-_ ]*mail" "sendmail" "mail[-_ ]*send" "smtp"
        "send[-_ ]*(message|email|sms|text)"
        "(permanently|forever)[-_ ]*delete" "delete[-_ ]*(permanently|forever)"
        "empty[-_ ]*trash" "trash[-_ ]*empty" "expunge"
        "rm[-_ ]+-[a-z]*[rf]"
        ;; user ruling 2026-09-02: a push through jj is always allowed;
        ;; agent identity rides in jj descriptions, never in authors.
        "(?<!jj[-_ ])git[-_ ]+push" "force[-_ ]*push"
        "\\bpublish\\b" "\\bdeploy\\b"))

(define (decide--git-pattern? p) (string-contains? p "git[-_ ]+"))

(define (permission-denied-verb? text)
  "(permission-denied-verb? TEXT) — the deny pattern TEXT names, or #f; with decide-allow-git on, git never asks"
  (let ((t (string-downcase text)))
    (let loop ((ps *permission-deny-patterns*))
      (cond ((null? ps) #f)
            ((and decide-allow-git (decide--git-pattern? (car ps))) (loop (cdr ps)))
            ((re-match? (car ps) t) (car ps))
            (else (loop (cdr ps)))))))

(effects! '(pure))

(define decide--allowed-near-tree
  "git, jj and the project's own build and test tools are the only shell commands allowed near the work tree.")

(define (decide-refusal kind &optional detail)
  "(decide-refusal KIND [DETAIL]) — the words of one refusal: edit, read, denied, or policy with DETAIL naming what the policy matched"
  (cond ((equal? kind 'edit)
         (string-append
           "refused by the shell gate: a shell command may not write files. Edit the live buffer instead — "
           "(find-file PATH), then (code-replace! BUF LINE NEW), (code-sexp-replace! BUF ANCHOR NEW) or "
           "(buffer-replace! BUF OLD NEW), and save it with "
           "(with-current-buffer BUF (lambda () (run-command \"save-buffer\"))). "
           "When none of those is the right call, ask (apropos \"WORDS\") for the one that is: "
           "the catalog answers for the editor as it is now, and this list does not. "
           decide--allowed-near-tree))
        ((equal? kind 'read)
         (string-append
           "refused by the shell gate: a shell command may not read or search files. Use the editor — "
           "(grep PATTERN [ROOT]) to search the project, (ls [DIR]) to list a directory, and "
           "(find-file PATH) then (code-outline BUF), (code-read BUF LINE) or (buffer-text BUF) to read one. "
           "When none of those is the right call, ask (apropos \"WORDS\") for the one that is: "
           "the catalog answers for the editor as it is now, and this list does not. "
           decide--allowed-near-tree))
        ((equal? kind 'denied)
         "refused: denied in the chat. Do not retry it — ask what to do instead.")
        (else
         (string-append
           "refused: compos's permission policy did not allow this (" (or detail "no rule") "). "
           "Ask the user to run it, or to approve it in the chat."))))

(effects! '(read external execute))

(defcustom 'decide-shell-gate #t
  "Recognise the shell commands in an agent's eval-scheme payload, and refuse the kinds decide-shell-policy refuses."
  'group 'decide)

(defcustom 'decide-shell-policy
  '((edit ask) (read ask) (build allow) (git allow) (jj allow) (other allow))
  "What each kind of shell command gets: allow, ask or refuse. Ask raises a permission card in the chat and refuses when nobody answers in permission-ask-timeout-ms, or when the lane has no chat to ask. The kinds: edit writes files, read reads or searches them, build runs the project's own build, test or format tool, git and jj run version control, other touches no file."
  'group 'decide)

(define decide--shell-primitives "shell-command->string|start-process!")

(define (decide--shell-criteria)
  (list 'edit "A shell command creates, writes, moves, renames or deletes a file or directory by itself: a > or >> redirection, sed -i, tee, cp, mv, rm, mkdir, touch, ln, patch, or an install step."
        'read "A shell command reads or searches files or directories: cat, head, tail, less, sed -n, ls, find, grep, rg, ag, wc, or a pipeline that feeds one of those a path."
        'build "A shell command builds, tests, formats or type-checks the project with the project's own tool: mix compile, mix test, mix format, cargo build, cargo test, npm test, make, go test, and the like, with any environment variables, options, or a pipe of its own output into head or tail. It writes only that tool's own artifacts."
        'git "Every shell command in it is a git invocation."
        'jj "Every shell command in it is a jj invocation."
        'other "No shell command in it reads or writes any file: date, uname, echo, env, which, uptime, a network call, and the like."))

(define (decide--shell-questions)
  (list 'kind
        (decide-choice
          (string-append
            "This is Scheme an editor agent wants to evaluate. Read only the shell commands it runs "
            "and say which description fits them. When more than one fits, choose the most restrictive: "
            "edit first, then read, then build, then git or jj, then other.")
          (decide--shell-criteria))))

(define (decide--choice-symbol v)
  (cond ((symbol? v) v)
        ((and (string? v) (not (equal? v ""))) (string->symbol v))
        (else #f)))

(define (decide-shell-kind code)
  "(decide-shell-kind CODE) — what the shell commands in CODE are for: edit, read, build, git, jj or other; #f when no backend answers"
  (let* ((reply (ignore-errors (lambda () (decide code (decide--shell-questions) 'purpose 'fast))))
         (row (and reply (assoc 'kind (plist-get reply 'answers)))))
    (and row (decide--choice-symbol (plist-get (cadr row) 'choice)))))

;; One payload, one kind, kept: an agent retries the same probe more
;; often than it writes a new one, and a kept kind costs no round trip.
;; The kind is kept, not the verdict, so a policy change counts at once.
(define decide--shell-seen '())

(define (decide--shell-kind-seen code)
  (let ((hit (assoc code decide--shell-seen)))
    (if hit
        (cadr hit)
        (let ((kind (decide-shell-kind code)))
          ;; a backend that did not answer is not an answer: ask again next time
          (when kind
            (set! decide--shell-seen (cons (list code kind) decide--shell-seen))
            (when (> (length decide--shell-seen) 200)
              (set! decide--shell-seen (list-head decide--shell-seen 200))))
          kind))))

(define (decide-shell-verdict code)
  "(decide-shell-verdict CODE) — the refusal the shell gate gives CODE, or #f to let it run; an ask the user has not approved refuses"
  (let* ((kind (decide--shell-kind-seen code))
         (rule (and kind (assq kind decide-shell-policy))))
    (cond ((not rule) #f)
          ((equal? (cadr rule) 'refuse) (decide-refusal kind))
          ((and (equal? (cadr rule) 'ask) (not (equal? code decide--shell-approved)))
           (decide-refusal kind))
          (else #f))))

;; The one payload the user just approved. The approved call runs in the
;; Task that waited for the answer, so this set! lives in that Task's heap
;; and ends with it.
(define decide--shell-approved #f)

(define (decide-shell-approve! code)
  "(decide-shell-approve! CODE) — let CODE through the gate's ask, in this Task"
  (set! decide--shell-approved code))

(define (decide-shell-asks? code)
  "(decide-shell-asks? CODE) — #t when the shell gate would ask the user before the eval-scheme payload CODE runs"
  (and decide-shell-gate
       (string? code)
       (re-match? decide--shell-primitives code)
       (let* ((kind (decide--shell-kind-seen code))
              (rule (and kind (assq kind decide-shell-policy))))
         (and rule (equal? (cadr rule) 'ask) #t))))

;; tool-call-hook: #f lets the call through, a string aborts it and becomes
;; the result the agent reads instead
(define (decide-shell-gate-hook name args)
  "(decide-shell-gate-hook NAME ARGS) — tool-call-hook: refuse an eval-scheme payload whose shell commands decide-shell-policy refuses"
  (and decide-shell-gate
       (equal? name "eval-scheme")
       (let ((code (plist-get args 'code)))
         (and (string? code)
              (re-match? decide--shell-primitives code)
              (decide-shell-verdict code)))))

(add-hook! 'tool-call-hook 'decide-shell-gate-hook)
