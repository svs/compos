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

(define (define-tool! name description params handler)
  (set! *llm-tools*
    (cons (list name (list 'description description 'params params 'handler handler))
          (remove (lambda (t) (equal? (car t) name)) *llm-tools*)))
  name)

(define (llm-tool-specs)
  (map (lambda (t)
         (list (symbol->string (car t))
               (custom--plist-get (cadr t) 'description)
               (custom--plist-get (cadr t) 'params)))
       (reverse *llm-tools*)))

(define (llm-tool-call name args)
  (let ((t (assoc (string->symbol name) *llm-tools*)))
    (if t
        ((custom--plist-get (cadr t) 'handler) args)
        (string-append "no such tool: " name))))

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
    "like get-buffer, set-buffer, goto-char, point-max, insert, "
    "save-excursion, with-current-buffer do not exist. Core API: "
    "(buffer-list) names; (buffer-text NAME); (buffer-append! NAME TEXT) "
    "append to any buffer — the usual way to add text; (buffer-create NAME); "
    "(buffer-replace! NAME OLD NEW) exact unique replacement in a live "
    "buffer; (visit PATH) opens a file; (switch-to-buffer! NAME); "
    "(current-buffer); "
    "(insert! TEXT) at point in the current buffer; (message TEXT) echoes; "
    "(run-command \"name\") runs any M-x command. File buffers are named by "
    "full path. Discovery is ONE call: apropos searches the public API, "
    "the M-x commands, the keybindings and the settings by WORDS — "
    "(apropos \"split window\"), not a regex — and returns signatures. "
    "apropos-categories shows the shape of the surface first. Everything "
    "outside the public API is private implementation detail; reach for it "
    "with scope \"all\" plus describe-function only when nothing public "
    "fits. Before writing code with a name you are not sure exists, check "
    "it with apropos, and read any function's real source with "
    "describe-function. "
    ;; without this the assistant tells people it has no browser, while
    ;; sitting on a wire to one — apropos would find these, but only if
    ;; it thinks to look
    "You CAN drive the user's Chrome, when the ai-max extension is "
    "attached — check (browser-connected?). (tab-list K) gives every open "
    "tab as plists with id/title/url; (tab-open URL) opens one; "
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
                         (string-join (map car (actions-for type)) ", "))))))

;;; --- the built-in toolbox ----------------------------------------------------
;;; One tool is viable only because failure is instructive: a model that
;;; guesses `buffer-insert` gets back the nearest real names with their
;;; signatures instead of six blind retries.

(define (tool--edit-distance a b)
  (let ((la (string-length a)) (lb (string-length b)))
    (let loop ((i 0) (row (iota (+ lb 1))))
      (if (= i la)
          (list-ref row lb)
          (loop (+ i 1)
                (let inner ((j 1) (diag (car row)) (acc (list (+ i 1))))
                  (if (> j lb)
                      (reverse acc)
                      (let ((cost (if (equal? (substring a i (+ i 1))
                                              (substring b (- j 1) j))
                                      0 1)))
                        (inner (+ j 1)
                               (list-ref row j)
                               (cons (min (+ (car acc) 1)
                                          (+ (list-ref row j) 1)
                                          (+ diag cost))
                                     acc))))))))))

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
           (r (eval-string-safe code)))
      (if (equal? (car r) 'ok)
          (value->string (cadr r))
          (string-append "error: " (cadr r) (tool--error-hint (cadr r) code))))))

;; Emacs-grade introspection: most of the editor is userland Scheme, and
;; closures carry their AST — so a function's real source is one call away.
(define (describe-function name)
  (cond ((boundp name)
         (function-source (symbol-value name)))
        ((command-fn name)
         (string-append "M-x command:\n" (function-source (command-fn name))))
        (else (string-append "no function or command named "
                             (symbol->string name)))))

