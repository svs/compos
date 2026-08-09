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
    "full path. The API has a public and a private side: apropos-api "
    "searches the public, documented surface — start there and trust its "
    "one-line docs. Everything else in the namespace is private "
    "implementation detail; only reach for it via apropos-api scope "
    "\"all\" plus describe-function when nothing public fits, and prefer "
    "not to. Before writing code with a name you are not sure exists, "
    "check it with apropos-api, and read any function's real source with "
    "describe-function. Keep replies short; the user is in an editor, not "
    "a browser."))

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

(define (tool--format-suggestions entries)
  (fold (lambda (acc e)
          (string-append acc "\n  " (car e) " — " (cadr e)))
        "" entries))

;; the feedback that makes one-tool work: name the real API on a miss
(define (tool--error-hint msg code)
  (cond
    ((re-match? "unbound variable: " msg)
     (let* ((name (string-trim (car (reverse (string-split msg "unbound variable: ")))))
            (hits (tool--suggest name)))
       (if (null? hits)
           "\nNo close public-api match — search with apropos-api before retrying."
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
  "Evaluate Scheme in the live editor session. Full editor API: buffers, windows, faces, modes, customize. NOT Emacs Lisp — verify unfamiliar names with apropos-api first. Returns the printed value; on an unbound name the error suggests the nearest real API."
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

(define-tool! 'apropos-api
  "Search the editor's PUBLIC Scheme API by regex: each hit is (name one-line-doc), plus matching M-x commands. This is the supported, documented surface — prefer it and trust its docs. Pass scope \"all\" only when nothing public fits: that searches every global including undocumented internals, which may change without notice."
  (list (list 'pattern "string" "Regex over names, e.g. \"buffer\" or \"window|frame\"")
        (list 'scope "string" "\"public\" (default) or \"all\"" 'optional))
  (lambda (args)
    (let ((pat (custom--plist-get args 'pattern))
          (scope (or (custom--plist-get args 'scope) "public")))
      (value->string
        (if (equal? scope "all")
            (list 'globals (filter (lambda (n) (re-match? pat n)) (global-names))
                  'commands (filter (lambda (n) (re-match? pat n)) (command-names)))
            (list 'api (filter (lambda (e) (re-match? pat (car e))) (public-api))
                  'commands (filter (lambda (n) (re-match? pat n)) (command-names))))))))

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

(public! 'buffer-replace!
  "(buffer-replace! NAME OLD NEW) — replace exact, unique OLD with NEW in a live buffer")

;;; --- the MCP proxy surface ----------------------------------------------------
;;; External ACP agents get this same registry over MCP: the bundled
;;; aimax-mcp-proxy.exs bridges stdio MCP to the daemon socket and calls
;;; these two. Payloads are base64 both ways — RPC eval returns printed
;;; values, and printed-string escaping is not JSON-safe for every byte.

(define (mcp-proxy-tools-json)
  (base64-encode (tool-specs-json (llm-tool-specs))))

;; the second chokepoint. In auto mode the agent stops asking us
;; ANYTHING — but the deny-list must still hold, and every deny-listed
;; verb reaches the world either through the direct lane's gate or
;; through this proxy. So the payload is checked here too, whatever the
;; backend decided upstream.
(define (mcp-proxy-call name args-b64)
  (base64-encode
    (let* ((args-json (base64-decode args-b64))
           (denied (and (boundp (quote permission-denied-verb?))
                        (permission-denied-verb?
                          (string-append name " " args-json)))))
      (if denied
          (string-append
            "refused: this is an irreversible, outward-facing action ("
            denied "). Ask the user to run it, or have them approve it in "
            "the chat.")
          (let ((r (llm-tool-call name (json-parse args-json))))
            (if (string? r) r (value->string r)))))))

(public! 'define-tool! "(define-tool! 'name DESC PARAMS HANDLER) — register an LLM tool")
(public! 'llm-with-tools "(llm-with-tools PROMPT HANDLER) — completion with the full tool loop")

;; chat integration: chat-send routes through llm-with-tools when this is on
(defcustom 'chat-use-tools #t
  "When true, the *chat* buffer's LLM can act on the editor via tools."
  'group 'chat 'type 'boolean)
