;;; groups-test.scm --- group records: identity, naming, and membership.
;;;
;;; A group is a durable record with an opaque id and a display name.
;;; Everything below is policy this package decides on its own, so the
;;; test calls the function. None of it needs a key or a window.

(domain! 'testing)
(effects! '(write))

;; Every test founds what it needs under this prefix and deletes it, so
;; a run leaves the live editor holding no groups it did not start with.
(define (t--group name)
  (group-record-create! (string-append "zztest-" name)))

(define (t--drop! id) (when id (group-record-delete! id)))

(deftest 'group-rename-keeps-the-id
  "a rename moves the display name and leaves the identity alone"
  (lambda ()
    (let ((id (t--group "rename")))
      (group-rename! id "zztest-renamed")
      (check-equal! (group-name id) "zztest-renamed" "the name follows the rename")
      (check-equal! (group-resolve-id "zztest-renamed") id "the new name resolves to the same id")
      (check-false! (group-resolve-id "zztest-rename") "the old name resolves to nothing")
      (t--drop! id))))

(deftest 'a-dangling-id-founds-no-group
  "an id whose record is gone is a dead reference, never a new name"
  (lambda ()
    (let ((before (length (group-ids))))
      (check-false! (group-ensure-record! "grp:9999:1")
                    "an id-shaped string founds nothing")
      (check-equal! (length (group-ids)) before "the record set did not grow")
      (let ((id (group-ensure-record! "zztest-a-chosen-name")))
        (check-true! id "a name still founds a group")
        (check-equal! (group-name id) "zztest-a-chosen-name" "and carries that name")
        (t--drop! id)))))

(deftest 'a-name-is-unique
  "two groups cannot share a display name"
  (lambda ()
    (let ((id (t--group "unique")))
      (check-false! (group-record-create! "zztest-unique")
                    "the second founding answers #f")
      (check-equal! (group-resolve-id "zztest-unique") id "the name still names the first")
      (t--drop! id))))

(deftest 'group-display-name-falls-back
  "a value that names no group prints as itself, never as #f"
  (lambda ()
    (let ((id (t--group "display")))
      (check-equal! (group-display-name id) "zztest-display" "an id prints its name")
      (check-equal! (group-display-name "zztest-display") "zztest-display"
                    "a name prints itself")
      (check-equal! (group-display-name "/tmp/not-a-group") "/tmp/not-a-group"
                    "an unknown string prints itself")
      (check-equal! (group-display-name #f) "" "#f prints as the empty string")
      (t--drop! id))))

(deftest 'a-group-founded-from-a-path-is-named-by-its-last-segment
  "the name is journal; the path stays as the origin and still finds the group"
  (lambda ()
    (let ((id (group-record-create! "/zztest/docs/zzjournal")))
      (check-equal! (group-name id) "zzjournal" "the shortest name")
      (check-equal! (group-display-label-in id (selected-frame)) "zzjournal"
                    "the modeline says the short name")
      (check-equal! (group-resolve-id "/zztest/docs/zzjournal") id
                    "the founding path still finds the group")
      (check-equal! (group-resolve-id "zzjournal") id "and so does the name")
      (check-false! (group-record-create! "/zztest/docs/zzjournal")
                    "founding it again answers #f, as for any name")
      (t--drop! id))))

(deftest 'two-groups-from-paths-with-one-last-segment-read-apart
  "both lengthen by a segment: docs/journal and work/journal"
  (lambda ()
    (let* ((a (group-record-create! "/zztest/docs/zzjournal"))
           (b (group-record-create! "/zztest/work/zzjournal")))
      (check-equal! (group-name a) "docs/zzjournal" "the first lengthened")
      (check-equal! (group-name b) "work/zzjournal" "the second reads apart")
      (check-equal! (group-resolve-id "/zztest/work/zzjournal") b "each path finds its own")
      (check-equal! (group-label b) "work/zzjournal" "the card wears the deduped name")
      ;; the second goes: the first is alone again, and shortens
      (t--drop! b)
      (check-equal! (group-name a) "zzjournal" "alone again, the shortest name returns")
      (t--drop! a))))

(deftest 'a-typed-name-is-never-shortened
  "a person's name for a group is the name, slashes and all"
  (lambda ()
    (let ((id (group-record-create! "zztest-a/b")))
      (check-equal! (group-name id) "zztest-a/b" "kept whole")
      (check-false! (group-record-origin (group-record-by-id id)) "no origin: not a path")
      (t--drop! id))))

(deftest 'group-label-shortens-a-path
  "a card wears the last segment, and a project root keeps its basename"
  (lambda ()
    (let ((id (group-record-create! "/zztest/deep/project")))
      (check-equal! (group-label id) "project" "a path-named group wears its basename")
      (check-equal! (group-label "/zztest/not/a/group/yet") "yet"
                    "a root that is not a group yet still wears one")
      (check-equal! (group-label "no-such-group-at-all") "no-such-group-at-all"
                    "an unknown plain name wears itself")
      (t--drop! id))))

(deftest 'membership-answers-the-id
  "a work buffer holds ids, and buffer-group answers one"
  (lambda ()
    (let ((id (t--group "member"))
          (buf "*zztest-member*"))
      (buffer-create buf)
      (check-equal! (buffer-group-ids buf) '() "a fresh buffer belongs to nothing")
      (buffer-add-group! buf id)
      (check-equal! (buffer-group buf) id "buffer-group answers the id")
      (check-true! (buffer-in-group? buf id) "the buffer is in the group")
      (check-true! (buffer-in-group? buf "zztest-member")
                   "the name finds the membership too")
      (buffer-add-group! buf id)
      (check-equal! (length (buffer-group-ids buf)) 1 "joining twice adds one membership")
      (buffer-remove-group! buf id)
      (check-equal! (buffer-group-ids buf) '() "leaving clears it")
      (buffer-kill! buf)
      (t--drop! id))))

(deftest 'a-rename-keeps-every-membership
  "the point of the id: a rename does not touch the buffers"
  (lambda ()
    (let ((id (t--group "carry"))
          (buf "*zztest-carry*"))
      (buffer-create buf)
      (buffer-add-group! buf id)
      (group-rename! id "zztest-carried")
      (check-equal! (buffer-group buf) id "the buffer still holds the same id")
      (check-equal! (group-name (buffer-group buf)) "zztest-carried"
                    "and reads back under the new name")
      (buffer-kill! buf)
      (t--drop! id))))

(deftest 'a-summary-is-always-a-string
  "marginalia measures columns with string-length; one #f breaks the row"
  (lambda ()
    (let ((buf "*zztest-summary*"))
      (buffer-create buf)
      (check-equal! (buffer-group-summary buf) "ungrouped" "no membership reads as ungrouped")
      (let ((id (t--group "summary")))
        (buffer-add-group! buf id)
        (check-true! (string? (buffer-group-summary buf)) "a member's summary is a string")
        (check-contains! (buffer-group-summary buf) "zztest-summary" "and names the group")
        (t--drop! id))
      ;; the record is gone and the buffer still holds its id
      (check-true! (string? (buffer-group-summary buf))
                   "a lost record still answers a string")
      (buffer-kill! buf))))

(deftest 'modeline-memberships-follow-the-buffer
  "the render cache holds all and only this buffer's group names"
  (lambda ()
    (let ((buf "*zztest-modeline-groups*")
          (one (t--group "modeline-one"))
          (two (t--group "modeline-two")))
      (buffer-create buf)
      (buffer-modeline-group-refresh! buf)
      (check-equal! (buffer-local buf 'modeline-groups) '()
                    "an ungrouped buffer carries no modeline membership")
      (buffer-add-group! buf one)
      (check-equal! (buffer-local buf 'modeline-groups) '("zztest-modeline-one")
                    "one membership carries its name")
      (buffer-add-group! buf two)
      (check-equal! (buffer-local buf 'modeline-groups)
                    '("zztest-modeline-one" "zztest-modeline-two")
                    "multiple memberships are all retained for C-x ? and compaction")
      (group-rename! two "zztest-modeline-renamed")
      (check-equal! (buffer-local buf 'modeline-groups)
                    '("zztest-modeline-one" "zztest-modeline-renamed")
                    "renaming a group refreshes its member labels")
      (buffer-remove-group! buf one)
      (check-equal! (buffer-local buf 'modeline-groups) '("zztest-modeline-renamed")
                    "leaving a group removes only that name")
      (buffer-kill! buf)
      (t--drop! one)
      (t--drop! two))))

(deftest 'add-founds-a-typed-name
  "the add prompt takes a name it does not list, and founds it"
  (lambda ()
    (let ((buf "*zztest-add*"))
      (buffer-create buf)
      (switch-to-buffer! buf)
      ;; the command acts on the selection, so make one: a person marks
      ;; the buffers first, in the switcher or with buffer-select
      (buffer-set-local! buf 'buffer-selected #t)
      (run-command "group-add")
      (minibuffer-change! "zztest-added")
      (run-command "minibuffer-confirm")
      (let ((id (group-resolve-id "zztest-added")))
        (check-true! id "the typed name founded a group")
        (check-equal! (buffer-group buf) id "and the buffer joined it")
        (t--drop! id))
      (buffer-kill! buf))))

(deftest 'a-reply-link-fills-the-chat-without-sending
  "a reply action writes the draft and leaves the conversation unchanged"
  (lambda ()
    (let* ((id (t--group "reply-link"))
           (chat (group-chat id))
           (before (chat-turn-count chat)))
      (with-current-buffer chat
        (lambda () (chat-inject-reply! "Yes, use this option.")))
      (check-equal! (chat-input-text chat) "Yes, use this option."
                    "the action fills the live reply")
      (check-equal! (chat-turn-count chat) before "the action does not send the reply")
      (check-equal! (chat-reply-link "Use it" "Yes, use this option.")
                    "[Use it](compos:reply/Yes%2C%20use%20this%20option.)"
                    "the helper emits the shared action-link form")
      (buffer-kill! chat)
      (t--drop! id))))
