;;; llm-config-test.scm --- the model catalog policy.
;;;
;;; The refresh itself is a network fetch of several megabytes and belongs
;;; to no test. What is testable is the policy: when this editor calls a
;;; catalog stale, and what it reports about the one it loaded.

(domain! 'testing)
(effects! '(read))

(deftest 'llm-catalog-counts-an-unrecorded-catalog-as-stale
  "the catalog packaged with the build records no capture time, so it is stale"
  (lambda ()
    (check-true! (llm-catalog-stale-age? #f)
                 "a catalog with no recorded age is stale")))

(deftest 'llm-catalog-stale-follows-the-max-age
  "the limit is llm-catalog-max-age-days, and the limit itself is still fresh"
  (lambda ()
    (let ((max llm-catalog-max-age-days))
      (check-false! (llm-catalog-stale-age? 0)
                    "a catalog captured today is fresh")
      (check-false! (llm-catalog-stale-age? max)
                    "a catalog exactly at the limit is still fresh")
      (check-true! (llm-catalog-stale-age? (+ max 1))
                   "a catalog one day past the limit is stale"))))

(define (llm-catalog-test--has-key? plist key)
  (cond ((null? plist) #f)
        ((equal? (car plist) key) #t)
        ((null? (cdr plist)) #f)
        (else (llm-catalog-test--has-key? (cddr plist) key))))

(deftest 'llm-catalog-info-names-every-field-the-policy-reads
  "the policy reads these keys, so the primitive must carry every one"
  (lambda ()
    (let ((info (llm-catalog-info)))
      (for-each
        (lambda (key)
          ;; plist-get answers #f for a key that is absent AND for one whose
          ;; value is #f, so the presence test walks the keys themselves
          (check-true! (llm-catalog-test--has-key? info key)
                       (string-append "llm-catalog-info carries " (symbol->string key))))
        '(snapshot-id captured-at models providers stale-days path)))))

(deftest 'llm-catalog-describe-says-what-the-catalog-holds
  "the line a person reads names the counts and the capture time"
  (lambda ()
    (let ((text (llm-catalog--describe
                  '(models 7430 providers 179 captured-at "2026-09-22T04:30:15Z"))))
      (check-contains! text "7430" "the description counts the models")
      (check-contains! text "179" "the description counts the providers")
      (check-contains! text "2026-09-22T04:30:15Z"
                       "the description says when the catalog was captured"))))

;;; --- the menu and a dead chat ---------------------------------------------

(deftest 'llm-config-quit-skips-a-chat-that-died
  "ESC on the menu does not write to a chat that was killed while it was open"
  (lambda ()
    (let ((saved *llm-bundles*)
          (history *llm-config-history*)
          (buf (test-buffer! "zz-llm-config-dead" "")))
      (buffer-set-local! buf 'llm-connector "api")
      (buffer-set-local! buf 'llm-model "m1")
      (set! *llm-bundles* '())
      (with-current-buffer buf
        (lambda ()
          (transient-setup "llm-configure" buf)
          (llm-config--box-set! 'model "m2")
          (llm-config--box-set! 'permission "approve")))
      (buffer-kill! buf)
      (run-command "transient-quit-one")
      (check-false! (transient--active) "the menu closes")
      (check-false! (frame-local 'llm-config-box) "and the box is gone")
      (check-false! (buffer-exists? buf) "and the chat stays dead")
      (set! *llm-bundles* saved)
      (set! *llm-config-history* history))))

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
