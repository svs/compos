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

;; The install command for a connector that setup can install, or #f.
(define *setup-wizard-installs*
  '(("claude-code" "claude") ("codex-app-server" "codex")))

(define (setup-wizard--install-for name)
  (let ((e (assoc name *setup-wizard-installs*)))
    (and e (cadr e))))

;; The buttons of one connector card. ROW is (NAME KIND READY? DETAIL).
(define (setup-wizard--card-actions row)
  (let ((name (list-ref row 0))
        (kind (list-ref row 1))
        (ready? (list-ref row 2)))
    (cond
      ((equal? name *default-connector*) '())
      (ready? (list (list (string-append "wizard:use:" name) "Use this")))
      ((setup-wizard--install-for name)
       (list (list (string-append "wizard:install:" (setup-wizard--install-for name))
                   "Install")))
      ((equal? kind "hosted") (list (list "wizard:key" "Add a key")))
      (else '()))))

;; The hosted connector reads as what it is: your own key for a hosted
;; model. Its scan row only says "api".
(define (setup-wizard--card-title name)
  (if (equal? name "api") "Hosted model (your API key)" name))

(define (setup-wizard--card-detail row)
  (if (equal? (list-ref row 0) "api")
      (if (list-ref row 2)
          "A key is stored. Chats use it directly, with no agent program."
          "Paste a key from OpenRouter, Anthropic, or OpenAI. No agent program is needed.")
      (string-append (list-ref row 1) " · " (list-ref row 3))))

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

;; A hosted key in three steps, all in the editor: pick the provider, its
;; key page opens in a tab, paste the key. The key lives where a user's
;; keys live: (define *openrouter-api-key* "...") in ~/.compos/secrets.scm,
;; mode 600. ~/.compos/ai-config.scm loads that file at boot and registers
;; the key, and the wizard registers it now as well, so no restart is due.
(define *setup-key-providers*
  ;; (LABEL PROVIDER VARIABLE KEY-PAGE MODEL)
  '(("OpenRouter — one key for every model (recommended)" "openrouter" "*openrouter-api-key*"
     "https://openrouter.ai/settings/keys" "openrouter:anthropic/claude-sonnet-5")
    ("Anthropic — Claude models" "anthropic" "*anthropic-api-key*"
     "https://console.anthropic.com/settings/keys" "claude-sonnet-5")
    ("OpenAI — GPT models" "openai" "*openai-api-key*"
     "https://platform.openai.com/api-keys" "openai:gpt-5.6-luna")))

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
;; pasted key, a doppler-secret-get call for a key that stays in Doppler.
(define (setup--write-secret! var value-form)
  (let* ((path (setup--config-file "secrets.scm"))
         (old (or (read-file path)
                  ";;; secrets.scm --- API keys. ai-config.scm loads this file. Keep it private.\n")))
    (write-file! path (setup--put-line old (string-append "(define " var " ")
                        (string-append "(define " var " " value-form ")")))
    (set-file-mode! path "600")))

;; ai-config.scm loads secrets.scm once and registers each provider once.
(define (setup--ensure-ai-config! provider var)
  (let* ((path (setup--config-file "ai-config.scm"))
         (old (or (read-file path) ";;; ai-config.scm --- models and keys. Compos loads this file at boot.\n"))
         (load-line "(load \"secrets.scm\")")
         (with-load (if (string-contains? old load-line) old
                        (string-append (string-trim old) "\n" load-line "\n")))
         (register-line (string-append "(register-llm-key! \"" provider "\" " var ")")))
    (write-file! path (if (string-contains? with-load register-line) with-load
                          (string-append with-load register-line "\n")))))

(define (setup--use-key! entry value-form key buf)
  (let ((provider (list-ref entry 1))
        (var (list-ref entry 2))
        (model (list-ref entry 4)))
    (setup--write-secret! var value-form)
    (setup--ensure-ai-config! provider var)
    (eval-string-safe (string-append "(define " var " " value-form ")"))
    (register-llm-key! provider key)
    (customize-save! 'setup-default-connector "api")
    (set! *default-connector* "api")
    (set-llm-model! model)
    (message (string-append "Setup: " var " is in ~/.compos/secrets.scm; new chats use " model))
    (when (buffer-exists? buf) (setup-wizard-redraw! buf))))

(define (setup-store-key! entry key buf)
  (let ((key (string-trim key)))
    (if (equal? key "")
        (message "Setup: the key was empty; nothing changed")
        (setup--use-key! entry (setup--scheme-string key) key buf))))

;; The key stays in Doppler: secrets.scm holds the lookup, and every boot
;; asks Doppler for the current value. A rotated key needs no edit here.
(define (setup--doppler-place)
  (let ((p (and (buffer-exists? *doppler-buffer*) (buffer-local *doppler-buffer* 'doppler-project)))
        (c (and (buffer-exists? *doppler-buffer*) (buffer-local *doppler-buffer* 'doppler-config))))
    (list (or p key-doppler-project) (or c key-doppler-config))))

(define (setup-key-from-doppler! entry buf)
  (let* ((place (setup--doppler-place))
         (project (car place))
         (config (cadr place))
         (names (dp--secret-name-list project config))
         (wanted (string-upcase (string-append (list-ref entry 1) "_API_KEY")))
         ;; the conventional name first, so RET takes it
         (ordered (if (member wanted names)
                      (cons wanted (remove (lambda (n) (equal? n wanted)) names))
                      names)))
    (if (null? names)
        (message (string-append "Setup: Doppler has no secrets in " project "/" config))
        (minibuffer-read (string-append "Doppler secret (" project "/" config "): ") ordered
          (lambda (name)
            (let ((key (doppler-secret-get project config name)))
              (if (not (and (string? key) (not (equal? key ""))))
                  (message (string-append "Setup: Doppler gave no value for " name))
                  (setup--use-key! entry
                    (string-append "(doppler-secret-get " (setup--scheme-string project) " "
                                   (setup--scheme-string config) " "
                                   (setup--scheme-string name) ")")
                    key buf))))))))

(define (setup-key-paste! entry buf)
  (unless setup-bot-silent-mode (tab-open (list-ref entry 3)))
  (minibuffer-read (string-append "Paste your " (list-ref entry 1)
                                  " API key (the key page is open in a tab): ")
                   '()
    (lambda (key) (setup-store-key! entry key buf))))

(define (setup-wizard-add-key! buf)
  (minibuffer-read "Which provider is the key from? " (map car *setup-key-providers*)
    (lambda (label)
      (let ((entry (assoc label *setup-key-providers*)))
        (cond
          ((not entry) (message "Setup: no key added"))
          ((setup--program-present? "doppler")
           (minibuffer-read "Where is the key? "
             '("In Doppler — secrets.scm asks Doppler at each boot" "Paste it — secrets.scm holds the key")
             (lambda (where)
               (if (string-prefix? "In Doppler" where)
                   (setup-key-from-doppler! entry buf)
                   (setup-key-paste! entry buf)))))
          (else (setup-key-paste! entry buf)))))))

(define (setup-wizard-click buf id)
  (cond
    ((equal? id "wizard:next") (setup-wizard-go! buf "learn") #t)
    ((equal? id "wizard:back") (setup-wizard-go! buf "model") #t)
    ((equal? id "wizard:rescan") (setup-wizard-redraw! buf) (message "Setup: scanned again") #t)
    ((equal? id "wizard:key") (setup-wizard-add-key! buf) #t)
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

(define (setup-wizard! &optional step)
  (let ((buf *setup-wizard-buffer*))
    (unless (buffer-exists? buf)
      (buffer-create buf)
      (buffer-append! buf "Setup\n"))
    (when step (buffer-set-local! buf 'setup-wizard-step step))
    (switch-to-buffer! buf)
    (set-mode! "setup-wizard-mode")
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
