;;; prompts.scm --- standing prompts, composition, and prompt inspection.
;;;
;;; Fragment providers stay with the feature that owns their facts. This
;;; package owns shared prose, the canonical join, and the user-facing view.
;;; It loads after skills.scm, so every bundled fragment provider is ready.

(package! 'prompts)
(category! 'chat)
(domain! 'chat)
(effects! '(read))

;; Agents work through the Scheme object model. Visible editor state belongs
;; to the user, so showing a buffer is an explicit presentation action.
(define *agent-quiet-prompt*
  (string-append
    "QUIET EDITOR — work through names, not visible state. The complete "
    "editor is reachable through Scheme without making a buffer visible. "
    "Use APIs that take a buffer name for reading, editing, saving, and "
    "inspection. Do not select, switch to, or display a buffer merely to "
    "work on it. Do not move the user's selected window, visible buffers, "
    "point, mark, or scroll position. You can mention a useful buffer by "
    "name. Display a buffer only when the user asks to see it or the result "
    "needs presentation. Display is a presentation action, never a "
    "prerequisite for work. Preserve focus unless the user asks to move "
    "there. Agent discovery excludes display-effect operations by default. "
    "Include them only for an explicit presentation request. "))

;; The standing context every tool-enabled request carries.
(define *llm-system*
  (string-append
    "You are the assistant inside ai-max, an Emacs-style editor scripted in "
    "Scheme, and you act on the live editor through eval-scheme — one tool, "
    "the whole editor. " *agent-quiet-prompt* "Appearance and behavior are controlled by "
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
    "(with-current-buffer NAME THUNK) scopes an operation that lacks a named "
    "buffer argument and restores its context; "
    "(current-buffer); "
    "(insert! TEXT) at point in the current buffer; (message TEXT) echoes; "
    "(run-command \"name\") runs any M-x command. File buffers are named by "
    "full path. Discovery is ONE call: apropos searches the public API, "
    "M-x commands, keybindings, settings, recipes, modes and UI components "
    "by WORDS — (apropos \"split window\"), not a regex. Filter with kind, "
    "package, namespace, domain, or effect. Effects are pure/read/write/"
    "destroy/spend/execute/external/display: prefer pure/read while investigating "
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
    "destroy, or unknown; modifiers are external, execute, spend, and display. Never "
    "use read as a guess. The loader stamps package and namespace. Before "
    "writing a Scheme package, query apropos for existing APIs and components. "
    "Before choosing or defining UI, read docs/COMPONENTS.md and reuse a catalogued "
    "component when it fits. "
    ;; Without this note, an agent can deny a browser that it can use.
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

;;; An ACP client receives hello as its ai-max primer at session start.
(define (hello)
  (string-append
    "ai-max — an Emacs-style editor on the BEAM, scripted in this Scheme. "
    "Everything the GUI can do, you can do: eval is the whole API.\n\n"
    *agent-quiet-prompt* "\n\n"
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

;; A prompt is named data before it becomes text. This is the only join.
(define (prompt-parts-text parts)
  (string-join (map (lambda (part) (car (cdr part))) parts) "\n\n"))

;; Modes add named fragments to the buffer they affect. The value is derived
;; runtime state: mode setup rebuilds it after restore or reload.
(define (prompt-buffer-parts buf)
  (or (buffer-local buf 'prompt-parts) '()))

(define (prompt-part-set! buf name text)
  (let* ((key (if (symbol? name) (symbol->string name) name))
         (old (prompt-buffer-parts buf))
         (hit (assoc key old))
         (next
           (if hit
               (map (lambda (part) (if (equal? (car part) key)
                                       (list key text)
                                       part))
                    old)
               (append old (list (list key text))))))
    (unless (equal? old next)
      (buffer-set-local! buf 'prompt-parts next))
    next))

(define (prompt-part-remove! buf name)
  (let* ((key (if (symbol? name) (symbol->string name) name))
         (old (prompt-buffer-parts buf))
         (next (remove (lambda (part) (equal? (car part) key)) old)))
    (unless (equal? old next)
      (buffer-set-local! buf 'prompt-parts next))
    next))

(define (chat-prompt-direct? buf)
  (and (boundp (quote chat-stateless?)) (chat-stateless? buf)))

(define (chat-prompt-lane buf)
  (if (chat-prompt-direct? buf) 'direct 'acp))

(define (chat-prompt-snapshot buf)
  (buffer-local buf 'chat-prompt-snapshot))

(define (chat-prompt-live-parts buf)
  (if (chat-prompt-direct? buf)
      (chat-live-system-prompt-parts
        buf (and (boundp (quote chat-use-tools)) chat-use-tools))
      (agent-live-system-prompt-parts
        (list 'buffer buf
              'presets (if (boundp (quote chat-presets-of))
                           (chat-presets-of buf)
                           '())))))

(define (chat-prompt-snapshot-parts buf lane live-parts)
  (let ((snapshot (chat-prompt-snapshot buf)))
    (if (and snapshot (equal? (plist-get snapshot 'lane) lane))
        (or (plist-get snapshot 'parts) '())
        (begin
          (buffer-set-local! buf 'chat-prompt-snapshot
            (list 'lane lane 'parts live-parts))
          live-parts))))

(define (chat-prompt-freeze! buf)
  (chat-prompt-snapshot-parts
    buf (chat-prompt-lane buf) (chat-prompt-live-parts buf)))

(define (chat-prompt-frozen? buf)
  (let ((snapshot (chat-prompt-snapshot buf)))
    (and snapshot
         (equal? (plist-get snapshot 'lane) (chat-prompt-lane buf))
         #t)))

(define (chat-prompt-parts buf)
  (if (chat-prompt-frozen? buf)
      (plist-get (chat-prompt-snapshot buf) 'parts)
      (chat-prompt-live-parts buf)))

(define (chat-refresh-prompt! buf)
  (buffer-set-local! buf 'chat-prompt-snapshot #f)
  (let ((parts (chat-prompt-freeze! buf)))
    (when (and (not (chat-prompt-direct? buf))
               (buffer-local buf 'agent-slug)
               (member (buffer-local buf 'agent-slug) (agent-list)))
      (let* ((slug (buffer-local buf 'agent-slug))
             (status (agent-status slug)))
        (if (member status '(running starting needs_attention))
            (buffer-set-local! buf 'chat-mcp-dirty #t)
            (begin
              (buffer-set-local! buf 'chat-mcp-dirty #f)
              (agent-reconnect!
                slug
                (or (buffer-local buf 'agent-connector) *default-connector*)
                (or (buffer-local buf 'agent-model) ""))))))
    parts))

(define (prompt-code-block text)
  (let loop ((fence "```"))
    (if (string-contains? text fence)
        (loop (string-append fence "`"))
        (string-append fence "text\n" text "\n" fence "\n\n"))))

(define (prompt-parts-index parts)
  (let loop ((rest parts) (n 1) (out '()))
    (if (null? rest)
        (string-join (reverse out) "\n")
        (let* ((part (car rest))
               (name (car part))
               (body (car (cdr part))))
          (loop (cdr rest) (+ n 1)
            (cons (string-append (number->string n) ". `" name "` — "
                                 (number->string (string-byte-length body))
                                 " bytes")
                  out))))))

(define (prompt-parts-sections parts)
  (let loop ((rest parts) (n 1) (out ""))
    (if (null? rest)
        out
        (let* ((part (car rest))
               (name (car part))
               (body (car (cdr part))))
          (loop (cdr rest) (+ n 1)
            (string-append out "## Fragment " (number->string n) ": `"
                           name "`\n\n" (prompt-code-block body)))))))

(define (chat-prompt-report buf)
  (let* ((direct? (chat-prompt-direct? buf))
         (frozen? (chat-prompt-frozen? buf))
         (parts (chat-prompt-parts buf))
         (joined (prompt-parts-text parts)))
    (string-append
      "# System prompt\n\n"
      "`" buf "` · "
      (if direct? "direct API" "ACP session append") " · "
      (number->string (string-byte-length joined)) " bytes\n\n"
      (if frozen?
          (string-append
            "This conversation uses this frozen fragment set. "
            "Prompt source changes do not affect it.\n\n")
          (string-append
            "This is the prospective fragment set. "
            "The first send freezes it for this conversation.\n\n"))
      (if direct?
          "The direct API sends this same system text on every turn.\n\n"
          (string-append
            "ACP adds this text when the session starts. "
            "The connector can also supply its own system prompt.\n\n"))
      "## Composition\n\n" (prompt-parts-index parts) "\n\n"
      (prompt-parts-sections parts)
      "## Final joined text\n\n" (prompt-code-block joined))))

(category! 'discovery)
(public! 'hello "(hello) — what this editor is and how to find anything in it")
(public! 'prompt-parts-text
  "(prompt-parts-text PARTS) — join named prompt fragments with the canonical separator")
(public! 'prompt-buffer-parts
  "(prompt-buffer-parts BUF) — named prompt fragments that modes added to one buffer")

(category! 'chat)
(public! 'chat-prompt-parts
  "(chat-prompt-parts BUF) — current named prompt fragments for a chat's connector lane")
(public! 'chat-prompt-report
  "(chat-prompt-report BUF) — markdown with a chat prompt's parts, lifecycle, and joined text")
(public! 'chat-prompt-frozen?
  "(chat-prompt-frozen? BUF) — whether this chat has frozen its current lane's prompt")

(effects! '(write))
(public! 'prompt-part-set!
  "(prompt-part-set! BUF NAME TEXT) — add or replace one buffer-local prompt fragment")
(public! 'prompt-part-remove!
  "(prompt-part-remove! BUF NAME) — remove one buffer-local prompt fragment")
(public! 'chat-prompt-freeze!
  "(chat-prompt-freeze! BUF) — freeze the current lane's live prompt for this conversation")

(effects! '(write external execute))
(public! 'chat-refresh-prompt!
  "(chat-refresh-prompt! BUF) — replace a chat's frozen prompt and reconnect ACP when safe")

(define-command "chat-refresh-prompt" "Replace this conversation's frozen prompt from current sources"
  (lambda ()
    (let ((buf (and (boundp (quote llm-preset-target)) (llm-preset-target))))
      (if buf
          (let ((parts (chat-refresh-prompt! buf)))
            (message (string-append
                       "prompt refreshed: " (number->string (length parts))
                       " fragments"
                       (if (buffer-local buf 'chat-mcp-dirty)
                           " — ACP reconnects before the next turn"
                           ""))))
          (message "No chat here — open one with M-x chat first")))))

(effects! '(write display))
(define-command "chat-show-prompt" "Show this chat's system prompt and its named composition"
  (lambda ()
    (let ((buf (and (boundp (quote llm-preset-target)) (llm-preset-target))))
      (if buf
          (help-doc! "system prompt" (chat-prompt-report buf))
          (message "No chat here — open one with M-x chat first")))))
