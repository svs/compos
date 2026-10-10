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

(deftest 'a-work-buffer-has-only-one-group-owner
  "joining another group replaces ownership before any removal command"
  (lambda ()
    (let ((buf (test-buffer! "*zztest-single-owner*" ""))
          (a (t--group "owner-a"))
          (b (t--group "owner-b")))
      (buffer-add-group-as! buf a 'source)
      (buffer-add-group! buf b)
      (check-equal! (buffer-group-ids buf) (list b) "only the destination owns the buffer")
      (check-equal! (buffer-local buf 'group-ids) (list b) "storage also holds one owner")
      (check-false! (buffer-in-group? buf a) "the former owner loses membership immediately")
      (check-false! (buffer-group-role buf a) "the former role does not survive the move")
      (buffer-kill! buf)
      (t--drop! a)
      (t--drop! b))))

(deftest 'legacy-multiple-memberships-normalize-to-one-owner
  "old desktop memberships retain the first owner when all records resolve"
  (lambda ()
    (let ((buf (test-buffer! "*zztest-legacy-owners*" ""))
          (a (t--group "legacy-owner-a"))
          (b (t--group "legacy-owner-b")))
      (buffer-set-local! buf 'group-ids (list a b))
      (check-equal! (buffer-group-ids buf) (list a) "the first legacy owner is retained")
      (check-equal! (buffer-local buf 'group-ids) (list a) "the old storage is normalized")
      (check-false! (buffer-in-group? buf b) "no second membership remains")
      (buffer-kill! buf)
      (t--drop! a)
      (t--drop! b))))

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
  "the render cache holds the one group this buffer is in"
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
                    "the membership carries its name")
      (buffer-add-group! buf two)
      (check-equal! (buffer-local buf 'modeline-groups) '("zztest-modeline-two")
                    "joining a group is leaving the last one")
      (group-rename! two "zztest-modeline-renamed")
      (check-equal! (buffer-local buf 'modeline-groups) '("zztest-modeline-renamed")
                    "renaming a group refreshes its member label")
      (buffer-remove-group! buf two)
      (check-equal! (buffer-local buf 'modeline-groups) '()
                    "leaving takes the name with it")
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

;;; --- pseudo groups ------------------------------------------------------------
;;;
;;; A pseudo group has a name and members, and no record. A function
;;; answers the members, so the group holds whatever the function says
;;; at the moment somebody asks.

(define t--pseudo-answer '())

(define (t--pseudo! name)
  (define-pseudo-group! (string-append "zztest-" name)
                        (lambda () t--pseudo-answer)))

(deftest 'a-pseudo-group-answers-its-members-each-time
  "the function decides the members, and a later call sees the later answer"
  (lambda ()
    (let ((one (test-buffer! "*zztest-pseudo-one*" ""))
          (two (test-buffer! "*zztest-pseudo-two*" "")))
      (set! t--pseudo-answer (list one))
      (let ((id (t--pseudo! "members")))
        (check-equal! (group-resolve-id "zztest-members") id "the name resolves to the id")
        (check-equal! (group-name id) "zztest-members" "and the id carries the name")
        (check-equal! (group-buffers id) (list one) "the members are the answer")
        (set! t--pseudo-answer (list two one))
        (check-equal! (group-buffers id) (list two one) "a later ask sees the later answer")
        (check-equal! (group-buffers-mru id) (list two one)
                      "the function's order is the MRU order")
        (check-equal! (buffer-pseudo-group-ids one) (list id)
                      "a member reports the pseudo group it is in")
        (undefine-pseudo-group! id))
      (set! t--pseudo-answer '())
      (buffer-kill! one)
      (buffer-kill! two))))

(deftest 'a-pseudo-group-drops-a-buffer-that-went
  "the answer holds names, and a name without a buffer is not a member"
  (lambda ()
    (let ((buf (test-buffer! "*zztest-pseudo-gone*" "")))
      (set! t--pseudo-answer (list buf "*zztest-pseudo-never*"))
      (let ((id (t--pseudo! "gone")))
        (check-equal! (group-buffers id) (list buf) "only the live buffer is a member")
        (buffer-kill! buf)
        (check-equal! (group-buffers id) '() "the killed buffer leaves the group")
        (undefine-pseudo-group! id))
      (set! t--pseudo-answer '()))))

(deftest 'a-pseudo-group-stays-out-of-the-records
  "the record list never holds one, so save and dissolve never see it"
  (lambda ()
    (let ((id (t--pseudo! "records")))
      (check-false! (member id (group-ids)) "the id is not a record id")
      (check-false! (member "zztest-records" (group-names)) "nor is the name a record name")
      (check-true! (and (member "zztest-records" (group-names-all)) #t)
                   "the reader still sees it among the groups")
      (undefine-pseudo-group! id)
      (check-false! (group-resolve-id "zztest-records") "and it goes away again"))))

(deftest 'a-buffer-cannot-join-a-pseudo-group
  "membership comes from the function, so no command writes it"
  (lambda ()
    (let ((buf (test-buffer! "*zztest-pseudo-join*" ""))
          (id (t--pseudo! "join")))
      (group-add-buffers-to! (list buf) id)
      (check-false! (buffer-in-group? buf id) "the buffer did not join")
      (check-equal! (buffer-group-ids buf) '() "and it holds no membership at all")
      (undefine-pseudo-group! id)
      (buffer-kill! buf))))

(deftest 'a-pseudo-group-refuses-a-rename
  "the definition owns the name"
  (lambda ()
    (let ((id (t--pseudo! "rename")))
      (group-rename! id "zztest-pseudo-renamed")
      (check-equal! (group-name id) "zztest-rename" "the name did not move")
      (check-false! (group-resolve-id "zztest-pseudo-renamed") "the new name names nothing")
      (undefine-pseudo-group! id))))

(deftest 'last-chats-holds-the-chats-you-used-last
  "the bundled pseudo group gathers chat buffers, most recent first"
  (lambda ()
    (check-true! (and (member "Last chats" (group-names-all)) #t)
                 "the editor declares it at load")
    (check-true! (<= (length (last-chats)) last-chats-limit)
                 "it holds no more chats than the limit")
    (check-true! (fold (lambda (ok b) (and ok (chat-buffer? b))) #t (last-chats))
                 "and every member is a chat")))

(deftest 'a-mode-two-buffers-share-is-a-group
  "mode groups follow the buffer list: two buffers make one, a kill ends it"
  (lambda ()
    (let ((a (test-buffer! "*zztest-mode-a*" ""))
          (b (test-buffer! "*zztest-mode-b*" "")))
      (buffer-set-local! a 'mode-name "zztest-mode")
      (buffer-set-local! b 'mode-name "zztest-mode")
      (set! *mode-groups-key* #f)
      (check-true! (and (member "mode: zztest" (group-names-all)) #t)
                   "the mode is a group")
      (check-equal! (length (group-buffers "mode: zztest")) 2 "holding two buffers")
      (check-true! (and (member a (group-buffers "mode: zztest"))
                        (member b (group-buffers "mode: zztest")) #t)
                   "the buffers in that mode")
      (check-true! (and (member "pseudo:mode--zztest" (buffer-goto-group-ids a)) #t)
                   "buffer-goto-group offers it")
      (buffer-kill! b)
      (check-false! (member "mode: zztest" (pseudo-group-names))
                    "one buffer left is no group")
      (buffer-kill! a))))

;;; --- the last buffer of a group --------------------------------------------

;; y-or-n reads its answer on the minibuffer's change handler: the same
;; path a typed answer takes.
(define (t--answer! key) (minibuffer-change! key))

(deftest 'killing-the-last-buffer-of-a-group-asks-and-kills-the-group
  "a yes kills the last work buffer and its group"
  (lambda ()
    (let ((buf (test-buffer! "*zztest-last-yes*" ""))
          (g (t--group "last-yes")))
      (buffer-add-group! buf g)
      (check-equal! (group-last-buffer-of buf) g "the buffer is the last buffer")
      (kill-buffer-confirm! buf #f)
      (check-contains! (plist-get (minibuffer-state) 'prompt) "dissolve the group?" "it asks")
      (t--answer! "y")
      (check-false! (buffer-known? buf) "the buffer is gone")
      (check-false! (group-resolve-id g) "the group is gone")
      (t--drop! (group-resolve-id g)))))

(deftest 'a-no-to-the-last-buffer-kills-nothing
  "a no keeps the buffer and the group"
  (lambda ()
    (let ((buf (test-buffer! "*zztest-last-no*" ""))
          (g (t--group "last-no")))
      (buffer-add-group! buf g)
      (kill-buffer-confirm! buf #f)
      (t--answer! "n")
      (check-true! (buffer-known? buf) "the buffer stays")
      (check-equal! (group-resolve-id g) g "the group stays")
      (buffer-kill! buf)
      (t--drop! g))))

(deftest 'a-buffer-with-company-dies-without-a-question
  "a group that keeps other work loses only the buffer, and nothing asks"
  (lambda ()
    (let ((a (test-buffer! "*zztest-company-a*" ""))
          (b (test-buffer! "*zztest-company-b*" ""))
          (g (t--group "company")))
      (buffer-add-group! a g)
      (buffer-add-group! b g)
      (check-false! (group-last-buffer-of a) "another buffer remains")
      (kill-buffer-confirm! a #f)
      (check-false! (minibuffer-state) "no question")
      (check-false! (buffer-known? a) "the buffer is gone")
      (check-equal! (group-resolve-id g) g "the group stays")
      (buffer-kill! b)
      (t--drop! g))))

;; The kill repair shows the group's chat when the work is gone, so the
;; chat is often the last buffer. Its kill asks too.
(deftest 'a-chat-that-is-the-last-buffer-asks-too
  "killing the only chat of a group with no other buffer asks to kill the group"
  (lambda ()
    (let* ((g (t--group "last-chat"))
           (chat (group-chat g)))
      (check-equal! (group-last-buffer-of chat) g "the chat is the last buffer")
      (kill-buffer-confirm! chat #f)
      (check-contains! (plist-get (minibuffer-state) 'prompt) "dissolve the group?" "it asks")
      (t--answer! "y")
      (check-false! (buffer-known? chat) "the chat is gone")
      (check-false! (group-resolve-id g) "the group is gone"))))

(deftest 'killing-the-group-you-stand-in-enters-the-most-recent-other
  "after a kill the frame enters the most recent group that is left"
  (lambda ()
    (let ((buf (test-buffer! "*zztest-follow*" ""))
          (a (t--group "follow-a"))
          (b (t--group "follow-b")))
      (buffer-add-group! buf a)
      (switch-to-group! a)
      (switch-to-group! b)
      (group-kill! b)
      (check-equal! (frame-group) a "the frame is in the other group")
      (group-kill! a))))
