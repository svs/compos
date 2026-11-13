;;; ai.scm --- M-x ai: the LLM setup of a chat, its prompts, the connectors
;;; and the local models, in one app.
;;;
;;; Four tabs over one listing, a page per row beside it:
;;;
;;;   setup       the chat the app was opened from, and the saved presets
;;;   prompts     the prompt sections, on or off in that chat
;;;   connectors  the agents, hosted APIs and browser models, with their tests
;;;   models      the models each model host holds, and models to install
;;;
;;; Each key does the same on the listing and on the page. C-l C-l opens it.
;;; The parts stay the work of their own packages: vscode.scm draws the
;;; picker, llm-connectors.scm tests, models.scm talks to the hosts.

(require 'tabulated-list)
(require 'llm-connectors)
(require 'models)

(domain! 'llm)
(effects! '(write))

(define *ai-buffer* "*ai*")
(define *ai-tabs* '("setup" "prompts" "connectors" "models"))

(defcustom 'ai-suggested-models
  '(("qwen3:8b" "Qwen 3, 8B: a strong all-round model for a laptop")
    ("qwen2.5-coder:7b" "Qwen 2.5 Coder, 7B: code completion and edits")
    ("gemma3:4b" "Gemma 3, 4B: small and fast, sees images")
    ("llama3.2:3b" "Llama 3.2, 3B: quick answers on little memory")
    ("deepseek-r1:8b" "DeepSeek R1, 8B: thinks before it answers")
    ("nomic-embed-text" "Nomic embed: vectors for search"))
  "Models the AI app offers to install on this machine: (TAG ABOUT) each, as ollama names them."
  'group 'llm)

;; the chat the app sets up: the one it was opened from
(define *ai-chat* #f)
;; the entries of every model host, or #f before the first answer
(define *ai-models* #f)
(define *ai-models-busy* #f)

(effects! '(pure))

(define (ai--clip s n)
  (cond ((not (string? s)) "")
        ((> (string-length s) n) (string-append (substring s 0 (- n 1)) "…"))
        (else s)))

(define (ai--sep? r) (equal? (plist-get r 'kind) "sep"))
(define (ai--sep tab title) (list 'kind "sep" 'tab tab 'id (string-append "sep:" tab ":" title) 'title title))

(define (ai--first-prose text)
  (let loop ((ls (string-split (or text "") "\n")))
    (if (null? ls) ""
        (let ((l (string-trim (car ls))))
          (if (or (equal? l "") (string-prefix? "#" l) (string-prefix? "---" l) (string-prefix? "<!--" l))
              (loop (cdr ls))
              (ai--clip l 110))))))

(define (ai--keys-of row)
  (let ((kind (and row (plist-get row 'kind))))
    (cond ((equal? kind "chat") '(("RET" "presets") ("b" "backend") ("m" "model") ("e" "effort") ("u" "tools")
                                     ("s" "save new") ("U" "update preset") ("G" "group default") ("A" "global default")))
          ((equal? kind "preset") '(("a" "apply") ("G" "group default") ("A" "global default")))
          ((equal? kind "prompt") '(("o" "on/off") ("v" "edit")))
          ((equal? kind "connector") '(("t" "test") ("i" "install") ("l" "sign in") ("k" "key") ("d" "default") ("P" "full page")))
          ((equal? kind "model") '(("x" "load") ("i" "install") ("D" "uninstall")))
          ((equal? kind "suggest") '(("i" "install")))
          (else '()))))

(effects! '(read))

(define (ai--list)
  (cond ((equal? (buffer-local-value 'mode-name (current-buffer)) "ai-mode") (current-buffer))
        ((buffer-local-value 'ai-list (current-buffer)))
        (else (list-mode-group-buffer "ai-mode"))))

(define (ai--chat) (and *ai-chat* (buffer-known? *ai-chat*) *ai-chat*))

(define (ai--at)
  "the row at hand: the page's own, else the listing's"
  (or (buffer-local-value 'ai-row (current-buffer))
      (let ((r (list-current (ai--list)))) (and r (not (ai--sep? r)) r))))

(define (ai--prompt-source path)
  ;; a prompt read from the build copy is edited in its source
  (let ((src (string-replace path "/_build/dev/lib/compos_core/priv/" "/apps/compos_core/priv/")))
    (if (and (not (equal? src path)) (file-exists? src)) src path)))

(define (ai--file-text path) (if (and path (file-exists? path)) (read-file path) ""))

;; --- the rows --------------------------------------------------------

(define (ai--setup-rows)
  (append (list (ai--sep "setup" "This chat")
                (list 'kind "chat" 'tab "setup" 'id "chat" 'name (or (ai--chat) "no chat")))
          (if (null? *llm-bundles*) '()
              (cons (ai--sep "setup" "Presets")
                    (map (lambda (b) (list 'kind "preset" 'tab "setup" 'id (llm-bundle-name b) 'name (llm-bundle-name b)))
                         *llm-bundles*)))))

(define (ai--prompt-rows)
  (let ((files (prompt-files)))
    (if (null? files) '()
        (cons (ai--sep "prompts" "Prompt sections")
              (map (lambda (f) (list 'kind "prompt" 'tab "prompts" 'id (car f) 'name (car f) 'path (cadr f)))
                   files)))))

(define (ai--connector-rows)
  (map (lambda (r)
         (if (llm-connectors--section? r)
             (ai--sep "connectors" (cadr r))
             (list 'kind "connector" 'tab "connectors" 'id r 'name r)))
       (llm-connectors-rows)))

(define (ai--model-key e) (string-append (models--host-label (models--entry-host e)) " " (plist-get e 'name)))

(define (ai--model-rows)
  (if (not *ai-models*)
      (list (ai--sep "models" "Model hosts")
            (list 'kind "note" 'tab "models" 'id "asking" 'name "Asking the model hosts…"))
      (let* ((hosts (models-host-list))
             (installed (map (lambda (e) (plist-get e 'name)) *ai-models*))
             (local (models--local-host))
             (offer (filter (lambda (s) (not (member (car s) installed))) ai-suggested-models)))
        (append
          (apply append
            (map (lambda (h)
                   (let ((es (filter (lambda (e) (equal? (models--entry-host e) h)) *ai-models*)))
                     (if (null? es) '()
                         (cons (ai--sep "models" (string-append "On " (models--host-label h)))
                               (map (lambda (e) (list 'kind "model" 'tab "models" 'id (ai--model-key e)
                                                      'name (plist-get e 'name) 'entry e))
                                    es)))))
                 hosts))
          (if (or (not local) (null? offer)) '()
              (cons (ai--sep "models" "Install on this machine")
                    (map (lambda (s) (list 'kind "suggest" 'tab "models" 'id (car s) 'name (car s) 'about (cadr s) 'host local))
                         offer)))))))

(define (ai--rows buf)
  (append (ai--setup-rows) (ai--prompt-rows) (ai--connector-rows) (ai--model-rows)))

(define (ai--cells buf r)
  (let* ((kind (plist-get r 'kind))
         (chat (ai--chat))
         (now (and chat (llm-config-combination chat))))
    (cond
     ((ai--sep? r) (list (list (plist-get r 'title) "list-section-name") "" ""))
     ((equal? kind "note") (list (list (plist-get r 'name) "dim") "" ""))
     ((equal? kind "chat")
      (if (not now)
          (list "no chat" (list "open from a chat" "dim") "")
          (list (ai--clip chat 40)
                (list (plist-get now 'connector) "success")
                (list (string-append (plist-get now 'model) " · " (plist-get now 'effort) " effort") "dim"))))
     ((equal? kind "preset")
      (let ((b (llm-bundle-named (plist-get r 'name))))
        (list (plist-get r 'name)
              (if (and chat (equal? (llm-config-preset-name chat) (plist-get r 'name))) (list "● in use" "success") "")
              (list (string-append (llm-bundle-get b 'connector "") " · " (llm-bundle-get b 'model "default")) "dim"))))
     ((equal? kind "prompt")
      (let ((off (and chat (member (plist-get r 'name) (prompt-disabled-parts chat)))))
        (list (plist-get r 'name)
              (if off (list "○ off" "dim") (list "● on" "success"))
              (list (ai--first-prose (ai--file-text (plist-get r 'path))) "dim"))))
     ((equal? kind "connector")
      (let* ((n (plist-get r 'name)) (state (llm-connectors-state n)))
        (list (if (llm-connectors--default? n) (string-append "✓ " (llm-connectors--title n)) (llm-connectors--title n))
              (list state (if (equal? state "ready") "success" "warning"))
              (list (llm-connectors--about n) "dim"))))
     ((equal? kind "model")
      (let ((e (plist-get r 'entry)))
        (list (plist-get e 'name)
              (cond ((plist-get e 'loaded) (list "● loaded" "success"))
                    ((member (plist-get e 'note) '(#f "")) (list "installed" "dim"))
                    (else (list (plist-get e 'note) "warning")))
              (list (string-join (filter (lambda (s) (and (string? s) (not (equal? s ""))))
                                         (list (models--size-label (plist-get e 'size)) (plist-get e 'params) (plist-get e 'quant)))
                                 " · ")
                    "dim"))))
     ((equal? kind "suggest")
      (list (plist-get r 'name) (list "not installed" "dim") (list (plist-get r 'about) "dim")))
     (else (list (or (plist-get r 'name) "") "" "")))))

;; --- the pages -------------------------------------------------------

(define (ai--prose text) (list 'tag "c-group" 'class "c-prose c-lines" 'text text))
(define (ai--group title body) (component 'ui/group (list 'title title 'body body)))
(define (ai--kv pairs)
  (component 'ui/kv (list 'pairs (filter (lambda (p) (and (pair? p) (string? (cadr p)) (not (equal? (cadr p) "")))) pairs))))
(define (ai--meta items)
  (component 'ui/meta
    (list 'segs (let loop ((xs (filter (lambda (s) (and (string? s) (not (equal? s "")))) items)) (acc '()))
                  (cond ((null? xs) (reverse acc))
                        ((null? acc) (loop (cdr xs) (list (list "" (car xs)))))
                        (else (loop (cdr xs) (cons (list "" (car xs)) (cons '("c-sep" "  ·  ") acc)))))))))
(define (ai--actions acts) (component 'ui/actions (list 'actions acts)))

(define (ai--page title badge tone meta acts parts)
  "(TEXT BLOCKS): a title, a meta line, the action bar, then PARTS, each (NAME BLOCK) and one anchor"
  (let* ((stop (lambda (blk name i) (append blk (list 'anchor-name name 'lines (list i i)))))
         (head (stop (component 'ui/title (append (list 'text title) (if badge (list 'badge badge 'tone (or tone "")) '())))
                     "Title" 1))
         (body (let loop ((ps parts) (i 2) (acc '()))
                 (if (null? ps) (reverse acc)
                     (loop (cdr ps) (+ i 1) (cons (stop (cadr (car ps)) (car (car ps)) i) acc))))))
    (list (string-join (cons title (map car parts)) "\n")
          (list (component 'ui/page
                  (list 'body (append (list head) (if meta (list meta) '()) (if (pair? acts) (list (ai--actions acts)) '()) body)))))))

(define (ai--test-pairs r)
  (if (not r) (list (list "Last test" "never tested: t tests it"))
      (list (list "Last test" (llm-connectors--result-text r))
            (list "Time" (if (plist-get r 'ms) (llm-connectors--secs (plist-get r 'ms)) ""))
            (list "Reply" (ai--clip (or (plist-get r 'reply) "") 300))
            (list "Error" (ai--clip (or (plist-get r 'error) "") 300)))))

(define (ai--group-of chat) (group-resolve-id (or (and chat (buffer-group chat)) (frame-group))))

(define (ai--setup-name b)
  (cond ((not b) #f)
        ((string? b) b)
        ((plist-get b 'name))
        (else (string-append (or (plist-get b 'connector) "?") " · " (or (plist-get b 'model) "default")))))

(define (ai--tool-rows on)
  ;; (NAME ABOUT ON?): the toolsets, then the MCP servers no toolset names
  (append (map (lambda (e) (list (symbol->string (car e)) (or (plist-get (cadr e) 'description) "") (memq (car e) on))) *chat-presets*)
          (map (lambda (s) (list (symbol->string (car s)) "MCP server" (memq (car s) on)))
               (filter (lambda (s) (not (assq (car s) *chat-presets*))) *mcp-registry*))))

(define (ai--chat-page)
  (let* ((chat (ai--chat)))
    (if (not chat)
        (ai--page "No chat" #f #f #f '()
          (list (list "About" (ai--group "About" (list (ai--prose "Open this app from a chat (C-l C-l) to set that chat up."))))))
        (let* ((now (llm-config-combination chat))
               (conn (plist-get now 'connector))
               (on (or (plist-get now 'presets) '()))
               (off (or (plist-get now 'prompt-disabled) '()))
               (state (llm-connectors-state conn))
               (preset (llm-config-preset-name chat))
               (g (ai--group-of chat))
               (group-default (ai--setup-name (and g (llm-group-bundle g))))
               (global-default (ai--setup-name (llm-default-bundle-record))))
          (ai--page chat conn (if (equal? state "ready") "good" "warn")
            (ai--meta (list (or preset "own setup") (string-append "permission " (plist-get now 'permission))
                            (string-append "sandbox " (plist-get now 'sandbox))))
            (append
              (list (list "ai-backend" "Backend" "b") (list "ai-model" "Model" "m")
                    (list "ai-effort" "Effort" "e") (list "ai-tools" "Tools" "u")
                    (list "ai-save" "Save as new preset…" "s" "good"))
              (if preset (list (list "ai-update-preset" (string-append "Update " preset) "U")) '())
              (if g (list (list "ai-group-default" "Default for this group" "G")) '())
              (list (list "ai-global-default" "Default for every group" "A")))
            (list (list "Setup"
                        (component 'ui/stats
                          (list 'stats (list (list 'label "Backend" 'value conn 'sub state 'class (if (equal? state "ready") "good" "warn"))
                                             (list 'label "Model" 'value (plist-get now 'model))
                                             (list 'label "Effort" 'value (plist-get now 'effort))
                                             (list 'label "Tools" 'value (number->string (length on)) 'sub "on")))))
                  (list "Tools"
                        (ai--group (string-append "Tools · " (number->string (length on)) " on")
                          (list (component 'ui/table
                                  (list 'columns '(("tool") ("about") ("in this chat"))
                                        'rows (map (lambda (t) (list (car t) (ai--clip (cadr t) 70)
                                                                     (if (caddr t) (list "● on" "good") "○ off")))
                                                   (ai--tool-rows on))))
                                (ai--prose "u turns them on and off."))))
                  (list "Saved as"
                        (ai--group "Saved as"
                          (list (ai--kv (list (list "Preset" (or preset "none: s saves this setup as one"))
                                              (list (if g (string-append "New chats in " (group-name g)) "This group")
                                                    (or group-default "the global default"))
                                              (list "New chats elsewhere" (or global-default "none")))))))
                  (list "Prompt"
                        (ai--group "Prompt"
                          (list (ai--prose (if (null? off) "Every prompt section is on. The prompts tab turns one off."
                                               (string-append "Off in this chat: " (string-join off ", ")))))))
                  (list "Connector"
                        (ai--group (string-append "Connector · " conn)
                          (list (ai--kv (cons (list "About" (llm-connectors--about conn))
                                              (ai--test-pairs (llm-connectors-test-result conn)))))))))))))

(define (ai--preset-page row)
  (let* ((name (plist-get row 'name))
         (b (llm-bundle-named name))
         (chat (ai--chat))
         (on (and chat (equal? (llm-config-preset-name chat) name)))
         (tools (llm-bundle-get b 'presets '())))
    (ai--page name (if on "in use" #f) "good"
      (ai--meta (list (llm-bundle-get b 'connector "") (llm-bundle-get b 'model "default") (or (llm-bundle-label b) "")))
      (append (list (list "ai-apply" (if chat (string-append "Apply to " (ai--clip chat 30)) "Apply") "a" "good"))
              (if (ai--group-of chat) (list (list "ai-group-default" "Default for this group" "G")) '())
              (list (list "ai-global-default" "Default for every group" "A")))
      (list (list "Default"
                  (ai--group "Default"
                    (list (ai--prose
                            (let* ((g (ai--group-of chat))
                                   (in-group (and g (equal? (ai--setup-name (llm-group-bundle g)) name)))
                                   (global (equal? (ai--setup-name (llm-default-bundle-record)) name)))
                              (cond ((and in-group global) "New chats start with this preset, here and in every group without its own.")
                                    (in-group (string-append "New chats in " (group-name g) " start with this preset."))
                                    (global "New chats start with this preset where the group names none.")
                                    (else "Not a default. G makes it this group's, A every group's.")))))))
            (list "Setup"
                  (ai--group "Setup"
                    (list (ai--kv (list (list "Backend" (llm-bundle-get b 'connector ""))
                                        (list "Model" (llm-bundle-get b 'model "default"))
                                        (list "Effort" (llm-bundle-get b 'effort "default"))
                                        (list "Tools" (if (null? tools) "none" (string-join (map (lambda (t) (if (symbol? t) (symbol->string t) t)) tools) ", ")))
                                        (list "Permission" (llm-bundle-get b 'permission ""))
                                        (list "Sandbox" (llm-bundle-get b 'sandbox "")))))))))))

(define (ai--prompt-page row)
  (let* ((name (plist-get row 'name))
         (path (plist-get row 'path))
         (chat (ai--chat))
         (off (and chat (member name (prompt-disabled-parts chat))))
         (text (ai--file-text path)))
    (ai--page name (if off "off" "on") (if off "" "good")
      (ai--meta (list (ai--prompt-source path) (string-append (number->string (length (string-split text "\n"))) " lines")))
      (list (list "ai-toggle" (if off "Turn on" "Turn off") "o" (if off "good" "bad")) (list "ai-visit" "Edit" "v"))
      (list (list "Text" (ai--group "Text" (list (ai--prose (ai--clip text 6000)))))))))

(define (ai--connector-page row)
  (let* ((n (plist-get row 'name))
         (state (llm-connectors-state n))
         (models (llm-connectors-models n))
         (shown (if (> (length models) 40) (list-head models 40) models)))
    (ai--page (llm-connectors--title n) state (if (equal? state "ready") "good" "warn")
      (ai--meta (list (llm-connectors-kind n) (string-append (number->string (length models)) " models")
                      (if (llm-connectors--default? n) "new chats use it" "")))
      (list (list "ai-test" "Test" "t" "good") (list "ai-install" "Install" "i") (list "ai-sign-in" "Sign in" "l")
            (list "ai-key" "Key" "k") (list "ai-default" "Make default" "d") (list "ai-page" "Full page ↗" "P"))
      (append
        (list (list "About" (ai--group "About" (list (ai--prose (llm-connectors--about n)))))
              (list "Last test" (ai--group "Last test" (list (ai--kv (ai--test-pairs (llm-connectors-test-result n)))))))
        (if (null? shown) '()
            (list (list "Models"
                        (ai--group (string-append "Models · " (number->string (length models)))
                          (list (component 'ui/table
                                  (list 'columns '(("model") ("about") ("last test"))
                                        'rows (map (lambda (m)
                                                     (let ((r (llm-connectors-test-result n (car m))))
                                                       (list (car m) (ai--clip (or (cadr m) "") 60)
                                                             (if r (list (llm-connectors--result-short r) (if (equal? (plist-get r 'status) "ok") "good" "bad")) ""))))
                                                   shown))))))))))))

(define (ai--model-page row)
  (let* ((e (plist-get row 'entry))
         (host (models--entry-host e)))
    (ai--page (plist-get e 'name) (if (plist-get e 'loaded) "loaded" "installed") (if (plist-get e 'loaded) "good" "")
      (ai--meta (list (models--host-label host) (models--size-label (plist-get e 'size))))
      (list (list "ai-load" "Load" "x" "good") (list "ai-install" "Install another…" "i") (list "ai-uninstall" "Uninstall" "D" "bad"))
      (list (list "Details"
                  (ai--group "Details"
                    (list (ai--kv (list (list "Host" (models--host-label host))
                                        (list "Size" (models--size-label (plist-get e 'size)))
                                        (list "Parameters" (plist-get e 'params))
                                        (list "Quantization" (plist-get e 'quant))
                                        (list "State" (models--state e)))))))))))

(define (ai--suggest-page row)
  (ai--page (plist-get row 'name) "not installed" ""
    (ai--meta (list (string-append "installs on " (models--host-label (plist-get row 'host)))))
    (list (list "ai-install" "Install" "i" "good"))
    (list (list "About" (ai--group "About" (list (ai--prose (string-append (plist-get row 'about) "\n\nInstalling pulls the model with ollama; a large one takes minutes."))))))))

(define (ai--page-of row)
  (let ((kind (plist-get row 'kind)))
    (cond ((equal? kind "chat") (ai--chat-page))
          ((equal? kind "preset") (ai--preset-page row))
          ((equal? kind "prompt") (ai--prompt-page row))
          ((equal? kind "connector") (ai--connector-page row))
          ((equal? kind "model") (ai--model-page row))
          ((equal? kind "suggest") (ai--suggest-page row))
          (else #f))))

;; --- show ------------------------------------------------------------

(effects! '(write display))

(define (ai--detail-buffer row) (string-append "*ai:" (plist-get row 'kind) ":" (plist-get row 'id) "*"))

(define (ai--render-page! buf row)
  (let ((page (ai--page-of row)))
    (when page
      (buffer-set-local! buf 'ai-row row)
      (buffer-set-read-only! buf #f)
      (buffer-set-text! buf (car page) #t)
      (buffer-set-local! buf 'render-mode "blocks")
      (buffer-set-local! buf 'render-blocks (cadr page))
      (anchor-set-blocks! buf (car page) (cadr page))
      (unless (minor-mode-on? buf "anchor-mode") (enable-minor-mode! buf "anchor-mode"))
      (anchor-sync! buf)
      (buffer-set-local! buf 'footer-line-blocks
        (list (component 'ui/keys-bar (list 'main (append (ai--keys-of row) '(("g" "refresh") ("q" "quit")))))))
      (buffer-set-read-only! buf #t)
      buf)))

(define (ai-show-detail! row)
  "(ai-show-detail! ROW) -- show the page of ROW beside the AI listing"
  (when (and row (not (ai--sep? row)) (ai--page-of row))
    (let* ((list-buf (ai--list))
           (buf (ai--detail-buffer row)))
      (unless (buffer-known? buf)
        (buffer-create buf)
        (let ((g (buffer-group list-buf))) (when g (buffer-move-to-group! buf g)))
        (with-current-buffer buf (lambda () (set-mode! "ai-detail-mode")))
        (desktop-skip! buf 'render-blocks)
        (desktop-skip! buf 'footer-line-blocks))
      (buffer-set-local! buf 'ai-list list-buf)
      (ai--render-page! buf row)
      (display-buffer-detail! buf list-buf)
      buf)))

(define (ai--redraw!)
  "draw the listing and the open pages again from the live state"
  (let ((l (list-mode-group-buffer "ai-mode")))
    (when (buffer-known? l)
      (list-refresh! l)
      (for-each (lambda (b)
                  (let ((r (buffer-local-value 'ai-row b)))
                    (when r (ai--render-page! b (if (equal? (plist-get r 'kind) "model")
                                                    (or (find (lambda (x) (equal? (plist-get x 'id) (plist-get r 'id))) (ai--model-rows)) r)
                                                    r)))))
                (filter (lambda (b) (equal? (buffer-local-value 'mode-name b) "ai-detail-mode")) (buffer-list))))))

(define (ai--on-change buf) (ai--redraw!))
(add-hook! 'llm-config-changed-hook 'ai--on-change)

(effects! '(write external))

(define (ai--models-fetch!)
  (unless *ai-models-busy*
    (set! *ai-models-busy* #t)
    (models--fetch (ai--list)
      (lambda (es)
        (set! *ai-models-busy* #f)
        (set! *ai-models* es)
        (ai--redraw!)))))

(define (ai--models-done! verb name)
  (lambda (reply)
    (models--report! verb name reply)
    (set! *ai-models* #f)
    (ai--models-fetch!)))

(define (ai-install-model! host name)
  "(ai-install-model! HOST NAME) -- pull model NAME onto model HOST; the list reads the host again when it is in"
  (when (models--manages? host)
    (message (string-append "installing " name " on " (models--host-label host) ", this takes minutes…"))
    (*models-request* host "POST" "/api/pull" (models--model-body name 'stream #f) models-pull-timeout
      (ai--models-done! "installed" name))))

;; --- the verbs: one key, the same on the listing and the page ---------

(effects! '(write))

(define (ai--with kinds what fn)
  (let ((r (ai--at)))
    (if (and r (member (plist-get r 'kind) kinds))
        (fn r)
        (message (string-append "Nothing to " what " on this row")))))

(define (ai--dialog! section)
  (let ((chat (ai--chat)))
    (if (not chat)
        (message "Open this app from a chat to set it up")
        (begin (set! *vscode-llm-advanced* #t)
               (vscode--llm-open! chat section)))))

(define-command "ai" "Open the AI app: a chat's LLM setup, the prompts, the connectors and the local models"
  (lambda ()
    (let ((here (or (window-buffer (active-window)) (current-buffer))))
      (unless (member (buffer-local-value 'mode-name here) '("ai-mode" "ai-detail-mode"))
        (set! *ai-chat* (llm-config-session here))))
    (unless *ai-models* (ai--models-fetch!))
    (let ((buf (list-mode-show! "ai-mode")))
      (list-refresh! buf)
      (ai-show-detail! (list-current buf))
      buf)))

(define-command "ai-do" "Do the main thing of the row: pick a preset, apply, turn on or off, test, load or install"
  (lambda ()
    (let* ((r (ai--at)) (kind (and r (plist-get r 'kind))))
      (cond ((equal? kind "chat") (ai--dialog! "p"))
            ((equal? kind "preset") (run-command "ai-apply"))
            ((equal? kind "prompt") (run-command "ai-toggle"))
            ((equal? kind "connector") (run-command "ai-test"))
            ((equal? kind "model") (run-command "ai-load"))
            ((equal? kind "suggest") (run-command "ai-install"))
            (else #f))))
  'modes '(ai-mode ai-detail-mode))

(define-command "ai-backend" "Choose the backend of the chat" (lambda () (ai--with '("chat") "change" (lambda (r) (ai--dialog! "b")))) 'modes '(ai-mode ai-detail-mode))
(define-command "ai-model" "Choose the model of the chat" (lambda () (ai--with '("chat") "change" (lambda (r) (ai--dialog! "m")))) 'modes '(ai-mode ai-detail-mode))
(define-command "ai-effort" "Choose the reasoning effort of the chat" (lambda () (ai--with '("chat") "change" (lambda (r) (ai--dialog! "e")))) 'modes '(ai-mode ai-detail-mode))
(define-command "ai-tools" "Turn the chat's tools and MCP servers on and off" (lambda () (ai--with '("chat") "change" (lambda (r) (ai--dialog! "t")))) 'modes '(ai-mode ai-detail-mode))
(define (ai--setup-of r)
  ;; what a save or a default takes: the chat's whole setup, or the preset's name
  (if (equal? (plist-get r 'kind) "chat")
      (and (ai--chat) (llm-config-combination (ai--chat)))
      (plist-get r 'name)))

(define (ai--save-preset! chat name)
  (llm-bundle-save! name (llm-config-combination chat))
  (buffer-set-local! chat 'llm-preset name)
  (llm-config-changed! chat)
  (message (string-append "saved this setup as preset " name)))

(define-command "ai-save" "Save the chat's setup as a new preset"
  (lambda ()
    (ai--with '("chat") "save"
      (lambda (r)
        (let ((chat (ai--chat)))
          (if (not chat) (message "Open this app from a chat to save its setup")
              (minibuffer-read "New preset name: " (map llm-bundle-name *llm-bundles*)
                (lambda (name)
                  (let ((n (string-trim name)))
                    (cond ((equal? n "") #f)
                          ((llm-bundle-named n)
                           (yes-or-no? (string-append "Preset " n " exists. Overwrite it? ")
                             (lambda (ok) (when ok (ai--save-preset! chat n)))))
                          (else (ai--save-preset! chat n)))))))))))
  'modes '(ai-mode ai-detail-mode))

(define-command "ai-update-preset" "Write the chat's setup into the preset it runs"
  (lambda ()
    (ai--with '("chat") "update"
      (lambda (r)
        (let* ((chat (ai--chat)) (preset (and chat (llm-config-preset-name chat))))
          (if (not preset) (message "This chat runs no preset: s saves its setup as a new one")
              (ai--save-preset! chat preset))))))
  'modes '(ai-mode ai-detail-mode))

(define-command "ai-group-default" "Make the chat's setup, or the preset on this row, what new chats in this group start with"
  (lambda ()
    (ai--with '("chat" "preset") "make a default"
      (lambda (r)
        (let ((g (ai--group-of (ai--chat))) (setup (ai--setup-of r)))
          (cond ((not g) (message "No group here"))
                ((not setup) (message "Open this app from a chat to use its setup"))
                (else (group-llm! setup g)
                      (ai--redraw!)
                      (message (string-append (group-name g) ": new chats start with " (ai--setup-name setup)))))))))
  'modes '(ai-mode ai-detail-mode))

(define-command "ai-global-default" "Make the chat's setup, or the preset on this row, what new chats start with where the group names none"
  (lambda ()
    (ai--with '("chat" "preset") "make a default"
      (lambda (r)
        (let ((setup (ai--setup-of r)))
          (if (not setup) (message "Open this app from a chat to use its setup")
              (begin (llm-default-save! (if (string? setup) (llm-bundle-named setup) setup))
                     (ai--redraw!)
                     (message (string-append "new chats start with " (ai--setup-name setup) " where the group names none"))))))))
  'modes '(ai-mode ai-detail-mode))

(define-command "ai-apply" "Run the preset on this row in the chat"
  (lambda ()
    (ai--with '("preset") "apply"
      (lambda (r)
        (let ((chat (ai--chat)) (name (plist-get r 'name)))
          (if (not chat) (message "Open this app from a chat to apply a preset")
              (begin (llm-bundle-apply! chat (llm-bundle-named name))
                     (buffer-set-local! chat 'llm-preset name)
                     (llm-config-changed! chat)
                     (message (string-append chat " now runs " name))))))))
  'modes '(ai-mode ai-detail-mode))

(define-command "ai-toggle" "Turn the prompt section on this row on or off in the chat"
  (lambda ()
    (ai--with '("prompt") "turn on or off"
      (lambda (r)
        (let ((chat (ai--chat)) (name (plist-get r 'name)))
          (if (not chat) (message "Open this app from a chat to change its prompt")
              (let ((off (member name (prompt-disabled-parts chat))))
                (if off (prompt-section-on! chat name) (prompt-section-off! chat name))
                (ai--redraw!)
                (message (string-append name (if off " is on in " " is off in ") chat))))))))
  'modes '(ai-mode ai-detail-mode))

(define-command "ai-visit" "Edit the prompt file on this row in the other window"
  (lambda ()
    (ai--with '("prompt") "edit"
      (lambda (r) (window-set-buffer! (get-other-window) (visit (ai--prompt-source (plist-get r 'path)) (buffer-group (current-buffer)))))))
  'modes '(ai-mode ai-detail-mode))

(define-command "ai-default" "Make the connector on this row the one new chats use"
  (lambda () (ai--with '("connector") "make default" (lambda (r) (llm-connectors-make-default! (plist-get r 'name)) (ai--redraw!))))
  'modes '(ai-mode ai-detail-mode))

(define-command "ai-page" "Show the connector on this row in the connectors app, with every model"
  (lambda () (ai--with '("connector") "show" (lambda (r) (run-command "llm-connectors") (llm-connectors-show-detail! (plist-get r 'name)))))
  'modes '(ai-mode ai-detail-mode))

(define-command "ai-refresh" "Read every tab again: the setup, the prompts, the connectors and the model hosts"
  (lambda () (set! *ai-models* #f) (ai--models-fetch!) (ai--redraw!))
  'modes '(ai-mode ai-detail-mode))

(effects! '(write execute external))

(define-command "ai-install" "Install the connector's agent program, or a model on a model host"
  (lambda ()
    (let* ((r (ai--at)) (kind (and r (plist-get r 'kind))))
      (cond ((equal? kind "connector") (llm-connectors-install! (plist-get r 'name)))
            ((equal? kind "suggest") (ai-install-model! (plist-get r 'host) (plist-get r 'name)))
            ((equal? kind "model")
             (let ((host (models--entry-host (plist-get r 'entry))))
               (read-string (string-append "Install on " (models--host-label host) " (an ollama name): ")
                 (lambda (input) (let ((n (string-trim input))) (unless (equal? n "") (ai-install-model! host n)))))))
            (else (message "Nothing to install on this row")))))
  'modes '(ai-mode ai-detail-mode))

(define-command "ai-sign-in" "Sign in to the connector on this row in a terminal"
  (lambda () (ai--with '("connector") "sign in to" (lambda (r) (llm-connectors-sign-in! (plist-get r 'name)))))
  'modes '(ai-mode ai-detail-mode))

(define-command "ai-key" "Add or change the API key of the connector on this row"
  (lambda () (ai--with '("connector") "add a key to" (lambda (r) (llm-connectors-add-key! (plist-get r 'name)))))
  'modes '(ai-mode ai-detail-mode))

(define-command "ai-load" "Load the model on this row into its host's memory"
  (lambda ()
    (ai--with '("model") "load"
      (lambda (r)
        (let* ((e (plist-get r 'entry)) (host (models--entry-host e)) (name (plist-get e 'name)))
          (when (models--loads? host)
            (message (string-append "loading " name "…"))
            (if (equal? (models--kind host) 'daemon)
                (models--daemon-op! host "load" name "loaded")
                (*models-request* host "POST" "/api/generate" (models--model-body name 'keep_alive models-keep-alive 'stream #f) 600
                  (ai--models-done! "loaded" name))))))))
  'modes '(ai-mode ai-detail-mode))

(define-command "ai-uninstall" "Uninstall the model on this row from its host"
  (lambda ()
    (ai--with '("model") "uninstall"
      (lambda (r)
        (let* ((e (plist-get r 'entry)) (host (models--entry-host e)) (name (plist-get e 'name)))
          (when (models--manages? host)
            (yes-or-no? (string-append "Uninstall " name " from " (models--host-label host) "? ")
              (lambda (ok)
                (when ok
                  (*models-request* host "DELETE" "/api/delete" (models--model-body name) 60
                    (ai--models-done! "uninstalled" name))))))))))
  'modes '(ai-mode ai-detail-mode))

(effects! '(write external spend))

(define-command "ai-test" "Test the connector on this row with a short message, and time the reply"
  (lambda ()
    (ai--with '("connector") "test"
      (lambda (r)
        (message (string-append "testing " (plist-get r 'name) "…"))
        (llm-connectors-test! (plist-get r 'name) (lambda (res) (ai--redraw!))))))
  'modes '(ai-mode ai-detail-mode))

;; --- the modes -------------------------------------------------------

(effects! '(write))

(define *ai-keys*
  '(("RET" "ai-do") ("b" "ai-backend") ("m" "ai-model") ("e" "ai-effort") ("u" "ai-tools")
    ("s" "ai-save") ("U" "ai-update-preset") ("G" "ai-group-default") ("A" "ai-global-default") ("a" "ai-apply") ("o" "ai-toggle") ("v" "ai-visit") ("t" "ai-test")
    ("i" "ai-install") ("l" "ai-sign-in") ("k" "ai-key") ("d" "ai-default") ("P" "ai-page")
    ("x" "ai-load") ("D" "ai-uninstall") ("g" "ai-refresh") ("q" "quit-window")))

(define *ai-doc*
  (string-append
    "The LLM setup in one place, in four tabs; <left> and <right> step them. Moving the point shows the row's page beside the list, "
    "and every key works the same on the list and on the page. setup: the chat the app was opened from, and the presets. "
    "RET picks a preset, b the backend, m the model, e the effort, u the tools, s saves the setup as a new preset, U writes it into the preset the chat runs, "
    "G makes it what new chats in this group start with, A what new chats start with elsewhere; "
    "on a preset a applies it, and G and A make the preset a default. prompts: every prompt section, o turns it on or off in the chat, v edits its file. "
    "connectors: t tests one and times the reply, i installs its agent program, l signs in, k adds an API key, "
    "d makes it the default for new chats, P shows it in the connectors app. models: what each model host holds, "
    "and models to install on this machine: x loads one, i installs, D uninstalls. g reads everything again, / narrows, q quits."))

(define-list-mode! "ai-mode"
  (list
    'doc *ai-doc*
    'buffer *ai-buffer*
    'transient #f
    'rows ai--rows
    'key (lambda (buf r) (string-append (plist-get r 'kind) ":" (plist-get r 'id)))
    'tabs (map (lambda (t) (list t (lambda (buf r) (equal? (plist-get r 'tab) t)))) *ai-tabs*)
    'separator? (lambda (buf r) (ai--sep? r))
    'section? (lambda (buf r) (ai--sep? r))
    'section-label (lambda (buf r) (plist-get r 'title))
    'markable? (lambda (buf r) #f)
    'columns (lambda (buf) (list (list "name" 30) (list "state" 16) (list "about" #f)))
    'cells ai--cells
    'layouts (list (list 'name 'narrow 'max-cols (lambda (buf) 72)
                         'columns (lambda (buf) (list (list "name" 24) (list "state" #f)))
                         'cells (lambda (buf r) (let ((cs (ai--cells buf r))) (list (car cs) (cadr cs)))))
                   (list 'name 'wide 'default #t))
    'preview (lambda (buf r) (ai-show-detail! r))
    'title (lambda (buf) "AI")
    'meta (lambda (buf)
            (let ((chat (ai--chat)))
              (string-append (if chat (string-append "setting up " chat) "no chat")
                             " · new chats use " *default-connector*)))
    'total (lambda (buf) (length (filter (lambda (r) (not (ai--sep? r))) (list-entries buf))))
    'noun "row"
    'no-marks #t
    'local-filter #t
    'footer (lambda (buf)
              (append (ai--keys-of (list-current buf))
                      '(("←/→" "tab") ("/" "filter") ("g" "refresh") ("q" "quit"))))
    'keys *ai-keys*))

(define-command "ai-scroll-line-down" "Scroll the page three lines down"
  (lambda () (scroll-window! (active-window) 3))
  'modes '(ai-detail-mode))
(define-command "ai-scroll-line-up" "Scroll the page three lines up"
  (lambda () (scroll-window! (active-window) -3))
  'modes '(ai-detail-mode))

(define-mode "ai-detail-mode" (lambda () (buffer-set-read-only! (current-buffer) #t)))
;; a page is read, not typed in: SPC and the arrows scroll it
(mode-keys! "ai-detail-mode"
  (append (filter (lambda (k) (not (equal? (car k) "q"))) *ai-keys*)
          '(("SPC" "scroll-up-command") ("S-SPC" "scroll-down-command") ("DEL" "scroll-down-command")
            ("<down>" "ai-scroll-line-down") ("<up>" "ai-scroll-line-up")
            ("C-n" "ai-scroll-line-down") ("C-p" "ai-scroll-line-up"))))
(mode-doc! "ai-detail-mode" (string-append "One row of the AI app as a page. SPC and S-SPC scroll it a screen, the arrows and C-n, C-p a few lines, M-<down> and M-<up> part by part. " *ai-doc*))
(detail-name! "ai-detail-mode"
  (lambda (buf) (let ((r (buffer-local-value 'ai-row buf))) (string-append "*" (if r (plist-get r 'name) buf) "*"))))

(effects! '(write display))
(public! 'ai-show-detail! "(ai-show-detail! ROW) -- show the page of ROW beside the AI listing")
(effects! '(write execute external))
(public! 'ai-install-model! "(ai-install-model! HOST NAME) -- pull model NAME onto model HOST; the list reads the host again when it is in")

(provide 'ai)
