;;; setup-wizard.scm --- first-run setup as a wizard: M-x setup.
;;;
;;; The wizard is a block view with two steps. Step one chooses the model:
;;; one card per connector, with a button that uses it, installs it, or
;;; asks for a key. Step two starts the guide (onboarding.scm): a chat that
;;; sees the screen and teaches one step at a time, beside a stage window.
;;;
;;; The step lives in a buffer local, so a restored wizard comes back on
;;; the step the user left. The mode setup draws the blocks from it.

(require 'setup)
(require 'components)

;;; --- wizard components ---------------------------------------------------------

(domain! 'ui)
(effects! '(pure))

(defcomponent 'wizard/steps
  "A row of numbered wizard steps; the current step is marked and the steps before it are done."
  '((steps list required) (current string required))
  '(steps (("model" "Choose a model") ("learn" "Start learning")) current "model")
  (lambda (p)
    (let ((current (component--get p 'current "")))
      (list 'tag "div" 'class "wizard-steps"
            'children
            (let loop ((steps (component--get p 'steps '())) (n 1) (seen? #f) (out '()))
              (if (null? steps)
                  (reverse out)
                  (let* ((id (car (car steps)))
                         (here? (equal? id current))
                         (state (cond (here? "current") (seen? "todo") (else "done"))))
                    (loop (cdr steps) (+ n 1) (or seen? here?)
                          (cons (list 'tag "div"
                                      'class (string-append "wizard-step wizard-step-" state)
                                      'segs (list (list "wizard-step-n"
                                                        (if (equal? state "done") "✓"
                                                            (number->string n)))
                                                  (list "wizard-step-label"
                                                        (cadr (car steps)))))
                                out)))))))))

(defcomponent 'wizard/choice
  "A choice card: a title, a status badge, one line of detail, and its action buttons."
  '((title string required) (detail string optional) (badge string optional)
    (tone string optional) (selected? boolean optional) (actions list optional))
  '(title "claude-code" detail "ready" badge "ready" tone "good"
    actions (("use" "Use this")))
  (lambda (p)
    (list 'tag "div"
          'class (string-append "wizard-choice"
                                (if (component--get p 'selected? #f) " wizard-selected" ""))
          'children
          (append
            (list (list 'tag "div" 'class "wizard-choice-head"
                        'children
                        (append
                          (list (list 'tag "div" 'class "wizard-choice-title"
                                      'text (component--get p 'title "")))
                          (if (component--has? p 'badge)
                              (list (component 'ui/badge
                                      (list 'text (component--get p 'badge "")
                                            'class (string-append "wizard-tone-"
                                                     (component--get p 'tone "plain")))))
                              '()))))
            (if (component--has? p 'detail)
                (list (list 'tag "div" 'class "wizard-choice-detail"
                            'text (component--get p 'detail "")))
                '())
            (if (pair? (component--get p 'actions '()))
                (list (component 'ui/actions
                        (list 'actions (component--get p 'actions '())
                              'class "wizard-buttons")))
                '())))))

(defcomponent 'wizard/nav
  "The foot of a wizard step: a back button and a next button, each optional."
  '((back list optional) (next list optional))
  '(back ("back" "← Back") next ("next" "Next →"))
  (lambda (p)
    (list 'tag "div" 'class "wizard-nav"
          'children
          (append
            (if (component--has? p 'back)
                (list (component 'ui/actions
                        (list 'actions (list (component--get p 'back '()))
                              'class "wizard-back")))
                (list (list 'tag "div" 'class "wizard-spacer" 'text "")))
            (if (component--has? p 'next)
                (list (component 'ui/actions
                        (list 'actions (list (component--get p 'next '()))
                              'class "wizard-next")))
                '())))))

;;; --- the steps -----------------------------------------------------------------

(domain! 'system)
(effects! '(read))

(define *setup-wizard-buffer* "*Setup*")

(define *setup-wizard-steps*
  '(("model" "Choose a model") ("learn" "Start learning")))

(define (setup-wizard-step buf)
  (or (buffer-local buf 'setup-wizard-step) "model"))

;; The buttons of one connector card. ROW is (NAME KIND READY? DETAIL NEXT),
;; NEXT the first unmet requirement (setup.scm). The hosted card always
;; offers its key: a set key can be replaced.
(define (setup-wizard--card-actions row)
  (let* ((name (list-ref row 0))
         (kind (list-ref row 1))
         (ready? (list-ref row 2))
         (next (and (> (length row) 4) (list-ref row 4)))
         (default? (equal? name *default-connector*))
         (key (string-append "wizard:key:" name))
         (use (if (and ready? (not default?))
                  (list (list (string-append "wizard:use:" name) "Use this"))
                  '())))
    (cond
      ((equal? kind "hosted")
       (append use (list (list key (if ready? "Change the key" "Add a key")))))
      (default? '())
      (ready? use)
      ((not next) '())
      ((memq (plist-get next 'kind) '(secret one-secret)) (list (list key "Add a key")))
      ((pair? (plist-get next 'install))
       (list (list (string-append "wizard:install:" name) "Install")))
      (else '()))))

;; A connector may name its card: the hosted lane reads as what it is.
(define (setup-wizard--card-title name)
  (or (plist-get (connector-config name) 'title) name))

(define (setup-wizard--card-detail row)
  (string-append (connector-description (list-ref row 0)) " · " (list-ref row 3)))

(define (setup-wizard--card row)
  (let* ((name (list-ref row 0))
         (ready? (list-ref row 2))
         (default? (equal? name *default-connector*)))
    (component 'wizard/choice
      (list 'title (setup-wizard--card-title name)
            'detail (setup-wizard--card-detail row)
            'badge (cond (default? "default") (ready? "ready") (else "needs setup"))
            'tone (cond (default? "accent") (ready? "good") (else "plain"))
            'selected? default?
            'actions (setup-wizard--card-actions row)))))

(define (setup-wizard--model-blocks)
  (append
    (list (list 'tag "div" 'class "wizard-title" 'text "Choose a model")
          (list 'tag "div" 'class "wizard-lede"
                'text (string-append
                        "Compos talks to a model through a connector. "
                        "Pick the one that new chats use. You can change it later in any chat."))
          (component 'ui/actions
            (list 'actions '(("wizard:rescan" "Scan again" "g")) 'class "wizard-tools")))
    (list (list 'tag "div" 'class "wizard-grid"
                'children (map setup-wizard--card (setup-inference-scan))))
    (list (component 'wizard/nav
            (list 'next (list "wizard:next" "Next: start learning →"))))))

(define (setup-wizard--learn-blocks)
  (list (list 'tag "div" 'class "wizard-title" 'text "Start learning")
        (list 'tag "div" 'class "wizard-lede"
              'text (string-append
                      "A guide teaches you Compos in a chat, one step at a time, with "
                      *default-connector* ". It sees your screen and starts with "
                      "windows: how to move the focus and get around. Ask it anything as you go."))
        (list 'tag "div" 'class "wizard-columns wizard-columns-2"
              'children
              (map (lambda (c)
                     (list 'tag "div" 'class "wizard-column"
                           'segs (list (list "wizard-column-name" (car c))
                                       (list "wizard-column-what" (cadr c)))))
                   '(("Guide" "a chat that teaches, and answers your questions")
                     ("Stage" "the window where you try each step"))))
        (component 'wizard/nav
          (list 'back (list "wizard:back" "← Back")
                'next (list "wizard:learn" "Start the guide →")))))

(define (setup-wizard-blocks buf)
  (let ((step (setup-wizard-step buf)))
    (list (list 'tag "div" 'class "wizard"
                'children
                (append
                  (list (component 'wizard/steps
                          (list 'steps *setup-wizard-steps* 'current step)))
                  (if (equal? step "learn")
                      (setup-wizard--learn-blocks)
                      (setup-wizard--model-blocks)))))))

(define (setup-wizard-redraw! buf)
  (desktop-skip! buf 'render-blocks)
  (buffer-set-local! buf 'render-mode "blocks")
  (buffer-set-local! buf 'render-blocks (setup-wizard-blocks buf)))

(mode-icon! "setup-wizard-mode" "")

(define-mode "setup-wizard-mode"
  (lambda ()
    (let ((buf (current-buffer)))
      (buffer-set-read-only! buf #t)
      (setup-wizard-redraw! buf))))

(mode-doc! "setup-wizard-mode"
  "First-run setup in two steps. Step one chooses the model that new chats use: click a card's button to use, install, or add a key. Step two starts the guide: a chat that teaches Compos beside a stage window.")

;;; --- actions -------------------------------------------------------------------

(domain! 'system)
(effects! '(write display))

(define (setup-wizard-go! buf step)
  (buffer-set-local! buf 'setup-wizard-step step)
  (setup-wizard-redraw! buf))

(define (setup-wizard-use! buf name)
  (customize-save! 'setup-default-connector name)
  (set! *default-connector* name)
  (message (string-append "Setup: new chats use " name))
  (setup-wizard-redraw! buf))

;; The learning space is the onboarding app: the guide chat and its stage.
(define (setup-open-learning-space!)
  (run-command "onboarding"))

;; A secret, all in the editor. The secrets are settings of type secret
;; (keys.scm), so the question comes from the declaration: its doc, its
;; env name, and its key page. Then: where is the key? A secret tool
;; (Doppler, 1Password, the Keychain, the Secret Service), a command, or a
;; paste. A tool asks its own names, and secrets.scm keeps the lookup, so the
;; value stays in the tool. The key lives where a user's keys live:
;; (define gemini-api-key ...) in ~/.compos/secrets.scm, mode 600.
;; ~/.compos/ai-config.scm loads that file at boot, and the wizard defines
;; it now as well, so no restart is due.
;;
;; Each step takes the secret S and CTX, a plist: 'connector the connector
;; that asked, 'done the thunk that runs after the answer or the refusal.

(define (setup--config-file name) (string-append (compos-config-dir) "/" name))

(define (setup--scheme-string text)
  (string-append "\"" (string-replace (string-replace text "\\" "\\\\") "\"" "\\\"") "\""))

;; TEXT with the line that starts with PREFIX replaced by LINE, else LINE
;; appended. One define per variable: a second key replaces the first.
(define (setup--put-line text prefix line)
  (let loop ((lines (string-split text "\n")) (out '()) (done? #f))
    (cond ((null? lines)
           (let ((kept (reverse (if done? out (cons line out)))))
             (string-append (string-trim (string-join kept "\n")) "\n")))
          ((string-prefix? prefix (car lines))
           (loop (cdr lines) (if done? out (cons line out)) #t))
          (else (loop (cdr lines) (cons (car lines) out) done?)))))

;; VALUE-FORM is the Scheme text that yields the key: a string literal for a
;; pasted key, or a lookup call (doppler-secret-get, op-secret-get, ...).
(define (setup--write-secret! var value-form)
  (let* ((path (setup--config-file "secrets.scm"))
         (old (or (read-file path)
                  ";;; secrets.scm --- API keys. ai-config.scm loads this file. Keep it private.\n")))
    (write-file! path (setup--put-line old (string-append "(define " var " ")
                        (string-append "(define " var " " value-form ")")))
    (set-file-mode! path "600")))

;; ai-config.scm loads secrets.scm once and registers each provider once.
(define (setup--ensure-secrets-load!)
  (let* ((path (setup--config-file "ai-config.scm"))
         (old (or (read-file path) ";;; ai-config.scm --- models and keys. Compos loads this file at boot.\n"))
         (load-line "(load \"secrets.scm\")"))
    (unless (string-contains? old load-line)
      (write-file! path (string-append (string-trim old) "\n" load-line "\n")))
    path))

(define (setup--ctx-done ctx)
  (let ((done (plist-get ctx 'done)))
    (when (procedure? done) (done))))

;; the name a secret goes by in a tool: its env name, else its own
(define (setup--secret-hint s)
  (or (secret-prop s 'env) (symbol->string s)))

;; Keep VALUE-FORM for the secret S, define it now, and make the connector
;; that asked the default once nothing else is missing. A provider key also
;; picks the model its declaration names.
(define (setup--use-key! s ctx value-form key)
  (let ((var (symbol->string s))
        (connector (plist-get ctx 'connector))
        (provider (secret-prop s 'provider))
        (model (secret-prop s 'model)))
    (setup--write-secret! var value-form)
    (setup--ensure-secrets-load!)
    (eval-string-safe (string-append "(define " var " " value-form ")"))
    ;; a key registered earlier would win over the setting; replace it too
    (when provider (register-llm-key! provider key))
    (if (and connector (null? (setup--unmet (setup-connector-requirements connector))))
        (begin
          (customize-save! 'setup-default-connector connector)
          (set! *default-connector* connector)
          (when model (set-llm-model! model))
          (message (string-append "Setup: " var " is in ~/.compos/secrets.scm; new chats use "
                                  (or model connector))))
        (message (string-append "Setup: " var " is in ~/.compos/secrets.scm")))
    (setup--ctx-done ctx)))

(define (setup-store-key! s ctx key)
  (let ((key (string-trim key)))
    (if (equal? key "")
        (begin (message "Setup: the key was empty; nothing changed") (setup--ctx-done ctx))
        (setup--use-key! s ctx (setup--scheme-string key) key))))

(define (setup-key-paste! s ctx)
  (let ((page (secret-prop s 'key-page)))
    (when (and page (not setup-bot-silent-mode)) (tab-open page))
    (minibuffer-read (string-append "Paste " (setup--secret-hint s)
                                    (if page " (the key page is open in a tab): " ": "))
                     '()
      (lambda (key) (setup-store-key! s ctx key)))))

;; FORM is the Scheme call that reads the key from a secret tool. It runs
;; once now: a lookup that answers nothing is not written to secrets.scm.
(define (setup-key-from-form! s ctx form)
  (let* ((r (eval-string-safe form))
         (key (and (pair? r) (equal? (car r) 'ok) (cadr r))))
    (if (and (string? key) (not (equal? key "")))
        (setup--use-key! s ctx form key)
        (begin
          (message (string-append "Setup: " form " gave no key; check the names and try again"))
          (setup--ctx-done ctx)))))

(define (setup--ask prompt choices k)
  (minibuffer-read prompt choices (lambda (v) (k (string-trim v)))))

(define (setup-key-doppler! s ctx)
  (let ((wanted (setup--secret-hint s)))
    (setup--ask "Doppler project: " (doppler--project-candidates)
      (lambda (project)
        (setup--ask "Doppler config: " (doppler--config-candidates project)
          (lambda (config)
            (let* ((names (dp--secret-name-list project config))
                   (ordered (if (member wanted names)
                                (cons wanted (remove (lambda (n) (equal? n wanted)) names))
                                names)))
              (setup--ask "Doppler secret: " ordered
                (lambda (name)
                  (setup-key-from-form! s ctx
                    (string-append "(doppler-secret-get " (setup--scheme-string project) " "
                                   (setup--scheme-string config) " "
                                   (setup--scheme-string name) ")")))))))))))

(define (setup-key-1password! s ctx)
  (setup--ask "1Password vault: " '("Private")
    (lambda (vault)
      (setup--ask "1Password item: " (list (symbol->string s))
        (lambda (item)
          (setup--ask "1Password field: " '("credential" "password")
            (lambda (field)
              (setup-key-from-form! s ctx
                (string-append "(op-secret-get "
                               (setup--scheme-string (string-append "op://" vault "/" item "/" field))
                               ")")))))))))

(define (setup-key-keychain! s ctx)
  (setup--ask "Keychain service: " (list (symbol->string s))
    (lambda (service)
      (setup--ask "Keychain account (RET for any): " '("")
        (lambda (account)
          (setup-key-from-form! s ctx
            (string-append "(keychain-secret-get " (setup--scheme-string service)
                           (if (equal? account "") "" (string-append " " (setup--scheme-string account)))
                           ")")))))))

(define (setup-key-secret-tool! s ctx)
  (setup--ask "Secret Service service name: " (list (symbol->string s))
    (lambda (service)
      (setup-key-from-form! s ctx
        (string-append "(secret-tool-get " (setup--scheme-string service) ")")))))

(define (setup-key-command! s ctx)
  (setup--ask "Shell command that prints the key: " '()
    (lambda (cmd)
      (setup-key-from-form! s ctx
        (string-append "(secret-command " (setup--scheme-string cmd) ")")))))

;; (LABEL PROGRAM ASK): a backend appears when its program is installed.
;; A command and a paste need no program.
(define *setup-key-backends*
  (list (list "Doppler" "doppler" setup-key-doppler!)
        (list "1Password" "op" setup-key-1password!)
        (list "macOS Keychain" "security" setup-key-keychain!)
        (list "Linux Secret Service" "secret-tool" setup-key-secret-tool!)
        (list "A command that prints the key" #f setup-key-command!)
        (list "Paste the key" #f setup-key-paste!)))

(define (setup-key-backends-here)
  (filter (lambda (b) (or (not (cadr b)) (setup--program-present? (cadr b))))
          *setup-key-backends*))

;; Ask for the secret S on behalf of CONNECTOR, then DONE.
(define (setup-ask-secret! s connector done)
  (let ((backends (setup-key-backends-here))
        (ctx (list 'connector connector 'done done)))
    (minibuffer-read (string-append "Where is " (setup--secret-hint s) "? ") (map car backends)
      (lambda (where)
        (let ((b (assoc where backends)))
          (if b
              ((caddr b) s ctx)
              (begin (message "Setup: no key added") (setup--ctx-done ctx))))))))

;; The key button of a card asks for the connector's own secrets: one is
;; asked at once, more offer a choice.
(define (setup-wizard-add-key! buf connector)
  (let* ((reqs (filter (lambda (r) (memq (plist-get r 'kind) '(secret one-secret)))
                       (setup-connector-requirements connector)))
         (ss (apply append (map (lambda (r) (if (plist-get r 'secret)
                                                (list (plist-get r 'secret))
                                                (plist-get r 'secrets)))
                                reqs)))
         (done (lambda () (when (buffer-exists? buf) (setup-wizard-redraw! buf)))))
    (cond
      ((null? ss) (message (string-append "Setup: " connector " declares no key")))
      ((null? (cdr ss)) (setup-ask-secret! (car ss) connector done))
      (else
       (minibuffer-read "Which key? " (map setup-secret-label ss)
         (lambda (label)
           (let ((s (find (lambda (s) (equal? (setup-secret-label s) label)) ss)))
             (if s
                 (setup-ask-secret! s connector done)
                 (message "Setup: no key added")))))))))

(define (setup-wizard-click buf id)
  (cond
    ((equal? id "wizard:next") (setup-wizard-go! buf "learn") #t)
    ((equal? id "wizard:back") (setup-wizard-go! buf "model") #t)
    ((equal? id "wizard:rescan") (setup-wizard-redraw! buf) (message "Setup: scanned again") #t)
    ((string-prefix? "wizard:key:" id)
     (setup-wizard-add-key! buf (substring-bytes id 11 (string-byte-length id))) #t)
    ((equal? id "wizard:learn") (setup-open-learning-space!) #t)
    ((string-prefix? "wizard:use:" id)
     (setup-wizard-use! buf (substring-bytes id 11 (string-byte-length id))) #t)
    ((string-prefix? "wizard:install:" id)
     (setup-install-agent! (substring-bytes id 15 (string-byte-length id))) #t)
    (else #f)))

(add-hook! (list 'block-click 'setup-wizard)
  (lambda (buf id)
    (and (equal? (buffer-local buf 'mode-name) "setup-wizard-mode")
         (setup-wizard-click buf id))))

;; Setup chooses the columns layout: buffers open side by side, and the
;; guide's chat, its stage, and the next buffer share the frame as columns.
;; The choice is saved, so every frame and group starts in columns.
(define (setup-choose-columns!)
  (unless (equal? window-layout-default 'columns)
    (customize-save! 'window-layout-default 'columns))
  (set-frame-local! 'layout-freed #f)
  (unless (equal? (layout-target) 'columns)
    (layout-target-set! 'columns)))

(define (setup-wizard! &optional step)
  (setup-choose-columns!)
  (let ((buf *setup-wizard-buffer*))
    (unless (buffer-exists? buf)
      (buffer-create buf)
      (buffer-append! buf "Setup\n"))
    (when step (buffer-set-local! buf 'setup-wizard-step step))
    ;; a window on a blank buffer gives its place to the wizard; a window
    ;; on work keeps it, and the wizard opens in the next column
    (if (member (current-buffer) '("*scratch*" "*Messages*"))
        (switch-to-buffer-here! buf)
        (switch-to-buffer! buf))
    (with-current-buffer buf (lambda () (set-mode! "setup-wizard-mode")))
    buf))

;;; --- the home page -------------------------------------------------------------

;; Setup is done when the user chose a connector, and this machine can
;; still run it. A connector that a reinstall removed opens setup again.
(define (setup-complete?)
  (and (not (equal? setup-default-connector ""))
       (member setup-default-connector (setup-inference-available))
       #t))

(define (setup-welcome-here!)
  (let ((buf *setup-buffer*))
    (buffer-create buf)
    (buffer-set-read-only! buf #f)
    (setup--document-set! buf (setup-welcome-document))
    (buffer-set-local! buf 'help-title "Welcome to Compos")
    (switch-to-buffer! buf)
    (set-mode! "help-mode")
    (unless (minor-mode-on? buf "preview-mode")
      (enable-minor-mode! buf "preview-mode"))
    buf))

;; The page a frame shows when it has nothing else: no group is left.
;; Before setup it is the setup status, with the buttons that fix it.
(define (compos-home!)
  (if (setup-complete?)
      (setup-welcome-here!)
      (setup-wizard! "model")))

;; Start the onboarding over: the connector choice and the welcome marker
;; go, and the home page is the wizard again. Keys in secrets.scm stay:
;; they are the user's, and the wizard offers to change them.
(define (setup-reset!)
  (customize-save! 'setup-default-connector "")
  (when (file-exists? (setup-welcome-marker-path))
    (delete-file-path! (setup-welcome-marker-path) #t))
  (setup-apply-default-connector!)
  (when (buffer-exists? *setup-wizard-buffer*)
    (buffer-set-local! *setup-wizard-buffer* 'setup-wizard-step "model"))
  (compos-home!)
  (message "Setup: reset. Choose a model to start again"))

(define-command "setup-reset" "Start setup over: forget the chosen model and show the setup wizard"
  (lambda () (setup-reset!)))

(define-command "compos-home" "Open the Compos home page: setup until it is done, then the welcome page"
  (lambda () (compos-home!)))

(define-command "setup" "Set up Compos: choose a model, then learn with the guide"
  (lambda () (setup-wizard! "model")))

;; The inference step is the wizard's first page: the scan as cards with
;; buttons, not a document to read.
(define-command "setup-inference" "Choose the model that new chats use"
  (lambda () (setup-wizard! "model")))

(define-command "setup-learning-space" "Open the guide: a chat that teaches Compos, and a stage to try each step"
  (lambda () (setup-open-learning-space!)))

(define-command "setup-wizard-next" "Go to the next setup step"
  (lambda () (setup-wizard-go! (current-buffer) "learn")))

(define-command "setup-wizard-back" "Go to the previous setup step"
  (lambda () (setup-wizard-go! (current-buffer) "model")))

(define-command "setup-wizard-rescan" "Scan this machine for models again"
  (lambda () (setup-wizard-redraw! (current-buffer))))

(mode-keys! "setup-wizard-mode"
  '(("n" "setup-wizard-next")
    ("p" "setup-wizard-back")
    ("g" "setup-wizard-rescan")
    ("q" "quit-window")))

(define-style! 'setup-wizard "
.wizard { max-width: 760px; margin: 0 auto; padding: 28px 20px 40px; font-family: var(--font-serif); }
.wizard-steps { display: flex; gap: 28px; margin-bottom: 34px; font-family: var(--font-mono); font-size: 12px;
  letter-spacing: .06em; text-transform: uppercase; }
.wizard-step { display: flex; align-items: center; gap: 9px; color: var(--dim-fg, #8a857a); }
.wizard-step-n { display: inline-flex; width: 24px; height: 24px; align-items: center; justify-content: center;
  border: 1px solid var(--border-bg, #cbc4b1); border-radius: 50%; }
.wizard-step-current { color: var(--default-fg, inherit); font-weight: 600; }
.wizard-step-current .wizard-step-n { background: var(--accent-fg, #26356b); border-color: var(--accent-fg, #26356b);
  color: var(--default-bg, #fff); }
.wizard-step-done .wizard-step-n { border-color: var(--accent-fg, #26356b); color: var(--accent-fg, #26356b); }
.wizard-title { font-size: 34px; font-weight: 600; line-height: 1.15; margin-bottom: 10px; }
.wizard-lede { font-size: 17px; line-height: 1.6; color: var(--dim-fg, #8a857a); max-width: 34em; margin-bottom: 18px; }
.wizard-tools { margin-bottom: 14px; }
.wizard-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 14px; }
.wizard-choice { border: 1px solid var(--border-bg, #cbc4b1); padding: 16px 16px 14px; display: flex;
  flex-direction: column; gap: 8px; background: var(--window-bg, transparent); }
.wizard-choice.wizard-selected { border-color: var(--accent-fg, #26356b); box-shadow: inset 0 0 0 1px var(--accent-fg, #26356b); }
.wizard-choice-head { display: flex; align-items: center; justify-content: space-between; gap: 10px; }
.wizard-choice-title { font-size: 19px; font-weight: 600; }
.wizard-choice-detail { font-family: var(--font-mono); font-size: 12px; color: var(--dim-fg, #8a857a); flex: 1; }
.wizard .c-badge { font-family: var(--font-mono); font-size: 11px; padding: 2px 8px; border: 1px solid currentColor;
  text-transform: uppercase; letter-spacing: .06em; white-space: nowrap; }
.wizard-tone-good { color: #2f7d4f; }
.wizard-tone-accent { color: var(--accent-fg, #26356b); }
.wizard-tone-plain { color: var(--dim-fg, #8a857a); }
.wizard .c-actions { display: flex; gap: 8px; flex-wrap: wrap; }
.wizard c-action { cursor: pointer; font-family: var(--font-mono); font-size: 13px; padding: 7px 14px;
  border: 1px solid var(--border-bg, #cbc4b1); user-select: none; }
.wizard c-action:hover { border-color: var(--accent-fg, #26356b); color: var(--accent-fg, #26356b); }
.wizard-buttons c-action, .wizard-next c-action { background: var(--accent-fg, #26356b); color: var(--default-bg, #fff);
  border-color: var(--accent-fg, #26356b); }
.wizard-buttons c-action:hover, .wizard-next c-action:hover { opacity: .88; color: var(--default-bg, #fff); }
.wizard-nav { display: flex; justify-content: space-between; align-items: center; margin-top: 34px;
  padding-top: 18px; border-top: 1px solid var(--border-bg, #cbc4b1); }
.wizard-next c-action { font-size: 15px; padding: 11px 20px; }
.wizard-columns { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; margin-top: 8px; }
.wizard-columns-2 { grid-template-columns: repeat(2, 1fr); }
.wizard-column { border: 1px solid var(--border-bg, #cbc4b1); border-top: 3px solid var(--accent-fg, #26356b);
  padding: 18px 14px 26px; display: flex; flex-direction: column; gap: 6px; }
.wizard-column-name { font-size: 19px; font-weight: 600; display: block; }
.wizard-column-what { font-size: 14px; color: var(--dim-fg, #8a857a); display: block; }
")