(define-tool! 'describe-function
  "Read a function's actual implementation. Userland functions and M-x commands return their full Scheme source (most of the editor — dired, org, chat, modes — is userland); builtins are Elixir and return only a marker. Use it to understand how something works before changing it."
  (list (list 'name "string" "Function or command name, e.g. chat-send or face-remap!"))
  (lambda (args)
    (describe-function (string->symbol (custom--plist-get args 'name)))))

;;; --- apropos: one search over everything ---------------------------------------
;;; The first question an agent asks is "what can I call". Four registries
;;; held the answer and nothing searched across them: the public API, the
;;; M-x commands and their docstrings, the keybindings, and the
;;; defcustoms. The old apropos-api matched names only — never doc text —
;;; so "how do I split a window" found nothing while split-window! sat
;;; there with a doc saying exactly that.
;;;
;;; Matching is word-AND, like mcp-find: every word of the query must
;;; appear somewhere in the entry. A query that finds nothing falls back to
;;; edit distance, so a near-miss on a name still lands.

(define (apropos--words q)
  (filter (lambda (w) (not (equal? w "")))
          (string-split (string-downcase (string-trim q)) " ")))

(define (apropos--hit? hay words)
  (let ((h (string-downcase hay)))
    (let loop ((ws words))
      (cond ((null? ws) #t)
            ((string-contains? h (car ws)) (loop (cdr ws)))
            (else #f)))))

(define (apropos--fn e words)
  (and (apropos--hit? (string-append (car e) " " (nth 1 e) " " (nth 2 e) " "
                                     (symbol->string (nth 3 e)))
                      words)
       (list 'kind "function" 'name (car e) 'sig (nth 2 e)
             'doc (nth 1 e) 'category (symbol->string (nth 3 e)))))

(define (apropos--command n words)
  (let ((doc (command-doc n)))
    (and (apropos--hit? (string-append n " " doc) words)
         (list 'kind "command" 'name n 'doc doc
               'key (let ((k (key-for-command n))) (if (equal? k "") #f k))))))

(define (apropos--key row words)
  (and (apropos--hit? (string-append (car row) " " (nth 1 row)) words)
       (list 'kind "key" 'name (car row) 'runs (nth 1 row))))

(define (apropos--var v words)
  (let* ((rec (cadr v))
         (name (symbol->string (car v)))
         (doc (or (custom--plist-get rec 'doc) "")))
    (and (apropos--hit? (string-append name " " doc) words)
         (list 'kind "variable" 'name name 'doc doc))))

(define (apropos--compact xs) (filter (lambda (x) x) xs))

;; QUERY is words, not a regex: "split window", "open a file", "chat cost".
;; Recipes come first: a task-level hit beats four name-level ones, and it
;; is the answer the caller actually wanted.
(define (apropos query)
  (let* ((words (apropos--words query))
         (hits (append
                 (if (boundp (quote recipe-search)) (recipe-search query) '())
                 (apropos--compact (map (lambda (e) (apropos--fn e words)) (public-api)))
                 (apropos--compact (map (lambda (n) (apropos--command n words)) (command-names)))
                 (apropos--compact (map (lambda (r) (apropos--key r words)) (global-keys)))
                 (apropos--compact (map (lambda (v) (apropos--var v words)) *custom-vars*)))))
    (if (or (pair? hits) (null? words))
        hits
        ;; nothing matched: the query is probably a near-miss on a name
        (map (lambda (e)
               (list 'kind "function" 'name (car e) 'sig (nth 2 e) 'doc (nth 1 e)
                     'category (symbol->string (nth 3 e)) 'note "closest name"))
             (tool--suggest (string-trim query))))))

;; everything in one category — the shape of the API, not a search of it
(define (apropos-category name)
  (map (lambda (e)
         (list 'kind "function" 'name (car e) 'sig (nth 2 e) 'doc (nth 1 e)))
       (filter (lambda (e) (equal? (nth 3 e) name)) (public-api))))

(category! 'discovery)
(public! 'apropos
  "(apropos \"words\") — search the whole editor by words: public functions, M-x commands, keybindings and settings. Start here.")
(public! 'apropos-category
  "(apropos-category 'windows) — every public function in one category")
(public! 'public-categories "(public-categories) — the category names")

(define-tool! 'apropos
  (string-append
    "Search the editor by WORDS, not by regex: public functions with their "
    "signatures, M-x commands with their docstrings, keybindings, and "
    "settings. Every word must appear somewhere in the entry, so "
    "\"split window\" finds the window splitters and \"chat cost\" finds "
    "the cost commands. This is the supported surface and the place to "
    "start. Nothing matched? You get the closest names instead. Pass "
    "category to list one area whole, or scope \"all\" to include "
    "undocumented internals, which may change without notice.")
  (list (list 'query "string" "words, e.g. \"open a file\" or \"buffer text\"")
        (list 'category "string" "list this category whole instead of searching" 'optional)
        (list 'scope "string" "\"public\" (default) or \"all\"" 'optional))
  (lambda (args)
    (let ((q (or (custom--plist-get args 'query) ""))
          (cat (custom--plist-get args 'category))
          (scope (or (custom--plist-get args 'scope) "public")))
      (value->string
        (cond
          (cat (apropos-category (string->symbol cat)))
          ((equal? scope "all")
           (list 'public (apropos q)
                 'globals (filter (lambda (n) (apropos--hit? n (apropos--words q)))
                                  (global-names))))
          (else (apropos q)))))))

(define-tool! 'apropos-categories
  "List the editor API's categories. Cheapest way to see the shape of the surface before searching it."
  '()
  (lambda (args) (value->string (public-categories))))

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
    "settings by WORDS, not regex. Returns signatures.\n"
    "  (apropos-category 'NAME) list one area whole.\n"
    "  (describe-function 'NAME) read the real source.\n\n"
    "Categories: " (string-join (map symbol->string (public-categories)) ", ") "\n\n"
    "NOTE: this is ai-max's own small Scheme, NOT Emacs Lisp. Names like "
    "get-buffer, goto-char, save-excursion and with-current-buffer do not "
    "exist. Check a name with apropos before you write it; an unbound name "
    "comes back with the nearest real ones and their signatures.\n\n"
    (if (boundp (quote recipes-text)) (recipes-text) "")))

(category! 'discovery)
(public! 'hello "(hello) — what this editor is and how to find anything in it")


;; the edit primitive the old edit-doc tool wrapped — now a public function
;; reached through eval-scheme. Edits the live buffer, never the file.
(define (buffer-replace! b old new)
  (cond ((not (buffer-exists? b)) (string-append "no such buffer: " b))
        ((equal? old "") "error: old must be non-empty")
        (else
          (let ((hits (- (length (string-split (buffer-text b) old)) 1)))
            (cond ((equal? hits 0)
                   "error: old text not found — read the buffer and copy it exactly")
                  ((> hits 1)
                   (string-append "error: old text occurs "
                                  (number->string hits)
                                  " times — include surrounding text to make it unique"))
                  (else
                    (let ((pos (string-index (buffer-text b) old)))
                      (buffer-delete-range! b pos (string-byte-length old))
                      (buffer-insert! b pos new)
                      "edited")))))))

(category! 'editing)
(public! 'buffer-replace!
  "(buffer-replace! NAME OLD NEW) — replace exact, unique OLD with NEW in a live buffer")

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
(define (mcp-proxy-call name args-b64)
  (base64-encode
    (let* ((args-json (base64-decode args-b64))
           (raw (string-append name " " args-json))
           (verdict (if (boundp (quote *permission-policy*))
                        (*permission-policy* #f name "tool" raw)
                        'allow)))
      (cond
        ((member verdict '(allow allow-always))
         (mcp-proxy-dispatch name args-json))
        (else
          (string-append
            "refused: aimax's permission policy did not allow this ("
            (or (and (boundp (quote permission-denied-verb?))
                     (permission-denied-verb? raw))
                (symbol->string verdict))
            "). Ask the user to run it, or to approve it in the chat."))))))

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

;; Compaction: a conversation that never ends resends all of itself every
;; turn, so cost grows with the square of its length. Past the threshold
;; the head becomes one summary and the recent turns stay verbatim. The
;; mechanism is in editor.scm (chat-should-compact?, chat-compact!); these
;; are the knobs.
(defcustom 'chat-compact-threshold 60000
  "Compact a chat once its record passes this many estimated tokens. 0 disables it."
  'group 'chat 'type 'integer)

(defcustom 'chat-compact-keep 8
  "How many recent turns a compaction keeps verbatim."
  'group 'chat 'type 'integer)
