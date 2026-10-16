;;; migrations-test.scm --- every old shape converts once, and the reader sees the new one.
;;;
;;; The two registries run what a buffer or a home has not seen and stamp
;;; it. Each registered migration has one test here: the old shape goes
;;; in, the current shape comes out, and the package's reader answers it.

(domain! 'testing)
(effects! '(write))

(define t--mg-buf "zz-migrations")

(define (t--mg! text)
  (test-buffer! t--mg-buf text)
  (buffer-set-local! t--mg-buf 'migrations #f)
  t--mg-buf)

(define (t--mg-done!) (when (buffer-known? t--mg-buf) (buffer-kill! t--mg-buf)))

;; a home of the test's own: the stamp file, the browse history and the
;; annotation store live there, and the person's own are put back after
(define t--mg-dir "/tmp/zz-migrations-home")

(define (t--mg-home! thunk)
  (let ((held-stamp *home-migrations-file*)
        (held-visited *web-visited-file*)
        (held-annotations *migration-annotations-dir*))
    (shell-command->string (string-append "rm -rf " t--mg-dir))
    (make-directory! t--mg-dir)
    (set! *home-migrations-file* (string-append t--mg-dir "/migrations"))
    (set! *web-visited-file* (string-append t--mg-dir "/web-history"))
    (set! *migration-annotations-dir* (string-append t--mg-dir "/annotations"))
    (thunk)
    (set! *home-migrations-file* held-stamp)
    (set! *web-visited-file* held-visited)
    (set! *migration-annotations-dir* held-annotations)
    (shell-command->string (string-append "rm -rf " t--mg-dir))))

;; the registered body of one home migration, run outside the stamp
(define (t--mg-home-run! name)
  ((car (cdr (cdr (assoc name *home-migrations*))))))

;;; --- the registries --------------------------------------------------------------

(deftest 'a-migration-runs-once-per-buffer-and-is-stamped
  "the pass runs what the buffer has not seen; a second pass runs nothing"
  (lambda ()
    (let ((buf (t--mg! ""))
          (runs 0)
          (held *buffer-migrations*))
      (define-buffer-migration! 'zz-count "2026-09-19"
        (lambda (b) (set! runs (+ runs 1))))
      (define-buffer-migration! 'zz-throws "2026-09-19"
        (lambda (b) (error "a migration that fails")))
      (let ((ran (migrate-buffer! buf)))
        (check-true! (and (member 'zz-count ran) #t) "the new migration ran")
        (check-true! (and (member 'zz-throws ran) #t) "the failing one was tried")
        (check-equal! runs 1 "once")
        (check-true! (and (member 'zz-count (buffer-migrations-done buf)) #t) "and is stamped")
        (check-true! (and (member 'zz-throws (buffer-migrations-done buf)) #t)
                     "a failure is stamped too: it does not run on every restore"))
      (check-equal! (migrate-buffer! buf) '() "the second pass runs nothing")
      (check-equal! runs 1 "still once")
      (set! *buffer-migrations* held)
      (t--mg-done!))))

(deftest 'a-home-migration-runs-once-per-home-and-is-stamped
  "the stamp file holds the names; a second pass runs nothing"
  (lambda ()
    (t--mg-home!
      (lambda ()
        (let ((runs 0)
              (held *home-migrations*))
          (set! *home-migrations* '())
          (define-home-migration! 'zz-home-count "2026-10-16"
            (lambda () (set! runs (+ runs 1))))
          (define-home-migration! 'zz-home-throws "2026-10-16"
            (lambda () (error "a migration that fails")))
          (check-equal! (migrate-home!) '(zz-home-count zz-home-throws) "both ran")
          (check-equal! runs 1 "once")
          (check-equal! (home-migrations-done) '(zz-home-count zz-home-throws)
                        "the stamp file names them, the failure too")
          (check-equal! (migrate-home!) '() "the second pass runs nothing")
          (check-equal! runs 1 "still once")
          (set! *home-migrations* held))))))

;;; --- the chat ----------------------------------------------------------------------

(deftest 'the-chat-record-migration-reads-the-old-turn-pairs-once
  "'chat-turns becomes the record and the old local goes"
  (lambda ()
    (let ((buf (t--mg! "")))
      (buffer-set-local! buf 'chat-turns '(("user" "hi") ("assistant" "hello")))
      (migrate-buffer! buf)
      (check-equal! (length (buffer-local buf 'chat-wire-turns)) 2 "two turns in the record")
      (check-equal! (plist-get (car (buffer-local buf 'chat-wire-turns)) 'role) "user" "in order")
      (check-false! (buffer-local buf 'chat-turns) "the old local is gone")
      (t--mg-done!))))

(deftest 'the-marker-migration-strips-the-marker-and-finds-a-missing-mark
  "a chat from before the marker left the input loses the bytes; one with no mark gets it"
  (lambda ()
    (let ((buf (t--mg! (string-append "old talk" *chat-input-marker* "draft"))))
      (migrate-buffer! buf)
      (check-equal! (buffer-local buf 'agent-saved-mark) 8 "the mark stands after the talk")
      (check-equal! (buffer-text buf) "old talkdraft" "the marker bytes are gone, the draft stays")
      (check-equal! (buffer-local buf 'agent-marker-bytes) 0 "and the input starts at the mark")
      (check-equal! (migrate-buffer! buf) '() "the pass is stamped")
      (t--mg-done!))))

(deftest 'the-companion-migration-turns-companion-of-into-a-group
  "both ends get the group tag"
  (lambda ()
    (let ((buf (t--mg! ""))
          (doc (test-buffer! "zz-migrations-doc" "")))
      (buffer-set-local! doc 'group #f)
      (buffer-set-local! buf 'companion-of doc)
      (migrate-buffer! buf)
      (check-equal! (buffer-local buf 'group) doc "the chat joins the document's group")
      (check-equal! (buffer-local doc 'group) doc "and the document names it too")
      (buffer-kill! doc)
      (t--mg-done!))))

;;; --- the terminal ------------------------------------------------------------------

(deftest 'the-shell-mode-migration-renames-the-mode
  "an old desktop says shell-mode; the buffer wakes as term-mode"
  (lambda ()
    (let ((buf (t--mg! "")))
      (buffer-set-local! buf 'mode-name "shell-mode")
      (migrate-buffer! buf)
      (check-equal! (buffer-local buf 'mode-name) "term-mode" "renamed")
      (t--mg-done!))))

;;; --- the groups --------------------------------------------------------------------

(deftest 'an-old-group-ids-list-folds-into-group-id-on-restore
  "a desktop from the days of many memberships: the first id is the buffer's group, and the list goes"
  (lambda ()
    (let ((buf (t--mg! ""))
          (a (group-record-create! "zztest-legacy-owner-a"))
          (b (group-record-create! "zztest-legacy-owner-b")))
      ;; a buffer from before 'group-id: a new one already holds the frame's group
      (buffer-set-local! buf 'group-id #f)
      (buffer-set-local! buf 'group-ids (list a b))
      (migrate-buffer! buf)
      (check-equal! (buffer-local buf 'group-id) a "the first legacy owner is the group")
      (check-false! (buffer-local buf 'group-ids) "the list is gone")
      (check-equal! (buffer-group buf) a "and the reader answers it")
      (check-false! (buffer-in-group? buf b) "no second membership remains")
      (t--mg-done!)
      (group-record-delete! a)
      (group-record-delete! b))))

;;; --- the diff ----------------------------------------------------------------------

(deftest 'the-git-diff-migration-hands-the-buffer-to-the-diff-backend
  "the old mode names and git locals become the git backend's diff locals"
  (lambda ()
    (let ((buf (t--mg! "")))
      (buffer-set-local! buf 'mode-name "git-diff")
      (buffer-set-local! buf 'git-root "/tmp/zz-repo")
      (buffer-set-local! buf 'git-prefix "sub")
      (buffer-set-local! buf 'git-watch #t)
      (migrate-buffer! buf)
      (check-equal! (buffer-local buf 'mode-name) "diff-mode" "the mode has its current name")
      (check-equal! (buffer-local buf 'diff-backend) "git" "the backend is git")
      (check-equal! (buffer-local buf 'diff-root) "/tmp/zz-repo" "the root moved")
      (check-equal! (buffer-local buf 'diff-scope) "sub" "the prefix is the scope")
      (check-equal! (buffer-local buf 'diff-watch) #t "the watch moved")
      (check-false! (buffer-local buf 'git-root) "the old locals are gone")
      (check-false! (buffer-local buf 'git-prefix) "all of them")
      (t--mg-done!))
    (let ((buf (t--mg! "")))
      (buffer-set-local! buf 'mode-name "git-show")
      (migrate-buffer! buf)
      (check-equal! (buffer-local buf 'mode-name) "diff-show" "git-show is diff-show")
      (check-equal! (buffer-local buf 'diff-scope) "" "no prefix is the whole tree")
      (t--mg-done!))))

;;; --- the mail ----------------------------------------------------------------------

(deftest 'the-notmuch-query-migration-makes-the-old-local-the-base
  "one derived query becomes the base with no filters; a buffer with a base only drops the old local"
  (lambda ()
    (let ((buf (t--mg! "")))
      (buffer-set-local! buf 'notmuch-query "from:bob")
      (migrate-buffer! buf)
      (check-equal! (buffer-local buf 'notmuch-query-base) "from:bob" "the base")
      (check-equal! (buffer-local buf 'notmuch-query-filters) '() "no filters")
      (check-false! (buffer-local buf 'notmuch-query) "the old local is gone")
      (check-equal! (nm--query-of buf) "from:bob" "and the reader answers it")
      (t--mg-done!))
    (let ((buf (t--mg! "")))
      (buffer-set-local! buf 'notmuch-query-base "tag:inbox")
      (buffer-set-local! buf 'notmuch-query "from:bob")
      (migrate-buffer! buf)
      (check-equal! (nm--query-of buf) "tag:inbox" "the old derived local cannot bypass the base")
      (check-false! (buffer-local buf 'notmuch-query) "and it is gone")
      (t--mg-done!))))

;;; --- the inline LLM ----------------------------------------------------------------

(deftest 'the-llm-responses-migration-makes-each-old-range-a-block
  "an upgraded document keeps every old response highlight, as a block, through its first send"
  (lambda ()
    (let ((buf (t--mg! "Old\n\nPrompt")))
      (buffer-set-local! buf 'llm-responses '((0 3)))
      (migrate-buffer! buf)
      (let ((blocks (llm-mode--addressable-kind buf 'llm-response)))
        (check-equal! (length blocks) 1 "one block for the one range")
        (check-equal! (plist-get (car blocks) 'state) 'complete "a complete response"))
      (check-equal! (llm-mode--response-ranges buf) '((0 3)) "the reader paints it from the block")
      (llm-mode--begin-turn! buf 7 11)
      (check-equal! (llm-mode--response-ranges buf) '((0 3))
                    "the empty pending address exists but does not paint")
      (t--mg-done!))))

(deftest 'a-stale-old-range-over-a-block-goes
  "a broad old face frozen at the first send yields to the exact response block"
  (lambda ()
    (let ((buf (t--mg! "012345")))
      (buffer-set-local! buf 'llm-legacy-responses '((0 6)))
      (let ((id (block-create! buf 'llm-response 2 4 #f 'complete '())))
        (block-close-end! buf id))
      (migrate-buffer! buf)
      (check-false! (buffer-local buf 'llm-legacy-responses) "the frozen mirror is gone")
      (check-equal! (llm-mode--response-ranges buf) '((2 4))
                    "only the exact addressable response remains")
      (t--mg-done!))))

;;; --- the scratch -------------------------------------------------------------------

(deftest 'the-writing-scratch-migration-points-the-document-at-its-scratch
  "either side completes the pair, and the scratch loses writing's presentation"
  (lambda ()
    (let ((doc (test-buffer! "zz-mg-doc" "text\n"))
          (scratch (test-buffer! "*writing:zz-mg-doc*" "# notes\n")))
      (buffer-set-local! doc 'migrations #f)
      (buffer-set-local! scratch 'migrations #f)
      (buffer-set-local! doc 'scratch-buffer #f)
      (buffer-set-local! doc 'writing-scratch scratch)
      (buffer-set-local! scratch 'render-mode "markdown")
      (buffer-set-local! scratch 'preview-renderer "markdown")
      (buffer-set-local! scratch 'visual-line-mode #t)
      (migrate-buffer! doc)
      (check-equal! (buffer-local doc 'scratch-buffer) scratch "the document points at its scratch")
      (check-false! (buffer-local doc 'writing-scratch) "the old pointer is gone")
      (buffer-set-local! doc 'scratch-buffer #f)
      (migrate-buffer! scratch)
      (check-equal! (buffer-local doc 'scratch-buffer) scratch "the scratch's side completes the pair too")
      (check-false! (buffer-local scratch 'render-mode) "writing's presentation is gone")
      (check-false! (buffer-local scratch 'preview-renderer) "all of it")
      (check-false! (buffer-local scratch 'visual-line-mode) "so scratch-mode's own is the last word")
      (buffer-kill! scratch)
      (buffer-kill! doc))))
