;;; transient-test.scm --- transient menu policy.

(domain! 'testing)
(effects! '(write))

(deftest 'llm-config-history-keeps-recent-distinct-setups
  "The LLM selector history is newest-first, distinct, and bounded"
  (lambda ()
    (let ((saved *llm-config-history*))
      (set! *llm-config-history* '())
      (llm-config-remember! '(connector "api" model "default" effort "default"))
      (llm-config-remember!
        '(connector "codex-app-server" model "gpt-5.6-terra" effort "high"))
      (llm-config-remember! '(connector "api" model "default" effort "default"))
      (check-equal!
        (map llm-bundle-connector *llm-config-history*)
        '("api" "codex-app-server")
        "a repeated setup moves to the front without a duplicate")
      (set! *llm-config-history*
        (map (lambda (c) (list 'connector c 'model "m" 'effort "e"))
             '("c1" "c2" "c3" "c4" "c5" "c6" "c7" "c8" "c9" "c10")))
      (llm-config-remember! '(connector "c11" model "m" effort "e"))
      (check-equal! (length *llm-config-history*) llm-config-history-limit
                    "a new setup drops the oldest entry")
      (check-false! (member "c10" (map llm-bundle-connector *llm-config-history*))
                    "the history removes its oldest entry")
      (set! *llm-config-history* saved))))

(deftest 'llm-config-history-separates-setups-by-their-tools
  "Two setups that differ only in their presets are two recent choices"
  (lambda ()
    (let ((saved *llm-config-history*))
      (set! *llm-config-history* '())
      (llm-config-remember!
        '(connector "api" model "default" effort "default" presets (compos)))
      (llm-config-remember!
        '(connector "api" model "default" effort "default" presets (compos web)))
      (check-equal! (length *llm-config-history*) 2
                    "the tool surface is part of what a choice IS")
      (set! *llm-config-history* saved))))

(deftest 'llm-config-history-reads-its-old-three-part-entries
  "A history saved before presets still recalls what it did record"
  (lambda ()
    (let ((b (llm-bundle-normalize '("api" "gpt-5.5" "high"))))
      (check-equal! (llm-bundle-connector b) "api" "the backend survives")
      (check-equal! (llm-bundle-model b) "gpt-5.5" "the model survives")
      (check-equal! (llm-bundle-effort b) "high" "the effort survives")
      (check-false! (llm-bundle-presets b)
                    "an entry that named no presets changes none"))))

(deftest 'llm-bundle-label-says-what-is-unusual
  "A bundle label leaves out every part that is already the default"
  (lambda ()
    (check-equal!
      (llm-bundle-label '(connector "claude-code" model "default"
                          effort "default" presets (compos)
                          permission "approve" agent-mode "default"))
      "claude-code"
      "the defaults and the always-on editor bridge stay quiet")
    (check-equal!
      (llm-bundle-label '(name "review" connector "claude-code"
                          model "opus[1m]" effort "high"
                          presets (compos web) permission "ask"
                          agent-mode "plan"))
      "claude-code · opus[1m] · high · web · ask · plan"
      "everything chosen is named, in the order the menu sets it")))

(deftest 'llm-bundles-are-named-and-replaceable
  "A named bundle is saved by name, replaced by name, and forgotten by name"
  (lambda ()
    (let ((saved *llm-bundles*))
      (set! *llm-bundles* '())
      (llm-bundle-save! "zz-work" '(connector "api" model "m1" effort "high"))
      (llm-bundle-save! "zz-read" '(connector "claude-code" model "haiku"))
      (check-equal! (llm-bundle-model (llm-bundle-named "zz-work")) "m1"
                    "a bundle answers to its name")
      (llm-bundle-save! "zz-work" '(connector "api" model "m2" effort "high"))
      (check-equal! (length *llm-bundles*) 2
                    "saving over a name replaces that bundle")
      (check-equal! (llm-bundle-model (llm-bundle-named "zz-work")) "m2"
                    "the newer setup is the one kept")
      (llm-bundle-forget! "zz-work")
      (check-false! (llm-bundle-named "zz-work") "a forgotten bundle is gone")
      (check-true! (and (llm-bundle-named "zz-read") #t)
                   "and the others are not")
      (set! *llm-bundles* saved))))

(deftest 'llm-config-history-offers-ten-numbered-choices
  "The LLM selector offers ten recent setups with numeric keys"
  (lambda ()
    (let ((saved *llm-config-history*)
          (buf (test-buffer! "zz-llm-config-history" "")))
      (buffer-set-local! buf 'llm-connector "codex-app-server")
      (buffer-set-local! buf 'llm-model "gpt-5.6-luna")
      (buffer-set-local! buf 'llm-effort "medium")
      (set! *llm-config-history*
        (map (lambda (c) (list 'connector c 'model "m" 'effort "e"))
             '("c1" "c2" "c3" "c4" "c5" "c6" "c7" "c8" "c9" "c10")))
      (check-equal!
        (map (lambda (item) (plist-get item 'key))
             (llm-config--history-items buf))
        '("1" "2" "3" "4" "5" "6" "7" "8" "9" "0")
        "the tenth setup uses zero")
      (set! *llm-config-history* saved)
      (buffer-kill! buf))))

(deftest 'llm-config-menu-shows-tools-permissions-and-bundles
  "C-c b groups the whole setup: model, tools, permissions, bundles"
  (lambda ()
    (let ((saved *llm-bundles*)
          (buf (test-buffer! "zz-llm-config-groups" "")))
      (set! *llm-bundles* '())
      (llm-bundle-save! "zz-review" '(connector "api" model "m" effort "high"))
      (let* ((groups (llm-config--groups buf))
             (titles (map car groups))
             (bundles (assoc "Bundles" groups))
             (keys (map (lambda (i) (plist-get i 'key)) (cdr bundles))))
        (check-equal! (take-n titles 4)
                      '("Model" "Tools" "Permissions" "Bundles")
                      "every part of the setup has a place in the menu")
        (check-true! (and (member "A" keys) #t)
                     "a saved bundle is one key away")
        (check-true! (and (member "s" keys) (member "x" keys) #t)
                     "and the menu can save one and forget one"))
      (set! *llm-bundles* saved)
      (buffer-kill! buf))))
