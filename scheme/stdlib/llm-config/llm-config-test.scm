;;; llm-config-test.scm --- the C-c b menu.
;;;
;;; The model catalog's tests live in llm-catalog/llm-catalog-test.scm.

(domain! 'testing)
(effects! '(read))

;;; --- the menu and a dead chat ---------------------------------------------

(deftest 'llm-config-quit-skips-a-chat-that-died
  "ESC on the menu does not write to a chat that was killed while it was open"
  (lambda ()
    (with-stubs (list (list '*llm-bundles* '())
                      (list '*llm-config-history* *llm-config-history*))
      (lambda ()
        (let ((buf (test-buffer! "zz-llm-config-dead" "")))
          (buffer-set-local! buf 'llm-connector "api")
          (buffer-set-local! buf 'llm-model "m1")
          (with-current-buffer buf
            (lambda ()
              (transient-setup "llm-configure" buf)
              (llm-config--box-set! 'model "m2")
              (llm-config--box-set! 'permission "approve")))
          (buffer-kill! buf)
          (run-command "transient-quit-one")
          (check-false! (transient--active) "the menu closes")
          (check-false! (frame-local 'llm-config-box) "and the box is gone")
          (check-false! (buffer-exists? buf) "and the chat stays dead"))))))

(deftest 'llm-bundle-apply-ignores-a-dead-buffer
  "a bundle applied to a buffer that does not exist changes nothing"
  (lambda ()
    (check-false! (llm-bundle-apply! "zz-no-such-chat" '(permission "approve"))
                  "the apply answers #f")))

;; The exit gives the selected row to the chat. An edit on another row
;; was a draft the exit ignored, so the chat kept its old backend.
(deftest 'an-edit-selects-the-row-it-edits
  "changing a field of the shown row makes that row the one the exit applies"
  (lambda ()
    (set-frame-local! 'llm-config-source "zz-shown")
    (set-frame-local! 'llm-config-selected "zz-other")
    (set-frame-local! 'llm-config-box '())
    (set-frame-local! 'llm-config-drafts '())
    (llm-config--box-set! 'connector "opencode")
    (check-equal! (llm-config--selected-name) "zz-shown" "the edited row is selected")
    (check-equal! (plist-get (llm-config--config-of "zz-shown") 'connector) "opencode"
                  "and the exit applies its draft")
    (for-each (lambda (k) (set-frame-local! k #f))
              '(llm-config-source llm-config-selected llm-config-box llm-config-drafts))))

(deftest 'llm-config-shows-save-actions-in-the-preset-config-section
  "the large config section contains the three save buttons"
  (lambda ()
    (let* ((groups (llm-config--groups #f))
           (config-section (assoc (llm-config--config-title) groups))
           (actions (filter (lambda (item) (plist-get item 'preset-action))
                            (cdr config-section))))
      (check-equal! (filter (lambda (item) (plist-get item 'preset-action))
                            (cdr (car groups)))
                    '() "the preset list has no save buttons")
      (check-equal! (map (lambda (item) (plist-get item 'command)) actions)
                    '("llm-config-save-into" "llm-config-save-bundle" "llm-config-save-default")
                    "the config section has all three save commands")
      (check-equal! (map (lambda (item) (plist-get item 'description)) actions)
                    '("Save" "Save as preset..." "Make default...")
                    "the button labels state their actions")
      (check-equal! (assoc "Save config" groups) #f
                    "the buttons share the large config section"))))

(deftest 'llm-config-save-default-asks-for-scope
  "make default asks for the group or all of Compos before saving"
  (lambda ()
    (run-command "llm-config-save-default")
    (let ((state (minibuffer-state)))
      (check-equal! (plist-get state 'prompt) "Make default for: " "the prompt names its purpose")
      (check-equal! (plist-get state 'total) 2 "the prompt has two scopes"))
    (minibuffer-cancel!)))
