;;; llm-config.scm --- the C-c b menu: one LLM setup, whole.
;;;
;;; transient.scm is the mechanism: prefixes, keys, the frame's menu. This
;;; file is the policy for one menu, the language-model setup that chat-mode
;;; and llm-mode share. It loads after mcp.scm, skills.scm, and prompts.scm,
;;; because its rows read presets, the permission policy, and the prompt
;;; sections. The bundle record itself (llm-bundle-*) lives in chat-mode.scm,
;;; because the chat applies bundles at boot, before any menu exists.
;;;
;;; The menu is two columns. The left one lists the presets (saved bundles)
;;; and the chat's own setup; the cursor moves through them, typing filters
;;; them, and RET selects one. The right one is the config of the row under
;;; the cursor, and every edit there is a draft of that row. Only ESC, C-g
;;; and C-q close the menu, and each one gives the selected row's config to
;;; the chat. Saving a draft into a preset is a separate key.

(domain! 'llm)
(effects! '(write))


(define (llm-config--refresh!)
  (when (transient--active) (transient--render!)))

;; The dashboard line re-reads state only when told. One hook on exit tells
;; every subscriber -- editor.scm subscribes to refresh the headline.
(define (llm-config-changed! buf)
  (run-hook-with-args 'llm-config-changed-hook buf))

;; The session buffer a bundle's presets and stance belong to. chat-mode.scm
;; resolves it, because a bundle is written and applied there too.
(define (llm-config--session buf) (llm-config-session buf))

;;; --- the box ----------------------------------------------------------------
;;; Frame-locals, because the menu is the frame's:
;;;   llm-config-box     the whole setup being edited, every field filled
;;;   llm-config-live    the chat's setup when the menu opened
;;;   llm-config-source  the name of the preset the box came from, or #f
;;;   llm-config-new     #t while the box is a new preset with no name yet
;;;   llm-config-follow  ((NAME OLD-BUNDLE) ...) presets saved in this menu;
;;;                      other chats on the old setup follow when it closes
;;;   llm-config-selected the preset ESC gives the chat, or #f: its own setup
;;;   llm-config-drafts  ((NAME BOX) ...) unsaved edits; "" is the chat's own
;;;   llm-config-filter  what was typed in the preset column
;;;   llm-config-more    #t shows the third tier; it outlives one opening

(define (llm-config--box) (or (frame-local 'llm-config-box) '()))
(define (llm-config--live) (or (frame-local 'llm-config-live) '()))
(define (llm-config--source-name) (frame-local 'llm-config-source))
(define (llm-config--new?) (and (frame-local 'llm-config-new) #t))
(define (llm-config--more?) (and (frame-local 'llm-config-more) #t))

(define (llm-config--box-get key) (llm-bundle-get (llm-config--box) key #f))

;; Every edit is also the draft of the preset the box came from, so the
;; cursor can leave a preset and come back to the same unsaved edit.
(define (llm-config--draft-key) (or (llm-config--source-name) ""))

(define (llm-config--drafts) (or (frame-local 'llm-config-drafts) '()))

(define (llm-config--box-set! key value)
  (set-frame-local! 'llm-config-box (llm-bundle-put (llm-config--box) key value))
  (set-frame-local! 'llm-config-drafts
    (alist-put (llm-config--drafts) (llm-config--draft-key) (llm-config--box)))
  ;; An edit chooses the row it edits. The exit gives the selected row to
  ;; the chat, and a change made on one row while another stayed selected
  ;; was dropped on ESC: the chat kept its old backend and model.
  (set-frame-local! 'llm-config-selected (llm-config--source-name)))

(define (llm-config--drop-draft! key)
  (set-frame-local! 'llm-config-drafts
    (filter (lambda (e) (not (equal? (car e) key))) (llm-config--drafts))))

(define (llm-config--with-compos presets)
  (let ((p (or presets '())))
    (if (member 'compos p) p (cons 'compos p))))

;; B as a whole setup: a field B never recorded takes LIVE's value, because
;; applying B leaves that field as it is.
(define (llm-config--fill b live)
  (let ((nb (llm-bundle-normalize b)))
    (list 'connector (llm-bundle-connector nb)
          'model (llm-bundle-model nb)
          'effort (llm-bundle-effort nb)
          'presets (llm-config--with-compos
                     (or (llm-bundle-presets nb) (llm-bundle-presets live)))
          'permission (or (llm-bundle-permission nb) (llm-bundle-permission live))
          'agent-mode (let ((m (llm-bundle-agent-mode nb)))
                        (if (or (not m) (equal? m ""))
                            (or (llm-bundle-agent-mode live) "")
                            m))
          'prompt-disabled (or (llm-bundle-prompt-disabled nb)
                               (llm-bundle-prompt-disabled live)
                               '())
          'sandbox (or (llm-bundle-get nb 'sandbox #f) (llm-bundle-get live 'sandbox #f) "group"))))

;; BUF's live setup as one whole bundle, with no name
(define (llm-config--current buf)
  (llm-config--fill (llm-config-combination buf) '()))

(define (llm-config--set=? a b)
  (and (= (length a) (length b))
       (null? (filter (lambda (x) (not (member x b))) a))))

(define *llm-config-box-fields*
  '(connector model effort presets permission agent-mode prompt-disabled sandbox))

(define (llm-config--field-same? key a b)
  (let ((x (llm-bundle-get a key #f)) (y (llm-bundle-get b key #f)))
    (cond ((equal? key 'presets)
           (llm-config--set=? (llm-config--with-compos x) (llm-config--with-compos y)))
          ((equal? key 'prompt-disabled)
           (llm-config--set=? (or x '()) (or y '())))
          (else (equal? x y)))))

;; the fields of A that differ from B, both whole setups
(define (llm-config--changes a b)
  (filter (lambda (key) (not (llm-config--field-same? key a b)))
          *llm-config-box-fields*))

(define (llm-config--same? a b) (null? (llm-config--changes a b)))

;; what the box is measured against: the saved preset it came from, as a
;; whole setup, else the chat's own setup
(define (llm-config--source)
  (let* ((name (llm-config--source-name))
         (b (and (string? name) (llm-bundle-named name))))
    (if b (llm-config--fill b (llm-config--live)) (llm-config--live))))

;; the fields the box changed against its source
(define (llm-config--drift)
  (llm-config--changes (llm-config--box) (llm-config--source)))

(define (llm-config--drifted? key) (and (member key (llm-config--drift)) #t))

;; the saved bundle whose setup equals SETUP (a whole setup), or #f
(define (llm-config--matching setup live)
  (let loop ((bs *llm-bundles*))
    (cond ((null? bs) #f)
          ((llm-config--same? setup (llm-config--fill (car bs) live)) (car bs))
          (else (loop (cdr bs))))))

;; the saved bundle whose setup equals BUF's live setup, or #f
(define (llm-config--matching-bundle buf)
  ;; two presets can hold the same setup (Coding and Smartbrew); the one
  ;; picked in the box names the chat while its setup still matches
  (let* ((cur (llm-config--current buf))
         (chosen (llm-bundle-named (buffer-local buf 'llm-preset))))
    (if (and chosen (llm-config--same? cur (llm-config--fill chosen cur)))
        chosen
        (llm-config--matching cur cur))))

;;; The name the dashboard line shows. It follows the buffer's own setup, not
;;; the menu's box, so a chat that drifted off its bundle names no preset.
(define (llm-config-preset-name buf)
  (let ((b (llm-config--matching-bundle buf)))
    (and b (llm-bundle-name b))))

(define (llm-config--setup! buf)
  (let* ((live (llm-config--current buf))
         (match (llm-config--matching-bundle buf)))
    (set-frame-local! 'llm-config-live live)
    (set-frame-local! 'llm-config-box live)
    (set-frame-local! 'llm-config-source (and match (llm-bundle-name match)))
    (set-frame-local! 'llm-config-selected (and match (llm-bundle-name match)))
    (set-frame-local! 'llm-config-drafts '())
    (set-frame-local! 'llm-config-filter "")
    (set-frame-local! 'llm-config-new #f)
    (set-frame-local! 'llm-config-follow '())))

;; the box shows NAME's config (#f: the chat's own), its draft if it has one
(define (llm-config--show! name)
  (let* ((b (and (string? name) (llm-bundle-named name)))
         (draft (transient--alist-get (llm-config--drafts) (or name "") #f)))
    (set-frame-local! 'llm-config-source (and b name))
    (set-frame-local! 'llm-config-new #f)
    (set-frame-local! 'llm-config-box
      (or draft (if b (llm-config--fill b (llm-config--live)) (llm-config--live))))))

;;; A preset saved in this menu is a new setup for every chat that was on
;;; the old one. They follow when the menu closes, once, and not on each
;;; save: two saves then cost one reattach per chat.
(define (llm-config--follow! target)
  (let ((follow (or (frame-local 'llm-config-follow) '()))
        (session (and (buffer-exists? target) (llm-config--session target)))
        (moved 0))
    (for-each
      (lambda (entry)
        (let ((new (llm-bundle-named (car entry))) (old (cadr entry)))
          (when new
            (for-each
              (lambda (b)
                (when (and (not (equal? b session))
                           (chat-buffer? b)
                           (let ((cur (llm-config--current b)))
                             (llm-config--same? cur (llm-config--fill old cur))))
                  (llm-bundle-apply! b new)
                  (set! moved (+ moved 1))))
              (buffer-list)))))
      follow)
    (set-frame-local! 'llm-config-follow '())
    moved))

;; the config of one row: its draft, else the saved preset, else the chat's
(define (llm-config--config-of name)
  (let ((draft (transient--alist-get (llm-config--drafts) (or name "") #f))
        (b (and (string? name) (llm-bundle-named name))))
    (or draft (if b (llm-config--fill b (llm-config--live)) (llm-config--live)))))

(define (llm-config--selected-name) (frame-local 'llm-config-selected))

;;; Every exit gives the selected row's config to the chat: ESC and C-g
;;; alike. To keep the chat as it is, select its own row. A chat that died
;;; while the menu was open gets nothing: the menu only closes.
(define (llm-config--quit! buf)
  (let ((box (llm-config--config-of (llm-config--selected-name)))
        (alive (buffer-exists? buf))
        (renamed (and (buffer-exists? buf)
                      (not (equal? (llm-config--selected-name) (llm-config-preset-name buf)))))
        (applied #f))
    (when (and alive
               (pair? box)
               (not (llm-config--same? box (llm-config--current buf))))
      (llm-bundle-apply! buf box)
      (llm-config-remember! box)
      (set! applied #t))
    (when alive (buffer-set-local! buf 'llm-preset (llm-config--selected-name)))
    (let ((moved (llm-config--follow! buf)))
      (message
        (string-append
          (cond ((or applied renamed)
                 (string-append "the chat now runs "
                                (or (llm-config--selected-name) "its own setup")))
                (alive "no change")
                (else "the chat is gone"))
          (if (> moved 0)
              (string-append " · " (number->string moved)
                             (if (= moved 1) " other chat follows" " other chats follow")
                             " the saved preset")
              ""))))
    (set-frame-local! 'llm-config-box #f)
    (set-frame-local! 'llm-config-live #f)
    (set-frame-local! 'llm-config-source #f)
    (set-frame-local! 'llm-config-selected #f)
    (set-frame-local! 'llm-config-new #f)
    (when alive (llm-config-changed! buf))))

;;; --- tools ------------------------------------------------------------------
;;; Presets are the tool selection: a preset names MCP servers, and the
;;; servers serve the tools. So the menu picks presets and reports what
;;; they serve; it never offers a tool list of its own.

(define (llm-config--presets buf)
  (if (boundp (quote chat-presets-of)) (chat-presets-of buf) '()))

;; how many tools one server serves right now, or #f while it connects
(define (llm-config--server-tools server)
  (if (equal? server 'compos)
      (if (boundp (quote llm-tool-specs)) (length (llm-tool-specs)) 0)
      (let ((d (conn-detail 'mcp (symbol->string server))))
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

;; the preset palette, with the glyphs following the box, not the chat
(define (llm-config--preset-candidates)
  (let* ((loaded (llm-config--with-compos (llm-config--box-get 'presets)))
         (names (map car *chat-presets*)))
    (append
      (map (lambda (e)
             (list (symbol->string (car e))
                   (string-append (if (member (car e) loaded) "● " "○ ")
                                  (plist-get (car (cdr e)) 'description))))
           *chat-presets*)
      (map (lambda (srv)
             (list (symbol->string (car srv))
                   (string-append (if (member (car srv) loaded) "● " "○ ") "server")))
           (filter (lambda (srv) (not (member (car srv) names))) *mcp-registry*)))))

(define (llm-config--toggle-preset! name)
  (let ((loaded (llm-config--with-compos (llm-config--box-get 'presets))))
    (cond ((equal? name 'compos)
           (message "The compos preset is the editor bridge — it stays on"))
          ((member name loaded)
           (llm-config--box-set! 'presets (remove (lambda (p) (equal? p name)) loaded))
           (message (string-append "Preset " (symbol->string name) " off in the box")))
          (else
           (llm-config--box-set! 'presets (cons name loaded))
           (message (string-append "Preset " (symbol->string name) " on in the box"))))))

(define (llm-config--pick-preset-loop! preselect)
  (minibuffer-read* "Preset: "
    (llm-config--preset-candidates)
    (append
      (list (list 'confirm
                  (lambda (name)
                    (unless (equal? name "")
                      (llm-config--toggle-preset! (string->symbol name))
                      (llm-config--refresh!)
                      (llm-config--pick-preset-loop! name))))
            (list 'cancel (lambda () #f))
            (list 'style "palette")
            (list 'legend '(("RET" "toggle") ("C-n C-p" "select") ("TAB" "complete") ("C-g" "done")))
            (list 'note "RET turns a preset on or off and keeps the list open; C-g when done. The chat gets them when the menu closes."))
      (if preselect (list (list 'preselect preselect)) '()))))

(define-command "llm-config-pick-preset" "Turn tool presets on or off in the box"
  (lambda ()
    (if (not (boundp (quote chat-preset-candidates)))
        (message "No MCP presets — packages/mcp.scm is not loaded")
        (llm-config--pick-preset-loop! #f))))

;;; --- prompt sections ----------------------------------------------------------
;; One child transient holds a draft. Toggling rows changes only that draft.
;; Apply commits every section once. Under C-c b the draft starts from the
;; box and goes back to the box; opened alone it edits the chat.
(define *llm-config-prompt-keys*
  '("1" "2" "3" "4" "5" "6" "7" "8" "9" "0"
    "q" "w" "e" "r" "t" "y" "u" "o" "p"))

(define (llm-config--prompt-argument name)
  (string-append "--prompt-" name))

;; true while C-c b is open under the current menu: the box is live only then
(define (llm-config--boxed?)
  (let ((state (transient--active)))
    (and state
         (pair? (frame-local 'llm-config-box))
         (let loop ((ss (cons state (or (plist-get state 'stack) '()))))
           (cond ((null? ss) #f)
                 ((equal? (plist-get (car ss) 'prefix) "llm-configure") #t)
                 (else (loop (cdr ss))))))))

(define (llm-config--prompt-off buf)
  (if (llm-config--boxed?)
      (or (llm-config--box-get 'prompt-disabled) '())
      (prompt-disabled-parts (llm-config--session buf))))

(define (llm-config--prompt-items buf)
  (let* ((session (llm-config--session buf))
         (off (llm-config--prompt-off buf)))
    (let loop ((parts (chat-prompt-source-parts session))
               (keys *llm-config-prompt-keys*)
               (items '()))
      (if (or (null? parts) (null? keys))
          (reverse items)
          (let* ((part (car parts))
                 (name (car part)))
            (loop (cdr parts) (cdr keys)
              (cons (transient-switch (car keys) name
                      (llm-config--prompt-argument name)
                      'default (not (member name off)))
                    items)))))))

(define (llm-config--prompt-groups buf)
  (list
    (cons "Sections" (llm-config--prompt-items buf))
    (list "Selection"
      (transient-suffix "a" "Turn all on" "llm-config-prompt-all"
        'transient 'stay)
      (transient-suffix "n" "Turn all off" "llm-config-prompt-none"
        'transient 'stay)
      (transient-suffix "x" "Apply selection" "llm-config-apply-prompt-sections"
        'transient 'stay))))

(define (llm-config--prompt-set-draft! enabled?)
  (let ((buf (llm-config--session (transient-scope))))
    (for-each
      (lambda (part)
        (transient--set-value! (llm-config--prompt-argument (car part)) enabled?))
      (chat-prompt-source-parts buf))))

(define-command "llm-config-prompt-all" "Turn on every prompt section in this draft"
  (lambda () (llm-config--prompt-set-draft! #t)))

(define-command "llm-config-prompt-none" "Turn off every prompt section in this draft"
  (lambda () (llm-config--prompt-set-draft! #f)))

(define-command "llm-config-apply-prompt-sections" "Apply all selected prompt sections"
  (lambda ()
    (let* ((buf (llm-config--session (transient-scope)))
           (parts (chat-prompt-source-parts buf))
           (off
             (let loop ((rest parts) (out '()))
               (if (null? rest)
                   (reverse out)
                   (let ((name (car (car rest))))
                     (loop (cdr rest)
                       (if (transient-value (llm-config--prompt-argument name))
                           out
                           (cons name out))))))))
      (if (llm-config--boxed?)
          (llm-config--box-set! 'prompt-disabled off)
          (chat-prompt-sections-set! buf off))
      (run-command "transient-quit-one")
      (message (if (llm-config--boxed?)
                   "Prompt sections are in the box"
                   "Prompt sections applied")))))

(transient-define-prefix "llm-prompt-sections"
  "Select the prompt sections, then apply them together"
  llm-config--prompt-groups)

;;; --- backend, model, effort -----------------------------------------------------
;;; Each picker writes the box. THEN runs after a pick: the new-preset flow
;;; chains the three pickers through it.

(define (llm-config--read-backend buf then)
  (let ((current (llm-config--box-get 'connector)))
    (llm-config-read! "Backend: "
      (llm-config-current-first
        (map (lambda (c)
               (let ((models (length (chat-model-options buf c))))
                 (llm-config-row c (connector-description c)
                   (list (list "backend" (connector-description c))
                         (list "models"
                               (if (= models 0) "asks the backend"
                                   (string-append (number->string models) " known")))
                         (list "model" (if (equal? c current)
                                           (llm-config--box-get 'model)
                                           "default"))))))
             (connector-names))
        current)
      (lambda (choice)
        (unless (equal? choice "")
          (llm-config--box-set! 'connector choice)
          (llm-config--box-set! 'model "default")
          (llm-config--box-set! 'effort "default")
          (llm-config--refresh!)
          (then)))
      (lambda () #f)
      "RET puts the backend in the box and resets the model and effort to its defaults.")))

;; one model row with the facts the rail shows: backend, provider prefix,
;; and the reasoning efforts the catalog or the live backend lists for it
(define (llm-config--model-row buf connector row)
  (let* ((id (car row))
         (hint (if (pair? (cdr row)) (cadr row) ""))
         (info (chat-model-effort-info buf connector id))
         (efforts (car info))
         (colon (string-index id ":")))
    (llm-config-row id hint
      (append
        (list (list "backend" connector))
        (if colon (list (list "provider" (substring id 0 colon))) '())
        (if (equal? hint "") '() (list (list "name" hint)))
        (list (list "efforts" (if (null? efforts) "none listed" (string-join efforts " "))))))))

(define (llm-config--read-model buf then)
  (let ((connector (llm-config--box-get 'connector))
        (current (llm-config--box-get 'model)))
    ;; the direct lane offers every model a provider lists, so a day-old
    ;; catalog refreshes behind this list for the next time
    (when (and (equal? connector "api")
               (boundp (quote llm-catalog-maybe-refresh!)))
      (llm-catalog-maybe-refresh!))
    (llm-config-read! "Model: "
      (llm-config-current-first
        (cons (llm-config-row "default" "connector default"
                (list (list "backend" connector) (list "model" "the backend's own default")))
              (map (lambda (row) (llm-config--model-row buf connector row))
                   (chat-model-options buf connector)))
        current)
      (lambda (model)
        (unless (equal? model "")
          (llm-config--box-set! 'model model)
          (llm-config--box-set! 'effort "default")
          (llm-config--refresh!)
          (then)))
      (lambda () #f)
      (string-append "RET puts the model on " connector
                     " in the box and resets the effort to the model's default."))))

(define (llm-config--read-effort buf then)
  (let* ((connector (llm-config--box-get 'connector))
         (model (llm-config--box-get 'model))
         (current (llm-config--box-get 'effort))
         (info (chat-model-effort-info buf connector model))
         (efforts (car info))
         (default (cadr info)))
    (llm-config-read! "Effort: "
      (llm-config-current-first
        (cons (llm-config-row "default"
                (if (equal? default "") "model default"
                    (string-append "model default: " default))
                (list (list "model" model)
                      (list "effort" (if (equal? default "") "the model decides" default))))
              (map (lambda (e)
                     (llm-config-row e "reasoning effort"
                       (list (list "model" model) (list "effort" e))))
                   efforts))
        current)
      (lambda (effort)
        (unless (equal? effort "")
          (llm-config--box-set! 'effort effort)
          (llm-config--refresh!)
          (then)))
      (lambda () #f)
      (string-append "RET sets how hard " (if (equal? model "default") connector model)
                     " reasons. More effort costs more time and tokens."))))

(define-command "llm-config-pick-backend" "Choose the LLM backend in the box"
  (lambda () (llm-config--read-backend (transient-scope) (lambda () #f))))

(define-command "llm-config-pick-model" "Choose the LLM model in the box"
  (lambda () (llm-config--read-model (transient-scope) (lambda () #f))))

(define-command "llm-config-pick-effort" "Choose the LLM reasoning effort in the box"
  (lambda () (llm-config--read-effort (transient-scope) (lambda () #f))))

;;; --- what stops to ask ----------------------------------------------------
;;; Permissions are part of the setup, not a separate subject: the same
;;; menu that chooses the model chooses what that model may do without
;;; asking. Three controls, and they are not the same control: the stance
;;; is compos's own policy, the agent mode is the backend's (ACP names it,
;;; and plan mode changes what a turn DOES), and the file switch says
;;; whether the agent may go around buffers to the filesystem. The stance
;;; and the agent mode are in the box. The file switch is one setting for
;;; the whole editor, so it applies at once.

(define (llm-config--agent-mode-text mode)
  (if (or (not mode) (equal? mode "") (equal? mode "default")) "none" mode))

;; the modes the box's backend can be put in: the live session's list, else
;; the connector's remembered one. Empty hides the row.
(define (llm-config--agent-modes buf)
  (if (and buf (boundp (quote chat-mode-options)))
      (map (lambda (m) (list (car m) (or (nth 2 m) "")))
           (chat-mode-options (llm-config--session buf)
                              (or (llm-config--box-get 'connector)
                                  (buffer-local (llm-config--session buf) 'agent-connector))))
      '()))

(define (llm-config--filesystem)
  (if (boundp (quote agent-filesystem-tools)) agent-filesystem-tools "deny"))

(define-command "llm-config-pick-sandbox" "Choose whether this chat's shell commands run in the sandbox, in the box"
  (lambda ()
    (llm-config-read! "Sandbox: "
      (llm-config-current-first
        (list (list "on" "shell commands write only in the chat's directory, temp and tool caches")
              (list "off" "shell commands write anywhere")
              (list "group" "as the chat's group says, else agent-sandbox"))
        (or (llm-config--box-get 'sandbox) "group"))
      (lambda (choice)
        (unless (equal? choice "")
          (llm-config--box-set! 'sandbox choice)
          (llm-config--refresh!)))
      (lambda () #f))))

(define-command "llm-config-pick-permission" "Choose when this session stops to ask, in the box"
  (lambda ()
    (if (not (boundp (quote chat-permission-mode-set!)))
        (message "No permission policy — packages/agent-permissions.scm is not loaded")
        (llm-config-read! "Asks: "
          (llm-config-current-first
            (map (lambda (m) (list (symbol->string m)
                                   (chat-permission-mode-note m)))
                 *permission-modes*)
            (or (llm-config--box-get 'permission) ""))
          (lambda (choice)
            (unless (equal? choice "")
              (llm-config--box-set! 'permission choice)
              (llm-config--refresh!)))
          (lambda () #f)))))

(define-command "llm-config-pick-agent-mode" "Choose the agent session's own mode, in the box"
  (lambda ()
    (let ((modes (llm-config--agent-modes (transient-scope))))
      (if (null? modes)
          (message "this backend has no session modes")
          (llm-config-read! "Agent mode: "
            (llm-config-current-first modes (or (llm-config--box-get 'agent-mode) ""))
            (lambda (choice)
              (unless (equal? choice "")
                (llm-config--box-set! 'agent-mode choice)
                (llm-config--refresh!)))
            (lambda () #f))))))

(define-command "llm-config-pick-filesystem" "Choose what the agent's own file tools may do"
  (lambda ()
    (llm-config-read! "Agent file tools: "
      (llm-config-current-first
        (list (list "deny" "the agent edits buffers, and saves them")
              (list "ask" "each direct write asks first")
              (list "allow" "the agent writes files itself"))
        (llm-config--filesystem))
      (lambda (choice)
        (unless (equal? choice "")
          (customize-save! 'agent-filesystem-tools choice)
          (llm-config--refresh!)))
      (lambda () #f)
      "One setting for every chat. It applies now, not when the menu closes.")))

;; the report never covers the chat that asked for it

;; What always asks, and what this group took off the list with Always.
;; The patterns are global; an Always is kept in the group record as the
;; pattern it answered, so the box can show it and take it back.
(define (llm-config--group scope)
  (let ((buf (and scope (llm-config--session scope))))
    (and buf (buffer-exists? buf) (buffer-group buf))))

(define (llm-config--allowed-verbs g)
  (or (and g (group-setting g 'always-verbs)) '()))

(define (llm-config--verb-label pat)
  "PAT as words: send[-_ ]*mail reads send mail"
  (let* ((s (re-replace-all "\\(\\?<![^)]*\\)" pat ""))
         (s (re-replace-all "\\\\b" s ""))
         (s (re-replace-all "\\[-_ \\][*+]" s " "))
         (s (string-replace s "-[a-z]*[rf]" "-r/-f"))
         (s (re-replace-all "[()]" s "")))
    (string-replace s "|" "/")))

(define (llm-config--asks-text scope)
  (let* ((pats (if (boundp (quote *permission-deny-patterns*)) *permission-deny-patterns* '()))
         (n (length (llm-config--allowed-verbs (llm-config--group scope)))))
    (string-append (number->string (length pats)) " verbs"
                   (if (> n 0) (string-append " · " (number->string n) " allowed here") ""))))

(define-command "llm-config-pick-asks" "Choose which always-ask verbs this group allows, in the box"
  (lambda ()
    (let* ((g (llm-config--group (transient-scope)))
           (allowed (llm-config--allowed-verbs g))
           (pats (if (boundp (quote *permission-deny-patterns*)) *permission-deny-patterns* '()))
           ;; an Always for a shell kind is not a pattern, but it is still
           ;; this group's to take back
           (keys (append pats (filter (lambda (v) (not (member v pats))) allowed)))
           (rows (map (lambda (k)
                        (list (llm-config--verb-label k)
                              (if (member k allowed) "allowed in this group" "asks")
                              k))
                      keys)))
      (if (not g)
          (message "this chat has no group")
          (llm-config-read! "Always asks — choose one to switch it: "
            (map (lambda (r) (list (car r) (cadr r))) rows)
            (lambda (choice)
              (let ((r (assoc choice rows)))
                (when r
                  (let ((k (caddr r)))
                    (group-setting-set! g 'always-verbs
                      (if (member k allowed)
                          (filter (lambda (v) (not (equal? v k))) allowed)
                          (cons k allowed)))))
                (llm-config--refresh!)))
            (lambda () #f)
            "Allowed in this group: every chat of the group runs it without a card.")))))

(define-command "llm-config-permission-report"
  "Show everything this session's permission policy does"
  (lambda ()
    (let ((buf (llm-config--session (transient-scope))))
      (if (not (boundp (quote permission-policy-report)))
          (message "No permission policy — packages/agent-permissions.scm is not loaded")
          (let ((out "*permissions*"))
            (buffer-create out)
            (buffer-set-read-only! out #f)
            (buffer-delete-range! out 0 (buffer-size out))
            (buffer-append! out (permission-policy-report buf))
            (buffer-set-read-only! out #t)
            (display-buffer out))))))

;;; --- the tool surface ---------------------------------------------------------

;; `t` opens this child menu: the tool surface as menu rows over the
;; same scope, not a buffer covering the chat. A digit echoes one
;; server's tools; l is the full text list for actual reading.
(define (llm-config--chat-servers session)
  (let ((frozen (buffer-local session 'chat-tool-specs)))
    (if (pair? frozen)
        (let loop ((specs frozen) (acc '()))
          (if (null? specs) (reverse acc)
              (loop (cdr specs)
                    (let ((s (chat-tool-server (car (car specs)))))
                      (if (member s acc) acc (cons s acc))))))
        (map symbol->string (chat-active-servers session)))))

(define (llm-config--server-row-count session server)
  ;; never connects: the frozen list counts itself, a live server is
  ;; only read through the registry's detail
  (let ((frozen (buffer-local session 'chat-tool-specs)))
    (if (pair? frozen)
        (length (filter (lambda (s) (equal? (chat-tool-server (car s)) server))
                        frozen))
        (llm-config--server-tools (string->symbol server)))))

(define (llm-config--server-tool-names session server)
  (let ((frozen (buffer-local session 'chat-tool-specs)))
    (cond
      ((pair? frozen)
       (map car (filter (lambda (s) (equal? (chat-tool-server (car s)) server))
                        frozen)))
      ((and (equal? server "compos") (boundp (quote llm-tool-specs)))
       (map car (llm-tool-specs)))
      (else
        (let ((d (conn-detail 'mcp server)))
          (map (lambda (t) (if (pair? t) (car t) t))
               (or (plist-get d 'tools) '())))))))

(define (llm-config--presets-label buf)
  (let ((ps (llm-config--presets (llm-config--session buf))))
    (if (null? ps) "none" (string-join (map symbol->string ps) " "))))

(define (llm-config--tools-groups buf)
  (let* ((session (llm-config--session buf))
         (can (boundp (quote chat-tool-server)))
         (servers (if can (llm-config--chat-servers session) '())))
    (append
      (if (null? servers)
          '()
          (list
            (cons (string-append "Servers · " (llm-config--tools-label buf))
              (let loop ((ss servers) (k 1) (acc '()))
                (if (or (null? ss) (> k 9))
                    (reverse acc)
                    (loop (cdr ss) (+ k 1)
                      (cons
                        (let ((server (car ss)))
                          (transient-suffix (number->string k) server
                            (lambda ()
                              (let ((names (llm-config--server-tool-names session server)))
                                (message
                                  (string-append server ": "
                                    (if (null? names)
                                        "no tools yet — still connecting?"
                                        (string-join names ", "))))))
                            'transient 'stay
                            'value-fn
                            (lambda (_scope)
                              (let ((n (llm-config--server-row-count session server)))
                                (if n
                                    (string-append (number->string n) " tools")
                                    "connecting")))))
                        acc)))))))
      (list
        (list "Change"
          (transient-infix "p" "Presets" "llm-config-pick-preset"
            (lambda (scope)
              (if (llm-config--boxed?)
                  (llm-config--field-text 'presets (llm-config--box))
                  (llm-config--presets-label scope))))
          (transient-suffix "r" "Adopt the editor's live tools" "chat-refresh-tools")
          (transient-suffix "l" "The full list, with docs" "chat-tool-list"))))))

(transient-define-prefix "chat-tools"
  "This chat's tool surface"
  llm-config--tools-groups)

;;; --- saving the box -------------------------------------------------------------

(define (llm-config--bundle-candidates)
  (map (lambda (b) (list (or (llm-bundle-name b) "?") (llm-bundle-label b)))
       *llm-bundles*))

;; S: the box under a name. A new name is a new preset; a saved name is
;; saved over, and keeps its key.
(define (llm-config--save-as!)
  (minibuffer-read "Preset name: " (llm-config--bundle-candidates)
    (lambda (name)
      (let ((n (string-trim name)))
        (unless (equal? n "")
          (let ((old (llm-bundle-named n)))
            (when old
              (set-frame-local! 'llm-config-follow
                (cons (list n old) (or (frame-local 'llm-config-follow) '())))))
          (let ((box (llm-config--box)))
            ;; the preset the edit started from stays as it was saved
            (llm-config--drop-draft! (llm-config--draft-key))
            (llm-bundle-save! n box)
            (llm-config--drop-draft! n)
            (llm-config--refresh!)
            (llm-config--select-preset! n)
            (message (string-append "saved as preset " n))))))))

(define-command "llm-config-save-bundle" "Save this config as a preset under a name"
  (lambda () (llm-config--save-as!)))

(define-command "llm-config-save-into" "Update the preset with this config"
  (lambda ()
    (let* ((name (llm-config--source-name))
           (old (and (string? name) (llm-bundle-named name))))
      (cond ((not old) (message "this chat is no preset — S saves it under a name"))
            ((null? (llm-config--drift)) (message (string-append name " has no unsaved changes")))
            (else
              (set-frame-local! 'llm-config-follow
                (cons (list name old) (or (frame-local 'llm-config-follow) '())))
              (llm-bundle-save! name (llm-config--box))
              (llm-config--drop-draft! name)
              (llm-config--refresh!)
              (message (string-append "updated " name
                         " · other chats on " name " follow when the menu closes")))))))

(define-command "llm-config-revert" "Undo the unsaved changes to this config"
  (lambda ()
    (if (null? (llm-config--drift))
        (message "no changes to undo")
        (begin
          (set-frame-local! 'llm-config-box (llm-config--source))
          (llm-config--drop-draft! (llm-config--draft-key))
          (llm-config--refresh!)
          (message (string-append (or (llm-config--source-name) "this chat")
                                  " is as saved again"))))))

;; n: a new preset. The box keeps the chat's tools and stance, and the
;; three pickers ask for what a preset is mostly about. The name comes last.
(define-command "llm-config-new-preset" "Make a new preset: backend, model, effort, then a name"
  (lambda ()
    (let ((buf (transient-scope)))
      (set-frame-local! 'llm-config-new #t)
      (llm-config--refresh!)
      (llm-config--read-backend buf
        (lambda ()
          (llm-config--read-model buf
            (lambda ()
              (llm-config--read-effort buf
                (lambda () (llm-config--save-as!))))))))))

(define-command "llm-config-use-bundle" "Move to a saved preset by name"
  (lambda ()
    (if (null? *llm-bundles*)
        (message "no saved presets — S saves this config as one")
        (llm-config-read! "Preset: " (llm-config--bundle-candidates)
          (lambda (name)
            (let ((b (and (not (equal? name "")) (llm-bundle-named name))))
              (when b (llm-config--select-preset! (llm-bundle-name b)))))
          (lambda () #f)))))

(define-command "llm-config-forget-bundle" "Forget a saved preset"
  (lambda ()
    (if (null? *llm-bundles*)
        (message "no saved presets")
        (llm-config-read! "Delete preset: "
          (llm-config-current-first (llm-config--bundle-candidates)
                                    (or (llm-config--source-name) ""))
          (lambda (name)
            (unless (equal? name "")
              (llm-bundle-forget! name)
              (llm-config--drop-draft! name)
              (when (equal? name (llm-config--source-name))
                (llm-config--show! #f))
              (llm-config--refresh!)
              (when (equal? name (llm-config--selected-name))
                (set-frame-local! 'llm-config-selected #f))
              (message (string-append "preset " name " deleted"))))
          (lambda () #f)))))

;;; The bundle a new chat starts with. It is a setting like any other, so it
;;; lands in custom.scm, survives a restart, and can be edited by hand. ""
;;; means no default: a new chat keeps whatever it inherits.
(defgroup 'llm "The language model a chat talks to.")

(defcustom 'llm-default-bundle ""
  "The saved bundle every new chat starts with. Empty means no default."
  'group 'llm 'type 'string)

(define (llm-default-bundle-record)
  (and (string? llm-default-bundle)
       (not (equal? llm-default-bundle ""))
       (llm-bundle-named llm-default-bundle)))

;;; --- model presets --------------------------------------------------------
;;; A bundle is a whole chat setup, and a person picks it at C-c b. A preset
;;; is smaller and code picks it: one model id for one named job. A feature
;;; that wants "the fast model" asks by name, so no model id is written into
;;; a feature and one table moves every job at once.

(defcustom 'llm-model-presets
  '((default . "") (fast . "") (summarize . "") (coding . ""))
  "((ROLE . MODEL-ID) ...) - the model each named job uses. Empty means the session model."
  'group 'llm)

(define (llm-models! presets)
  (customize-set! 'llm-model-presets presets)
  llm-model-presets)

;; An unknown role, or one left empty, falls back to the session model: the
;; table is a preference and never a requirement.
(define (llm-model-for role)
  ;; This dialect has no dotted pairs: it reads (coding . "claude-opus-5") as
  ;; the three-element list (coding . "claude-opus-5") with a bare `.` symbol
  ;; in the middle. assq still finds the row, but (cdr row) is then (. "id")
  ;; and not the string -- so the preset silently lost to the session model for
  ;; every role, and the table had never once been read. Taking the first
  ;; string in the row reads both that shape and a plain (ROLE "id") list.
  (let* ((row (assq role llm-model-presets))
         (ss (and row (filter (lambda (x) (string? x)) (cdr row))))
         (id (and (pair? ss) (car ss))))
    (if (and (string? id) (> (string-length id) 0)) id (llm-model))))

(public! 'llm-models!
  "(llm-models! '((ROLE . MODEL-ID) ...)) - declare the model each named job uses.")
(public! 'llm-model-for
  "(llm-model-for ROLE) - the model id for a named job, else the session model.")

;;; A new chat has no agent session yet, so its locals are the whole setup:
;;; the session reads them when it attaches on the first send. Going through
;;; llm-bundle-apply! here would attach the connector at once, and every new
;;; chat would start a process before the user had typed anything.
(define (llm-default--seed! buf b)
  (buffer-set-local! buf 'agent-connector (llm-bundle-connector b))
  (let ((m (llm-bundle-model b)))
    (buffer-set-local! buf 'agent-model (if (equal? m "default") #f m)))
  (let ((e (llm-bundle-effort b)))
    (buffer-set-local! buf 'agent-effort (if (equal? e "default") #f e)))
  (let ((k (llm-bundle-permission b)))
    (when (and k (boundp 'chat-permission-mode-set!))
      (chat-permission-mode-set! buf (string->symbol k))))
  (let ((p (llm-bundle-presets b)))
    (when (and p (boundp 'chat-presets-set!))
      (chat-presets-set! buf p)))
  (let ((off (llm-bundle-prompt-disabled b)))
    (when (and off (boundp 'chat-prompt-sections-set!))
      (chat-prompt-sections-set! buf off)))
  (let ((mode (llm-bundle-agent-mode b)))
    (when (and mode (not (equal? mode "")) (boundp 'agent-mode-set!))
      (agent-mode-set! buf mode)))
  (when (boundp 'agent-update-modeline!) (agent-update-modeline! buf))
  b)

(define (llm-bundle-resolve v)
  ;; a bundle's name, or a bundle itself
  (cond ((and (string? v) (not (equal? v ""))) (llm-bundle-named v))
        ((pair? v) v)
        (else #f)))

(define (llm-group-bundle g)
  ;; G's 'llm setting: a preset's name or a whole bundle; #f when it names none
  (let ((id (and g (group-resolve-id g))))
    (when (and id (boundp 'group-config-ensure!)) (group-config-ensure! id))
    (and id (llm-bundle-resolve (group-setting id 'llm)))))

(define (llm-default-bundle-apply! buf &optional g)
  (let ((b (or (llm-group-bundle (or g (buffer-group buf)))
               (llm-default-bundle-record))))
    (cond ((not b) #f)
          ((buffer-local buf 'agent-slug) (llm-bundle-apply! buf b))
          (else (llm-default--seed! buf b)))))

(public! 'llm-default-bundle-apply!
  "(llm-default-bundle-apply! BUF [GROUP]) — put the group's 'llm bundle, else llm-default-bundle, on a new chat; #f when neither names one")
(public! 'llm-group-bundle
  "(llm-group-bundle G) — G's 'llm setting as a bundle: it names a preset or is one; #f when unset")

(define-command "group-llm" "Choose the preset this group's new chats start with"
  (lambda ()
    (let ((id (group-resolve-id (or (buffer-group (current-buffer)) (frame-group)))))
      (if (not id)
          (message "no group here")
          (minibuffer-read* "Group preset: "
            (cons "(global default)" (map llm-bundle-name *llm-bundles*))
            (list
              (list 'confirm
                (lambda (name)
                  (let ((v (if (equal? name "(global default)") #f name)))
                    (when (group-config-set! id 'llm v)
                      (message (string-append (group-name id) ": new chats start with "
                                              (or v "the global default")
                                              " (group.scm)"))))))))))))

(define-command "llm-config-save-default" "Make the box's preset the default for new chats"
  (lambda ()
    (let ((name (llm-config--source-name)))
      (cond ((not (string? name)) (message "the box came from no preset — S saves it first"))
            ((pair? (llm-config--drift))
             (message (string-append "the box changed " name " — s saves it first")))
            (else
              (customize-save! 'llm-default-bundle name)
              (llm-config--refresh!)
              (message (string-append "new chats start with " name)))))))

;;; --- the menu -------------------------------------------------------------------
;;; Two columns. The left column is the presets: the cursor moves through
;;; them, and the right column shows the config of the preset under it.
;;; RET (or right) goes into that config; left comes back. Every key keeps
;;; the menu open. Only ESC, C-g and C-q close it, and only then does the
;;; chat change. The keys that save are no row: the footer names them.

;; one field of a whole setup as a row shows it
(define (llm-config--field-text key b)
  (let ((v (llm-bundle-get b key #f)))
    (cond
      ((equal? key 'presets)
       (cond ((not v) "as is")
             (else
               (let ((extra (remove (lambda (x) (equal? x 'compos)) v)))
                 (if (null? extra) "editor only"
                     (string-join (map symbol->string extra) " "))))))
      ((equal? key 'prompt-disabled)
       (cond ((not v) "as is")
             ((null? v) "all on")
             (else (string-append (number->string (length v)) " off"))))
      ((equal? key 'agent-mode) (llm-config--agent-mode-text v))
      ((equal? key 'permission) (or v "as is"))
      ((equal? key 'sandbox)
       (if (member v '("on" "off")) v "as group"))
      ((equal? key 'connector) (or v *default-connector*))
      (else (or v "default")))))

;; a config row's value: the box's value, and the saved value when they differ
(define (llm-config--field-value key)
  (let ((now (llm-config--field-text key (llm-config--box))))
    (if (llm-config--drifted? key)
        (string-append (llm-config--field-text key (llm-config--source)) " → " now)
        now)))

(define (llm-config--field-row key label field command &rest properties)
  (append
    (transient-infix key label command
      (lambda (_scope) (llm-config--field-value field))
      'flags-fn (lambda (_scope) (if (llm-config--drifted? field) "drift" "")))
    properties))

;; the row the cursor is on, or #f
(define (llm-config--selected-item)
  (let* ((state (transient--active))
         (prefix (and state (transient-prefix (plist-get state 'prefix)))))
    (and prefix
         (let ((items (transient--visible-items (transient--visible-groups prefix state)))
               (i (or (plist-get state 'selected) 0)))
           (and (< i (length items)) (nth i items))))))

(define (llm-config--source-row? item)
  (and item (or (plist-get item 'bundle) (plist-get item 'live-row)) #t))

(define (llm-config--on-left?) (llm-config--source-row? (llm-config--selected-item)))

;; move the cursor to the first row PRED accepts; the cursor hook runs
(define (llm-config--select-row! pred)
  (let* ((state (transient--active))
         (prefix (and state (transient-prefix (plist-get state 'prefix)))))
    (when prefix
      (let loop ((items (transient--visible-items (transient--visible-groups prefix state)))
                 (i 0))
        (cond ((null? items) #f)
              ((pred (car items)) (transient--select! state i) (transient--render!) #t)
              (else (loop (cdr items) (+ i 1))))))))

(define (llm-config--select-preset! name)
  (llm-config--select-row!
    (lambda (item)
      (let ((b (plist-get item 'bundle)))
        (and b (equal? (llm-bundle-name b) name))))))

;; the cursor hook: a source row shows its config on the right
(define (llm-config--on-select _buf item)
  (cond ((plist-get item 'bundle) (llm-config--show! (llm-bundle-name (plist-get item 'bundle))))
        ((plist-get item 'live-row) (llm-config--show! #f))
        (else #f)))

;; RET on a row selects it: ESC then gives its config to the chat
(define (llm-config--choose! name)
  (set-frame-local! 'llm-config-selected name)
  (llm-config--refresh!)
  (message (string-append "selected " (or name "this chat")
                          " · ESC gives it to the chat")))

(define (llm-config--dirty-name? name)
  (let ((draft (transient--alist-get (llm-config--drafts) (or name "") #f)))
    (and draft
         (not (llm-config--same? draft
                (let ((b (and (string? name) (llm-bundle-named name))))
                  (if b (llm-config--fill b (llm-config--live)) (llm-config--live))))))))

(define (llm-config--dirty? name) (llm-config--dirty-name? name))

(define (llm-config--selected? name) (equal? name (llm-config--selected-name)))

;; the row whose config the right column shows, while the cursor is there
(define (llm-config--shown-flag name)
  (if (and (equal? name (llm-config--source-name)) (not (llm-config--on-left?)))
      "shown" ""))

;;; --- the filter ---------------------------------------------------------------
;;; In the preset column a printable key types into the filter, and the list
;;; keeps the presets whose name holds it. DEL takes a character back. In
;;; the config column the same keys are the fields' keys.

(define (llm-config--filter) (or (frame-local 'llm-config-filter) ""))

(define (llm-config--filter-set! text)
  (set-frame-local! 'llm-config-filter text)
  (llm-config--refresh!)
  ;; the cursor goes to the first row still in the list
  (llm-config--select-row! llm-config--source-row?))

(define (llm-config--matches? name)
  (let ((f (llm-config--filter)))
    (or (equal? f "")
        (string-contains? (string-downcase name) (string-downcase f)))))

(define *llm-config-filter-chars*
  (let loop ((cs "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.") (out '()))
    (if (equal? cs "")
        (reverse out)
        (loop (substring cs 1 (string-length cs)) (cons (substring cs 0 1) out)))))

(define (llm-config--filter-command ch)
  (string-append "llm-config-filter-" (if (equal? ch " ") "space" ch)))

(for-each
  (lambda (ch)
    (define-command--raw (llm-config--filter-command ch)
      (lambda () (llm-config--filter-set! (string-append (llm-config--filter) ch)))))
  (cons " " *llm-config-filter-chars*))

(define-command "llm-config-filter-back" "Take the last character off the preset filter"
  (lambda ()
    (let ((f (llm-config--filter)))
      (unless (equal? f "")
        (llm-config--filter-set! (substring f 0 (- (string-length f) 1)))))))

;;; --- the rows -----------------------------------------------------------------

(define (llm-config--by-name bundles)
  (map cadr (sort (map (lambda (b) (list (or (llm-bundle-name b) "") b)) bundles))))

(define (llm-config--preset-items)
  (map (lambda (b)
         (let ((name (or (llm-bundle-name b) "?")))
           (transient-suffix ""
             (string-append name
               (if (llm-config--dirty? name) "*" "")
               (if (equal? name llm-default-bundle) " · default" ""))
             (lambda () (llm-config--choose! name))
             'transient 'stay 'bundle b
             'flags-fn (lambda (_scope) (llm-config--shown-flag name))
             'value-fn (lambda (_scope) (if (llm-config--selected? name) "selected" ""))
             'active-fn (lambda (_scope) (llm-config--selected? name)))))
       (filter (lambda (b) (llm-config--matches? (or (llm-bundle-name b) "")))
               (llm-config--by-name *llm-bundles*))))

;; When no preset equals the chat, the chat's own setup is a row too, so
;; the menu can open on it and the chat has a config to go into.
(define (llm-config--live-item)
  (transient-suffix "" (string-append "this chat" (if (llm-config--dirty? #f) "*" ""))
    (lambda () (llm-config--choose! #f))
    'transient 'stay 'live-row #t
    'flags-fn (lambda (_scope) (llm-config--shown-flag #f))
    'value-fn (lambda (_scope) (if (llm-config--selected? #f) "selected" ""))
    'active-fn (lambda (_scope) (llm-config--selected? #f))))

(define (llm-config--more-row)
  (transient-suffix "+" (if (llm-config--more?) "fewer fields" "more fields")
    (lambda ()
      (set-frame-local! 'llm-config-more (not (llm-config--more?)))
      (llm-config--refresh!))
    'transient 'stay
    'value-fn (lambda (_scope)
                (if (llm-config--more?) "" "prompt · sandbox"))))

(define (llm-config--box-items)
  (list
    (llm-config--field-row "b" "backend" 'connector "llm-config-pick-backend")
    (llm-config--field-row "m" "model" 'model "llm-config-pick-model")
    (llm-config--field-row "e" "effort" 'effort "llm-config-pick-effort")
    (llm-config--field-row "p" "tools" 'presets "llm-config-pick-preset")
    (llm-config--more-row)))

(define (llm-config--more-items)
  (list
    (transient-suffix "i" "prompt" "llm-prompt-sections"
      'value-fn (lambda (_scope) (llm-config--field-value 'prompt-disabled))
      'flags-fn (lambda (_scope) (if (llm-config--drifted? 'prompt-disabled) "drift" "")))
    (llm-config--field-row "x" "sandbox" 'sandbox "llm-config-pick-sandbox")
    ;; our gates decide what asks: the sandbox, and a card for an action
    ;; it cannot see. The backend's own stances (asks, agent mode, file
    ;; tools) are not fields.
    (transient-suffix "t" "tool surface" "chat-tools"
      'value-fn (lambda (scope) (llm-config--tools-label scope)))
    (transient-suffix "v" "show prompt" "chat-show-prompt" 'transient 'stay)
    (transient-infix "d" "always asks" "llm-config-pick-asks"
      (lambda (scope) (llm-config--asks-text scope)))))

;; the right column's title: whose config it is
(define (llm-config--config-title)
  (string-append (or (llm-config--source-name) "this chat")
                 (if (pair? (llm-config--drift)) "*" "")
                 " · config"))

(define (llm-config--presets-title)
  (let ((f (llm-config--filter)))
    (if (equal? f "") "Presets" (string-append "Presets · " f))))

(define (llm-config--groups _buf)
  (append
    (list (cons (llm-config--presets-title)
            (append (if (or (llm-config--matching (llm-config--live) (llm-config--live))
                            (not (llm-config--matches? "this chat")))
                        '()
                        (list (llm-config--live-item)))
                    (llm-config--preset-items))))
    (list (cons (llm-config--config-title) (llm-config--box-items)))
    (if (llm-config--more?) (list (cons "More" (llm-config--more-items))) '())))

(define (llm-config--columns _buf)
  (list (list (llm-config--presets-title)) (list (llm-config--config-title) "More")))

;; The keys that are no row. In the preset column the printable keys type
;; into the filter, so the actions there take Meta; in the config column
;; the letters are the fields' keys, and saving takes s S u.
(define (llm-config--keys _buf)
  (append
    (if (llm-config--on-left?)
        (append
          (map (lambda (ch) (list ch (llm-config--filter-command ch))) *llm-config-filter-chars*)
          (list (list "SPC" (llm-config--filter-command " "))
                (list "DEL" "llm-config-filter-back")))
        (list (list "s" "llm-config-save-into")
              (list "S" "llm-config-save-bundle")
              (list "u" "llm-config-revert")))
    (list (list "M-u" "llm-config-save-into")
          (list "M-s" "llm-config-save-bundle")
          (list "M-n" "llm-config-new-preset")
          (list "M-k" "llm-config-forget-bundle")
          (list "M-d" "llm-config-save-default"))))

;; what the menu writes to: this buffer, or the group chat whose session
;; the buffer shares
(define (llm-config--target buf)
  (let ((session (llm-config--session buf)))
    (if (equal? session buf) "this buffer" (string-append "chat " session))))

(define (llm-config--context buf)
  (let* ((g (and (boundp (quote buffer-group)) (buffer-group buf)))
         (gname (and g (boundp (quote group-name)) (group-name g))))
    (string-append (if (string? gname) (string-append "group " gname " · ") "")
                   (llm-config--target buf))))

;; the status line: what ESC gives the chat, in one line
(define (llm-config--subtitle _buf)
  (let ((sel (llm-config--selected-name)))
    (if (llm-config--new?)
        "new preset · not saved · M-s names it"
        (string-append "selected: " (or sel "this chat")
                       (if (llm-config--dirty? sel) "*" "")
                       " · ESC gives it to the chat"))))

(define (llm-config--legend _buf)
  (let* ((name (llm-config--source-name))
         (drift? (pair? (llm-config--drift)))
         (sel (llm-config--selected-name)))
    (append
      (if (llm-config--on-left?)
          (append
            (list (list "type" "filter") (list "↑↓" "move") (list "RET" "select")
                  (list "→" "edit config"))
            (if (and name drift?) (list (list "M-u" (string-append "update " name))) '())
            (list (list "M-s" "save as…") (list "M-n" "new preset"))
            (if name (list (list "M-k" "delete…")) '())
            (if (and name (not drift?) (not (equal? name llm-default-bundle)))
                (list (list "M-d" "default for new chats"))
                '()))
          (append
            (list (list "←" "back to presets"))
            (if (and name drift?) (list (list "s" (string-append "update " name))) '())
            (list (list "S" "save as…"))
            (if drift? (list (list "u" "undo changes")) '())))
      (list (list "ESC C-g" (string-append "apply " (or sel "this chat")
                                           (if (llm-config--dirty? sel) "*" "")
                                           " + close"))))))

;; Every option looks its function up by name at each call, so a hot
;; reload of one function reaches the open menu without this form changing.
(transient-define-prefix "llm-configure"
  "LLM setup"
  (lambda (buf) (llm-config--groups buf))
  'columns (lambda (buf) (llm-config--columns buf))
  'layout "split"
  'on-setup (lambda (buf) (llm-config--setup! buf))
  'on-select (lambda (buf item) (llm-config--on-select buf item))
  'on-quit (lambda (buf) (llm-config--quit! buf))
  'keys-fn (lambda (buf) (llm-config--keys buf))
  'subtitle-fn (lambda (buf) (llm-config--subtitle buf))
  'context-fn (lambda (buf) (llm-config--context buf))
  'legend-fn (lambda (buf) (llm-config--legend buf)))


;;; --- the model catalog --------------------------------------------------------
;;; llm_db packages a catalog inside deps/. It ages from the day the lock was
;;; written, and a model it does not carry has no price, no context limit and
;;; no capabilities: the ledger then records a cost of #f. A published
;;; snapshot is rebuilt every day. This keeps a copy outside the build, where
;;; a dependency update cannot remove it.

(domain! 'llm)
(effects! '(read))

(defcustom 'llm-catalog-max-age-days 7
  "Refresh the model catalog when the loaded snapshot is older than this many days."
  'group 'llm 'type 'number)

(define (llm-catalog-age)
  "The age of the loaded catalog in days, or #f when nothing records it."
  (plist-get (llm-catalog-info) 'stale-days))

;; the policy alone, so a test can state it without a catalog on disk. An
;; age of #f is the catalog packaged with the build: nothing records when it
;; was captured, so it counts as stale.
(define (llm-catalog-stale-age? age)
  (or (not age) (> age llm-catalog-max-age-days)))

(define (llm-catalog-stale?)
  "#t when the catalog is older than llm-catalog-max-age-days, or unrecorded."
  (llm-catalog-stale-age? (llm-catalog-age)))

(define (llm-catalog--describe info)
  (string-append
    (number->string (or (plist-get info 'models) 0)) " models from "
    (number->string (or (plist-get info 'providers) 0)) " providers, captured "
    (or (plist-get info 'captured-at) "at an unrecorded time")))

(domain! 'llm)
(effects! '(write external))

(define (llm-catalog-refresh! k)
  "Fetch the newest published catalog and load it. K gets (ok MESSAGE)."
  (message "fetching the model catalog…")
  ;; the lane hands a callback one value: here the list (OK INFO-OR-MESSAGE)
  (llm-catalog-install!
    (lambda (result)
      (let* ((ok (car result))
             (info (cadr result))
             (text (if ok
                       (string-append "catalog: " (llm-catalog--describe info))
                       (string-append "catalog refresh failed: " info))))
        (message text)
        (when k (k ok text))))))

(define-command "llm-catalog-refresh" "Fetch the newest model catalog and load it now"
  (lambda () (llm-catalog-refresh! #f)))

(define-command "llm-catalog-status" "Say what the loaded model catalog is and how old it is"
  (lambda ()
    (let* ((info (llm-catalog-info))
           (age (plist-get info 'stale-days)))
      (message
        (string-append
          (llm-catalog--describe info)
          (if age
              (string-append " (" (number->string age) " days old)")
              " (age unrecorded: the catalog packaged with the build)"))))))


;; No timer refreshes this. A catalog fetch is several megabytes over the
;; GitHub API, which rate-limits an unauthenticated caller, and a background
;; fetch nobody asked for is not worth that. M-x llm-catalog-status says how
;; old the catalog is; M-x llm-catalog-refresh replaces it.

(public! 'llm-catalog-stale?
  "(llm-catalog-stale?) — #t when the loaded model catalog is older than llm-catalog-max-age-days")
(public! 'llm-catalog-age
  "(llm-catalog-age) — the age of the loaded model catalog in days, or #f")
(public! 'llm-catalog-refresh!
  "(llm-catalog-refresh! K) — fetch the newest model catalog and load it; K gets (ok MESSAGE)")
