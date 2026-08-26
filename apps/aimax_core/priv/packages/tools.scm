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
;; modifiers (external, execute, spend). The catalog entry carries it,
;; and *permission-policy* reads it from there.
(define (define-tool! name description params handler &optional effects)
  (set! *llm-tools*
    (cons (list name (list 'description description 'params params 'handler handler
                           'effects (or effects '(unknown))))
          (remove (lambda (t) (equal? (car t) name)) *llm-tools*)))
  (if effects
      (catalog-register! 'tool name description 'effects effects)
      (catalog-register! 'tool name description))
  name)

(define (llm-tool-specs)
  (map (lambda (t)
         (list (symbol->string (car t))
               (custom--plist-get (cadr t) 'description)
               (custom--plist-get (cadr t) 'params)
               (custom--plist-get (cadr t) 'effects)))
       (reverse *llm-tools*)))

(define (llm-tool-call name args)
  (let ((t (assoc (string->symbol name) *llm-tools*)))
    (if t
        ((custom--plist-get (cadr t) 'handler) args)
        (string-append "no such tool: " name))))

(define (llm-tool-read-only? name)
  (let* ((tool (assoc (string->symbol name) *llm-tools*))
         (effects (and tool (custom--plist-get (cadr tool) 'effects))))
    (and (pair? effects) (member (car effects) '(pure read)) #t)))

;; the standing context every tool-enabled request carries — the "skill"
(define *llm-system*
  (string-append
    "You are the assistant inside ai-max, an Emacs-style editor scripted in "
    "Scheme, and you act on the live editor through eval-scheme — one tool, "
    "the whole editor. Appearance and behavior are controlled by "
    "customizable variables and faces; changes made through customize "
    "persist across restarts. To change how something looks: discover the "
    "knob with (customize-apropos \"font\"), set it with "
    "(customize-save! 'name value), then confirm briefly what you "
    "changed. IMPORTANT: the "
    "language is ai-max's own small Scheme, NOT Emacs Lisp — elisp names "
    "like get-buffer, set-buffer, goto-char, point-max, insert and "
    "save-excursion do not exist. Core API: "
    "(buffer-list) names; (buffer-text NAME); (buffer-append! NAME TEXT) "
    "append to any buffer — the usual way to add text; (buffer-create NAME); "
    "(buffer-replace! NAME OLD NEW) exact unique replacement in a live "
    "buffer; (find-file PATH) loads a file without displaying it; "
    "(switch-to-buffer! NAME) changes only the tool's internal current "
    "buffer; (with-current-buffer NAME THUNK) scopes that internal switch; "
    "(current-buffer); "
    "(insert! TEXT) at point in the current buffer; (message TEXT) echoes; "
    "(run-command \"name\") runs any M-x command. File buffers are named by "
    "full path. Discovery is ONE call: apropos searches the public API, "
    "M-x commands, keybindings, settings, recipes, modes and UI components "
    "by WORDS — (apropos \"split window\"), not a regex. Filter with kind, "
    "package, namespace, domain, or effect. Effects are pure/read/write/"
    "destroy/spend/execute/external: prefer pure/read while investigating "
    "and inspect consequential calls before using them. apropos-categories "
    "shows the shape of the surface first. Everything "
    "outside the public API is private implementation detail; reach for it "
    "with scope \"all\" plus describe-function only when nothing public "
    "fits. Before writing code with a name you are not sure exists, check "
    "it with apropos, and read any function's real source with "
    "describe-function. "
    "For repository work, do not open an interactive shell or recursively "
    "dump the tree. Start with (default-directory), then use "
    "(git-root (default-directory)), (project-files ROOT), "
    "(project-search-matches ROOT PATTERN), and "
    "(read-file-numbered PATH). These return bounded evidence directly; "
    "the numbered reader is the source of truth for line citations. "
    "For source code, read the structure before the text. "
    "(code-outline BUF) lists every definition as (LINE KIND NAME DOC), "
    "where DOC is the docstring or the first line; "
    "(code-find BUF TEXT) filters those rows; (code-read BUF LINE) returns "
    "the one definition that holds LINE; (code-replace! BUF LINE NEW) "
    "swaps it. Below a definition, (code-sexp BUF ANCHOR) returns the "
    "smallest expression that spans that unique text, and "
    "(code-sexp-replace! BUF ANCHOR NEW) replaces it; an optional LEVELS "
    "argument widens the selection by parents. Do not call buffer-text on "
    "a whole source file when the outline answers the question. "
    "When several independent read tools are needed, issue up to four in "
    "the same tool round; the editor evaluates read-only tools concurrently. "
    "Run a focused external check directly with "
    "(shell-command->string CMD (default-directory)); it returns stdout and "
    "stderr together. Use an interactive shell buffer only when the task "
    "actually requires an ongoing process. "
    "When you WRITE Scheme, stamp every public section with (domain! 'NAME) "
    "and (effects! '(LEVEL MODIFIERS...)). LEVEL is pure, read, write, "
    "destroy, or unknown; modifiers are external, execute, and spend. Never "
    "use read as a guess. The loader stamps package and namespace. Before "
    "writing a Scheme package, query apropos for existing APIs and components. "
    "Before choosing or defining UI, read docs/COMPONENTS.md and reuse a catalogued "
    "component when it fits. "
    ;; without this the assistant tells people it has no browser, while
    ;; sitting on a wire to one — apropos would find these, but only if
    ;; it thinks to look
    "You CAN drive the user's Chrome, when the ai-max extension is "
    "attached — check (browser-connected?). (tab-list K) gives every open "
    "tab as plists with id/title/url; (tab-open URL) opens one beside this "
    "chat, in the same browser window; "
    "(tab-activate TAB) brings one to the front; (tab-read TAB K) gives its "
    "visible text; (tab-eval TAB CODE K) runs JS in it; (tab-say TAB TEXT) "
    "puts a line on its screen; (tab-type TAB TEXT) and (tab-click TAB X Y) "
    "are real trusted input. These are async: they take a continuation K "
    "rather than returning. Use (apropos \"tab\") for the full set. "
    "Keep replies short; the user is in an editor."))

(define (llm-with-tools prompt handler)
  (llm-tools prompt *llm-system* (llm-tool-specs) llm-tool-call handler))

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
    (let* ((type (string->symbol (custom--plist-get args 'type)))
           (raw (custom--plist-get args 'id))
           (id (if (string-prefix? "thread:" raw)
                   (substring raw 7 (string-length raw))
                   raw))
           (a (assoc (custom--plist-get args 'action) (actions-for type))))
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
    (take-n (append (pick 0) (pick 1) (pick 2) prefix) 3)))

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
                          (tool--format-suggestions (take-n named 5))))))
    (else "")))

(define-tool! 'eval-scheme
  "Evaluate Scheme in the live editor session. Full editor API: buffers, windows, faces, modes, customize. NOT Emacs Lisp — verify unfamiliar names with apropos first. Returns the printed value; on an unbound name the error suggests the nearest real API."
  (list (list 'code "string" "Scheme source to evaluate"))
  (lambda (args)
    (let* ((code (custom--plist-get args 'code))
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

(define-tool! 'describe-function
  "Read a function's actual implementation. Userland functions and M-x commands return their full Scheme source (most of the editor — dired, org, chat, modes — is userland); builtins are Elixir and return only a marker. Use it to understand how something works before changing it."
  (list (list 'name "string" "Function or command name, e.g. chat-send or face-remap!"))
  (lambda (args)
    (describe-function (string->symbol (custom--plist-get args 'name))))
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
  '("a" "an" "and" "current" "do" "for" "how" "i" "in" "my" "of"
    "please" "the" "this" "to" "with"))

(domain! 'discovery)
(effects! '(read))

(defcustom 'apropos-semantic-search #t
  "Use OpenAI embeddings to add semantic apropos results when an OpenAI key exists."
  'group 'discovery)

(defcustom 'apropos-semantic-limit 24
  "The maximum semantic results that apropos reads from the embedding index."
  'group 'discovery)

(defcustom 'apropos-semantic-threshold 0.30
  "The minimum cosine similarity for an apropos semantic result."
  'group 'discovery)

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
         (doc (or (custom--plist-get rec 'doc) "")))
    (and (apropos--hit? (string-append name " " doc) words)
         (apropos--enrich (list 'kind "variable" 'name name 'doc doc)
                          "setting" index))))

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
  (let ((kind (catalog--get e 'kind)))
    (and (member kind '("component" "mode" "note"))
         (apropos--hit?
           (string-append (apropos--catalog-field e 'name) " "
                          (apropos--catalog-field e 'qualified-name) " "
                          (apropos--catalog-field e 'doc) " "
                          (apropos--catalog-field e 'package) " "
                          (apropos--catalog-field e 'namespace) " "
                          (apropos--catalog-field e 'domain) " "
                          (value->string (or (catalog--get e 'props) '())) " "
                          (value->string (or (catalog--get e 'example) '())))
           words)
         e)))

;; One row is (LOWERCASED-SEARCH-TEXT HIT). The original registry order is
;; retained because it is the stable fallback order after ranking buckets.
(define (apropos--rows index)
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
              (map (lambda (e) (apropos--catalog-entry e '())) (catalog))))))
    (map (lambda (hit) (list (string-downcase (value->string hit)) hit)) hits)))

(define (apropos--row-hit? row words)
  (apropos--hit? (car row) words))

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
  (append
    (if (boundp (quote recipe-search)) (recipe-search "") '())
    (map (lambda (row) (car (cdr row))) rows)))

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
    ". Usage: " (or (plist-get hit 'use) (plist-get hit 'run) "")))

(define (apropos--semantic-hits query rows filters)
  (let ((key (and apropos-semantic-search
                  (boundp (quote llm-key))
                  (llm-key "openai"))))
    (if (or (not key) (equal? key "") (equal? (string-trim query) ""))
        '()
        (let* ((sources (apropos--semantic-sources rows))
               (texts (map apropos--embedding-text sources))
               (eligible (map (lambda (hit) (apropos--filter-match? hit filters)) sources))
               (semantic-query (string-append "Find the editor API for this task: " query))
               (scores (embedding-search semantic-query texts key
                                         apropos-semantic-limit eligible)))
          (map (lambda (score)
                 (append (nth (car score) sources)
                         (list 'note "semantic match" 'semantic-score (nth 1 score))))
               (filter (lambda (score) (>= (nth 1 score) apropos-semantic-threshold))
                       scores))))))

(define (apropos-rebuild-embeddings!)
  (let ((path (embedding-cache-clear!))
        (key (and (boundp (quote llm-key)) (llm-key "openai"))))
    (if (or (not key) (equal? key ""))
        (string-append "Cleared " path "; no OpenAI key is configured.")
        (begin
          ;; This result is discarded. The embedding mechanism still indexes
          ;; every current source before it selects the small result set.
          (apropos--semantic-hits "editor API discovery" (apropos--rows-cached) '())
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
        (effect (apropos--filter filters 'effect)))
    (and (or (not kind) (equal? (plist-get hit 'kind) (catalog--string kind)))
         (or (not package) (equal? (plist-get hit 'package) (catalog--string package)))
         (or (not namespace) (equal? (plist-get hit 'namespace) (catalog--string namespace)))
         (or (not domain) (equal? (plist-get hit 'domain) (catalog--string domain)))
         (or (not effect) (member (catalog--string effect) (or (plist-get hit 'effects) '()))))))

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
                semantic))))

(define (apropos--rank-by-name hits query)
  (let* ((q (string-downcase (string-trim query)))
         (name-of (lambda (h)
                    (string-downcase
                      (or (plist-get h 'qualified-name)
                          (plist-get h 'name) (plist-get h 'task) ""))))
         (short-of (lambda (h)
                     (string-downcase (or (plist-get h 'name) (plist-get h 'task) ""))))
         (exact? (lambda (h) (or (equal? q (name-of h)) (equal? q (short-of h)))))
         (recipe? (lambda (h) (equal? (plist-get h 'kind) "recipe")))
         (prefix? (lambda (h)
                    (or (string-prefix? q (name-of h))
                        (string-prefix? q (short-of h)))))
         (exact (filter exact? hits))
         (recipes (filter (lambda (h) (and (not (exact? h)) (recipe? h))) hits))
         (prefixes (filter (lambda (h)
                            (and (not (exact? h)) (not (recipe? h)) (prefix? h))) hits))
         (rest (filter (lambda (h)
                         (and (not (exact? h)) (not (recipe? h)) (not (prefix? h)))) hits)))
    (append exact recipes prefixes rest)))

;; an internal entry carries its doc when the primitive has one; a bare
;; userland define stays a bare name — describe-function has its source
(define (apropos--internal n doc words)
  (and (apropos--hit? (if doc (string-append n " " doc) n) words)
       (if doc (list 'kind "internal" 'name n 'doc doc) n)))

;; QUERY is words, not a regex: "split window", "open a file", "chat cost".
;; Recipes come first: a task-level hit beats four name-level ones, and it
;; is the answer the caller actually wanted.
(define (apropos query &rest filters)
  ;; Build rows first. Their single-flight refresh also publishes the index.
  ;; The next lookup is then a cheap read of the same catalog generation.
  (let ((rows (apropos--rows-cached)))
    (apropos--search query filters (apropos--index-cached) rows)))

(define (apropos--search query filters index rows)
  (let* ((words (apropos--words query))
         (recipes (if (boundp (quote recipe-search)) (recipe-search query) '()))
         (literal-rows (filter (lambda (row) (apropos--row-hit? row words)) rows))
         (literal-hits (append recipes (map (lambda (row) (car (cdr row))) literal-rows)))
         (suggestions (if (pair? literal-hits) '()
                          (apropos--name-suggestions query words index)))
         (semantic-hits
           (filter (lambda (hit)
                     (and (not (apropos--has-hit? literal-hits hit))
                          (not (apropos--has-hit? suggestions hit))))
                   (apropos--semantic-hits query rows filters)))
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
  "(apropos QUERY &rest FILTERS) — hybrid literal/semantic catalog search; accepts kind/package/namespace/domain/effect filters. The public call shape is unchanged.")
(catalog-meta! 'function "apropos" 'domain 'discovery 'effects '(read external spend))
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
    "signatures, M-x commands with their docstrings, keybindings, and "
    "settings. Literal matches rank first. OpenAI embeddings add semantic matches, so "
    "\"split window\" finds the window splitters and \"chat cost\" finds "
    "the cost commands. This is the supported surface and the place to "
    "start. Nothing matched? You get the closest names instead. Pass "
    "kind/package/namespace/domain/effect narrow the catalog. Pass "
    "category as a compatibility alias for domain, or scope \"all\" to include "
    "the internal primitives, one-line docs only, which may change "
    "without notice.")
  (list (list 'query "string" "intent words, e.g. \"open a file\" or \"remove document\"")
        (list 'kind "string" "function, command, key, variable, recipe, mode, or component" 'optional)
        (list 'package "string" "owning load unit" 'optional)
        (list 'namespace "string" "stable public vocabulary" 'optional)
        (list 'domain "string" "subject area, e.g. windows or buffers" 'optional)
        (list 'effect "string" "pure, read, write, destroy, spend, execute, or external" 'optional)
        (list 'category "string" "deprecated alias for domain" 'optional)
        (list 'scope "string" "\"public\" (default) or \"all\"" 'optional))
  (lambda (args)
    (let ((q (or (custom--plist-get args 'query) ""))
          (cat (custom--plist-get args 'category))
          (kind (custom--plist-get args 'kind))
          (package (custom--plist-get args 'package))
          (namespace (custom--plist-get args 'namespace))
          (domain (custom--plist-get args 'domain))
          (effect (custom--plist-get args 'effect))
          (scope (or (custom--plist-get args 'scope) "public")))
      (let ((filters
              (append (if kind (list 'kind kind) '())
                      (if package (list 'package package) '())
                      (if namespace (list 'namespace namespace) '())
                      (if (or domain cat) (list 'domain (or domain cat)) '())
                      (if effect (list 'effect effect) '()))))
        (value->string
          (if (equal? scope "all")
              (let ((words (apropos--words q)))
                (list 'public (apply apropos (cons q filters))
                      'globals (apropos--compact
                                 (map (lambda (n)
                                        (apropos--internal n (primitive-doc n) words))
                                      (global-names)))))
              (apply apropos (cons q filters)))))))
  '(read external spend))

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

;;; --- hello: the cold start ------------------------------------------------------
;;; An agent that connects to the socket used to learn nothing: it got a
;;; prompt and no idea what was on the other end. (hello) is the primer —
;;; what this is, the one call that answers everything else, and the
;;; category list so the next question can name an area instead of
;;; guessing. The RPC server answers `initialize` with the same text, so a
;;; cold client is one round-trip from being able to work.

(define (hello)
  (string-append
    "ai-max — an Emacs-style editor on the BEAM, scripted in this Scheme. "
    "Everything the GUI can do, you can do: eval is the whole API.\n\n"
    "DISCOVERY — one call:\n"
    "  (apropos \"words\")        search functions, commands, keys and "
    "settings, recipes, modes and components by WORDS, not regex.\n"
    "  (apropos \"\" 'domain 'windows) lists one subject area.\n"
    "  Add 'effect 'read/write/destroy/spend to choose safely.\n"
    "  (describe-function 'NAME) read the real source.\n\n"
    "WORKFLOW — search once, then act:\n"
    "  1. Reuse API names and recipes already present in this primer, an "
    "earlier tool result, or an eval error; do not rediscover them.\n"
    "  2. For an unfamiliar operation, call apropos once with the shortest "
    "task-level query. Choose the best hit and run its use expression with "
    "eval-scheme.\n"
    "  3. Search again only when there was no relevant hit, or eval-scheme "
    "reported an unbound name or arity error. Never repeat an equivalent "
    "search after a usable hit.\n"
    "  4. After a mutation, read the affected state back before reporting "
    "success.\n\n"
    "REPOSITORY READS — exact evidence, no guessing:\n"
    "  (default-directory)                     current task workspace.\n"
    "  (git-root (default-directory))          repository root for that workspace.\n"
    "  (project-files ROOT)                    tracked and unignored files.\n"
    "  (project-search-matches ROOT PATTERN)   structured PATH/LINE matches.\n"
    "  (read-file-numbered PATH)               source text with citation lines.\n\n"
    "STRUCTURAL CODE — outline first, then one definition:\n"
    "  (code-outline BUF)                      every definition as (LINE KIND NAME DOC).\n"
    "  (code-find BUF TEXT)                    the rows whose name or doc contains TEXT.\n"
    "  (code-read BUF LINE)                    the one definition that holds LINE.\n"
    "  (code-replace! BUF LINE NEW)            swap that whole definition.\n"
    "  (code-sexp BUF ANCHOR [LEVELS])         the smallest expression around unique ANCHOR text.\n"
    "  (code-sexp-replace! BUF ANCHOR NEW [LEVELS]) replace that expression.\n"
    "  Do not read a whole source buffer when the outline answers.\n\n"
    "FOCUSED EXTERNAL CHECKS:\n"
    "  (shell-command->string CMD (default-directory))\n"
    "                                              run once; stdout+stderr returned.\n\n"
    "Categories: " (string-join (map symbol->string (public-categories)) ", ") "\n\n"
    "NOTE: this is ai-max's own small Scheme, NOT Emacs Lisp. Names like "
    "get-buffer, goto-char, save-excursion and with-current-buffer do not "
    "exist. When a name is not already documented above, check it with "
    "apropos before use; an unbound name comes back with the nearest real "
    "ones and their signatures.\n\n"
    (if (boundp (quote recipes-text)) (recipes-text) "")))

(category! 'discovery)
(public! 'hello "(hello) — what this editor is and how to find anything in it")

;; Source citations are a common agent read, and byte offsets or guessed line
;; counts are the wrong policy. Keep numbering in Scheme over the ordinary
;; read-file mechanism so every caller gets stable, inspectable text.
(define (line-numbered-text source)
  (let loop ((lines (string-split source "\n")) (n 1) (out '()))
    (if (null? lines)
        (string-join (reverse out) "\n")
        (loop (cdr lines) (+ n 1)
              (cons (string-append (number->string n) "\t" (car lines)) out)))))

(define (read-file-numbered path)
  (let ((source (read-file path)))
    (if source (line-numbered-text source) #f)))

(public! 'read-file-numbered
  "(read-file-numbered PATH) — read source text files with stable line numbers for exact citations")
(catalog-meta! 'function "read-file-numbered" 'domain 'discovery 'effects '(read))

(define-tool! 'read-file
  "Read one source file with stable line numbers for exact citations. Independent read-file, apropos, describe-function, code-outline, and code-read calls can be issued together and run concurrently."
  (list (list 'path "string" "absolute or workspace-relative source file path"))
  (lambda (args)
    (let ((result (read-file-numbered (custom--plist-get args 'path))))
      (if result result "error: file does not exist or cannot be read")))
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
;;; aimax-mcp-proxy.exs bridges stdio MCP to the daemon socket and calls
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
;; author: the proxy sends its thread's slug (AIMAX_AGENT), so edits an
;; external agent makes through this bridge land in buffer-authors
(define (mcp-proxy-call name args-b64 &optional author)
  (let* ((args-json (base64-decode args-b64))
         (raw (string-append name " " args-json))
         (verdict (if (boundp (quote *permission-policy*))
                      (*permission-policy* #f name "tool" raw)
                      'allow)))
    (cond
      ((member verdict '(allow allow-always))
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
               (if (cadr parts)
                   (shell-command->string (car parts) (cadr parts) resolve)
                   (shell-command->string (car parts) resolve))
               'pending))
           ((and token read-only?)
            (task-run!
              (lambda ()
                (base64-encode (mcp-proxy--sync name args-json author)))
              (lambda (ok value)
                (eval-resolve! token
                  (if ok value
                      (base64-encode (string-append "error: " (value->string value)))))))
            'pending)
           (else
             (base64-encode (mcp-proxy--sync name args-json author))))))
      (else
        (base64-encode
          (string-append
            "refused: aimax's permission policy did not allow this ("
            (or (and (boundp (quote permission-denied-verb?))
                     (permission-denied-verb? raw))
                (symbol->string verdict))
            "). Ask the user to run it, or to approve it in the chat."))))))

;; the inline path, with the agent's edits attributed to its thread
(define (mcp-proxy--sync name args-json author)
  (if author
      (let* ((slug (and (string-prefix? "agent:" author)
                        (substring author 6 (string-length author))))
             (buf (and slug (agent-buf slug))))
        (if (and buf (buffer-exists? buf))
            (with-current-buffer buf
              (lambda ()
                (with-edit-author author
                  (lambda () (mcp-proxy-dispatch name args-json)))))
            (with-edit-author author
              (lambda () (mcp-proxy-dispatch name args-json)))))
      (mcp-proxy-dispatch name args-json)))

;; (mcp-proxy--shell-code ARGS-JSON) -> (CMD DIR|#f) | #f
;; #f unless the payload's code is one (shell-command->string ...) form
;; with a literal CMD. DIR can be a literal string, the exact form
;; (default-directory), or absent.
(define (mcp-proxy--shell-code args-json)
  (let ((args (json-parse args-json)))
    (and args
         (let ((code (custom--plist-get args 'code)))
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
              (list (cadr form) (default-directory)))
             (else #f))))))

;; This surface serves mcp-proxy-tools-json — the Scheme registry — so
;; every name it dispatches is a Scheme handler, and a Scheme handler runs
;; in the session by definition. (The "never dispatch in the session" rule
;; in mcp.ex is about MCP tools, which this surface does not expose;
;; mcp-call! already obeys it for those.)
(define (mcp-proxy-dispatch name args-json)
  (let ((r (llm-tool-call name (json-parse args-json))))
    (if (string? r) r (value->string r))))

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
