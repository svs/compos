;;; transient.scm --- temporary command menus, after Emacs Transient.
;;;
;;; A transient keeps the source buffer selected. The command palette shows
;;; its menu, and a frame-local Scheme keymap owns input until exit.

(package! 'transient 'transient)
(domain! 'interaction)
(effects! '(write))

(define *transient-prefixes* '())
(define *transient-defaults* '())
(define *transient-history* '())
(define transient-default-level 4)
(define transient-history-limit 20)

(define (transient--put pl key value)
  (append (list key value)
    (let loop ((xs pl))
      (cond ((null? xs) '())
            ((null? (cdr xs)) '())
            ((equal? (car xs) key) (loop (cdr (cdr xs))))
            (else (cons (car xs) (cons (cadr xs) (loop (cdr (cdr xs))))))))))

(define (transient--alist-put al key value)
  (cons (list key value)
    (filter (lambda (e) (not (equal? (car e) key))) al)))

(define (transient--alist-get al key fallback)
  (let ((e (assoc key al))) (if e (cadr e) fallback)))

(define (transient-prefix name) (assoc name *transient-prefixes*))

(define (transient--prefix-option prefix key)
  (plist-get (car (cdr (cdr (cdr prefix)))) key))

(define (transient--run-hook prefix key state)
  (let ((fn (and prefix (transient--prefix-option prefix key))))
    (when fn (fn (plist-get state 'scope)))))

(define (transient-suffix key description command &rest properties)
  (append (list 'kind 'suffix 'key key 'description description 'command command)
          properties))

(define (transient-infix key description command value-fn &rest properties)
  (append (list 'kind 'infix 'key key 'description description
                'command command 'value-fn value-fn 'transient 'stay)
          properties))

(define (transient-switch key description argument &rest properties)
  (append (list 'kind 'switch 'key key 'description description
                'argument argument 'transient 'stay)
          properties))

(define (transient-choice key description argument choices &rest properties)
  (append (list 'kind 'choice 'key key 'description description
                'argument argument 'choices choices 'transient 'stay)
          properties))

(define (transient--item-wrapper prefix item)
  (string-append "transient:" prefix ":" (plist-get item 'key)))

(define (transient--install-item prefix item)
  (let ((name (transient--item-wrapper prefix item))
        (kind (plist-get item 'kind)))
    (define-command--raw name
      (lambda ()
        (if (or (equal? kind 'switch) (equal? kind 'choice))
            (transient--invoke-value prefix item)
            (transient--invoke-command prefix item))))
    (transient--put item 'wrapper name)))

(define (transient--prefix-put prefix)
  (set! *transient-prefixes*
    (cons prefix
      (filter (lambda (e) (not (equal? (car e) (car prefix))))
              *transient-prefixes*))))

(define (transient-define-prefix name doc groups &rest options)
  (transient--prefix-put (list name doc groups options))
  (define-command name doc
    (lambda () (transient-setup name (current-buffer))))
  name)

(define (transient--active) (frame-local 'transient-active))
(define (transient--set-active! state) (set-frame-local! 'transient-active state))

(define (transient-scope)
  (let ((state (transient--active))) (and state (plist-get state 'scope))))

(define (transient-value argument)
  (let ((state (transient--active)))
    (and state
         (transient--alist-get (plist-get state 'values) argument #f))))

(define (transient--set-value! argument value)
  (let* ((state (transient--active))
         (values (transient--alist-put (plist-get state 'values) argument value)))
    (transient--set-active! (transient--put state 'values values))))

(define (transient--raw-groups prefix state)
  (let ((groups (caddr prefix)))
    (if (procedure? groups) (groups (plist-get state 'scope)) groups)))

(define (transient--groups prefix state)
  (map (lambda (group)
         (cons (car group)
           (map (lambda (item) (transient--install-item (car prefix) item))
                (cdr group))))
       (transient--raw-groups prefix state)))

(define (transient--item-visible? item state)
  (let ((level (or (plist-get item 'level) 4))
        (pred (plist-get item 'if)))
    (and (<= level (or (plist-get state 'level) transient-default-level))
         (or (not pred) (pred (plist-get state 'scope))))))

(define (transient--visible-groups prefix state)
  (map (lambda (group)
         (cons (car group)
           (filter (lambda (item) (transient--item-visible? item state))
                   (cdr group))))
       (transient--groups prefix state)))

(define (transient--visible-items groups)
  (let loop ((gs groups) (out '()))
    (if (null? gs)
        (reverse out)
        (loop (cdr gs) (append (reverse (cdr (car gs))) out)))))

(define (transient--item-default item)
  (let ((kind (plist-get item 'kind)))
    (cond ((equal? kind 'switch) (or (plist-get item 'default) #f))
          ((equal? kind 'choice)
           (or (plist-get item 'default)
               (let ((choices (plist-get item 'choices)))
                 (and (pair? choices)
                      (if (pair? (car choices)) (car (car choices)) (car choices))))))
          (else #f))))

(define (transient--initial-values prefix groups)
  (let ((saved (assoc (car prefix) *transient-defaults*)))
    (if saved
        (cadr saved)
        (let loop ((items (transient--visible-items groups)) (values '()))
          (if (null? items)
              values
              (let* ((item (car items))
                     (argument (plist-get item 'argument)))
                (loop (cdr items)
                  (if argument
                      (transient--alist-put values argument
                        (transient--item-default item))
                      values))))))))

(define (transient--close-menu!)
  (set-frame-local! 'transient-keymap #f)
  (transient-show! #f))

(define (transient--choice-pair choice)
  (if (pair? choice) choice (list choice choice)))

(define (transient--choice-next choices value)
  (if (null? choices)
      #f
      (let loop ((rest choices))
        (cond ((null? rest) (car (transient--choice-pair (car choices))))
              ((equal? (car (transient--choice-pair (car rest))) value)
               (if (pair? (cdr rest))
                   (car (transient--choice-pair (cadr rest)))
                   (car (transient--choice-pair (car choices)))))
              (else (loop (cdr rest)))))))

;; An infix always carries a value-fn. A suffix may carry one too: a row
;; that opens a view still says what the view holds.
(define (transient--item-value item)
  (let ((kind (plist-get item 'kind))
        (fn (plist-get item 'value-fn)))
    (cond ((equal? kind 'switch)
           (if (transient-value (plist-get item 'argument)) "on" "off"))
          ((equal? kind 'choice)
           (let* ((value (transient-value (plist-get item 'argument)))
                  (choice (assoc value (map transient--choice-pair
                                            (plist-get item 'choices)))))
             (if choice (cadr choice) (value->string value))))
          (fn
           (let ((value (fn (transient-scope))))
             (if (string? value) value (value->string value))))
          (else ""))))

(define (transient--bindings groups)
  (append
    (map (lambda (item) (list (plist-get item 'key) (plist-get item 'wrapper)))
         (transient--visible-items groups))
    (list (list "C-g" "transient-quit-one")
          (list "C-q" "transient-quit-all")
          (list "ESC ESC ESC" "transient-quit-all")
          (list "C-z" "transient-suspend")
          (list "?" "transient-toggle-help")
          (list "C-h" "transient-toggle-help")
          (list "<up>" "transient-previous")
          (list "<down>" "transient-next")
          (list "RET" "transient-invoke-selected")
          (list "M-RET" "transient-invoke-selected")
          (list "C-M-p" "transient-history-prev")
          (list "C-M-n" "transient-history-next")
          (list "C-x s" "transient-set")
          (list "C-x C-s" "transient-save")
          (list "C-x C-k" "transient-reset"))))

(define (transient-dispatch-key sequence)
  (let* ((key (string-join sequence " "))
         (bindings (or (frame-local 'transient-keymap) '()))
         (exact (assoc key bindings))
         (prefix (string-append key " ")))
    (cond (exact (list "command" (cadr exact)))
          ((let loop ((xs bindings))
             (and (pair? xs)
                  (or (string-prefix? prefix (car (car xs)))
                      (loop (cdr xs)))))
           (list "prefix"))
          (else (list "none")))))

(define (transient--menu-groups groups state)
  (let ((selected (or (plist-get state 'selected) 0))
        (index 0)
        (help? (plist-get state 'help)))
    (map
      (lambda (group)
        (list (car group)
          (map
            (lambda (item)
              (let ((selected? (= index selected)))
                (set! index (+ index 1))
                (list (plist-get item 'key)
                      (if help?
                          (let ((command (plist-get item 'command)))
                            (if (string? command) (command-doc command)
                                (plist-get item 'description)))
                          (plist-get item 'description))
                      (transient--item-value item)
                      (plist-get item 'kind)
                      (or (plist-get item 'transient) 'exit)
                      selected?)))
            (cdr group))))
      groups)))

(define (transient--render!)
  (let* ((state (transient--active))
         (prefix (and state (transient-prefix (plist-get state 'prefix)))))
    (when prefix
      (let* ((groups (transient--visible-groups prefix state))
             (items (transient--visible-items groups))
             (selected (min (or (plist-get state 'selected) 0)
                            (max 0 (- (length items) 1))))
             (state (transient--put state 'selected selected)))
        (transient--set-active! state)
        (set-frame-local! 'transient-keymap (transient--bindings groups))
        (transient-show!
          (list (cadr prefix) (transient--menu-groups groups state)))))))

(define (transient-setup name &optional scope)
  (let ((prefix (transient-prefix name)))
    (if (not prefix)
        (message (string-append "No such transient: " name))
        (let* ((parent (transient--active))
               (seed (list 'prefix name 'scope (or scope (current-buffer))
                           'values '() 'stack (if parent (cons parent (plist-get parent 'stack)) '())
                           'selected 0 'history-index -1 'level transient-default-level
                           'help #f))
               (groups (transient--visible-groups prefix seed))
               (state (transient--put seed 'values
                        (transient--initial-values prefix groups))))
          (transient--set-active! state)
          (transient--run-hook prefix 'on-setup state)
          (transient--render!)))))

(define (transient--remember! state)
  (let* ((name (plist-get state 'prefix))
         (values (plist-get state 'values))
         (old (transient--alist-get *transient-history* name '()))
         (history (take-n (cons values (remove (lambda (v) (equal? v values)) old))
                          transient-history-limit)))
    (set! *transient-history* (transient--alist-put *transient-history* name history))))

(define (transient--export! state)
  (set-frame-local! 'transient-current-prefix (plist-get state 'prefix))
  (set-frame-local! 'transient-current-values (plist-get state 'values)))

(define (transient--exit! state)
  (transient--run-hook
    (transient-prefix (plist-get state 'prefix)) 'on-quit state)
  (transient--remember! state)
  (transient--export! state)
  (transient--close-menu!)
  (transient--set-active! #f))

(define (transient--call command)
  (cond ((string? command) (run-command command))
        ((procedure? command) (command))
        (else #f)))

(define (transient--invoke-command prefix item)
  (let ((state (transient--active)))
    (when (and state (equal? prefix (plist-get state 'prefix)))
      (let ((command (plist-get item 'command)))
        (cond
          ((and (string? command) (transient-prefix command))
           (transient-setup command (plist-get state 'scope)))
          ((equal? (plist-get item 'transient) 'stay)
           (transient--export! state)
           (transient--call command)
           (when (transient--active) (transient--render!)))
          (else
           (transient--exit! state)
           (transient--call command)))))))

(define (transient--invoke-value prefix item)
  (let ((state (transient--active)))
    (when (and state (equal? prefix (plist-get state 'prefix)))
      (let* ((kind (plist-get item 'kind))
             (argument (plist-get item 'argument))
             (old (transient-value argument))
             (value (if (equal? kind 'switch)
                        (not old)
                        (transient--choice-next (plist-get item 'choices) old))))
        (transient--set-value! argument value)
        (transient--render!)))))

(define (transient-args &optional prefix-name)
  (let* ((state (transient--active))
         (name (or prefix-name
                   (and state (plist-get state 'prefix))
                   (frame-local 'transient-current-prefix)))
         (values (if state (plist-get state 'values)
                     (or (frame-local 'transient-current-values) '())))
         (prefix (transient-prefix name)))
    (if (not prefix) '()
        (let loop ((items (transient--visible-items
                            (transient--groups prefix
                              (or state (list 'scope #f 'values values 'level 7)))))
                   (out '()))
          (if (null? items)
              (reverse out)
              (let* ((item (car items))
                     (kind (plist-get item 'kind))
                     (argument (plist-get item 'argument))
                     (value (and argument (transient--alist-get values argument #f))))
                (cond
                  ((and (equal? kind 'switch) value)
                   (loop (cdr items) (cons argument out)))
                  ((and (equal? kind 'choice) value)
                   (loop (cdr items) (cons (string-append argument (value->string value)) out)))
                  (else (loop (cdr items) out)))))))))

(define-command "transient-quit-one" "Exit this transient and return to its parent"
  (lambda ()
    (let* ((state (transient--active))
           (stack (and state (plist-get state 'stack))))
      (if (and stack (pair? stack))
          (begin
            (transient--run-hook
              (transient-prefix (plist-get state 'prefix)) 'on-quit state)
            (transient--set-active! (car stack))
            (transient--render!))
          (when state
            (transient--run-hook
              (transient-prefix (plist-get state 'prefix)) 'on-quit state)
            (transient--close-menu!)
            (transient--set-active! #f)
            (message "Quit"))))))

(define-command "transient-quit-all" "Exit this transient and every parent"
  (lambda ()
    (let ((state (transient--active)))
      (when state
        (transient--run-hook
          (transient-prefix (plist-get state 'prefix)) 'on-quit state)
        (transient--close-menu!)
        (transient--set-active! #f)
        (message "Quit")))))

(define-command "transient-suspend" "Suspend this transient for later resumption"
  (lambda ()
    (let ((state (transient--active)))
      (when state
        (set-frame-local! 'transient-suspended state)
        (transient--close-menu!)
        (transient--set-active! #f)
        (message "Transient suspended; use M-x transient-resume")))))

(define-command "transient-resume" "Resume the transient suspended in this frame"
  (lambda ()
    (let ((state (frame-local 'transient-suspended)))
      (if (not state)
          (message "No suspended transient")
          (begin
            (set-frame-local! 'transient-suspended #f)
            (transient--set-active! state)
            (transient--render!))))))

(define-command "transient-toggle-help" "Toggle suffix command documentation"
  (lambda ()
    (let ((state (transient--active)))
      (when state
        (transient--set-active! (transient--put state 'help (not (plist-get state 'help))))
        (transient--render!)))))

(define (transient--move-selection delta)
  (let* ((state (transient--active))
         (prefix (and state (transient-prefix (plist-get state 'prefix))))
         (count (if prefix
                    (length (transient--visible-items
                              (transient--visible-groups prefix state))) 0)))
    (when (> count 0)
      (transient--set-active!
        (transient--put state 'selected
          (modulo (+ (or (plist-get state 'selected) 0) delta count) count)))
      (transient--render!))))

(define-command "transient-next" "Select the next suffix in the menu"
  (lambda () (transient--move-selection 1)))
(define-command "transient-previous" "Select the previous suffix in the menu"
  (lambda () (transient--move-selection -1)))

(define-command "transient-invoke-selected" "Invoke the selected menu suffix"
  (lambda ()
    (let* ((state (transient--active))
           (prefix (and state (transient-prefix (plist-get state 'prefix))))
           (items (if prefix
                      (transient--visible-items (transient--visible-groups prefix state)) '()))
           (index (or (and state (plist-get state 'selected)) 0)))
      (when (< index (length items))
        (run-command (plist-get (nth index items) 'wrapper))))))

(define (transient--history-use! delta)
  (let* ((state (transient--active))
         (name (and state (plist-get state 'prefix)))
         (history (transient--alist-get *transient-history* name '()))
         (index (and state (or (plist-get state 'history-index) -1)))
         (next (+ index delta)))
    (if (or (not state) (< next 0) (>= next (length history)))
        (message "No more transient history")
        (begin
          (transient--set-active!
            (transient--put
              (transient--put state 'history-index next)
              'values (nth next history)))
          (transient--render!)))))

(define-command "transient-history-prev" "Use the previous infix value set"
  (lambda () (transient--history-use! 1)))
(define-command "transient-history-next" "Use the next infix value set"
  (lambda () (transient--history-use! -1)))

(define-command "transient-set" "Use this infix value set as the session default"
  (lambda ()
    (let ((state (transient--active)))
      (when state
        (set! *transient-defaults*
          (transient--alist-put *transient-defaults*
            (plist-get state 'prefix) (plist-get state 'values)))
        (message "Set transient values")))))

;;; --- the editor's LLM configuration menu ----------------------------------

(define (llm-config--connector buf)
  (car (llm-config-combination buf)))

(define (llm-config--model buf)
  (cadr (llm-config-combination buf)))

(define (llm-config--effort buf)
  (caddr (llm-config-combination buf)))

(define (llm-config--refresh!)
  (when (transient--active) (transient--render!)))

(define (llm-config--setup! _buf)
  (set-frame-local! 'llm-config-selected #f))

(define (llm-config--mark-selected!)
  (set-frame-local! 'llm-config-selected #t))

(define (llm-config--quit! buf)
  (when (frame-local 'llm-config-selected)
    (llm-config-remember! (llm-config-combination buf)))
  (set-frame-local! 'llm-config-selected #f))

;;; Presets are the tool selection: a preset names MCP servers, and the
;;; servers serve the tools. So the menu picks presets and reports what
;;; they serve; it never offers a tool list of its own.

;; The buffer whose LLM session the presets belong to. A chat or an
;; llm-mode buffer is its own session; a grouped work buffer shares its
;; group chat's session. This never CREATES a chat: the menu redraws on
;; every keystroke.
(define (llm-config--session buf)
  (cond ((or (chat-buffer? buf) (minor-mode-on? buf "llm-mode")) buf)
        ((buffer-group buf)
         (let ((chats (filter chat-buffer?
                              (group-buffers-mru (buffer-group buf)))))
           (if (pair? chats) (car chats) buf)))
        (else buf)))

(define (llm-config--presets buf)
  (if (boundp (quote chat-presets-of)) (chat-presets-of buf) '()))

(define (llm-config--presets-label buf)
  (let ((ps (llm-config--presets (llm-config--session buf))))
    (if (null? ps) "none" (string-join (map symbol->string ps) " "))))

;; how many tools one server serves right now, or #f while it connects
(define (llm-config--server-tools server)
  (if (equal? server 'compos)
      (if (boundp (quote llm-tool-specs)) (length (llm-tool-specs)) 0)
      (let ((d (mcp-server-detail (symbol->string server))))
        (and (pair? d)
             (equal? (plist-get d 'status) "ready")
             (length (or (plist-get d 'tools) '()))))))

;; What the presets serve, counted WITHOUT connecting anything: the menu
;; redraws on every keystroke and a connect belongs to a send. A chat
;; freezes its tool list at its first send, so say when the number is the
;; frozen one — that list, not the live surface, is what the model sees.
(define (llm-config--tools-label buf)
  (let* ((session (llm-config--session buf))
         (frozen (buffer-local session 'chat-tool-specs)))
    (cond
      ((pair? frozen)
       (string-append (number->string (length frozen)) " tools · frozen"))
      ((not (boundp (quote chat-active-servers))) "none")
      (else
        (let loop ((servers (chat-active-servers session)) (n 0) (pending 0))
          (if (null? servers)
              (string-append (number->string n) " tools"
                (if (> pending 0)
                    (string-append " · " (number->string pending) " connecting")
                    ""))
              (let ((count (llm-config--server-tools (car servers))))
                (if count
                    (loop (cdr servers) (+ n count) pending)
                    (loop (cdr servers) n (+ pending 1))))))))))

(define-command "llm-config-pick-preset" "Turn a tool preset on or off"
  (lambda ()
    (let ((buf (llm-config--session (transient-scope))))
      (if (not (boundp (quote chat-preset-candidates)))
          (message "No MCP presets — packages/mcp.scm is not loaded")
          (llm-config-read! "Preset: "
            (chat-preset-candidates buf)
            (lambda (name)
              (unless (equal? name "")
                (chat-preset-toggle! buf (string->symbol name))
                (llm-config--refresh!)))
            (lambda () #f))))))

(define-command "llm-config-pick-backend" "Choose the LLM backend"
  (lambda ()
    (let* ((buf (transient-scope))
           (current (llm-config--connector buf)))
      (llm-config-read! "Backend: "
        (llm-config-current-first
          (map (lambda (c) (list c (connector-description c))) (connector-names))
          current)
        (lambda (choice)
          (unless (equal? choice "")
            (llm-config-apply! buf choice "default" "default")
            (llm-config--mark-selected!)
            (llm-config--refresh!)))
        (lambda () #f)))))

(define-command "llm-config-pick-model" "Choose the LLM model"
  (lambda ()
    (let* ((buf (transient-scope))
           (connector (llm-config--connector buf))
           (current (llm-config--model buf)))
      (llm-config-read! "Model: "
        (llm-config-current-first
          (cons (list "default" "connector default")
                (chat-model-options buf connector))
          current)
        (lambda (model)
          (unless (equal? model "")
            (llm-config-apply! buf connector model "default")
            (llm-config--mark-selected!)
            (llm-config--refresh!)))
        (lambda () #f)))))

(define-command "llm-config-pick-effort" "Choose the LLM reasoning effort"
  (lambda ()
    (let* ((buf (transient-scope))
           (connector (llm-config--connector buf))
           (model (llm-config--model buf))
           (current (llm-config--effort buf))
           (info (chat-model-effort-info buf connector model))
           (efforts (car info))
           (default (cadr info)))
      (llm-config-read! "Effort: "
        (llm-config-current-first
          (cons (list "default"
                      (if (equal? default "") "model default"
                          (string-append "model default: " default)))
                (map (lambda (e) (list e "reasoning effort")) efforts))
          current)
        (lambda (effort)
          (unless (equal? effort "")
            (llm-config-apply! buf connector model effort)
            (llm-config--mark-selected!)
            (llm-config--refresh!)))
        (lambda () #f)))))

(define (llm-config--history-label combination)
  (string-join combination " · "))

(define (llm-config--history-key index)
  (if (= index 10) "0" (number->string index)))

(define (llm-config--history-items buf)
  (let loop ((choices *llm-config-history*) (index 1) (items '()))
    (if (null? choices)
        (reverse items)
        (let ((choice (car choices)))
          (loop (cdr choices) (+ index 1)
            (cons
              (transient-suffix
                (llm-config--history-key index)
                (llm-config--history-label choice)
                (lambda ()
                  (llm-config-apply! buf (car choice) (cadr choice) (caddr choice))
                  (llm-config-remember! choice)
                  (set-frame-local! 'llm-config-selected #f)
                  (run-command "transient-quit-all"))
                'transient 'stay)
              items))))))

(define (llm-config--groups buf)
  (let ((history (llm-config--history-items buf)))
    (append
      (list
        (list "Arguments"
          (transient-infix "b" "Backend" "llm-config-pick-backend"
            (lambda (scope) (llm-config--connector scope)))
          (transient-infix "m" "Model" "llm-config-pick-model"
            (lambda (scope) (llm-config--model scope)))
          (transient-infix "e" "Effort" "llm-config-pick-effort"
            (lambda (scope) (llm-config--effort scope)))
          (transient-infix "p" "Presets" "llm-config-pick-preset"
            (lambda (scope) (llm-config--presets-label scope)))
          (transient-suffix "t" "Tools" "chat-tool-list"
            'value-fn (lambda (scope) (llm-config--tools-label scope)))))
      (if (null? history) '() (list (cons "Recent combinations" history))))))

(transient-define-prefix "llm-configure"
  "Configure this buffer's language model"
  llm-config--groups
  'on-setup llm-config--setup!
  'on-quit llm-config--quit!)

(define (transient--values-file)
  (string-append (compos-home) "/transient-values.scm"))

(define-command "transient-save" "Save this infix value set for future sessions"
  (lambda ()
    (run-command "transient-set")
    (write-file! (transient--values-file)
      (string-append "(set! *transient-defaults* '"
                     (value->string *transient-defaults*) ")\n"))
    (message "Saved transient values")))

(define-command "transient-reset" "Reset this transient's infix values"
  (lambda ()
    (let* ((state (transient--active))
           (name (and state (plist-get state 'prefix)))
           (prefix (and name (transient-prefix name))))
      (when state
        (set! *transient-defaults*
          (filter (lambda (e) (not (equal? (car e) name))) *transient-defaults*))
        (transient--set-active!
          (transient--put state 'values
            (transient--initial-values prefix (transient--visible-groups prefix state))))
        (transient--render!)))))

(when (file-exists? (transient--values-file))
  (load (transient--values-file)))

(public! 'transient-define-prefix
  "(transient-define-prefix NAME DOC GROUPS [OPTIONS]) — define a temporary grouped command menu")
(public! 'transient-suffix
  "(transient-suffix KEY DESCRIPTION COMMAND [PROPERTIES]) — define a menu command")
(public! 'transient-infix
  "(transient-infix KEY DESCRIPTION COMMAND VALUE-FN [PROPERTIES]) — define a custom infix command")
(public! 'transient-switch
  "(transient-switch KEY DESCRIPTION ARGUMENT [PROPERTIES]) — define a boolean infix argument")
(public! 'transient-choice
  "(transient-choice KEY DESCRIPTION ARGUMENT CHOICES [PROPERTIES]) — define a cycling infix argument")
(public! 'transient-setup "(transient-setup NAME [SCOPE]) — activate a transient in this frame")
(public! 'transient-args "(transient-args [NAME]) — return the active or most recently exported arguments")
(public! 'transient-value "(transient-value ARGUMENT) — return one active infix value")
