;;; prompts.scm --- standing prompts, composition, and prompt inspection.
;;;
;;; Fragment providers stay with the feature that owns their facts. This
;;; package owns shared prose, the canonical join, and the user-facing view.
;;; It loads after skills.scm, so every bundled fragment provider is ready.

(category! 'chat)
(domain! 'chat)
(effects! '(read))

;; Standing guidance lives as Markdown files, so code review shows prompt
;; changes without Scheme quoting. Each FILE.md in prompts-directories is one
;; prompt section named FILE. An earlier directory wins a name, so
;; (add-to-list! 'prompts-directories DIR) overrides a default file with DIR's.
(defcustom 'prompts-directories (list (string-append (compos-priv-dir) "/prompts"))
  "Directories of Markdown prompt files. Each FILE.md is one prompt section named FILE; an earlier directory wins a name."
  'group 'chat 'type 'list)

;; The default files keep this order, so the prompt bytes stay stable and the
;; identity leads. Any other file follows, by name.
(define *prompt-file-order*
  '("identity" "quiet-editor" "scope" "chat-context" "scheme" "discovery"
    "reading" "repository" "browser"))

(define (prompt--rank name)
  (let loop ((names *prompt-file-order*) (i 0))
    (cond ((null? names) i)
          ((equal? (car names) name) i)
          (else (loop (cdr names) (+ i 1))))))

(define (prompt--stem file)
  (if (string-suffix? ".md" file)
      (substring file 0 (- (string-length file) 3))
      file))

(define (prompt-files)
  (let loop ((dirs prompts-directories) (acc '()))
    (if (null? dirs)
        (map cdr (sort (map (lambda (e) (cons (prompt--rank (car e)) e)) acc)))
        (let ((dir (expand-path (car dirs))))
          (loop (cdr dirs)
                (fold (lambda (acc file)
                        (let ((name (prompt--stem file)))
                          (if (or (not (string-suffix? ".md" file)) (assoc name acc))
                              acc
                              (cons (list name (string-append dir "/" file)) acc))))
                      acc
                      (if (file-directory? dir) (list-dir dir) '())))))))

(define (prompt-file-text file)
  (let ((hit (assoc (prompt--stem file) (prompt-files))))
    (if hit (string-trim (read-file (cadr hit))) "")))

(define (compos-shared-prompt-parts)
  (append
    (map (lambda (entry) (list (car entry) (string-trim (read-file (cadr entry)))))
         (prompt-files))
    (list
      (list "catalog"
        (string-append
          "Available areas: "
          (string-join (map symbol->string (public-categories)) ", ") "."))
      (list "recipes"
        (if (boundp (quote recipes-text)) (recipes-text) "")))))

(define (compos-direct-prompt-parts) (compos-shared-prompt-parts))
(define (compos-acp-prompt-parts) (compos-shared-prompt-parts))

;; A prompt is named data before it becomes text. This is the only join.
(define (prompt-parts-text parts)
  (string-join (map (lambda (part) (car (cdr part))) parts) "\n\n"))

;; Every fragment is its own section: a prompt file, a generated part
;; (catalog, recipes, mcp) or a part a mode or package added. An empty one is
;; dropped. Names are unique: the last fragment of a name wins, in the place
;; the name first took, so a buffer part overrides a prompt file.
(define (prompt-section-parts fragments)
  (let loop ((rest fragments) (out '()))
    (if (null? rest)
        (filter (lambda (part) (not (equal? (cadr part) ""))) (reverse out))
        (let ((part (car rest)))
          (loop (cdr rest)
                (if (assoc (car part) out)
                    (map (lambda (p) (if (equal? (car p) (car part)) part p)) out)
                    (cons part out)))))))

;; A prompt preset records only exceptions. New fragments therefore arrive on,
;; instead of silently disappearing from every bundle saved before they existed.
;; A name no fragment has any more is harmless: it switches nothing off.
(define (prompt-disabled-parts buf)
  (or (buffer-local buf 'prompt-disabled-parts) '()))

(define (prompt-parts-enabled buf parts)
  (let ((disabled (prompt-disabled-parts buf)))
    (filter (lambda (part) (not (member (car part) disabled))) parts)))

(define (prompt-parts-set-disabled! buf names)
  (let ((next (filter string? names))
        (old (or (buffer-local buf 'prompt-disabled-parts) '())))
    (unless (equal? next old)
      (buffer-set-local! buf 'prompt-disabled-parts next))
    next))

;; One section on or off for one chat. A project's compos.scm or a group's
;; ai-config.scm runs with the chat current, so it says
;;   (prompt-section-off! (current-buffer) "todo")
;; The switch persists with the chat and applies when the prompt is composed,
;; so it holds whichever runs first: the config or the part it turns off.
(define (prompt-section-off! buf name)
  (let ((key (if (symbol? name) (symbol->string name) name)))
    (prompt-parts-set-disabled! buf
      (if (member key (prompt-disabled-parts buf))
          (prompt-disabled-parts buf)
          (append (prompt-disabled-parts buf) (list key))))))

(define (prompt-section-on! buf name)
  (let ((key (if (symbol? name) (symbol->string name) name)))
    (prompt-parts-set-disabled! buf
      (remove (lambda (n) (equal? n key)) (prompt-disabled-parts buf)))))

;; Compatibility values for callers that still request one joined string.
(define *agent-quiet-prompt* (prompt-file-text "quiet-editor.md"))
(define *llm-system* (prompt-parts-text (compos-direct-prompt-parts)))

;; The RPC initialize response and ACP use the same shared composition.
(define (hello) (prompt-parts-text (compos-acp-prompt-parts)))

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

;; The unfiltered source is for configuration and inspection. It holds one
;; section per fragment; current group membership is fetched by chat-context.
(define (chat-prompt-source-parts buf)
  (prompt-section-parts
    (if (chat-prompt-direct? buf)
        (chat-live-system-prompt-source-parts
          buf (and (boundp (quote chat-use-tools)) chat-use-tools))
        (agent-live-system-prompt-source-parts
          (list 'buffer buf
                'presets (if (boundp (quote chat-presets-of))
                             (chat-presets-of buf)
                             '()))))))

(define (chat-prompt-live-parts buf)
  (prompt-parts-enabled buf (chat-prompt-source-parts buf)))

(define (chat-prompt-snapshot-parts buf lane live-parts)
  (let ((snapshot (chat-prompt-snapshot buf)))
    (if (and snapshot (equal? (plist-get snapshot 'lane) lane))
        (or (plist-get snapshot 'parts) '())
        (begin
          (buffer-set-local! buf 'chat-prompt-snapshot
            (list 'lane lane 'parts live-parts))
          live-parts))))

(define (chat-prompt-freeze! buf)
  ;; Prompt sources can run while another lane renames the chat.
  ;; Keep the snapshot attached to the same buffer throughout composition.
  (let ((target (or (buffer-ref buf) buf)))
    (chat-prompt-snapshot-parts
      target (chat-prompt-lane target) (chat-prompt-live-parts target))))

(define (chat-prompt-frozen? buf)
  (let ((snapshot (chat-prompt-snapshot buf)))
    (and snapshot
         (equal? (plist-get snapshot 'lane) (chat-prompt-lane buf))
         #t)))

(define (chat-prompt-parts buf)
  (if (chat-prompt-frozen? buf)
      (plist-get (chat-prompt-snapshot buf) 'parts)
      (chat-prompt-live-parts buf)))

;; A section change is an explicit prompt change. Prospective prompts stay
;; prospective; frozen conversations adopt the new composition through the
;; existing refresh/reconnect path.
(define (chat-prompt-sections-set! buf names)
  (prompt-parts-set-disabled! buf names)
  (if (chat-prompt-frozen? buf)
      (chat-refresh-prompt! buf)
      (when (and (minor-mode-on? buf "llm-mode")
                 (boundp (quote llm-mode-reset-runtime!)))
        (llm-mode-reset-runtime! buf #t)))
  names)

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

(define (prompt-parts-index buf parts)
  (let loop ((rest parts) (n 1) (out '()))
    (if (null? rest)
        (string-join (reverse out) "\n")
        (let* ((part (car rest))
               (name (car part))
               (body (car (cdr part))))
          (loop (cdr rest) (+ n 1)
            (cons (string-append (number->string n) ". "
                                 (if (member name (prompt-disabled-parts buf))
                                     "○ " "● ")
                                 "`" name "` — "
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
            (string-append out "## Section " (number->string n) ": `"
                           name "`\n\n" (prompt-code-block body)))))))

(define (chat-prompt-report buf)
  (let* ((direct? (chat-prompt-direct? buf))
         (frozen? (chat-prompt-frozen? buf))
         (parts (chat-prompt-parts buf))
         (available (chat-prompt-source-parts buf))
         (joined (prompt-parts-text parts)))
    (string-append
      "# System prompt\n\n"
      "`" buf "` · "
      (if direct? "direct API" "ACP session append") " · "
      (number->string (string-byte-length joined)) " bytes\n\n"
      (if frozen?
          (string-append
            "This conversation uses this frozen section set. "
            "Prompt source changes do not affect it.\n\n")
          (string-append
            "This is the prospective section set. "
            "The first send freezes it for this conversation.\n\n"))
      (if direct?
          "The direct API sends this same system text on every turn.\n\n"
          (string-append
            "ACP adds this text when the session starts. "
            "The connector can also supply its own system prompt.\n\n"))
      "## Composition\n\n● on · ○ off\n\n"
      (prompt-parts-index buf available) "\n\n"
      (prompt-parts-sections parts)
      "## Final joined text\n\n" (prompt-code-block joined))))

(category! 'discovery)
(public! 'hello "(hello) — what this editor is and how to find anything in it")
(public! 'prompt-parts-text
  "(prompt-parts-text PARTS) — join named prompt fragments with the canonical separator")
(public! 'prompt-parts-enabled
  "(prompt-parts-enabled BUF PARTS) — remove the prompt fragments BUF disabled")
(public! 'prompt-disabled-parts
  "(prompt-disabled-parts BUF) — section names disabled for this LLM surface")
(public! 'prompt-buffer-parts
  "(prompt-buffer-parts BUF) — named prompt fragments that modes added to one buffer")
(public! 'prompt-files
  "(prompt-files) — every prompt file as (NAME PATH): one section each, from prompts-directories")
(public! 'compos-shared-prompt-parts
  "(compos-shared-prompt-parts) — named standing guidance shared by direct and ACP agents")
(public! 'compos-direct-prompt-parts
  "(compos-direct-prompt-parts) — named standing guidance for direct API agents")
(public! 'compos-acp-prompt-parts
  "(compos-acp-prompt-parts) — named standing guidance for ACP agents")

(category! 'chat)
(public! 'chat-prompt-parts
  "(chat-prompt-parts BUF) — current named prompt sections for a chat's connector lane")
(public! 'chat-prompt-source-parts
  "(chat-prompt-source-parts BUF) — the live prompt sections, one per fragment, before filtering")
(public! 'chat-prompt-report
  "(chat-prompt-report BUF) — markdown with a chat prompt's parts, lifecycle, and joined text")
(public! 'chat-prompt-frozen?
  "(chat-prompt-frozen? BUF) — whether this chat has frozen its current lane's prompt")

(effects! '(write))
(public! 'prompt-part-set!
  "(prompt-part-set! BUF NAME TEXT) — add or replace one buffer-local prompt fragment")
(public! 'prompt-part-remove!
  "(prompt-part-remove! BUF NAME) — remove one buffer-local prompt fragment")
(public! 'prompt-parts-set-disabled!
  "(prompt-parts-set-disabled! BUF NAMES) — set disabled prompt sections for this LLM surface")
(public! 'prompt-section-off!
  "(prompt-section-off! BUF NAME) — leave one prompt section out of this chat's prompt")
(public! 'prompt-section-on!
  "(prompt-section-on! BUF NAME) — put one prompt section back into this chat's prompt")
(public! 'chat-prompt-sections-set!
  "(chat-prompt-sections-set! BUF NAMES) — set disabled sections and refresh a frozen prompt")
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
                       " sections"
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
