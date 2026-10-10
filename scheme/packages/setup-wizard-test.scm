;;; setup-wizard-test.scm --- setup-wizard.scm: the two-step first-run wizard.

(domain! 'testing)
(effects! '(write))

(tests-need-a-disposable-editor!
  "opens the wizard, changes the default connector, and lays out the learning space")

(define (t--wiz-text blocks) (value->string blocks))

(deftest 'wizard-steps-mark-done-current-and-todo
  "the steps before the current one are done, and the steps after it are to do"
  (lambda ()
    (let ((text (t--wiz-text
                  (component 'wizard/steps
                    '(steps (("a" "One") ("b" "Two") ("c" "Three")) current "b")))))
      (check-contains! text "wizard-step-done" "the first step")
      (check-contains! text "wizard-step-current" "the second step")
      (check-contains! text "wizard-step-todo" "the third step"))))

(deftest 'every-wizard-component-renders-its-example
  "the wizard components render their declared examples without an error"
  (lambda ()
    (for-each
      (lambda (name)
        (let ((e (component-entry name)))
          (check-false! (string-contains? (t--wiz-text (component name (nth 2 e))) "(error")
                        name)))
      '(wizard/steps wizard/choice wizard/nav))))

(deftest 'a-connector-card-offers-the-button-that-fits
  "ready offers use, an installable agent offers install, a hosted model offers a key"
  (lambda ()
    (let ((old *default-connector*))
      (set! *default-connector* "zz-other")
      (check-equal! (map car (setup-wizard--card-actions '("opencode" "acp" #t "ready")))
                    '("wizard:use:opencode") "a ready connector")
      (check-equal! (map car (setup-wizard--card-actions
                               '("claude-code" "acp" #f "not installed")))
                    '("wizard:install:claude") "claude")
      (check-equal! (map car (setup-wizard--card-actions
                               '("codex-app-server" "acp" #f "not installed")))
                    '("wizard:install:codex") "codex")
      (check-equal! (map car (setup-wizard--card-actions '("api" "hosted" #f "no key")))
                    '("wizard:key") "a hosted model")
      (set! *default-connector* "opencode")
      (check-equal! (setup-wizard--card-actions '("opencode" "acp" #t "ready")) '()
                    "the default needs no button")
      (set! *default-connector* old))))

(deftest 'use-this-makes-the-connector-the-default
  "the use button sets the connector that new chats use"
  (lambda ()
    (let ((old *default-connector*)
          (old-saved setup-default-connector)
          (buf (setup-wizard! "model")))
      (check-true! (setup-wizard-click buf "wizard:use:zz-picked") "the click is the wizard's")
      (check-equal! *default-connector* "zz-picked" "the default")
      (customize-save! 'setup-default-connector old-saved)
      (set! *default-connector* old)
      (buffer-kill! buf))))

;; The step is a buffer local, and the mode setup draws from it: a
;; restored wizard comes back on the step the user left.
(deftest 'the-wizard-step-survives-a-mode-rerun
  "next moves to the learning step, and a mode rerun keeps it"
  (lambda ()
    (let ((buf (setup-wizard! "model")))
      (setup-wizard-click buf "wizard:next")
      (check-equal! (setup-wizard-step buf) "learn" "next")
      (with-current-buffer buf (lambda () (set-mode! "setup-wizard-mode")))
      (check-contains! (t--wiz-text (buffer-local buf 'render-blocks)) "Start learning"
                       "the redrawn step")
      (setup-wizard-click buf "wizard:back")
      (check-equal! (setup-wizard-step buf) "model" "back")
      (buffer-kill! buf))))

(deftest 'a-secret-define-replaces-the-old-one
  "writing a key replaces the variable's define and keeps the other lines"
  (lambda ()
    (check-equal! (setup--put-line "; head\n(define *a* \"1\")\n(define *b* \"2\")\n"
                                   "(define *a* " "(define *a* \"9\")")
                  "; head\n(define *a* \"9\")\n(define *b* \"2\")\n" "replaced in place")
    (check-contains! (setup--put-line "; head\n" "(define *c* " "(define *c* \"3\")")
                     "(define *c* \"3\")" "appended when absent")
    (check-equal! (setup--scheme-string "a\"b\\c") "\"a\\\"b\\\\c\"" "a key is a safe literal")))

(deftest 'every-key-provider-has-a-page-and-a-model
  "each hosted key choice names its provider, variable, key page, and model"
  (lambda ()
    (for-each
      (lambda (e)
        (check-equal! (length e) 5 (car e))
        (check-true! (string-prefix? "https://" (list-ref e 3)) "the key page")
        (check-true! (string-prefix? "*" (list-ref e 2)) "a variable name"))
      *setup-key-providers*)))

(deftest 'the-home-page-is-setup-until-setup-is-done
  "before a connector is chosen the home page is the wizard"
  (lambda ()
    (let ((saved setup-default-connector))
      (set! setup-default-connector "")
      (check-false! (setup-complete?) "nothing chosen")
      (compos-home!)
      (check-equal! (current-buffer) *setup-wizard-buffer* "the wizard")
      (buffer-kill! *setup-wizard-buffer*)
      (set! setup-default-connector saved))))

(deftest 'setup-reset-starts-onboarding-over
  "setup-reset forgets the chosen connector and shows the wizard on its first step"
  (lambda ()
    (let ((saved setup-default-connector))
      (set! setup-default-connector "zz-chosen")
      (setup-reset!)
      (check-equal! setup-default-connector "" "the choice is gone")
      (check-equal! (current-buffer) *setup-wizard-buffer* "the wizard shows")
      (check-equal! (setup-wizard-step *setup-wizard-buffer*) "model" "on its first step")
      (customize-save! 'setup-default-connector saved))))

(deftest 'setup-chooses-the-columns-layout
  "opening the wizard puts the frame in the columns layout"
  (lambda ()
    (layout-target-set! #f)
    (setup-wizard! "model")
    (check-equal! (layout-target) 'columns "the frame")
    (check-equal! window-layout-default 'columns "the saved default")))

(deftest 'every-machine-can-paste-or-run-a-command-for-a-key
  "the key backends always offer a command and a paste, whatever is installed"
  (lambda ()
    (let ((labels (map car (setup-key-backends-here))))
      (check-true! (member "A command that prints the key" labels) "a command")
      (check-true! (member "Paste the key" labels) "a paste"))))

(deftest 'a-set-key-can-be-changed
  "the hosted card offers to change a key that is set"
  (lambda ()
    (let ((saved *default-connector*))
      (set! *default-connector* "api")
      (check-equal! (setup-wizard--card-actions '("api" "hosted" #t "a key"))
                    '(("wizard:key" "Change the key")) "the default card")
      (set! *default-connector* saved))))

(deftest 'desktop-clear-leaves-one-window-on-the-home-page
  "a clear leaves one window, and it shows the home page"
  (lambda ()
    (let ((buf (test-buffer! "*zz-clear*" "")))
      (split-window! 'h 0.5)
      (desktop-clear--finish '() (list buf))
      (check-equal! (length (window-list)) 1 "one window")
      (check-true! (member (current-buffer) (list *setup-wizard-buffer* *setup-buffer*))
                   "the home page"))))
