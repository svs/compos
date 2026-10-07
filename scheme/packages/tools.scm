;;; tools.scm --- LLM tool registry: gptel-style native tool use.
;;;
;;; (define-tool! 'name "description" params handler) registers a tool the
;;; internal LLM can call. params is a list of (pname "type" "description")
;;; entries — append 'optional to mark a param optional. The handler gets a
;;; flat plist of the call arguments and returns a value (strings pass
;;; through; anything else is printed).
;;;
;;; (llm-with-tools prompt handler) runs the tool loop with every registered
;;; tool; handler receives the final text. The wire loop is Elixir mechanism
;;; (LLM.complete_tools); which tools exist, what they say, and what they do
;;; is all here. External ACP agents will get this same registry over MCP.

(define *llm-tools* '())

;; Non-#f only while an LLM tool evaluates Scheme. Browser policy uses this
;; dynamic seam to restrict agents without breaking the user's browser-aware
;; editor commands.
(define *llm-tool-buffer* #f)

;; EFFECTS is the tool's side-effect declaration for the permission
;; policy: a list with one level (pure, read, write, destroy) plus
;; modifiers (external, execute, spend, display). The catalog entry carries it,
;; and permit? reads it from there.
(define (define-tool! name description params handler &optional effects)
  (set! *llm-tools* (alist-put *llm-tools* name (list 'description description 'params params 'handler handler
                           'effects (or effects '(unknown)))))
  (if effects
      (catalog-register! 'tool name description 'effects effects)
      (catalog-register! 'tool name description))
  name)

(define (llm-tool-specs)
  (map (lambda (t)
         (list (symbol->string (car t))
               (plist-get (cadr t) 'description)
               (plist-get (cadr t) 'params)
               (plist-get (cadr t) 'effects)))
       (reverse *llm-tools*)))

;; tool-call-hook is the one seam that can still say no. Each function on
;; it gets (NAME ARGS) and answers #f to stay out of the way; the first
;; that answers anything else aborts the call and its answer becomes the
;; result the model reads. A veto is a return value, never an exception,
;; so the refusal reaches the model as an ordinary tool result and the
;; turn carries on. The permission policy gates whether a call may run at
;; all; this gates what a call that is allowed to run may contain.
(define (llm-tool-call name args)
  (let ((veto (run-hook-with-args-until-success 'tool-call-hook name args)))
    (if veto
        (if (string? veto) veto (value->string veto))
        (let ((t (assoc (string->symbol name) *llm-tools*)))
          (if t
              ((plist-get (cadr t) 'handler) args)
              (string-append "no such tool: " name))))))

(define (llm-tool-read-only? name)
  (let* ((tool (assoc (string->symbol name) *llm-tools*))
         (effects (and tool (plist-get (cadr tool) 'effects))))
    (and (pair? effects) (member (car effects) '(pure read)) #t)))

(define (llm-with-tools prompt handler)
  (llm-tools prompt
    (if (boundp (quote compos-direct-prompt-parts))
        (prompt-parts-text (compos-direct-prompt-parts))
        *llm-system*)
    (llm-tool-specs) llm-tool-call handler))

;; embark for the model: the same target/action table C-. uses. The
;; editor context names the target ids; act runs the verb on one.
(define-tool! 'act
  (string-append
    "Run an editor action on a target. The editor context names targets "
    "(e.g. an email's notmuch thread id). type: the target type, e.g. "
    "\"email\". id: the target id (an email's thread id, without the "
    "thread: prefix). action: one of the type's verbs — email: archive, "
    "trash, unread, mark, read, reply.")
  (list (list 'type "string" "target type, e.g. email")
        (list 'id "string" "target id")
        (list 'action "string" "the verb to run"))
  (lambda (args)
    (let* ((type (string->symbol (plist-get args 'type)))
           (raw (plist-get args 'id))
           (id (if (string-prefix? "thread:" raw)
                   (substring raw 7 (string-length raw))
                   raw))
           (a (assoc (plist-get args 'action) (actions-for type))))
      ;; the action's own return is the report — a hardcoded "done" here
      ;; would mean this tool call, whatever the action actually did
      (if a
          ((cadr a) id)
          (string-append "no such action; " (symbol->string type) " has: "
                         (string-join (map car (actions-for type)) ", ")))))
  '(write external))

;;; --- the built-in toolbox ----------------------------------------------------
;;; One tool is viable only because failure is instructive: a model that
;;; guesses `buffer-insert` gets back the nearest real names with their
;;; signatures instead of six blind retries.

(domain! 'chat)
(effects! '(read))

;; Agent backends intercept this tool before Scheme dispatch. The fallback
;; explains a bad call path instead of pretending that a question was shown.
(define-tool! 'ask
  (string-append
    "Ask the user one branching question and wait for the answer. Use this "
    "when their choice changes what you will do. answers can contain any "
    "number of concise labels. The user can also type a different answer.")
  (json-encode
    (list 'type "object"
          'properties
          (list 'question (list 'type "string"
                                'description "The question shown in the chat")
                'answers (list 'type "array"
                               'description "Any number of answer labels"
                               'items (list 'type "string")))
          'required (list "question" "answers")))
  (lambda (args)
    "error: ask must run through an agent thread")
  '(pure))

;; the builtin: an interpreted distance held the caller's lane for
;; seconds while a suggestion ranked the whole public api
(define (tool--edit-distance a b)
  (string-edit-distance a b))

;; nearest public-api entries: edit distance <= 2 first, shared prefix after
(define (tool--suggest name)
  (let* ((scored (map (lambda (e) (list (tool--edit-distance name (car e)) e))
                      (public-api)))
         (pick (lambda (d)
                 (map cadr (filter (lambda (s) (equal? (car s) d)) scored))))
         (prefix (filter (lambda (e)
                           (and (> (string-length name) 3)
                                (or (string-prefix? name (car e))
                                    (string-prefix? (car e) name))
                                (> (tool--edit-distance name (car e)) 2)))
                         (public-api))))
    (take (append (pick 0) (pick 1) (pick 2) prefix) 3)))

;; a suggestion shows the SIGNATURE, not just the name: the point of
;; "did you mean" is that the next call works, and the arguments are half
;; of that
(define (tool--format-suggestions entries)
  (fold (lambda (acc e)
          (string-append acc "\n  " (nth 2 e) " — " (cadr e)))
        "" entries))

;; the feedback that makes one-tool work: name the real API on a miss
(define (tool--error-hint msg code)
  (cond
    ((re-match? "unbound variable: " msg)
     (let* ((name (string-trim (car (reverse (string-split msg "unbound variable: ")))))
            (hits (tool--suggest name)))
       (if (null? hits)
           "\nNo close public-api match — search with (apropos \"words\") before retrying."
           (string-append "\nunbound: " name " — did you mean:"
                          (tool--format-suggestions hits)))))
    ;; a builtin fed the wrong arguments names itself before the colon
    ((re-match? "no function clause matching" msg)
     (let* ((name (car (string-split msg ":")))
            (hits (tool--suggest name)))
       (if (null? hits)
           ""
           (string-append "\nbad arguments to " name " — check:"
                          (tool--format-suggestions hits)))))
    ((re-match? "arity mismatch" msg)
     ;; a userland lambda's arity error carries no name: surface
     ;; signatures for every public name the code mentions
     (let ((named (filter (lambda (e) (string-contains? code (car e)))
                          (public-api))))
       (if (null? named)
           ""
           (string-append "\ncheck the signatures:"
                          (tool--format-suggestions (take named 5))))))
    (else "")))

(define-tool! 'eval-scheme
  "Evaluate Scheme in the live editor session. Full editor API: buffers, windows, faces, modes, customize. NOT Emacs Lisp — verify unfamiliar names with apropos first. Returns the printed value; on an unbound name the error suggests the nearest real API. Evaluation runs with this chat as the logical current buffer, so switch-to-buffer! retargets that context and changes no window; to change or observe the frame's real windows, wrap the code in (with-frame-windows (lambda () ...))."
  (list (list 'code "string" "Scheme source to evaluate"))
  (lambda (args)
    (let* ((code (plist-get args 'code))
           (previous-tool-buffer *llm-tool-buffer*)
           ;; A tool has a logical current buffer, never a claim on the
           ;; user's selected window. Inside this binding switch-to-buffer!
           ;; retargets subsequent point-relative operations without display.
           (r (begin
                (set! *llm-tool-buffer* (current-buffer))
                (let ((result
                        (with-current-buffer (current-buffer)
                          (lambda () (eval-string-safe code)))))
                  (set! *llm-tool-buffer* previous-tool-buffer)
                  result))))
      (if (equal? (car r) 'ok)
          (value->string (cadr r))
          (string-append "error: " (cadr r) (tool--error-hint (cadr r) code)))))
  ;; arbitrary code: the payload decides what it does, the policy scans it
  '(write execute))

;; Emacs-grade introspection: most of the editor is userland Scheme, and
;; closures carry their AST — so a function's real source is one call away.
(define (describe-function name)
  (cond ((boundp name)
         ;; a builtin has no Scheme source, but it has a one-line doc
         (let ((src (function-source (symbol-value name)))
               (doc (primitive-doc name)))
           (if doc (string-append doc "\n" src) src)))
        ((command-fn name)
         (string-append "M-x command:\n" (function-source (command-fn name))))
        (else (string-append "no function or command named "
                             (symbol->string name)))))
(public! 'describe-function "(describe-function 'NAME) — the Scheme source of a function or M-x command; a builtin gives its one-line doc")
(catalog-meta! 'function "describe-function" 'domain 'discovery 'effects '(read))

(define-tool! 'describe-function
  "Read a function's actual implementation. Userland functions and M-x commands return their full Scheme source (most of the editor — dired, org, chat, modes — is userland); builtins are Elixir and return only a marker. Use it to understand how something works before changing it."
  (list (list 'name "string" "Function or command name, e.g. chat-send or face-remap!"))
  (lambda (args)
    (describe-function (string->symbol (plist-get args 'name))))
  '(read))

;;; --- apropos: one search over everything ---------------------------------------
;;; The first question an agent asks is "what can I call". Four registries
;;; held the answer and nothing searched across them: the public API, the
;;; M-x commands and their docstrings, the keybindings, and the
;;; defcustoms. The old apropos-api matched names only — never doc text —
;;; so "how do I split a window" found nothing while split-window! sat
;;; there with a doc saying exactly that.
;;;
;;; Matching is hybrid. Literal word-AND hits rank first. OpenAI embeddings
;;; add semantic recall when a key is configured. A query that finds nothing
;;; falls back to edit distance, so a near-miss on a name still lands.

;; catalog-entry walks the whole catalog, and apropos enriches every hit
;; through it. The empty query hits everything: about 1300 hits across a
;; 1275 entry catalog is 1.6 million walks, and the search held the :ui
;; lane for nine seconds. Build one index per search instead.
;;
;; This Scheme has no hash table, so the index buckets the catalog by the
;; first character of the name. A bucket holds tens of entries where the
;; catalog holds thousands, and a lookup reads one bucket.

;; A component answers to its qualified name, and the bucket must still
;; find it: "ui/card" and "card" both bucket under "c".
;; Building the index costs more than a narrow search does: 245ms against
;; a 1275 entry catalog, paid on every call. The catalog only changes when
;; a package registers something, so keep the index and rebuild it when
;; the generation moves.
(define *apropos--index-cache* #f)
(define *apropos--index-gen* -1)
(define *apropos--rows-cache* #f)
(define *apropos--rows-gen* -1)

(define (apropos--ensure-index! gen)
  (unless (and *apropos--index-cache* (equal? gen *apropos--index-gen*))
    (set! *apropos--index-cache* (apropos--index))
    (set! *apropos--index-gen* gen))
  *apropos--index-cache*)

(define (apropos--index-cached)
  (let ((gen (catalog-generation)))
    (if (and *apropos--index-cache* (equal? gen *apropos--index-gen*))
        *apropos--index-cache*
        (with-scheme-lock 'apropos-cache
          (lambda () (apropos--ensure-index! (catalog-generation)))))))

;; Search used to rebuild names, docs, metadata plists, and lowercase strings
;; on every query. Publish those rows once for the catalog generation instead:
;; each query then performs only word checks and ranking over immutable data.
(define (apropos--rows-cached)
  (let ((gen (catalog-generation)))
    (if (and *apropos--rows-cache* (equal? gen *apropos--rows-gen*))
        *apropos--rows-cache*
        (with-scheme-lock 'apropos-cache
          (lambda ()
            (let ((locked-gen (catalog-generation)))
              (unless (and *apropos--rows-cache*
                           (equal? locked-gen *apropos--rows-gen*))
                (let ((index (apropos--ensure-index! locked-gen)))
                  (set! *apropos--rows-cache* (apropos--rows index))
                  (set! *apropos--rows-gen* locked-gen)))
              *apropos--rows-cache*))))))

(define (apropos--bucket-key name)
  (let* ((n (catalog--string (or name "")))
         (cut (string-rindex n "/"))
         (base (if cut (substring n (+ cut 1) (string-length n)) n)))
    (if (equal? base "") "" (string-downcase (substring base 0 1)))))

(define (apropos--index)
  ;; Each row is (LOOKUP-KEY ENTRY) with the key already built, so a scan
  ;; compares one string where it used to walk two plists per entry. A
  ;; component answers to its qualified name as well, so it gets a row for
  ;; each name it answers to.
  ;; cons and reverse: appending to the accumulator once per entry copies
  ;; the list every time, and the build cost more than the walk it saves.
  (let* ((rows
           (reverse
             (fold
               (lambda (out e)
                 (let* ((kind (catalog--string (or (catalog--get e 'kind) "")))
                        (name (catalog--string (or (catalog--get e 'name) "")))
                        (qual (catalog--string (or (catalog--get e 'qualified-name) "")))
                        (enrichment
                        (list 'qualified-name (catalog--get e 'qualified-name)
                              'package (catalog--get e 'package)
                              'namespace (catalog--get e 'namespace)
                              'domain (catalog--get e 'domain)
                              'effects (catalog--get e 'effects)
                              'use (catalog--get e 'use)))
                      (row (list (apropos--bucket-key name)
                                 (string-append kind " " name) enrichment)))
                   (if (or (equal? qual "") (equal? qual name))
                       (cons row out)
                       (cons (list (apropos--bucket-key qual)
                                   (string-append kind " " qual) enrichment)
                             (cons row out)))))
               '() (catalog))))
         (buckets (dedupe-names (map car rows))))
    (map (lambda (b)
           (list b (map cdr (filter (lambda (r) (equal? (car r) b)) rows))))
         buckets)))

;; the catalog entry for KIND and NAME, read from the index apropos built.
;; With no index it falls back to the linear walk, so a caller outside a
;; search keeps working.
(define (apropos--enrichment-of e)
  (list 'qualified-name (catalog--get e 'qualified-name)
        'package (catalog--get e 'package)
        'namespace (catalog--get e 'namespace)
        'domain (catalog--get e 'domain)
        'effects (catalog--get e 'effects)
        'use (catalog--get e 'use)))

;; the six enrichment fields for KIND and NAME, already built when the
;; index holds them. With no index it reads the catalog and builds them,
;; so a caller outside a search keeps working.
(define (apropos--lookup index kind name)
  (if (not index)
      (let ((e (catalog-entry kind name)))
        (and e (apropos--enrichment-of e)))
      (let* ((want (string-append (catalog--string kind) " "
                                  (catalog--string name)))
             (cell (assoc (apropos--bucket-key (catalog--string name)) index)))
        (and cell
             (let loop ((rows (car (cdr cell))))
               (cond ((null? rows) #f)
                     ((equal? (car (car rows)) want) (car (cdr (car rows))))
                     (else (loop (cdr rows)))))))))

(define *apropos--stop-words*
  ;; Every word must appear for a literal hit, so a filler word is not
  ;; harmless here — it is the word that makes the right entry miss. A
  ;; directive carries pronouns the catalog will never contain.
  '("a" "an" "and" "current" "do" "for" "how" "i" "in" "it" "its"
    "me" "my" "of" "please" "that" "the" "this" "to" "us" "we"
    "with" "you" "your"))

(domain! 'discovery)
(effects! '(read))

(defcustom 'apropos-semantic-search #t
  "Use OpenAI embeddings to add semantic apropos results when an OpenAI key exists."
  'group 'discovery)

(defcustom 'apropos-semantic-limit 24
  "The maximum semantic results that apropos reads from the embedding index."
  'group 'discovery)

;; The minimum cosine similarity for an apropos semantic result.
(define apropos-semantic-threshold 0.30)

(define (apropos--raw-words q)
  (filter
    (lambda (w) (not (equal? w "")))
    (string-split
      (string-join
        (string-split
          (string-join (string-split (string-downcase (string-trim q)) "_") " ")
          "/")
        " ")
      " ")))

(define (apropos--words q)
  (let* ((raw (apropos--raw-words q))
         (meaningful (filter (lambda (w) (not (member w *apropos--stop-words*))) raw)))
    ;; A stop-word-only query must not become the empty-query catalog listing.
    (if (pair? meaningful) meaningful raw)))

(define (apropos--hit? hay words)
  (let ((h (string-downcase hay)))
    (let loop ((ws words))
      (cond ((null? ws) #t)
            ((string-contains? h (car ws)) (loop (cdr ws)))
            (else #f)))))

(define (apropos--fn e words index)
  (and (apropos--hit? (string-append (car e) " " (nth 1 e) " " (nth 2 e) " "
                                     (symbol->string (nth 3 e)))
                      words)
       (apropos--enrich
         (list 'kind "function" 'name (car e) 'sig (nth 2 e)
               'doc (nth 1 e) 'domain (symbol->string (nth 3 e))
               'category (symbol->string (nth 3 e))) #f index)))

(define (apropos--command n words index)
  (let ((doc (command-doc n)))
    (and (apropos--hit? (string-append n " " doc) words)
         (apropos--enrich
           (list 'kind "command" 'name n 'doc doc
                 'key (let ((k (key-for-command n))) (if (equal? k "") #f k)))
           #f index))))

(define (apropos--key row words index)
  (and (apropos--hit? (string-append (car row) " " (nth 1 row)) words)
       (let ((cmd (apropos--lookup index 'command (nth 1 row))))
         (append (list 'kind "key" 'name (car row) 'runs (nth 1 row)
                       'domain "keys" 'effects
                       (if cmd (plist-get cmd 'effects) '("read")))
                 (if cmd
                     (list 'package (plist-get cmd 'package)
                           'namespace (plist-get cmd 'namespace))
                     '())))))

(define (apropos--var v words index)
  (let* ((rec (cadr v))
         (name (symbol->string (car v)))
         (doc (or (plist-get rec 'doc) "")))
    (and (apropos--hit? (string-append name " " doc) words)
         (apropos--enrich (list 'kind "variable" 'name name 'doc doc)
                          "setting" index))))

;; The sixth registry. car, string-append, regex-match, db-query and 450
;; more are Elixir, and the interpreter's own doc map was the only place
;; that knew them: apropos answered nothing for a name every caller can
;; already use. A primitive a Scheme declaration covers keeps that entry,
;; because a declaration states domain and effects and this cannot. The
;; rest say builtin, and say they do not know.
(define (apropos--primitive p words index)
  (let ((name (car p))
        (doc (nth 1 p)))
    (and (not (apropos--lookup index 'function name))
         (apropos--hit? (string-append name " " doc) words)
         (let ((parts (public--split doc)))
           (list 'kind "function" 'name name
                 'sig (or (car parts) (string-append "(" name ")"))
                 'doc (nth 1 parts)
                 'package "builtins"
                 'namespace "core"
                 'origin "builtin"
                 'domain "unknown"
                 'effects '("unknown")
                 'metadata-source "unknown")))))

(define (apropos--primitives words index)
  (if (boundp 'primitive-docs)
      (apropos--compact
        (map (lambda (p) (apropos--primitive p words index)) (primitive-docs)))
      '()))

(define (apropos--compact xs) (filter (lambda (x) x) xs))

(define (apropos--enrich hit &optional catalog-kind index)
  (let* ((kind (or catalog-kind (plist-get hit 'kind)))
         (name (or (and (equal? kind "component") (plist-get hit 'qualified-name))
                   (plist-get hit 'name) (plist-get hit 'task)))
         (e (and name (apropos--lookup index
                                       (string->symbol kind) name))))
    (if (not e) hit (append hit e))))

;; catalog-meta! accepts a symbol for domain and friends, so read every
;; field through catalog--string before appending it into the haystack
(define (apropos--catalog-field e key)
  (let ((v (catalog--get e key)))
    (if v (catalog--string v) "")))

;; a "note" is a design decision left in the catalog for the next
;; agent: no code behind it, just the words that answer the search
;; before someone rebuilds what was already decided
(define (apropos--catalog-entry e words)
  ;; A recipe is the catalog's answer to a task phrased the way a person
  ;; phrases it, and it carries the expression that performs it. Search
  ;; skipped recipes entirely, so every directive had to be answered by
  ;; ranking identifiers instead. Its `use` expression is searched too:
  ;; the operation it calls is the best name a task phrase can carry.
  (let ((kind (catalog--get e 'kind)))
    (and (member kind '("component" "mode" "note" "fence-kind" "recipe" "howto"))
         (apropos--hit?
           (string-append (apropos--catalog-field e 'name) " "
                          (apropos--catalog-field e 'qualified-name) " "
                          (apropos--catalog-field e 'doc) " "
                          (apropos--catalog-field e 'package) " "
                          (apropos--catalog-field e 'namespace) " "
                          (apropos--catalog-field e 'domain) " "
                          (apropos--catalog-field e 'use) " "
                          (apropos--catalog-field e 'aliases) " "
                          (value->string (or (catalog--get e 'props) '())) " "
                          (value->string (or (catalog--get e 'example) '())))
           words)
         e)))

;; One row is (LOWERCASED-SEARCH-TEXT HIT). The original registry order is
;; retained because it is the stable fallback order after ranking buckets.
(define (apropos--rows index)
  ;; One row is (LOWERCASED-SEARCH-TEXT HIT). The original registry order is
  ;; kept, so ranking decides the answer and not the build order.
  (let ((hits
          (append
            (apropos--compact
              (map (lambda (e) (apropos--fn e '() index)) (public-api)))
            (apropos--compact
              (map (lambda (n) (apropos--command n '() index)) (command-names)))
            (apropos--compact
              (map (lambda (r) (apropos--key r '() index)) (global-keys)))
            (apropos--compact
              (map (lambda (v) (apropos--var v '() index)) *custom-vars*))
            (apropos--compact
              (map (lambda (e) (apropos--catalog-entry e '())) (catalog)))
            (apropos--primitives '() index))))
    (map (lambda (hit) (list (string-downcase (value->string hit)) hit)) hits)))

;; A row's text is lowercased once, when the rows are built, and so are the
;; query words. apropos--hit? lowercased every row again on every query,
;; which was two thirds of a search.
(define (apropos--row-hit? row words)
  (let ((h (car row)))
    (let loop ((ws words))
      (cond ((null? ws) #t)
            ((string-contains? h (car ws)) (loop (cdr ws)))
            (else #f)))))

;; The longest word is the rarest, so it goes first and most rows fail on
;; their first test.
(define (apropos--longest-first words)
  (map (lambda (p) (nth 2 p))
       (sort (let loop ((ws words) (i 0) (acc '()))
               (if (null? ws)
                   acc
                   (loop (cdr ws) (+ i 1)
                         (cons (list (- 0 (string-length (car ws))) i (car ws)) acc)))))))

(define (apropos--same-hit? a b)
  (and (equal? (plist-get a 'kind) (plist-get b 'kind))
       (equal? (or (plist-get a 'qualified-name) (plist-get a 'name) (plist-get a 'task))
               (or (plist-get b 'qualified-name) (plist-get b 'name) (plist-get b 'task)))))

(define (apropos--has-hit? hits hit)
  (pair? (filter (lambda (h) (apropos--same-hit? h hit)) hits)))

(define (apropos--name-query? query words)
  (and (= (length words) 1)
       (or (string-contains? query "-")
           (string-contains? query "!")
           (string-contains? query "?"))))

(define (apropos--name-suggestions query words index)
  (if (not (apropos--name-query? query words))
      '()
      (map (lambda (e)
             (apropos--enrich
               (list 'kind "function" 'name (car e) 'sig (nth 2 e) 'doc (nth 1 e)
                     'domain (symbol->string (nth 3 e))
                     'category (symbol->string (nth 3 e)) 'note "closest name")
               #f index))
           (tool--suggest (string-trim query)))))

(define (apropos--semantic-sources rows)
  (map (lambda (row) (car (cdr row))) rows))

(define (apropos--embedding-field hit key)
  (let ((value (plist-get hit key)))
    (if value (value->string value) "")))

(define (apropos--embedding-text hit)
  (string-append
    "Editor API candidate. Kind: " (apropos--embedding-field hit 'kind)
    ". Name: " (or (plist-get hit 'qualified-name)
                    (plist-get hit 'name) (plist-get hit 'task) "")
    ". Description: " (apropos--embedding-field hit 'doc)
    ". Signature: " (apropos--embedding-field hit 'sig)
    ". Domain: " (apropos--embedding-field hit 'domain)
    ". Effects: " (apropos--embedding-field hit 'effects)
    ". Usage: " (or (plist-get hit 'use) (plist-get hit 'run) "")
    ;; The words people say for this task, which are rarely the words the
    ;; identifier uses. "beside" has to reach the other-window operation.
    ". Also called: " (apropos--embedding-field hit 'aliases)))

;; The sources and their embedding texts change only when the catalog does.
;; Rebuilding 1800 strings on every query cost more than a second, and the
;; vectors they name are already on disk. Publish them once per generation,
;; the way the rows are published.
(define *apropos--sources-cache* #f)
(define *apropos--texts-cache* #f)
(define *apropos--sources-gen* -1)

;; Keep query embedding behind one seam. Tests replace it without a network
;; call, and the production path remains the cached embedding primitive.
(define *apropos--embedding-search* embedding-search)
(define *apropos--embedding-sync* embedding-sync!)

;; Catalog declarations arrive one form at a time. Keep that registration
;; path local and cheap, then reconcile the durable vector index once after
;; the burst. A foreground query reads the last complete index and embeds only
;; its own text; it never repairs catalog vectors while an agent waits.
;; the catalog generation whose vectors the index has already gathered, so a
;; query can leave its texts at home
(define *apropos--prepared-gen* -1)

(define *apropos--embedding-sync-running* #f)
(define *apropos--embedding-sync-pending* #f)
(define *apropos--embedding-synced-gen* -1)

(define (apropos--embedding-key)
  (and apropos-semantic-search
       (boundp (quote llm-key))
       (llm-key "openai")))

(define (apropos--sources-cached rows)
  (let ((gen (catalog-generation)))
    (unless (and *apropos--sources-cache* (equal? gen *apropos--sources-gen*))
      (let ((sources (apropos--semantic-sources rows)))
        (set! *apropos--sources-cache* sources)
        (set! *apropos--texts-cache* (map apropos--embedding-text sources))
        (set! *apropos--sources-gen* gen)))
    (list *apropos--sources-cache* *apropos--texts-cache*)))

(define (apropos--start-embedding-sync!)
  (let ((key (apropos--embedding-key)))
    (cond
      ((or (not key) (equal? key "")) #f)
      (*apropos--embedding-sync-running*
       (set! *apropos--embedding-sync-pending* #t)
       #f)
      (else
        (let ((gen (catalog-generation)))
          (set! *apropos--embedding-sync-running* #t)
          (set! *apropos--embedding-sync-pending* #f)
          ;; the rows, the sources, and their texts are built INSIDE the
          ;; task: rebuilding them for the whole catalog costs seconds,
          ;; and on the UI lane that was a stall after every reload. The
          ;; vectors themselves are incremental already: the index keeps
          ;; them by content hash and embeds only the texts it lacks.
          (task-run!
            (lambda ()
              (let ((both (apropos--sources-cached (apropos--rows-cached))))
                (*apropos--embedding-sync* (nth 1 both) key)))
            (lambda (ok value)
              (set! *apropos--embedding-sync-running* #f)
              (when (and ok value)
                (set! *apropos--embedding-synced-gen* gen))
              ;; A declaration can land while this batch is in flight. The
              ;; completed snapshot remains valid; schedule the next delta.
              (when (or *apropos--embedding-sync-pending*
                        (not (equal? gen (catalog-generation))))
                (apropos--schedule-embedding-sync!)))
            60000)
          #t)))))

(define (apropos--schedule-embedding-sync!)
  (set! *apropos--embedding-sync-pending* #t)
  (debounce! "apropos-embedding-sync" 250
    (lambda (ignored) (apropos--start-embedding-sync!)) #f)
  #t)

;; catalog-register! calls this after the entry is complete. A reload batches
;; all declarations until reload-finish!; an interactive declaration uses the
;; same short debounce directly.
(define (apropos-catalog-changed! entry)
  (set! *apropos--embedding-sync-pending* #t)
  (unless (and (boundp (quote *reloading?*)) *reloading?*)
    (apropos--schedule-embedding-sync!))
  entry)

(define (apropos-reload-finished!)
  (when *apropos--embedding-sync-pending*
    (apropos--schedule-embedding-sync!)))

(define (apropos-sync-embeddings!)
  (apropos--schedule-embedding-sync!))

(define (apropos--semantic-hits query rows filters &optional wait?)
  (let ((key (apropos--embedding-key)))
    (if (or (not key) (equal? key "") (equal? (string-trim query) ""))
        '()
        (let* ((both (apropos--sources-cached rows))
               (sources (car both))
               (texts (nth 1 both))
               ;; #t is "every entry is eligible": with no filter to apply,
               ;; the mask is eighteen hundred yeses, and building and
               ;; handing it over cost more than the scoring it guards
               (eligible (if (null? filters)
                             #t
                             (map (lambda (hit) (apropos--filter-match? hit filters)) sources)))
               ;; The catalog texts already identify themselves as editor API
               ;; candidates. A repeated instruction prefix overwhelms a short
               ;; task query and changes its meaning in embedding space.
               ;;
               ;; The generation names the vectors: the index gathers them
               ;; once for it and answers every later query from that. And the
               ;; search never goes to the network here — this runs on the
               ;; Session, which takes one form at a time, so a question
               ;; nobody has asked before would park every other caller for
               ;; seconds. A miss warms the query off-lane and says so by
               ;; answering #f; the next ask scores it.
               ;; Handing eighteen hundred strings over on every query cost
               ;; more than the scoring did. The index gathered them once for
               ;; this generation; withhold them until it says it needs them.
               (gen (catalog-generation))
               (ready? (equal? gen *apropos--prepared-gen*))
               (scores0 (*apropos--embedding-search* query (if ready? '() texts) key
                                                     apropos-semantic-limit eligible
                                                     gen #t))
               (scores (if (equal? scores0 'not-prepared)
                           (*apropos--embedding-search* query texts key
                                                        apropos-semantic-limit eligible
                                                        gen #t)
                           scores0)))
          (unless (equal? scores 'not-prepared) (set! *apropos--prepared-gen* gen))
          (cond
            ;; #f is "nobody embedded this query yet". A caller that waits
            ;; buys the vector now, on this lane: a tool asks its question
            ;; once, and an answer that lands after the call is no answer.
            ;; A caller that does not wait warms it off-lane and answers
            ;; from the catalog, so a keystroke never waits for OpenAI.
            ((and (equal? scores #f) wait?)
             (let ((warmed (*apropos--embedding-search*
                             query (if ready? '() texts) key
                             apropos-semantic-limit eligible gen #f)))
               (if (or (equal? warmed #f) (equal? warmed 'not-prepared))
                   '()
                   (apropos--semantic-rows warmed sources))))
            ((equal? scores #f)
             (when (boundp (quote embedding-warm!))
               (embedding-warm! query texts key (catalog-generation)))
             '())
            (else (apropos--semantic-rows scores sources)))))))

;; the scores above the threshold, as catalog hits that name their lane
(define (apropos--semantic-rows scores sources)
  (map (lambda (score)
         (append (nth (car score) sources)
                 (list 'note "semantic match" 'semantic-score (nth 1 score))))
       (filter (lambda (score) (>= (nth 1 score) apropos-semantic-threshold))
               scores)))

(define (apropos-rebuild-embeddings!)
  (let ((path (embedding-cache-clear!))
        (key (apropos--embedding-key)))
    (if (or (not key) (equal? key ""))
        (string-append "Cleared " path "; no OpenAI key is configured.")
        (let* ((both (apropos--sources-cached (apropos--rows-cached)))
               (texts (nth 1 both))
               (count (*apropos--embedding-sync* texts key)))
          (when count
            (set! *apropos--embedding-synced-gen* (catalog-generation)))
          (if (file-exists? path)
              (string-append "Rebuilt " path ".")
              (string-append "Could not rebuild " path "; lexical apropos remains available."))))))

(define (apropos--filter filters key)
  (or (plist-get filters key)
      (and (equal? key 'domain) (plist-get filters 'category))))

(define (apropos--filter-match? hit filters)
  (let ((kind (apropos--filter filters 'kind))
        (package (apropos--filter filters 'package))
        (namespace (apropos--filter filters 'namespace))
        (domain (apropos--filter filters 'domain))
        (effect (apropos--filter filters 'effect))
        (exclude-effect (apropos--filter filters 'exclude-effect)))
    (and (or (not kind) (equal? (plist-get hit 'kind) (catalog--string kind)))
         (or (not package) (equal? (plist-get hit 'package) (catalog--string package)))
         (or (not namespace) (equal? (plist-get hit 'namespace) (catalog--string namespace)))
         (or (not domain) (equal? (plist-get hit 'domain) (catalog--string domain)))
         (or (not effect) (member (catalog--string effect) (or (plist-get hit 'effects) '())))
         (or (not exclude-effect)
             (not (member (catalog--string exclude-effect)
                          (or (plist-get hit 'effects) '())))))))

;; Exact names and literal recipes remain ahead of vector results.
(define (apropos--rank hits query)
  ;; An empty query has no name to rank against, and the order it came in
  ;; is the answer. Leave before building the four buckets: the let* below
  ;; runs its predicates over every hit, and apropos-category asks with an
  ;; empty query every time.
  (if (equal? (string-trim query) "")
      hits
      (let ((literal (filter (lambda (h) (not (equal? (plist-get h 'note)
                                                       "semantic match")))
                             hits))
            (semantic (filter (lambda (h) (equal? (plist-get h 'note)
                                                   "semantic match"))
                              hits)))
        (append (apropos--rank-by-name literal query)
                (apropos--rank-semantic semantic query)))))

;; Semantic similarity finds related candidates. Field coverage resolves close
;; candidates. A word in the API name carries more intent than the same word
;; in a long description or a metadata field.
(define (apropos--field-coverage text words)
  (if (null? words)
      0.0
      (let ((hay (string-downcase text)))
        (/ (* 1.0
              (length (filter (lambda (word) (string-contains? hay word)) words)))
           (length words)))))

(define (apropos--semantic-rank-score hit words)
  (let ((name (string-append
                (or (plist-get hit 'qualified-name) "") " "
                (or (plist-get hit 'name) "") " "
                (or (plist-get hit 'task) "")))
        (signature (or (plist-get hit 'sig) ""))
        (doc (or (plist-get hit 'doc) ""))
        (metadata
          (string-append
            (apropos--embedding-field hit 'kind) " "
            (apropos--embedding-field hit 'package) " "
            (apropos--embedding-field hit 'namespace) " "
            (apropos--embedding-field hit 'domain) " "
            (apropos--embedding-field hit 'effects) " "
            (or (plist-get hit 'use) (plist-get hit 'run) ""))))
    (let ((name-coverage (apropos--field-coverage name words))
          (signature-coverage (apropos--field-coverage signature words)))
    (+ (or (plist-get hit 'semantic-score) 0.0)
       (* 0.30 name-coverage name-coverage)
       (* 0.12 signature-coverage signature-coverage)
       (* 0.06 (apropos--field-coverage doc words))
       (* 0.20 (apropos--field-coverage (or (plist-get hit 'aliases) "") words))
       (* 0.02 (apropos--field-coverage metadata words))))))

(define (apropos--rank-semantic hits query)
  (let ((words (apropos--words query)))
    (map (lambda (row) (nth 1 row))
         (reverse
           (sort
             (map (lambda (hit)
                    (list (apropos--semantic-rank-score hit words) hit))
                  hits))))))

(define (apropos--rank-by-name hits query)
  (let* ((q (string-downcase (string-trim query)))
         (name-of (lambda (h)
                    (string-downcase
                      (or (plist-get h 'qualified-name)
                          (plist-get h 'name) (plist-get h 'task) ""))))
         (short-of (lambda (h)
                     (string-downcase (or (plist-get h 'name) (plist-get h 'task) ""))))
         (exact? (lambda (h) (or (equal? q (name-of h)) (equal? q (short-of h)))))
         (prefix? (lambda (h)
                    (or (string-prefix? q (name-of h))
                        (string-prefix? q (short-of h)))))
         (exact (filter exact? hits))
         (prefixes (filter (lambda (h) (and (not (exact? h)) (prefix? h))) hits))
         (rest (filter (lambda (h)
                         (and (not (exact? h)) (not (prefix? h)))) hits)))
    (append exact prefixes (apropos--rank-semantic rest query))))

;; Scope "all" is the escape hatch for private globals. Keep every result
;; structured, so discovery can distinguish a private implementation from a
;; missing public declaration. Explicit declarations still own effects: the
;; search must never infer permission metadata from a function name or doc.
(define (apropos--internal n doc words catalogued-names)
  (and (apropos--hit? (if doc (string-append n " " doc) n) words)
       (let ((entry (append (list 'kind "internal" 'name n)
                            (if doc (list 'doc doc) '()))))
         (if (member n catalogued-names)
             entry
             (append entry
               (list 'catalog-status "uncatalogued"
                     'note
                     (string-append
                       "This global has no catalog declaration. "
                       "Inspect its defining source. If you use it, add a durable "
                       "declaration with explicit domain and effects.")))))))

;; QUERY is words, not a regex: "split window", "open a file", "chat cost".
;; Recipes come first: a task-level hit beats four name-level ones, and it
;; is the answer the caller actually wanted.
;; What a reader cannot work out from the rest of the row. The enrichment
;; appends the catalog entry to the hit, so a key the hit already carried
;; arrives twice and only the first is ever read; the qualified name is
;; the package and the name with a slash between them; the namespace and
;; the category repeat the package and the domain in the common case; and
;; a command's use line is its name in the one shape a command takes.
;; Half the answer said nothing, and every agent reads this.
(define (apropos--derivable? hit key value)
  (let ((name (plist-get hit 'name))
        (package (plist-get hit 'package))
        (domain (plist-get hit 'domain)))
    (cond ((member key '(note semantic-score match)) #t)
          ;; a command's use line stays: agents are told to read it, and a
          ;; row that drops it asks every reader to know the shape by heart
          ((equal? key 'use) (equal? value (plist-get hit 'sig)))
          ((equal? key 'category) (equal? value domain))
          ((equal? key 'namespace) (equal? value package))
          ;; the qualified name is the NAMESPACE and the name: core/... for
          ;; the editor's own, whose package is "editor". catalog-meta!
          ;; takes a symbol for these as readily as a string, so join only
          ;; what is already a string and keep the row whole otherwise.
          ((equal? key 'qualified-name)
           (let ((owner (or (plist-get hit 'namespace) package)))
             (and (string? value) (string? name) (string? owner)
                  (equal? value (string-append owner "/" name)))))
          (else #f))))

(define (apropos--public-hit hit)
  (if (not hit)
      #f
      (let loop ((xs hit) (seen '()) (out '()))
        (cond ((or (null? xs) (null? (cdr xs))) (reverse out))
              ((or (member (car xs) seen)
                   (apropos--derivable? hit (car xs) (cadr xs)))
               (loop (cdr (cdr xs)) (cons (car xs) seen) out))
              (else
                (loop (cdr (cdr xs))
                      (cons (car xs) seen)
                      (cons (cadr xs) (cons (car xs) out))))))))

(define (apropos query &rest filters)
  ;; Build rows first. Their single-flight refresh also publishes the index.
  ;; The next lookup is then a cheap read of the same catalog generation.
  (let ((rows (apropos--rows-cached)))
    (map apropos--public-hit
         (apropos--search query filters (apropos--index-cached) rows))))

;; 'lexical #t asks for the catalog alone. The semantic pass embeds the
;; query through an external service: it spends money and waits for the
;; network on every call. A surface that searches while the user types
;; must ask for the literal catalog.
;;
;; 'wait #f asks for the vectors already bought. A query nobody embedded
;; before is embedded at ask time and the caller waits, because a caller
;; asks its question once and an answer that arrives after the call is no
;; answer. One short query embeds in well under a second. A surface that
;; searches on every keystroke wants 'lexical #t instead.
;;
;; Both are instructions to the search, not catalog fields. Remove them
;; before the filters reach the match test, which reads the catalog
;; fields only.
(define *apropos--search-flags* '(lexical wait))

;; KEY's value, or DEFAULT when the filters do not name it. plist-get
;; cannot tell an absent key from one whose value is #f, and the whole
;; point of 'wait #f is to say #f out loud.
(define (apropos--flag filters key default)
  (let loop ((in filters))
    (cond ((or (null? in) (null? (cdr in))) default)
          ((equal? (car in) key) (nth 1 in))
          (else (loop (cdr (cdr in)))))))

(define (apropos--without-lexical filters)
  (let loop ((in filters) (out '()))
    (cond ((or (null? in) (null? (cdr in))) (reverse out))
          ((member (car in) *apropos--search-flags*) (loop (cdr (cdr in)) out))
          (else (loop (cdr (cdr in))
                      (cons (nth 1 in) (cons (car in) out)))))))

(define (apropos--search query filters0 index rows)
  (let* ((lexical? (plist-get filters0 'lexical))
         (wait? (apropos--flag filters0 'wait #t))
         (filters (apropos--without-lexical filters0))
         (words (apropos--words query))
         (scan (apropos--longest-first words))
         (literal-rows (filter (lambda (row) (apropos--row-hit? row scan)) rows))
         (literal-hits (map (lambda (row) (car (cdr row))) literal-rows))
         (suggestions (if (pair? literal-hits) '()
                          (apropos--name-suggestions query words index)))
         ;; The semantic pass embeds the query through a network service,
         ;; and it runs on the Session, which takes one form at a time: every
         ;; caller waits behind it, so a keystroke that needs the Session
         ;; queued for seconds. It is worth that only when the words found
         ;; nothing. A query the catalog already answered is answered.
         (semantic-hits
           (if (or lexical? (pair? literal-hits))
               '()
               (filter (lambda (hit)
                         (and (not (apropos--has-hit? literal-hits hit))
                              (not (apropos--has-hit? suggestions hit))))
                       (apropos--semantic-hits query rows filters wait?))))
         (hits (append literal-hits suggestions semantic-hits))
         (filtered (filter (lambda (h) (apropos--filter-match? h filters)) hits)))
    (if (or (pair? filtered) (null? words) (pair? filters))
        (apropos--rank filtered query)
        ;; No embedding key exists and nothing matched. Try any name shape.
        (map (lambda (e)
               (apropos--enrich
                 (list 'kind "function" 'name (car e) 'sig (nth 2 e) 'doc (nth 1 e)
                       'domain (symbol->string (nth 3 e))
                       'category (symbol->string (nth 3 e)) 'note "closest name")
                 #f index))
             (tool--suggest (string-trim query))))))

;; everything in one category — the shape of the API, not a search of it
(define (apropos-category name)
  (apropos "" 'domain name))

(category! 'discovery)
(public! 'apropos
  "(apropos QUERY &rest FILTERS) — hybrid literal/semantic catalog search; accepts kind/package/namespace/domain/effect filters, and 'lexical #t for the catalog alone (no embedding call). The public call shape is unchanged.")
(catalog-meta! 'function "apropos" 'domain 'discovery 'effects '(read external))

;; The word test on its own. A surface that searches one narrow source -
;; the command palette searches commands and recipes - matches the words
;; the same way apropos does, without building the whole catalog index.
(effects! '(pure))
(public! 'apropos-query-words
  "(apropos-query-words QUERY) -> the words a hit must all contain")
(public! 'apropos-text-hit?
  "(apropos-text-hit? TEXT WORDS) -> #t when TEXT contains every word")

(define (apropos-query-words query) (apropos--words query))
(define (apropos-text-hit? text words) (apropos--hit? text words))

;; A catalog change throws the rows away, and building them again costs
;; seconds: every command, primitive and function is enriched anew. A caller
;; that can live with the rows from just before the change takes them, and
;; one task builds the new ones off the lane.
;; The task, not a flag: a task that dies leaves a flag set, and nothing
;; ever rebuilt again.
(define *apropos--warming* #f)

(define (apropos-warm!)
  (unless (and *apropos--warming* (task-alive? *apropos--warming*))
    (set! *apropos--warming*
          (task-spawn (lambda () (ignore-errors (lambda () (apropos--rows-cached))))))))

(define (apropos--rows-stale-ok)
  (cond ((and *apropos--rows-cache* (equal? (catalog-generation) *apropos--rows-gen*))
         *apropos--rows-cache*)
        (*apropos--rows-cache* (apropos-warm!) *apropos--rows-cache*)
        (else (apropos--rows-cached))))

;; A lexical apropos that never waits for a rebuild: rows from just before
;; a catalog change will do, for a caller that asks many times a second.
(define (apropos-quick query n)
  (map apropos--public-hit
       (take-n (apropos--search query (list 'lexical #t 'wait #f)
                                (apropos--index-stale-ok) (apropos--rows-stale-ok))
               n)))

;; the index from before a catalog change, while a rebuild is due: asking for
;; the current one waited on the rebuild's lock, seconds, and a search task
;; gave up at five
(define (apropos--index-stale-ok)
  (if (and *apropos--index-cache* (not (equal? (catalog-generation) *apropos--index-gen*)))
      (begin (apropos-warm!) *apropos--index-cache*)
      (apropos--index-cached)))

;; apropos wants every word, which is precision: a sentence finds five
;; entries or none. A model choosing among entries wants recall, so this
;; ranks every entry by the words it holds, the rare ones and the ones in
;; its name counting most. Rows from just before a catalog change will do.
(define (apropos-recall query n)
  (let* ((words (apropos--words query))
         (rows (apropos--rows-stale-ok))
         ;; one pass: which of the words each entry holds; most hold none,
         ;; and only the ones that hold some are scored
         (held (let loop ((rs rows) (i 0) (acc '()))
                 (if (null? rs)
                     acc
                     (let* ((h (car (car rs)))
                            (in (filter (lambda (w) (string-contains? h w)) words)))
                       (loop (cdr rs) (+ i 1)
                             (if (pair? in) (cons (list in i (car rs)) acc) acc))))))
         ;; a word most entries hold says little, a rare one says what the
         ;; query is about: "open the groups list" is about groups. Counting
         ;; words alone ranked first the longest docs, which hold every word.
         (weight (map (lambda (w)
                        (list w (/ 1000.0 (+ 20 (length (filter (lambda (x) (member w (car x))) held))))))
                      words))
         ;; a word that is the whole name, or one of its parts, says more
         ;; than one in the doc; ties go to the shorter entry
         (scored (map (lambda (x)
                        (let* ((row (nth 2 x))
                               (nm (let ((s (plist-get (nth 1 row) 'name)))
                                     (if (string? s) (string-downcase s) "")))
                               (toks (string-split nm "-"))
                               (k (fold (lambda (s w)
                                          (let ((wt (nth 1 (assoc w weight))))
                                            (+ s (cond ((equal? nm w) (* 4 wt))
                                                       ((member w toks) (* 2 wt))
                                                       (else wt)))))
                                        0.0 (car x))))
                          (list (- 0 k) (string-length (car row)) (nth 1 x) (nth 1 row))))
                      held)))
    (map (lambda (row) (apropos--public-hit (nth 3 row)))
         (take-n (sort scored) n))))
(public! 'apropos-quick
  "(apropos-quick QUERY N) — the first N lexical apropos hits, from rows a catalog change ago if a rebuild is due")
(public! 'apropos-warm!
  "(apropos-warm!) — rebuild apropos's rows off the lane after a catalog change")
(public! 'apropos-recall
  "(apropos-recall QUERY N) — the N entries holding the most of QUERY's words, for a chooser that wants recall")
(effects! '(read external spend))
(public! 'apropos-rebuild-embeddings!
  "(apropos-rebuild-embeddings!) — clear and rebuild the OpenAI embedding cache for the current catalog")
(catalog-meta! 'function "apropos-rebuild-embeddings!"
  'domain 'discovery 'effects '(write external spend))
(public! 'apropos-category
  "(apropos-category 'windows) — every public function in one category")
(public! 'public-categories "(public-categories) — the category names")

(define-tool! 'apropos
  (string-append
    "Search the editor by intent, not by regex: public functions with their "
    "signatures, the Elixir primitives the interpreter binds, M-x commands "
    "with their docstrings, keybindings, and settings. A primitive with no "
    "Scheme declaration says package \"builtins\" and unknown effects. "
    "Literal matches rank first. OpenAI embeddings add semantic matches, so "
    "\"split window\" finds the window splitters and \"chat cost\" finds "
    "the cost commands. This is the supported surface and the place to "
    "start. Nothing matched? You get the closest names instead. Pass "
    "kind/package/namespace/domain/effect narrow the catalog. Pass "
    "Display-effect operations stay hidden unless include-display is true. "
    "When the user explicitly asks to open, show, switch, narrow, widen, or otherwise "
    "change visible editor state, set include-display true on the first search. "
    "Pass category as a compatibility alias for domain, or scope \"all\" to include "
    "internal globals, which may change without notice. An uncatalogued result asks "
    "you to inspect its source and add a durable declaration if you use it. Loading "
    "that declaration updates the live catalog immediately.")
  (list (list 'query "string" "intent words, e.g. \"open a file\" or \"remove document\"")
        (list 'kind "string" "function, command, key, variable, recipe, mode, or component" 'optional)
        (list 'package "string" "owning load unit" 'optional)
        (list 'namespace "string" "stable public vocabulary" 'optional)
        (list 'domain "string" "subject area, e.g. windows or buffers" 'optional)
        (list 'effect "string" "pure, read, write, destroy, spend, execute, external, or display" 'optional)
        (list 'include-display "boolean" "include operations that move visible editor state" 'optional)
        (list 'category "string" "deprecated alias for domain" 'optional)
        (list 'scope "string" "\"public\" (default) or \"all\"" 'optional))
  (lambda (args)
    (let ((q (or (plist-get args 'query) ""))
          (cat (plist-get args 'category))
          (kind (plist-get args 'kind))
          (package (plist-get args 'package))
          (namespace (plist-get args 'namespace))
          (domain (plist-get args 'domain))
          (effect (plist-get args 'effect))
          (include-display (plist-get args 'include-display))
          (scope (or (plist-get args 'scope) "public")))
      (let ((filters
              (append (if kind (list 'kind kind) '())
                      (if package (list 'package package) '())
                      (if namespace (list 'namespace namespace) '())
                      (if (or domain cat) (list 'domain (or domain cat)) '())
                      (if effect (list 'effect effect) '())
                      (if include-display '() (list 'exclude-effect 'display)))))
        (value->string
          (if (equal? scope "all")
              (let ((words (apropos--words q))
                    (catalogued-names
                      (map (lambda (entry) (plist-get entry 'name)) (catalog))))
                (list 'public (apply apropos (cons q filters))
                      'globals (apropos--compact
                                 (map (lambda (n)
                                        (apropos--internal
                                          n (primitive-doc n) words catalogued-names))
                                      (global-names)))))
              (apply apropos (cons q filters)))))))
  '(read external))

(define-tool! 'apropos-categories
  "List the catalog facets: kinds, packages, namespaces, domains, and effects. Cheapest way to see the shape of the surface before searching it."
  '()
  (lambda (args)
    (value->string
      (list 'kinds (catalog-facet 'kind)
            'packages (catalog-facet 'package)
            'namespaces (catalog-facet 'namespace)
            'domains (catalog-facet 'domain)
            'effects (catalog-facet 'effects))))
  '(read))

(define (catalog--add-unique value acc)
  (if (member value acc) acc (append acc (list value))))

(define (catalog-facet key)
  (fold (lambda (acc e)
          (let ((v (plist-get e key)))
            (if (not v)
                acc
                (if (equal? key 'effects)
                    (fold (lambda (a x) (catalog--add-unique x a)) acc v)
                    (catalog--add-unique v acc)))))
        '() (catalog)))

(category! 'discovery)
(public! 'catalog "(catalog) — every public catalog entry with package, namespace, domain and effects")
(public! 'catalog-entry "(catalog-entry KIND NAME) — one catalog entry, or #f")
(public! 'catalog-facet "(catalog-facet KEY) — distinct catalog values for kind, package, namespace, domain or effects")

;; Source citations are a common agent read, and byte offsets or guessed line
;; counts are the wrong policy. Keep numbering in Scheme over the ordinary
;; read-file mechanism so every caller gets stable, inspectable text.
(define (line-numbered-text source)
  (let loop ((lines (string-split source "\n")) (n 1) (out '()))
    (if (null? lines)
        (string-join (reverse out) "\n")
        (loop (cdr lines) (+ n 1)
              (cons (string-append (number->string n) "\t" (car lines)) out)))))

;; Keep the core file reader under a private name. Hot reload must not capture
;; this wrapper when this form runs again.
(unless (boundp 'read-file-source)
  (define read-file-source read-file))

(define (read-file path &optional line-numbers)
  (let ((source (read-file-source path)))
    (if (and source line-numbers) (line-numbered-text source) source)))

(define (read-file-numbered path)
  (read-file path #t))

(public! 'read-file
  "(read-file PATH [LINE-NUMBERS]) — read a text file; add stable line numbers when LINE-NUMBERS is true")
(catalog-meta! 'function "read-file" 'domain 'discovery 'effects '(read))
(public! 'read-file-numbered
  "(read-file-numbered PATH) — read source text files with stable line numbers for exact citations")
(catalog-meta! 'function "read-file-numbered" 'domain 'discovery 'effects '(read))

;; write-file! is a builtin: the Elixir side writes the file. Declared here
;; so a search for writing a file finds it in the files domain.
(public! 'write-file!
  "(write-file! PATH TEXT) — write TEXT to PATH, replacing the file, and create its parent directories; answer #t. It writes the disk only: a buffer open on PATH keeps its old text, so to change a file someone has open, edit its buffer.")
(catalog-meta! 'function "write-file!" 'domain 'files 'category 'files 'effects '(write))

;; A tool can answer with MCP content blocks instead of text:
;; (tool-content ((type "image" mimeType "image/png" data B64) ...)).
;; The MCP proxy sends the blocks as they are. A lane that takes text
;; only reads (tool-result-text R).
(define (tool-content blocks) (list 'tool-content blocks))

(define (tool-content? r)
  (and (pair? r) (equal? (car r) 'tool-content)))

(define (tool-result-text r)
  (cond ((string? r) r)
        ((tool-content? r)
         (string-join
           (map (lambda (b)
                  (if (equal? (plist-get b 'type) "text")
                      (plist-get b 'text)
                      (string-append "[" (plist-get b 'type)
                                     " content: this backend reads text only]")))
                (cadr r))
           "\n"))
        (else (value->string r))))

(define *tool-image-mimes*
  '(("png" "image/png") ("jpg" "image/jpeg") ("jpeg" "image/jpeg")
    ("gif" "image/gif") ("webp" "image/webp")))

;; (image-file-mime PATH) -> the image media type, or #f
(define (image-file-mime path)
  (let* ((parts (string-split path "."))
         (ext (and (pair? (cdr parts)) (string-downcase (car (reverse parts)))))
         (hit (and ext (assoc ext *tool-image-mimes*))))
    (and hit (cadr hit))))

(define (read-file-tool path line-numbers)
  (let ((mime (image-file-mime path))
        (source (read-file-source path)))
    (cond ((not source) "error: file does not exist or cannot be read")
          (mime
           (tool-content
             (list (list 'type "text" 'text (string-append "image " path))
                   (list 'type "image" 'mimeType mime
                         'data (base64-encode source)))))
          ((not (string-valid-utf8? source))
           (string-append "error: " path " is a binary file, not text"))
          (else (read-file path line-numbers)))))

(define-tool! 'read-file
  "Read one source file, or view an image file (png, jpg, gif, webp). Set line_numbers to true for stable line numbers. Independent read-file, apropos, describe-function, code-outline, and code-read calls can run concurrently."
  (list (list 'path "string" "absolute or workspace-relative source file path")
        (list 'line_numbers "boolean" "add stable line numbers" 'optional))
  (lambda (args)
    (read-file-tool (plist-get args 'path) (plist-get args 'line_numbers)))
  '(read))


(domain! 'buffers)
(effects! '(write))

;; the edit primitive the old edit-doc tool wrapped — now a public function
;; reached through eval-scheme. Edits the live buffer, never the file.
(define (buffer-replace! b old new)
  (let ((pos (buffer--one-hit b old "old text")))
    (if (string? pos)
        pos
        (begin
          (buffer-replace-range! b pos (string-byte-length old) new)
          "edited"))))

;;; --- the rest of edit-file semantics ------------------------------------------
;;; buffer-replace! is the one-hit edit. These four are the operations an
;;; agent otherwise fakes with byte arithmetic: replace every occurrence,
;;; insert relative to an anchor, and delete text. Every one of them
;;; addresses the buffer by TEXT the agent has read, never by offset, and
;;; every one reports what it did in a sentence the model can act on.

;; the byte offset of the one occurrence of NEEDLE, or an error string.
;; The three sentences below are the whole reason these helpers exist: a
;; model that gets "occurs 3 times" fixes its own call on the next round.
(define (buffer--one-hit b needle what)
  (cond ((not (buffer-exists? b)) (string-append "no such buffer: " b))
        ((equal? needle "") (string-append "error: " what " must be non-empty"))
        (else
          (let ((hits (- (length (string-split (buffer-text b) needle)) 1)))
            (cond ((equal? hits 0)
                   (string-append "error: " what
                                  " not found — read the buffer and copy it exactly"))
                  ((> hits 1)
                   (string-append "error: " what " occurs "
                                  (number->string hits)
                                  " times — include surrounding text to make it unique"))
                  (else (string-index (buffer-text b) needle)))))))

(define (buffer-replace-all! b old new)
  (cond ((not (buffer-exists? b)) (string-append "no such buffer: " b))
        ((equal? old "") "error: old must be non-empty")
        (else
          (let* ((text (buffer-text b))
                 (hits (- (length (string-split text old)) 1)))
            (if (= hits 0)
                "error: old text not found — read the buffer and copy it exactly"
                (begin
                  ;; One buffer message, whatever the number of hits: another
                  ;; Scheme evaluator cannot observe the delete half of a
                  ;; replacement or interleave an edit between the halves.
                  (buffer-replace-range!
                    b 0 (string-byte-length text)
                    (string-join (string-split text old) new))
                  (string-append "replaced " (number->string hits)
                                 (if (= hits 1) " occurrence" " occurrences"))))))))

(define (buffer-insert-before! b anchor text)
  (let ((pos (buffer--one-hit b anchor "anchor")))
    (if (string? pos)
        pos
        (begin (buffer-insert! b pos text) "inserted"))))

(define (buffer-insert-after! b anchor text)
  (let ((pos (buffer--one-hit b anchor "anchor")))
    (if (string? pos)
        pos
        (begin (buffer-insert! b (+ pos (string-byte-length anchor)) text)
               "inserted"))))

(define (buffer-delete-text! b old)
  (let ((pos (buffer--one-hit b old "text")))
    (if (string? pos)
        pos
        (begin (buffer-delete-range! b pos (string-byte-length old)) "deleted"))))

(category! 'editing)
(public! 'buffer-replace!
  "(buffer-replace! NAME OLD NEW) — replace exact, unique OLD with NEW in a live buffer")
(public! 'buffer-replace-all!
  "(buffer-replace-all! NAME OLD NEW) — replace every occurrence of OLD; reports the count")
(public! 'buffer-insert-before!
  "(buffer-insert-before! NAME ANCHOR TEXT) — insert TEXT in front of exact, unique ANCHOR")
(public! 'buffer-insert-after!
  "(buffer-insert-after! NAME ANCHOR TEXT) — insert TEXT after exact, unique ANCHOR")
(public! 'buffer-delete-text!
  "(buffer-delete-text! NAME TEXT) — delete exact, unique TEXT from a live buffer")

;; the sections below this one predate the stamps and take their metadata
;; from the frozen classification: leave them the way they were found
(domain! 'unknown)
(effects! '(unknown))

;;; --- the MCP proxy surface ----------------------------------------------------
;;; External ACP agents get this same registry over MCP: the bundled
;;; compos-mcp-proxy.exs bridges stdio MCP to the daemon socket and calls
;;; these two. Payloads are base64 both ways — RPC eval returns printed
;;; values, and printed-string escaping is not JSON-safe for every byte.

(define (mcp-proxy-tools-json)
  (base64-encode (tool-specs-json (llm-tool-specs))))

;; The third chokepoint. In auto mode the agent stops asking us ANYTHING,
;; and every deny-listed verb reaches the world through one of our three
;; gates — so this one asks the SAME policy the other two ask, not a
;; hand-rolled subset of it. It used to apply the deny-list alone, which
;; meant a chat in `ask` mode was in ask mode everywhere except here.
;;
;; Nobody can answer a banner for a proxy call: it arrives on the socket
;; from an agent we are not rendering, with no chat to raise it in. So
;; `ask` is a refusal here, with a sentence saying how to get it done.
;; That is the fail-closed rule, applied where it bites.
;; author: the proxy sends its thread's slug (COMPOS_AGENT), so edits an
;; external agent makes through this bridge land in buffer-authors
;; What "always" remembers: the VERB the policy tripped on, for every
;; chat of the asking chat's group. It is kept in the group record, so it
;; lasts as long as the group. The key is never eval-scheme itself — that
;; tool's name says nothing about what it runs.
(define (mcp-proxy--grant-key slug name args-json raw)
  ;; the pattern itself, so the box can list it and take it back; a
  ;; shell gate ask keys on its kind, such as "shell edit"
  (let* ((chat (and slug (agent-info slug) (agent-buf slug)))
         (group (and chat (buffer-group chat)))
         (verb (or (permission-denied-verb? raw)
                   (car (mcp-proxy--action slug name args-json raw)))))
    (and group (not (equal? verb "eval-scheme")) (list group verb))))

(define (mcp-proxy--granted? slug name args-json raw)
  (let ((key (mcp-proxy--grant-key slug name args-json raw)))
    (and key
         (member (cadr key) (or (group-setting (car key) 'always-verbs) '()))
         #t)))

(define (mcp-proxy--grant! slug name args-json raw)
  (let ((key (mcp-proxy--grant-key slug name args-json raw)))
    (when key
      (let ((verbs (or (group-setting (car key) 'always-verbs) '())))
        (unless (member (cadr key) verbs)
          (group-setting-set! (car key) 'always-verbs (cons (cadr key) verbs)))))))

(define (mcp-proxy--refused raw verdict)
  (base64-encode
    (decide-refusal 'policy
      (or (permission-denied-verb? raw) (symbol->string verdict)))))

;; A lone shell command, run off the lane with RESOLVE taking its output.
;; It runs in the sandbox of the chat it came from: the edit author is not
;; set on this path, so the chat comes from AUTHOR or the current buffer.
(define (mcp-proxy--shell-run! parts author resolve)
  (let* ((chat (or (and author (string-prefix? "agent:" author)
                        (agent-buf (substring author 6 (string-length author))))
                   (and (agent-slug-of (current-buffer)) (current-buffer))))
         (cmd (if (boundp (quote agent-sandbox-wrap))
                  (agent-sandbox-wrap (car parts) chat)
                  (car parts)))
         (run (if (boundp (quote %shell-command->string-builtin))
                  %shell-command->string-builtin
                  shell-command->string)))
    (let ((dir (or (cadr parts)
                   (and chat (with-current-buffer chat default-directory)))))
      (if dir
          (run cmd dir resolve)
          (run cmd resolve)))))

(define (mcp-proxy--run name args-json author)
  ;; The async lane. An eval-scheme payload whose whole program is
  ;; one shell command must not hold the Session for its runtime —
  ;; this is the exact payload behind every logged Session timeout.
  ;; eval-defer! keeps the caller's reply slot, the command runs in
  ;; a Task, and eval-resolve! answers with the output when the
  ;; command ends. Keys, saves and other evals run meanwhile.
  (let* ((parts (and (equal? name "eval-scheme")
                     (mcp-proxy--shell-code args-json)))
         (read-only? (llm-tool-read-only? name))
         (token (and (or parts read-only?) (eval-defer!))))
    (cond
      ((and token parts)
        (let ((resolve (lambda (out)
                         (eval-resolve! token
                           (base64-encode (value->string out))))))
          (mcp-proxy--shell-run! parts author resolve)
          'pending))
      ((and token read-only?)
       ;; the task answers the caller itself. The callback runs on a lane
       ;; with a time limit, and a callback that never ran left the proxy
       ;; waiting ten minutes. It now only reports an error; eval-resolve!
       ;; answers once, so a second resolve does nothing.
       (task-run!
         (lambda ()
           (eval-resolve! token
             (base64-encode (mcp-proxy--sync name args-json author))))
         (lambda (ok value)
           (unless ok
             (eval-resolve! token
               (base64-encode (string-append "error: " (value->string value)))))))
       'pending)
      (else
        (base64-encode (mcp-proxy--sync name args-json author))))))

;; Ask, on a lane that has no backend to ask through. This arm did not
;; exist: the cond ran allow and refused everything else, so a verdict of
;; ask fell into the refusal — the policy said "stop and ask" and the lane
;; answered no, with no card and nothing for the user to answer. The proxy
;; raises the card itself now, through the same door the ACP lane uses.
;; The wait happens in a Task behind eval-defer!, so the Session stays
;; free while the card sits there, and the chat's own C-c C-y / C-c C-n
;; answer it like any other.
;; What the card says: why this call stopped and what it will do, so the
;; answer is a decision and not a guess. The tool's name alone is not.
(define (mcp-proxy--shell-commands x)
  "the command strings of every shell call in the read payload X, in order"
  (cond ((not (pair? x)) '())
        ((and (member (car x) decide--shell-symbols) (pair? (cdr x)) (string? (cadr x)))
         (cons (if (and (pair? (cddr x)) (string? (caddr x)))
                   (string-append (cadr x) "   [in " (abbreviate-file-name (caddr x)) "]")
                   (cadr x))
               (mcp-proxy--shell-commands (cddr x))))
        (else (append (mcp-proxy--shell-commands (car x))
                      (mcp-proxy--shell-commands (cdr x))))))

(define (mcp-proxy--clip s n)
  (if (> (string-length s) n) (string-append (substring s 0 n) " ...") s))

;; What the always-ask patterns read in an eval: the name of every call
;; and the command of every shell call, not the payload's text. A string,
;; a comment or quoted data names no action, and must not raise a card.
;; Code that does not read is matched as it came: that fails closed.
(define (mcp-proxy--calls x)
  "the head names of every call in the read payload X, quoted data left out"
  (cond ((not (pair? x)) '())
        ((equal? (car x) 'quote) '())
        (else (append (if (symbol? (car x)) (list (symbol->string (car x))) '())
                      (apply append (map mcp-proxy--calls x))))))

(define (mcp-proxy--call-text name args-json)
  (let* ((raw (string-append name " " args-json))
         (code (and (equal? name "eval-scheme") (mcp-proxy--code args-json)))
         (forms (and code (ignore-errors (lambda () (scheme-read code))))))
    (if (pair? forms)
        (string-join (cons name (append (mcp-proxy--calls forms)
                                        (mcp-proxy--shell-commands forms)))
                     " ")
        raw)))

(define (mcp-proxy--smallest x pat)
  "the smallest list in the read payload X whose text PAT matches, or #f"
  (and (pair? x)
       (re-match? pat (string-downcase (value->string x)))
       (or (let loop ((ys x))
             (and (pair? ys)
                  (or (mcp-proxy--smallest (car ys) pat) (loop (cdr ys)))))
           x)))

;; (mcp-proxy--action SLUG NAME ARGS-JSON RAW) -> (VERB TARGET)
;; What made this call ask, and what it acts on: the card names both, and
;; Always is kept for exactly that pair. A shell command without a
;; directory runs in the chat's, so the target says which.
(define (mcp-proxy--action slug name args-json raw)
  (let* ((code (and (equal? name "eval-scheme") (mcp-proxy--code args-json)))
         (forms (and code (ignore-errors (lambda () (scheme-read code)))))
         (cmds (if (pair? forms) (mcp-proxy--shell-commands forms) '()))
         (pat (permission-denied-verb? raw))
         (hit (and pat (re-match pat (string-downcase raw))))
         (kind (and code (pair? cmds) (not pat) (decide--shell-kind-seen code)))
         (verb (cond (hit (string-trim (car hit)))
                     (kind (string-append "shell " (symbol->string kind)))
                     (else name)))
         (shell (if pat
                    (filter (lambda (c) (re-match? pat (string-downcase c))) cmds)
                    cmds))
         (chat (and slug (agent-info slug) (agent-buf slug)))
         (dir (and chat (with-current-buffer chat default-directory)))
         (in (lambda (c)
               (if (or (re-match? "   \\[in " c) (not dir))
                   c
                   (string-append c "   [in " (abbreviate-file-name dir) "]"))))
         (form (and pat (null? shell) (pair? forms) (mcp-proxy--smallest forms pat)))
         (target (cond ((pair? shell) (string-join (map in shell) "  ;  "))
                       (form (value->string form))
                       (code (first-line code))
                       (else args-json))))
    (list verb (mcp-proxy--clip target 300))))

(define (mcp-proxy--ask-title slug name args-json raw)
  (let ((action (mcp-proxy--action slug name args-json raw)))
    (string-append (car action) ": " (cadr action))))

(define (mcp-proxy--ask slug name args-json author raw)
  (let ((token (eval-defer!)))
    (task-run!
      (lambda () (agent-ask-permission! slug (mcp-proxy--ask-title slug name args-json raw)
                                         raw permission-ask-timeout-ms))
      (lambda (ok answer)
        (cond
          ((not ok)
           (eval-resolve! token
             (base64-encode (string-append "error: " (value->string answer)))))
          ((member answer '(allow always))
           ;; the grant is recorded HERE, on the Session, where the
           ;; global lives — the Task that waited has its own heap
           (when (equal? answer 'always)
             (mcp-proxy--grant! slug name args-json raw))
           (mcp-proxy--run-approved token name args-json author))
          (else
           (eval-resolve! token
             (base64-encode (decide-refusal 'denied (mcp-proxy--shell-kind name args-json))))))))
    'pending))

;; The approved call. A lone shell command runs in its own Task, as any
;; shell command does, so an install that takes minutes is not killed at the
;; shell time limit. Anything else runs here, and the shell gate lets this
;; one payload through while it does.
(define (mcp-proxy--run-approved token name args-json author)
  (let ((parts (and (equal? name "eval-scheme") (mcp-proxy--shell-code args-json))))
    (if parts
        (let ((resolve (lambda (out)
                         (eval-resolve! token (base64-encode (value->string out))))))
          (mcp-proxy--shell-run! parts author resolve))
        (let ((code (mcp-proxy--code args-json))
              (gate? (boundp (quote decide-shell-approve!))))
          (when (and code gate?) (decide-shell-approve! code))
          (let ((out (mcp-proxy--sync name args-json author)))
            (when gate? (decide-shell-approve! #f))
            (eval-resolve! token (base64-encode out)))))))

(define (mcp-proxy--code args-json)
  (let ((args (json-parse args-json)))
    (and args
         (let ((code (plist-get args 'code)))
           (and (string? code) code)))))

;; The shell gate's ask. A payload permit? lets through still stops here
;; when decide-shell-policy asks for its kind of shell command; a refusal
;; from permit? stays a refusal.
(define (mcp-proxy--shell-ask name args-json verdict)
  (if (and (member verdict '(allow allow-always))
           (equal? name "eval-scheme")
           (boundp (quote decide-shell-asks?))
           (decide-shell-asks? (mcp-proxy--code args-json)))
      'ask
      verdict))

;; The shell gate's refusal. A kind the policy refuses stays refused
;; whatever the permission mode or an Always granted: the ask above only
;; turns an allow into an ask, so without this a refuse let the call run.
(define (mcp-proxy--shell-kind name args-json)
  "(mcp-proxy--shell-kind NAME ARGS-JSON) — the kind of shell command (read, edit, ...) an eval-scheme call runs, or #f"
  (and (equal? name "eval-scheme")
       (boundp (quote decide-shell-verdict))
       (let ((code (mcp-proxy--code args-json)))
         (and code (decide-shell-calls? code) (decide--shell-kind-seen code)))))

(define (mcp-proxy--shell-refusal name args-json)
  (and (equal? name "eval-scheme")
       (boundp (quote decide-shell-verdict))
       decide-shell-gate
       (let ((code (mcp-proxy--code args-json)))
         (and code
              (decide-shell-calls? code)
              (let* ((kind (decide--shell-kind-seen code))
                     (rule (and kind (assq kind decide-shell-policy))))
                (and rule (equal? (cadr rule) 'refuse)
                     (decide-refusal kind)))))))

(define (mcp-proxy-call name args-b64 &optional author)
  (let* ((args-json (base64-decode args-b64))
         (raw (mcp-proxy--call-text name args-json))
         ;; the author names the thread when one is attributed; otherwise
         ;; the chat this eval runs in is the one that has to answer
         (slug (or (and author (string-prefix? "agent:" author)
                        (substring author 6 (string-length author)))
                   (agent-slug-of (current-buffer))))
         ;; a read the gate refuses and can say in Scheme runs as Scheme
         (answer (and (equal? name "eval-scheme")
                      (boundp (quote decide-shell-read-answer))
                      (decide-shell-read-answer (mcp-proxy--code args-json))))
         (refusal (and (not answer) (mcp-proxy--shell-refusal name args-json)))
         (verdict (cond ((or answer refusal) 'deny)
                        ((mcp-proxy--granted? slug name args-json raw) 'allow-always)
                        (else (mcp-proxy--shell-ask name args-json
                                (permit? #f name "tool"
                                         (or (and (equal? name "eval-scheme")
                                                  (mcp-proxy--code args-json))
                                             raw)))))))
    (cond
      (answer (base64-encode answer))
      (refusal (base64-encode refusal))
      ((member verdict '(allow allow-always))
       (mcp-proxy--run name args-json author))
      ((and (equal? verdict 'ask) slug (agent-info slug))
       (mcp-proxy--ask slug name args-json author raw))
      ;; no chat to ask in means nobody can answer, and the honest
      ;; answer to an unanswerable ask is still no
      (else
        (mcp-proxy--refused raw verdict)))))

;; the inline path, with the agent's edits attributed to its thread
(define (mcp-proxy--sync name args-json author)
  (if author
      (let* ((slug (and (string-prefix? "agent:" author)
                        (substring author 6 (string-length author))))
             (buf (and slug (agent-buf slug)))
             ;; same burst boundary as a chat tool call: the proxy call ends,
             ;; what it wrote is on disk
             (call (lambda ()
                     (if (boundp (quote jj-with-burst))
                         (jj-with-burst author
                           (lambda () (mcp-proxy-dispatch name args-json)))
                         (mcp-proxy-dispatch name args-json)))))
        (if (and buf (buffer-exists? buf))
            (with-current-buffer buf
              (lambda () (with-edit-author author call)))
            (with-edit-author author call)))
      (mcp-proxy-dispatch name args-json)))

;; (mcp-proxy--shell-code ARGS-JSON) -> (CMD DIR|#f) | #f
;; #f unless the payload's code is one (shell-command->string ...) form
;; with a literal CMD. DIR can be a literal string, the exact form
;; (default-directory), or absent.
(define (mcp-proxy--shell-code args-json)
  (let ((args (json-parse args-json)))
    (and args
         (let ((code (plist-get args 'code)))
           (and (string? code) (mcp-proxy--shell-parts code))))))

(define (mcp-proxy--shell-parts code)
  (let* ((forms (scheme-read code))
         (form (and (pair? forms) (null? (cdr forms)) (car forms))))
    (and (pair? form)
         (equal? (car form) 'shell-command->string)
         (pair? (cdr form))
         (string? (cadr form))
         (let ((rest (cddr form)))
           (cond
             ((null? rest) (list (cadr form) #f))
             ((and (pair? rest) (null? (cdr rest)) (string? (car rest)))
              (list (cadr form) (car rest)))
             ((and (pair? rest) (null? (cdr rest))
                   (equal? (car rest) '(default-directory)))
              ;; the chat's directory, found where the command runs:
              ;; here the Session's current buffer is not the chat
              (list (cadr form) #f))
             (else #f))))))

;; This surface serves mcp-proxy-tools-json — the Scheme registry — so
;; every name it dispatches is a Scheme handler, and a Scheme handler runs
;; in the session by definition. (The "never dispatch in the session" rule
;; in mcp.ex is about MCP tools, which this surface does not expose;
;; mcp-call! already obeys it for those.)
;; The proxy reads this prefix as "the rest is a JSON array of MCP content
;; blocks". A NUL never starts a text result, so plain text passes as is.
(define mcp-proxy-content-prefix "\x00;compos-content\n")

(define (mcp-proxy-dispatch name args-json)
  (let ((r (llm-tool-call name (json-parse args-json))))
    (cond ((string? r) r)
          ((tool-content? r)
           (string-append mcp-proxy-content-prefix (json-encode (cadr r))))
          (else (value->string r)))))

(category! 'chat)
(public! 'define-tool! "(define-tool! 'name DESC PARAMS HANDLER) — register an LLM tool")
(public! 'llm-with-tools "(llm-with-tools PROMPT HANDLER) — completion with the full tool loop")

;; chat integration: chat-send routes through llm-with-tools when this is on
(defcustom 'chat-use-tools #t
  "When true, the *chat* buffer's LLM can act on the editor via tools."
  'group 'chat 'type 'boolean)

;; How long the provider holds a cached prefix. The default five minutes
;; expires while the user reads the reply, so the next turn pays the write
;; surcharge on the whole transcript again. An hour covers a sitting.
;; Anthropic bills a longer TTL at a higher write rate, so "5m" is the
;; cheaper choice for a chat answered in bursts.
(defcustom 'llm-cache-ttl "1h"
  "How long the provider holds this chat's cached prompt prefix: \"5m\" or \"1h\"."
  'group 'chat 'type 'string
  'set (lambda (v) (set-llm-cache-ttl! v)))

(set-llm-cache-ttl! llm-cache-ttl)

;; Compaction: the head of a long record becomes one summary and the
;; recent turns stay verbatim. You ask for it — M-x chat-compact — and the
;; two knobs below only decide when the editor SUGGESTS it.
;;
;; It fired by itself, at a flat 60000 tokens, until the prompt cache
;; started working. A cached prefix costs a tenth of a fresh one, so
;; resending a long chat is cheap while a compaction pays for the summary
;; AND rewrites the cache. What remains is the model's input limit: past
;; it every request fails, and no cache rate helps.
;;
;; So the suggestion follows the model. A flat count cannot be right
;; across models whose limits differ by more than ten times: 200000
;; tokens is a fifth of one model's window and twice another's.
;; The mechanism is in editor.scm (chat-compact-limit, chat-compact!).
(defcustom 'chat-compact-percent 70
  "Suggest compacting a chat once its record passes this percent of the model's input limit. 0 stays quiet."
  'group 'chat 'type 'integer)

(defcustom 'chat-compact-threshold 0
  "Suggest compacting at this flat token count, whatever the model allows. 0 uses chat-compact-percent."
  'group 'chat 'type 'integer)

(defcustom 'chat-compact-keep 8
  "How many recent turns a compaction keeps verbatim."
  'group 'chat 'type 'integer)
