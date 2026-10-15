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
      (check-equal! (llm-bundle-key (llm-bundle-named "zz-work")) "a"
                    "the first bundle gets the first free key")
      (check-equal! (llm-bundle-key (llm-bundle-named "zz-read")) "b"
                    "the next bundle gets a different key")
      (set! *llm-bundles* (llm-bundles-assign-keys (reverse *llm-bundles*)))
      (check-equal! (llm-bundle-key (llm-bundle-named "zz-work")) "a"
                    "loading persisted bundles preserves their keys")
      (check-equal! (llm-bundle-key (llm-bundle-named "zz-read")) "b"
                    "persisted keys do not depend on list order")
      (set! *llm-bundles*
        (llm-bundles-assign-keys
          (map (lambda (b) (llm-bundle-put b 'key "A")) *llm-bundles*)))
      (check-equal! (llm-bundle-key (llm-bundle-named "zz-work")) "a"
                    "an upper-case key from the first menu is reassigned")
      (check-equal! (llm-bundle-key (llm-bundle-named "zz-read")) "b"
                    "in list order")
      (check-equal! (llm-bundle-model (llm-bundle-named "zz-work")) "m1"
                    "a bundle answers to its name")
      (llm-bundle-save! "zz-work" '(connector "api" model "m2" effort "high"))
      (check-equal! (length *llm-bundles*) 2
                    "saving over a name replaces that bundle")
      (check-equal! (llm-bundle-model (llm-bundle-named "zz-work")) "m2"
                    "the newer setup is the one kept")
      (check-equal! (llm-bundle-key (llm-bundle-named "zz-work")) "a"
                    "updating and moving a bundle never changes its key")
      (check-equal! (llm-bundle-key (llm-bundle-named "zz-read")) "b"
                    "reordering another bundle never changes this key")
      (llm-bundle-forget! "zz-work")
      (check-false! (llm-bundle-named "zz-work") "a forgotten bundle is gone")
      (check-true! (and (llm-bundle-named "zz-read") #t)
                   "and the others are not")
      (check-equal! (llm-bundle-key (llm-bundle-named "zz-read")) "b"
                    "forgetting another bundle does not compact this key")
      (set! *llm-bundles* saved))))

;;; C-c b is one pane: the presets, the box, and the save actions. These
;;; tests drive the menu through its commands on a plain buffer, whose
;;; setup is its llm-* locals.

(define (llm-config-test--buf name model)
  (let ((buf (test-buffer! name "")))
    (buffer-set-local! buf 'llm-connector "api")
    (buffer-set-local! buf 'llm-model model)
    buf))

(define (llm-config-test--row groups key)
  (let loop ((is (apply append (map cdr groups))))
    (cond ((null? is) #f)
          ((equal? (plist-get (car is) 'key) key) (car is))
          (else (loop (cdr is))))))

(define (llm-config-test--key key buf)
  (llm-config-test--row (llm-config--groups buf) key))

;; a preset-column row by the start of its description
(define (llm-config-test--named name buf)
  (let loop ((is (cdr (car (llm-config--groups buf)))))
    (cond ((null? is) #f)
          ((string-prefix? name (plist-get (car is) 'description)) (car is))
          (else (loop (cdr is))))))

(deftest 'llm-config-menu-is-presets-left-config-right
  "C-c b: the presets in the left column, the config of the chosen one in the right"
  (lambda ()
    (let ((saved *llm-bundles*)
          (more (frame-local 'llm-config-more))
          (buf (llm-config-test--buf "zz-llm-config-groups" "m1")))
      (set! *llm-bundles* '())
      (set-frame-local! 'llm-config-more #f)
      (llm-bundle-save! "zz-review" '(connector "api" model "m" effort "high"))
      (llm-config--setup! buf)
      (let* ((groups (llm-config--groups buf))
             (presets (cdr (assoc "Presets" groups))))
        (check-equal! (map (lambda (i) (plist-get i 'description)) presets)
                      '("this chat" "zz-review")
                      "a chat on no preset is a row of its own, then the presets")
        (check-equal! (map (lambda (i) (plist-get i 'key)) presets) '("" "")
                      "a preset takes no key: typing filters the list")
        (check-equal! (car (cadr groups)) "this chat · config"
                      "the right column says whose config it shows")
        (check-equal! (map (lambda (i) (plist-get i 'key)) (cdr (cadr groups)))
                      '("b" "m" "e" "p" "+")
                      "the config holds backend, model, effort, tools, and more")
        (check-equal! (llm-config--columns buf)
                      '(("Presets") ("this chat · config" "More"))
                      "presets on the left, the config on the right"))
      (set-frame-local! 'llm-config-more #t)
      (check-true! (and (assoc "More" (llm-config--groups buf)) #t)
                   "+ shows the third tier")
      (set-frame-local! 'llm-config-more more)
      (set! *llm-bundles* saved)
      (buffer-kill! buf))))

(deftest 'llm-config-field-edit-changes-only-the-box
  "A field edit changes the config on screen, shows the old value, and leaves the chat alone"
  (lambda ()
    (let ((saved *llm-bundles*)
          (buf (llm-config-test--buf "zz-llm-config-box" "m1")))
      (set! *llm-bundles* '())
      (llm-bundle-save! "zz-base" (llm-config-combination buf))
      (llm-config--setup! buf)
      (check-equal! (llm-config--source-name) "zz-base"
                    "the menu opens on the preset the chat equals")
      (check-equal! (llm-config--subtitle buf) "selected: zz-base · ESC gives it to the chat"
                    "the status line names the selection")
      (llm-config--box-set! 'model "m9")
      (check-equal! (buffer-local buf 'llm-model) "m1"
                    "the chat keeps its model while the menu is open")
      (check-equal! (llm-config--field-value 'model) "m1 → m9"
                    "the row shows the saved value and the new one")
      (check-equal! ((plist-get (llm-config-test--key "m" buf) 'flags-fn) buf) "drift"
                    "and carries the drift flag")
      (check-contains! (llm-config--subtitle buf) "zz-base*"
                       "the status line says the selection has unsaved changes")
      (check-equal! (llm-config--config-title) "zz-base* · config"
                    "and so does the config column")
      (check-equal! (plist-get (llm-config-test--named "zz-base" buf) 'description) "zz-base*"
                    "the preset row says it has unsaved changes")
      (set! *llm-bundles* saved)
      (buffer-kill! buf))))

(deftest 'llm-config-esc-and-c-g-both-apply-the-selection
  "Closing the menu gives the selected config to the chat, by ESC or by C-g"
  (lambda ()
    (let ((saved *llm-bundles*)
          (history *llm-config-history*)
          (buf (llm-config-test--buf "zz-llm-config-close" "m1")))
      (set! *llm-bundles* '())
      (with-current-buffer buf
        (lambda ()
          (transient-setup "llm-configure" buf)
          (llm-config--box-set! 'model "m2")
          (run-command "transient-cancel-one")))
      (check-equal! (buffer-local buf 'llm-model) "m2" "C-g applies the selection")
      (check-false! (transient--active) "and closes the menu")
      (with-current-buffer buf
        (lambda ()
          (transient-setup "llm-configure" buf)
          (llm-config--box-set! 'model "m3")
          (run-command "transient-quit-one")))
      (check-equal! (buffer-local buf 'llm-model) "m3" "ESC applies it too")
      (check-false! (frame-local 'llm-config-box) "and the box is gone")
      (set! *llm-bundles* saved)
      (set! *llm-config-history* history)
      (buffer-kill! buf))))

(deftest 'llm-config-cursor-shows-a-preset-and-keeps-its-draft
  "The cursor on a preset shows its config; an edit stays with that preset; s overwrites it"
  (lambda ()
    (let ((saved *llm-bundles*)
          (buf (llm-config-test--buf "zz-llm-config-load" "m1")))
      (set! *llm-bundles* '())
      (llm-bundle-save! "zz-other" '(connector "api" model "m2" effort "default"))
      (llm-config--setup! buf)
      (check-false! (llm-config--source-name) "no preset equals the chat")
      (llm-config--on-select buf (llm-config-test--named "zz-other" buf))
      (check-equal! (llm-config--box-get 'model) "m2" "the cursor shows the preset's config")
      (check-false! (llm-config--selected-name) "and selects nothing")
      (llm-config--box-set! 'effort "high")
      (llm-config--on-select buf (llm-config-test--named "this chat" buf))
      (check-equal! (llm-config--box-get 'model) "m1" "the chat's own row shows the chat")
      (llm-config--on-select buf (llm-config-test--named "zz-other" buf))
      (check-equal! (llm-config--box-get 'effort) "high"
                    "coming back to the preset finds its unsaved edit")
      (run-command "llm-config-revert")
      (check-equal! (llm-config--box-get 'effort) "default" "u undoes the edit")
      (llm-config--box-set! 'effort "high")
      (run-command "llm-config-save-into")
      (check-equal! (llm-bundle-effort (llm-bundle-named "zz-other")) "high"
                    "s overwrites the preset")
      (set-frame-local! 'llm-config-box #f)
      (set! *llm-bundles* saved)
      (buffer-kill! buf))))

(deftest 'llm-config-ret-selects-and-esc-applies-the-selection
  "RET on a preset selects it; ESC gives the selected config to the chat, not the one under the cursor"
  (lambda ()
    (let ((saved *llm-bundles*)
          (history *llm-config-history*)
          (buf (llm-config-test--buf "zz-llm-config-select" "m1")))
      (set! *llm-bundles* '())
      (llm-bundle-save! "zz-a" '(connector "api" model "ma" effort "default"))
      (llm-bundle-save! "zz-b" '(connector "api" model "mb" effort "default"))
      (with-current-buffer buf
        (lambda ()
          (transient-setup "llm-configure" buf)
          ((plist-get (llm-config-test--named "zz-a" buf) 'command))
          (check-equal! (llm-config--selected-name) "zz-a" "RET selects the row")
          (check-equal! ((plist-get (llm-config-test--named "zz-a" buf) 'value-fn) buf) "selected"
                        "and the row says selected")
          (llm-config--on-select buf (llm-config-test--named "zz-b" buf))
          (run-command "transient-quit-one")))
      (check-equal! (buffer-local buf 'llm-model) "ma"
                    "ESC applies the selected preset, not the one under the cursor")
      (set! *llm-bundles* saved)
      (set! *llm-config-history* history)
      (buffer-kill! buf))))

(deftest 'llm-config-typing-filters-the-presets
  "In the preset column a printable key filters the list; DEL takes it back"
  (lambda ()
    (let ((saved *llm-bundles*)
          (buf (llm-config-test--buf "zz-llm-config-filter" "m1")))
      (set! *llm-bundles* '())
      (llm-bundle-save! "zz-coding" '(connector "api" model "ma"))
      (llm-bundle-save! "zz-writing" '(connector "api" model "mb"))
      (with-current-buffer buf
        (lambda ()
          (transient-setup "llm-configure" buf)
          (check-equal! (transient-dispatch-key "d")
                        (list "command" (llm-config--filter-command "d"))
                        "on the preset column a letter types into the filter")
          (run-command (llm-config--filter-command "d"))
          (check-equal! (map (lambda (i) (plist-get i 'description))
                             (cdr (car (llm-config--groups buf))))
                        '("zz-coding")
                        "the list keeps the names that hold the filter")
          (check-equal! (car (car (llm-config--groups buf))) "Presets · d"
                        "and the column title shows it")
          (run-command "llm-config-filter-back")
          (check-equal! (length (cdr (car (llm-config--groups buf)))) 3
                        "DEL takes the character back")
          (run-command "transient-column-right")
          (check-equal! (transient-dispatch-key "m")
                        (list "command" "transient:llm-configure:m")
                        "in the config column the letters are the fields")
          (run-command "transient-cancel-one")))
      (set! *llm-bundles* saved)
      (buffer-kill! buf))))

(deftest 'llm-default-bundle-seeds-a-new-chat
  "The bundle named in custom.scm lands on a chat that has no session yet"
  (lambda ()
    (let ((saved *llm-bundles*)
          (default llm-default-bundle)
          (buf (test-buffer! "zz-llm-default" "")))
      (set! *llm-bundles* '())
      (llm-bundle-save! "zz-coding" '(connector "api" model "m9" effort "high"))
      (set! llm-default-bundle "zz-coding")
      (check-true! (and (llm-default-bundle-apply! buf) #t)
                   "the named default applies")
      (check-equal! (buffer-local buf 'agent-connector) "api"
                    "the connector comes from the bundle")
      (check-equal! (buffer-local buf 'agent-model) "m9"
                    "the model comes from the bundle")
      (check-equal! (buffer-local buf 'agent-effort) "high"
                    "the effort comes from the bundle")
      (check-equal! (plist-get (car (llm-config--preset-items)) 'description)
                    "zz-coding · default"
                    "and the menu row says which preset new chats start with")
      (set! llm-default-bundle "")
      (check-false! (llm-default-bundle-apply! buf)
                    "no name, nothing to apply")
      (set! llm-default-bundle default)
      (set! *llm-bundles* saved)
      (buffer-kill! buf))))

(deftest 'llm-default-bundle-holds-a-whole-config
  "A default saved without a preset lands on a new chat, and a preset equal to it says default"
  (lambda ()
    (let ((saved *llm-bundles*)
          (default llm-default-bundle)
          (buf (test-buffer! "zz-llm-default-config" "")))
      (set! *llm-bundles* '())
      (set! llm-default-bundle '(connector "api" model "m7" effort "low"))
      (check-true! (and (llm-default-bundle-apply! buf) #t)
                   "the saved config applies")
      (check-equal! (buffer-local buf 'agent-model) "m7"
                    "the model comes from the config")
      (llm-bundle-save! "zz-same" '(connector "api" model "m7" effort "low"))
      (check-equal! (plist-get (car (llm-config--preset-items)) 'description)
                    "zz-same · default"
                    "a preset equal to the default says so")
      (set! llm-default-bundle default)
      (set! *llm-bundles* saved)
      (buffer-kill! buf))))

(deftest 'transient-rows-can-skip-the-cursor-and-add-flags
  "A row with 'cursor 'skip keeps its key but never the cursor; 'flags-fn adds classes"
  (lambda ()
    (transient-define-prefix "zz-cursor-menu" "Cursor"
      (list (list "Sources"
                  (transient-suffix "1" "one" "transient-quit-all" 'cursor 'skip)
                  (transient-suffix "2" "two" "transient-quit-all" 'cursor 'skip))
            (list "Fields"
                  (transient-suffix "a" "alpha" "transient-quit-all"
                    'flags-fn (lambda (_s) "drift"))
                  (transient-suffix "b" "beta" "transient-quit-all"))))
    (let* ((prefix (transient-prefix "zz-cursor-menu"))
           (state (list 'prefix "zz-cursor-menu" 'scope "x" 'selected 0 'values '()))
           (items (transient--visible-items (transient--visible-groups prefix state))))
      (check-equal! (transient--initial-selection prefix state) 2
                    "the menu opens on the first row the cursor may take")
      (check-equal! (transient--selectable-index items 0 1) 2
                    "moving down skips the source rows")
      (check-equal! (transient--selectable-index items 1 -1) 3
                    "moving up wraps past them")
      (check-contains! (transient--item-flags (nth 2 items) state) "drift"
                       "flags-fn adds its class"))))

(deftest 'transient-up-and-down-stay-in-a-declared-column
  "In a menu that declares its columns, down wraps inside the cursor's column"
  (lambda ()
    (transient-define-prefix "zz-ring-menu" "Ring"
      (list (list "L" (transient-suffix "1" "l1" "transient-quit-all")
                      (transient-suffix "2" "l2" "transient-quit-all"))
            (list "R" (transient-suffix "3" "r1" "transient-quit-all")))
      'columns '(("L") ("R")))
    (transient-setup "zz-ring-menu" (current-buffer))
    (run-command "transient-next")
    (run-command "transient-next")
    (check-equal! (plist-get (transient--active) 'selected) 0
                  "two downs from the first row wrap back to it, not into the next column")
    (run-command "transient-quit-all")))

(deftest 'transient-on-select-follows-the-cursor
  "'on-select runs with the row the cursor lands on; 'keys-fn keys answer with no row"
  (lambda ()
    (let ((seen '()))
      (transient-define-prefix "zz-select-menu" "Select"
        (list (list "Rows"
                    (transient-suffix "a" "alpha" "transient-quit-all")
                    (transient-suffix "b" "beta" "transient-quit-all")))
        'on-select (lambda (_s item) (set! seen (cons (plist-get item 'key) seen)))
        'keys-fn (lambda (_s) '(("z" "transient-quit-all"))))
      (transient-setup "zz-select-menu" (current-buffer))
      (run-command "transient-next")
      (check-equal! seen '("b" "a") "the opening row, then the row below")
      (check-equal! (transient-dispatch-key "z") '("command" "transient-quit-all")
                    "a keys-fn key is bound")
      (run-command "transient-quit-all"))))

(deftest 'transient-cancel-tells-on-quit
  "transient-cancel-one runs on-quit with transient-cancelled? true; a plain quit runs it with false"
  (lambda ()
    (let ((seen '()))
      (transient-define-prefix "zz-cancel-menu" "Cancel"
        (list (list "Rows" (transient-suffix "q" "one" "transient-quit-all")))
        'on-quit (lambda (_s) (set! seen (cons (transient-cancelled?) seen))))
      (transient-setup "zz-cancel-menu" (current-buffer))
      (run-command "transient-cancel-one")
      (transient-setup "zz-cancel-menu" (current-buffer))
      (run-command "transient-quit-one")
      (check-equal! seen '(#f #t) "cancel first, then a plain quit")
      (check-false! (transient-cancelled?) "the flag does not outlive the quit"))))

(deftest 'transient-menu-carries-header-rail-and-legend
  "A prefix's header, rail, and legend options reach the menu as one alist"
  (lambda ()
    (transient-define-prefix "zz-meta-menu" "Meta"
      (list (list "Rows" (transient-suffix "q" "one" "transient-quit-all")))
      'subtitle-fn (lambda (_s) "sub")
      'context-fn (lambda (_s) "ctx")
      'detail-fn (lambda (_s item)
                   (list "rail" (list (list "k" (plist-get item 'description) "drift")) "note"))
      'legend-fn (lambda (_s) '(("q" "quit"))))
    (let* ((prefix (transient-prefix "zz-meta-menu"))
           (state (list 'prefix "zz-meta-menu" 'scope "x" 'selected 0 'values '()))
           (items (transient--visible-items (transient--visible-groups prefix state)))
           (meta (transient--menu-meta prefix state items)))
      (check-equal! (cadr (assoc "subtitle" meta)) "sub" "the subtitle")
      (check-equal! (cadr (assoc "context" meta)) "ctx" "the context")
      (check-equal! (car (cadr (assoc "detail" meta))) "rail" "the rail title")
      (check-equal! (cadr (assoc "detail" meta))
                    (list "rail" (list (list "k" "one" "drift")) "note")
                    "the rail rows come from the selected item")
      (check-equal! (cadr (assoc "legend" meta)) '(("q" "quit")) "the legend"))
    (let* ((plain (transient-define-prefix "zz-plain-menu" "Plain"
                    (list (list "Rows" (transient-suffix "q" "one" "transient-quit-all")))))
           (prefix (transient-prefix "zz-plain-menu"))
           (state (list 'prefix "zz-plain-menu" 'scope "x" 'selected 0 'values '()))
           (meta (transient--menu-meta prefix state '())))
      (check-equal! (cadr (assoc "subtitle" meta)) "" "a menu with no options has an empty header")
      (check-equal! (cadr (assoc "detail" meta)) #f "no rail")
      (check-equal! (cadr (assoc "legend" meta)) transient-default-legend "and the default legend"))))

(deftest 'the-tools-key-opens-a-menu-not-a-buffer
  "t stays in the transient world: a child prefix over the same scope.
The full text list is still one key deeper (l), for actual reading."
  (lambda ()
    (let ((buf (test-buffer! "zz-llm-tools-menu" "")))
      ;; the t row names a PREFIX — transient--invoke-command opens a
      ;; child menu for a prefix name, and runs a command otherwise
      (let* ((t-row (let loop ((is (llm-config--more-items)))
                      (cond ((null? is) #f)
                            ((equal? (plist-get (car is) 'key) "t") (car is))
                            (else (loop (cdr is)))))))
        (check-equal! (plist-get t-row 'command) "chat-tools"
                      "t names the child prefix")
        (check-true! (and (transient-prefix "chat-tools") #t)
                     "and that prefix is defined"))
      ;; the child builds real rows: a frozen chat shows its servers
      (buffer-set-local! buf 'chat-presets '(compos))
      (buffer-set-local! buf 'chat-tool-specs
        '(("eval-scheme" "Run Scheme." ())
          ("mcp__zzt__echo" "Echo." "{}")))
      (let* ((groups (llm-config--tools-groups buf))
             (servers (car groups))
             (change (assoc "Change" groups)))
        (check-contains! (car servers) "Servers" "the server group heads the menu")
        (check-equal! (length (cdr servers)) 2 "one row per server")
        (check-equal! (plist-get (car (cdr servers)) 'description) "compos"
                      "named after the server")
        (check-true! (and change #t) "and the actions keep their group")
        (let ((keys (map (lambda (i) (plist-get i 'key)) (cdr change))))
          (check-true! (and (member "p" keys) (member "r" keys) (member "l" keys) #t)
                       "presets, adopt, and the full list stay reachable")))
      (buffer-kill! buf))))

(deftest 'prompt-sections-are-one-multi-select-transaction
  "Prompt section switches stay in a draft until one apply commits all of them"
  (lambda ()
    (let ((buf (test-buffer! "zz-prompt-multi-select" "")))
      (buffer-set-local! buf 'prompt-disabled-parts '("reading"))
      (let* ((items (llm-config--prompt-items buf))
             (repository
               (let loop ((rest items))
                 (cond ((null? rest) #f)
                       ((equal? (plist-get (car rest) 'description) "reading")
                        (car rest))
                       (else (loop (cdr rest))))))
             (identity (car items)))
        (check-false! (plist-get repository 'default)
                      "a disabled section starts off")
        (check-true! (plist-get identity 'default)
                     "an enabled section starts on"))
      (transient-setup "llm-prompt-sections" buf)
      (transient--set-value! "--prompt-identity" #f)
      (transient--set-value! "--prompt-scope" #f)
      (check-equal! (prompt-disabled-parts buf) '("reading")
                    "editing the draft does not change the buffer")
      (run-command "llm-config-apply-prompt-sections")
      (check-equal! (take (prompt-disabled-parts buf) 2)
                    '("identity" "scope")
                    "one apply commits every changed switch")
      (buffer-kill! buf))))

(deftest 'transient-columns-and-left-right
  "A prefix names the groups that share a column; left and right move
between columns on the same row, and the edges do not wrap"
  (lambda ()
    (transient-define-prefix "zz-col-menu" "Cols"
      (list (list "A" (transient-suffix "1" "a1" "transient-quit-all")
                      (transient-suffix "2" "a2" "transient-quit-all"))
            (list "B" (transient-suffix "3" "b1" "transient-quit-all"))
            (list "C" (transient-suffix "4" "c1" "transient-quit-all")
                      (transient-suffix "5" "c2" "transient-quit-all")
                      (transient-suffix "6" "c3" "transient-quit-all"))
            (list "D" (transient-suffix "7" "d1" "transient-quit-all")))
      'columns '(("A" "B") ("C")))
    (let* ((prefix (transient-prefix "zz-col-menu"))
           (state (list 'prefix "zz-col-menu" 'scope "x" 'selected 0 'values '()))
           (groups (transient--visible-groups prefix state))
           (columns (transient--columns prefix state groups)))
      (check-equal! columns '(("A" "B") ("C") ("D"))
                    "declared columns first, an unnamed group stands alone")
      ;; items: a1=0 a2=1 b1=2 | c1=3 c2=4 c3=5 | d1=6
      (check-equal! (transient--column-target groups columns 0 1) 3
                    "right from the first row lands on the first row")
      (check-equal! (transient--column-target groups columns 2 1) 5
                    "the third row of the column, across group borders")
      (check-equal! (transient--column-target groups columns 5 1) 6
                    "a shorter column takes its last row")
      (check-equal! (transient--column-target groups columns 6 1) 6
                    "the last column does not wrap")
      (check-equal! (transient--column-target groups columns 4 -1) 1
                    "left goes back on the same row")
      (check-equal! (transient--column-target groups columns 0 -1) 0
                    "the first column does not wrap"))
    (let* ((prefix (transient-prefix "zz-plain-menu"))
           (state (list 'prefix "zz-plain-menu" 'scope "x" 'selected 0 'values '()))
           (groups (transient--visible-groups prefix state)))
      (check-equal! (transient--columns prefix state groups) '(("Rows"))
                    "a menu with no columns option: one column per group"))))

