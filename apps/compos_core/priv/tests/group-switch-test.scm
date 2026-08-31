;;; group-switch-test.scm --- the switcher, by the commands it runs.
;;;
;;; The switcher is a prompt. Typing is (minibuffer-change! TEXT), and
;;; every key it answers to is a command: minibuffer-confirm for RET,
;;; minibuffer-confirm-adopt for S-RET, minibuffer-confirm-context for
;;; C-RET, minibuffer-collect for C-SPC, minibuffer-next-candidate for
;;; C-n. Nothing here presses a key.

(domain! 'testing)
(effects! '(write))

;; These need a clean group world: several assert that NO group exists, or
;; count the ids. In a live editor that list is the person's own groups.
(tests-need-a-disposable-editor!
  "resets *group-records* and the frame's current group, which a live editor owns")

(define t--sw-first "zz-sw-first")
(define t--sw-second "zz-sw-second")
(define t--sw-third "zz-sw-third")

(define (t--sw-setup!)
  (when (minibuffer-state) (minibuffer-cancel!))
  (for-each
    (lambda (b)
      (test-buffer! b "")
      (buffer-set-local! b 'buffer-selected #f)
      (buffer-set-local! b 'scratch-buffer #f)
      (buffer-set-local! b 'scratch-owner #f)
      (buffer-set-local! b 'scratch-from #f)
      (buffer-set-local! b 'transient #f))
    (list t--sw-first t--sw-second t--sw-third))
  (set! *group-records* '())
  (set! *group-next-id* 0)
  (set-frame-local! 'current-group #f)
  (set-frame-local! 'previous-group #f)
  (set-frame-local! 'pinned-group #f)
  (delete-other-windows!)
  (switch-to-buffer! t--sw-first))

(define (t--sw-done!)
  (when (minibuffer-state) (minibuffer-cancel!))
  (set-frame-local! 'current-group #f)
  (set-frame-local! 'previous-group #f)
  (set-frame-local! 'pinned-group #f)
  (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
            (list t--sw-first t--sw-second t--sw-third))
  (set! *group-records* '())
  (set! *group-next-id* 0)
  (delete-other-windows!))

(define (t--sw-type! text) (minibuffer-change! text))
(define (t--sw-key! name) (run-command (string-append "minibuffer-" name)))

(define (t--sw-labels)
  (map (lambda (c) (plist-get c 'label))
       (plist-get (minibuffer-state) 'candidates)))

(define (t--sw-selected)
  (let ((st (minibuffer-state)))
    (and st
         (let ((sel (plist-get st 'sel)) (cs (plist-get st 'candidates)))
           (and (number? sel) (< sel (length cs)) (plist-get (nth sel cs) 'label))))))

;; where LABEL sits in the candidate list, or -1
(define (t--sw-at label)
  (let loop ((ls (t--sw-labels)) (i 0))
    (cond ((null? ls) -1)
          ((equal? (car ls) label) i)
          (else (loop (cdr ls) (+ i 1))))))

(define (t--sw-open-switcher!) (run-command "group-switch-buffer"))
(define (t--sw-open-all!)
  (set-prefix-arg! 4)
  (run-command "group-switch-buffer"))

(deftest 'group-switch-buffer-opens-its-candidate-prompt
  "the buffer helper has its own arity and opens the prompt"
  (lambda ()
    (t--sw-setup!)
    (t--sw-open-switcher!)
    (check-true! (minibuffer-state) "the prompt opened")
    (check-equal! (plist-get (minibuffer-state) 'prompt)
                  "Switch buffer: "
                  "the buffer switcher owns the prompt")
    (t--sw-done!)))

(deftest 'group-switch-buffer-pool-follows-the-invoking-window-history
  "another window cannot reorder this window's previous buffers"
  (lambda ()
    (t--sw-setup!)
    (let ((noise "zz-sw-noise"))
      (test-buffer! noise "")
      (switch-to-buffer! t--sw-second)
      (switch-to-buffer! t--sw-third)
      (switch-to-buffer! t--sw-first)
      (let ((window (active-window)))
        (split-window! 'h 0.5)
        (other-window!)
        (switch-to-buffer! t--sw-second)
        (switch-to-buffer! noise)
        (select-window! window)
        (let ((pool (group-switch-all-buffers-but t--sw-first)))
          (check-equal! (car pool) t--sw-third "the last buffer in this window leads")
          (check-equal! (cadr pool) t--sw-second "the older buffer follows it")))
      (buffer-kill! noise))
    (t--sw-done!)))

(deftest 'the-group-switcher-indexes-memberships-in-one-pass
  "the one-pass index lists the members a scan per group lists, in the same order"
  (lambda ()
    (t--sw-setup!)
    (let ((a (group-record-create! "zz-sw-index-a"))
          (b (group-record-create! "zz-sw-index-b")))
      (buffer-add-group! t--sw-first a)
      (buffer-add-group! t--sw-second a)
      (buffer-add-group! t--sw-second b)
      (switch-to-buffer! t--sw-second)
      (switch-to-buffer! t--sw-first)
      (let ((index (group-members-index)))
        (check-equal! (group-members-in index a) (group-buffers-mru a)
                      "group a: the index lists what the scan lists")
        (check-equal! (group-members-in index b) (group-buffers-mru b)
                      "group b: the index lists what the scan lists")
        (check-equal! (car (group-members-in index a)) t--sw-first
                      "the most recent member leads")
        (check-equal! (group-members-in index "zz-sw-no-such-group") '()
                      "an unknown group has no members")
        (check-equal! (group-switch-candidate-in index b) (group-switch-candidate b)
                      "the candidate row is the row the scan builds")))
    (t--sw-done!)))

;;; --- founding a group -----------------------------------------------------------

(deftest 'new-from-a-selection-preserves-old-memberships-and-the-layout
  "group-new on marked buffers takes the arrangement and leaves what was already true"
  (lambda ()
    (t--sw-setup!)
    (let ((old (group-record-create! "zzsw-old")))
      (buffer-add-group! t--sw-first old)
      (delete-other-windows!)
      (switch-to-buffer! t--sw-first)
      (split-window! 'h 0.5)
      (other-window!)
      (switch-to-buffer! t--sw-second)
      ;; the selection is the seed (docs/groups.md): both visible buffers
      (buffer-set-local! t--sw-first 'buffer-selected #t)
      (buffer-set-local! t--sw-second 'buffer-selected #t)
      (run-command "group-new")

      (t--sw-type! "zzsw-visible")
      (t--sw-key! "confirm")

      (let ((id (group-resolve-id "zzsw-visible")))
        (check-true! (buffer-in-group? t--sw-first old) "the old membership is kept")
        (check-true! (buffer-in-group? t--sw-first id) "and the new one added")
        (check-true! (buffer-in-group? t--sw-second id) "the other selected buffer joins")
        (check-equal! (frame-local 'current-group) id "the frame stands in it")
        (check-equal! (group-layout id) (window-tree) "and it remembers this layout"))
      (buffer-set-local! t--sw-first 'buffer-selected #f)
      (buffer-set-local! t--sw-second 'buffer-selected #f))
    (t--sw-done!)))

(deftest 'cancelled-group-creation-changes-no-group-state
  "C-g out of the prompt and nothing happened"
  (lambda ()
    (t--sw-setup!)
    (let ((before (window-tree)))
      (run-command "group-new")
      (t--sw-key! "cancel")
      (check-equal! (group-ids) '() "no group was founded")
      (check-false! (frame-local 'current-group) "the frame stands in none")
      (check-equal! (buffer-group-ids t--sw-first) '() "the buffer joined none")
      (check-equal! (window-tree) before "and the windows did not move"))
    (t--sw-done!)))

(deftest 'group-new-creates-and-enters-an-empty-work-context
  "group-new from a transient buffer seeds nothing (docs/groups.md: the empty seed)"
  (lambda ()
    (t--sw-setup!)
    (buffer-set-local! t--sw-first 'transient #t)
    (run-command "group-new")
    (t--sw-type! "zzsw-empty-context")
    (t--sw-key! "confirm")
    (buffer-set-local! t--sw-first 'transient #f)
    (let ((id (group-resolve-id "zzsw-empty-context")))
      (check-true! id "the group record exists")
      (check-equal! (filter group-work-buffer? (group-buffers id)) '()
                    "the group has no work members")
      (check-equal! (frame-group) id "the frame enters the empty context"))
    (t--sw-done!)))

(deftest 'the-active-groups-are-the-groups-of-the-open-buffers
  "a group is active while one of its buffers is open; the MRU only orders"
  (lambda ()
    (t--sw-setup!)
    (switch-to-buffer! t--sw-first)
    (run-command "group-new")
    (t--sw-type! "zzsw-active-one")
    (t--sw-key! "confirm")
    (switch-to-buffer! t--sw-second)
    (run-command "group-new")
    (t--sw-type! "zzsw-active-two")
    (t--sw-key! "confirm")
    ;; an empty group: group-new seeds nothing from a transient buffer
    (buffer-set-local! t--sw-second 'transient #t)
    (run-command "group-new")
    (t--sw-type! "zzsw-active-empty")
    (t--sw-key! "confirm")
    (buffer-set-local! t--sw-second 'transient #f)
    (let ((one (group-resolve-id "zzsw-active-one"))
          (two (group-resolve-id "zzsw-active-two"))
          (empty (group-resolve-id "zzsw-active-empty")))
      (check-true! (member one (active-groups)) "a group with an open buffer is active")
      (check-true! (member two (active-groups)) "so is the second")
      (check-false! (member empty (active-groups)) "a group with no buffer is not")
      (check-equal! (car (active-groups)) two "the most recent group comes first")
      (group-kill! two)
      (check-false! (member two (active-groups))
                    "a killed group's buffers are gone, so it is not active"))
    (t--sw-done!)))

;; Two groups for the kill tests. ONE-NAME holds first and third in two
;; windows; TWO-NAME holds second in one window, and the frame stands in
;; it. Leaving ONE with both windows on members is what saves its layout
;; as two windows: a window that shows a non-member is dropped from it.
(define (t--sw-two-groups! one-name two-name)
  ;; a chat left by an earlier run would pass for the group's own
  (for-each (lambda (name)
              (let ((c (string-append "*chat:" name "*")))
                (when (buffer-known? c) (buffer-kill! c))))
            (list one-name two-name))
  (switch-to-buffer! t--sw-second)
  (run-command "group-new")
  (t--sw-type! two-name)
  (t--sw-key! "confirm")
  (switch-to-buffer! t--sw-first)
  (run-command "group-new")
  (t--sw-type! one-name)
  (t--sw-key! "confirm")
  (split-window! 'v)
  (switch-to-buffer! t--sw-third)
  (buffer-add-group! t--sw-third (group-resolve-id one-name))
  (switch-to-group! (group-resolve-id two-name))
  (delete-other-windows!))

(deftest 'killing-the-group-you-stand-in-falls-into-the-next-buffers-group
  "after group-kill the frame enters the group of the buffer the window fell to"
  (lambda ()
    (t--sw-setup!)
    ;; two groups: "two" shows one window, "one" shows two member windows
    (t--sw-two-groups! "zzsw-fall-one" "zzsw-fall-two")
    (let ((one (group-resolve-id "zzsw-fall-one"))
          (two (group-resolve-id "zzsw-fall-two")))
      (check-equal! (frame-group) two "the frame stands in the second group")
      (check-equal! (length (window-list)) 1 "which shows one window")
      (run-command "group-kill")
      (check-false! (group-resolve-id "zzsw-fall-two") "the group is gone")
      (check-false! (buffer-exists? "*chat:zzsw-fall-two*") "the dying group's chat is not left open")
      (check-equal! (frame-group) one "the frame fell into the next buffer's group")
      (check-true! (member (current-buffer) (list t--sw-first t--sw-third))
                   "and shows that group's buffer")
      (check-equal! (length (window-list)) 2 "with that group's layout")
      (delete-other-windows!)
      (run-command "group-kill")
      (check-false! (frame-group) "with no grouped buffer left, the frame stands in none"))
    (t--sw-done!)))

(deftest 'a-killed-group-revives-with-the-members-that-still-exist
  "revive makes the record again; a member whose buffer and file are gone is missing"
  (lambda ()
    (t--sw-setup!)
    (set! *group-graveyard* '())
    (t--sw-two-groups! "zzsw-rev-one" "zzsw-rev-two")
    (let ((one (group-resolve-id "zzsw-rev-one"))
          (two (group-resolve-id "zzsw-rev-two")))
      ;; second is in both groups, so the kill of two keeps it open
      (buffer-add-group! t--sw-second one)
      (let ((color (group-record-color (group-record-by-id two))))
        (run-command "group-kill")
        (check-false! (group-resolve-id "zzsw-rev-two") "the group is gone")
        (check-equal! (car (car *group-graveyard*)) "zzsw-rev-two" "and lies in the graveyard")
        (check-true! (group-revive! "zzsw-rev-two") "revive answers the new id")
        (let ((again (group-resolve-id "zzsw-rev-two")))
          (check-true! again "the record is back")
          (check-equal! (group-record-color (group-record-by-id again)) color
                        "with its color")
          (check-true! (buffer-in-group? t--sw-second again) "the member that lived joins")
          (check-equal! (frame-group) again "and the frame enters it")
          (check-false! (assoc "zzsw-rev-two" *group-graveyard*) "the grave is empty"))))
    (t--sw-done!)))

(deftest 'reviving-a-group-whose-members-are-gone-is-not-an-error
  "a member with no buffer and no file is missing, and the revival says so"
  (lambda ()
    (t--sw-setup!)
    (set! *group-graveyard*
      (list (list "zzsw-rev-ghost" #f #f "quiet" #f "#123456" 0
                  (list (list "zz-sw-nobody" #f)
                        (list "/tmp/zzsw-no-such-file.txt" "/tmp/zzsw-no-such-file.txt")))))
    (check-true! (group-revive! "zzsw-rev-ghost") "revive still makes the group")
    (let ((id (group-resolve-id "zzsw-rev-ghost")))
      (check-true! id "the record exists")
      (check-equal! (filter group-work-buffer? (group-buffers id)) '() "with no work members")
      (check-equal! (frame-group) id "and the frame stands in it"))
    (set! *group-graveyard* '())
    (t--sw-done!)))

(deftest 'group-after-kill-stay-keeps-the-frame-out-of-the-next-group
  "the customisation turns the fall-through off"
  (lambda ()
    (t--sw-setup!)
    (let ((was group-after-kill))
      (set! group-after-kill "stay")
      (t--sw-two-groups! "zzsw-stay-one" "zzsw-stay-two")
      (run-command "group-kill")
      (check-false! (group-resolve-id "zzsw-stay-two") "the group is gone")
      (check-true! (member (current-buffer) (list t--sw-first t--sw-third))
                   "the window fell to the next buffer")
      (check-equal! (length (window-list)) 1 "and no layout was restored")
      (set! group-after-kill was))
    (t--sw-done!)))

(deftest 'group-new-without-selection-does-not-adopt-the-current-buffer
  "group-new without a selection starts empty rather than moving the current buffer"
  (lambda ()
    (t--sw-setup!)
    (buffer-set-local! t--sw-first 'scratch-buffer t--sw-second)
    (buffer-set-local! t--sw-second 'scratch-owner t--sw-first)
    (switch-to-buffer! t--sw-first)
    (run-command "group-new")
    (t--sw-type! "zzsw-empty-from-current")
    (t--sw-key! "confirm")
    (let ((id (group-resolve-id "zzsw-empty-from-current")))
      (check-false! (buffer-in-group? t--sw-first id) "the current buffer stays out")
      (check-false! (buffer-in-group? t--sw-second id) "its companion stays out")
      (check-equal! (frame-group) id "the empty context is entered"))
    (t--sw-done!)))

(deftest 'a-chat-opens-the-groups-shared-scratch
  "the scratch belongs to the group and resolves through every work companion"
  (lambda ()
    (t--sw-setup!)
    (let* ((id (group-record-create! "zzsw-shared-scratch"))
           (chat (group-chat id))
           (scratch "*scratch:zzsw-shared-scratch*"))
      (buffer-add-group! t--sw-first id)
      (switch-to-buffer! chat)
      (run-command "scratch-buffer")

      (check-equal! (current-buffer) scratch "the group scratch opens")
      (check-equal! (buffer-group scratch) id "the group owns the scratch")
      (check-equal! (buffer-group-role scratch id) "scratch"
                    "the membership carries the scratch role")
      (check-false! (buffer-local scratch 'scratch-owner)
                    "the chat does not own the scratch")
      (check-equal! (buffer-local scratch 'scratch-from) chat
                    "navigation remembers where the user came from")
      (check-equal! (buffer-local t--sw-first 'scratch-buffer) scratch
                    "the work buffer points to the shared scratch")
      (check-true! (member t--sw-first (buffer-family scratch))
                   "the scratch resolves through the group to its work buffer")
      (check-true! (member scratch (buffer-family chat))
                   "the chat reaches the same group scratch")

      (run-command "scratch-buffer")
      (check-equal! (current-buffer) chat "toggle returns to the last source")
      (when (buffer-known? scratch) (buffer-kill! scratch))
      (when (buffer-known? chat) (buffer-kill! chat)))
    (t--sw-done!)))

(deftest 'all-new-work-buffers-use-the-derived-current-group
  "the shared creation hook places direct and command-created work"
  (lambda ()
    (t--sw-setup!)
    (let ((here (group-record-create! "zzsw-here"))
          (direct "zz-sw-new-direct")
          (grouped "zz-sw-new-grouped")
          (ungrouped "zz-sw-new-ungrouped"))
      (buffer-add-group! t--sw-first here)
      (switch-to-buffer! t--sw-first)

      (buffer-create direct)
      (check-true! (buffer-in-group? direct here)
                   "direct creation runs the shared group hook")

      (run-command "buffer-new")
      (t--sw-type! grouped)
      (t--sw-key! "confirm-input")
      (check-true! (buffer-in-group? grouped here) "homogeneous work inherits current-group")

      (switch-to-buffer! t--sw-third)
      (check-false! (frame-group) "the ungrouped buffer clears current-group")
      (run-command "buffer-new")
      (t--sw-type! ungrouped)
      (t--sw-key! "confirm-input")
      (check-equal! (buffer-group-ids ungrouped) '() "without current-group it starts ungrouped")

      (buffer-kill! direct)
      (buffer-kill! grouped)
      (buffer-kill! ungrouped))
    (t--sw-done!)))

;;; --- add, move, remove -----------------------------------------------------------

(deftest 'membership-commands-use-only-add-move-and-remove
  "the command palette does not expose the obsolete membership verbs"
  (lambda ()
    (for-each
      (lambda (name)
        (check-false! (member name (command-names))
                      (string-append name " is not a command")))
      '("group-pull-buffer" "group-push-buffer" "group-push-visible"
        "group-push-selected" "group-pop"))))

(deftest 'add-keeps-existing-memberships-and-visible-context
  "add makes the buffer family available elsewhere without entering the destination"
  (lambda ()
    (t--sw-setup!)
    (let ((source (group-record-create! "zzsw-source"))
          (destination (group-record-create! "zzsw-destination")))
      (buffer-add-group! t--sw-first source)
      (switch-to-buffer! t--sw-first)
      (buffer-set-local! t--sw-first 'buffer-selected #t)
      (run-command "group-add")
      (t--sw-type! "zzsw-destination")
      (t--sw-key! "confirm")

      (check-true! (buffer-in-group? t--sw-first source) "the source membership remains")
      (check-true! (buffer-in-group? t--sw-first destination) "the destination is added")
      (check-equal! (frame-group) source "the visible context remains the source")
      (check-equal! (current-buffer) t--sw-first "the command does not change windows"))
    (t--sw-done!)))

(deftest 'add-can-create-a-destination-without-entering-it
  "a typed destination creates one group and adds the current buffer"
  (lambda ()
    (t--sw-setup!)
    (let ((source (group-record-create! "zzsw-source")))
      (buffer-add-group! t--sw-first source)
      (switch-to-buffer! t--sw-first)
      (buffer-set-local! t--sw-first 'buffer-selected #t)
      (run-command "group-add")
      (t--sw-type! "zzsw-created")
      (t--sw-key! "confirm")

      (let ((created (group-resolve-id "zzsw-created")))
        (check-true! created "the typed destination creates a group")
        (check-true! (buffer-in-group? t--sw-first created) "the buffer joins it")
        (check-equal! (frame-group) source "the frame does not enter it")))
    (t--sw-done!)))

(deftest 'add-works-without-a-current-group
  "an ungrouped buffer can add a destination while the frame has no context"
  (lambda ()
    (t--sw-setup!)
    (switch-to-buffer! t--sw-third)
    (set-frame-local! 'current-group #f)
    (buffer-set-local! t--sw-third 'buffer-selected #t)
    (run-command "group-add")
    (t--sw-type! "zzsw-null-add")
    (t--sw-key! "confirm")
    (let ((id (group-resolve-id "zzsw-null-add")))
      (check-true! id "the destination record exists")
      (check-equal! (buffer-group-ids t--sw-third) (list id)
                    "the buffer receives the destination"))
    (t--sw-done!)))

(deftest 'add-without-a-selection-acts-on-the-current-buffer
  "no selection means the current buffer, so a lone work buffer can join a group"
  (lambda ()
    (t--sw-setup!)
    (let ((destination (group-record-create! "zzsw-current-add")))
      (switch-to-buffer! t--sw-second)
      (run-command "group-add")
      (check-true! (minibuffer-state) "the destination prompt opens")
      (t--sw-type! "zzsw-current-add")
      (t--sw-key! "confirm")
      (check-true! (buffer-in-group? t--sw-second destination)
                   "the current buffer joins")
      (check-false! (buffer-in-group? t--sw-first destination)
                    "other buffers stay out")
      (check-equal! (current-buffer) t--sw-second
                    "the command does not change windows"))
    (t--sw-done!)))

(deftest 'add-uses-every-selected-buffer-and-clears-the-selection
  "the command changes selected buffers only, then consumes their selection"
  (lambda ()
    (t--sw-setup!)
    (let ((destination (group-record-create! "zzsw-selected-add")))
      (buffer-set-local! t--sw-first 'buffer-selected #t)
      (buffer-set-local! t--sw-second 'buffer-selected #t)
      (switch-to-buffer! t--sw-third)
      (run-command "group-add")
      (t--sw-type! "zzsw-selected-add")
      (t--sw-key! "confirm")
      (check-true! (buffer-in-group? t--sw-first destination)
                   "the first selected buffer joins")
      (check-true! (buffer-in-group? t--sw-second destination)
                   "the second selected buffer joins")
      (check-false! (buffer-in-group? t--sw-third destination)
                    "the unselected current buffer stays out")
      (check-false! (buffer-local t--sw-first 'buffer-selected)
                    "the first selection is consumed")
      (check-false! (buffer-local t--sw-second 'buffer-selected)
                    "the second selection is consumed"))
    (t--sw-done!)))

(deftest 'add-uses-switcher-marks-and-clears-them
  "the switcher and ordinary buffers feed the same selected-buffer command"
  (lambda ()
    (t--sw-setup!)
    (let ((destination (group-record-create! "zzsw-marked-add")))
      (switch-open! 'buffers)
      (buffer-set-local! *switch-buffer* 'list-marks
        ;; The switcher intentionally omits the home buffer (first): mark the
        ;; two buffer rows the user can actually see.
        (list (list t--sw-second *list-mark-char*)
              (list t--sw-third *list-mark-char*)))
      (run-command "group-add")
      (t--sw-type! "zzsw-marked-add")
      (t--sw-key! "confirm")
      (check-true! (buffer-in-group? t--sw-second destination)
                   "the first visible marked buffer joins")
      (check-true! (buffer-in-group? t--sw-third destination)
                   "the second visible marked buffer joins")
      (check-false! (buffer-in-group? t--sw-first destination)
                    "the hidden home buffer stays out")
      (check-equal! (list-marked *switch-buffer* *list-mark-char*) '()
                    "the switcher marks are consumed"))
    (t--sw-done!)))

(deftest 'move-replaces-existing-memberships-with-the-destination
  "move needs one destination and leaves the buffer in only that group"
  (lambda ()
    (t--sw-setup!)
    (let ((source (group-record-create! "zzsw-source"))
          (kept (group-record-create! "zzsw-kept"))
          (destination (group-record-create! "zzsw-destination")))
      (buffer-add-group! t--sw-first source)
      (buffer-add-group! t--sw-first kept)
      (switch-to-buffer! t--sw-first)
      (run-command "group-move")
      (t--sw-type! "zzsw-destination")
      (t--sw-key! "confirm")

      (check-false! (buffer-in-group? t--sw-first source) "the source is removed")
      (check-false! (buffer-in-group? t--sw-first kept) "another membership is removed")
      (check-true! (buffer-in-group? t--sw-first destination) "the destination is added")
      (check-equal! (buffer-group-ids t--sw-first) (list destination)
                    "the destination is the only membership")
      (check-true! (buffer-known? t--sw-first) "move keeps the buffer alive"))
    (t--sw-done!)))

(deftest 'move-never-asks-for-a-source-group
  "a multiply grouped buffer asks only for its destination"
  (lambda ()
    (t--sw-setup!)
    (let ((first (group-record-create! "zzsw-first-source"))
          (second (group-record-create! "zzsw-second-source"))
          (destination (group-record-create! "zzsw-destination")))
      (buffer-add-group! t--sw-first first)
      (buffer-add-group! t--sw-first second)
      (switch-to-buffer! t--sw-first)
      (set-frame-local! 'current-group #f)
      (run-command "group-move")

      (check-equal! (plist-get (minibuffer-state) 'prompt) "Move buffer to group: "
                    "the first prompt asks for the destination")
      (t--sw-type! "zzsw-destination")
      (t--sw-key! "confirm")

      (check-false! (buffer-in-group? t--sw-first first) "the first old group is removed")
      (check-false! (buffer-in-group? t--sw-first second) "the second old group is removed")
      (check-true! (buffer-in-group? t--sw-first destination) "the destination is added"))
    (t--sw-done!)))

(deftest 'an-ungrouped-buffer-moves-to-a-new-named-group
  "move creates one destination for a buffer that has no source group"
  (lambda ()
    (t--sw-setup!)
    (switch-to-buffer! t--sw-third)
    (check-equal! (buffer-group-ids t--sw-third) '()
                  "the buffer starts without a group")
    (run-command "group-move")
    (t--sw-type! "zzsw-ungrouped-destination")
    (t--sw-key! "confirm")

    (let ((destination (group-resolve-id "zzsw-ungrouped-destination")))
      (check-true! destination "the entered group name creates a durable record")
      (check-equal! (buffer-group-ids t--sw-third) (list destination)
                    "the destination becomes the only membership"))
    (t--sw-done!)))

(deftest 'a-failed-move-keeps-every-existing-membership
  "move changes no membership when it cannot resolve the destination"
  (lambda ()
    (t--sw-setup!)
    (let ((first (group-record-create! "zzsw-first"))
          (second (group-record-create! "zzsw-second")))
      (buffer-add-group! t--sw-first first)
      (buffer-add-group! t--sw-first second)
      (buffer-move-family-to-group! t--sw-first "grp:missing")
      (check-equal! (buffer-group-ids t--sw-first) (list first second)
                    "the failed move keeps every membership"))
    (t--sw-done!)))

(deftest 'remove-drops-one-membership-and-keeps-the-buffer
  "remove changes one membership without killing work"
  (lambda ()
    (t--sw-setup!)
    (let ((removed (group-record-create! "zzsw-removed"))
          (kept (group-record-create! "zzsw-kept")))
      (buffer-add-group! t--sw-first removed)
      (buffer-add-group! t--sw-first kept)
      (switch-to-buffer! t--sw-first)
      (set-frame-local! 'current-group removed)
      (run-command "group-remove")

      (check-equal! (plist-get (minibuffer-state) 'prompt)
                    "Toggle group removal (C-g applies): "
                    "multiple memberships always open the picker")
      (t--sw-type! "zzsw-removed")
      (t--sw-key! "confirm")
      (check-true! (minibuffer-state) "the picker stays open after a toggle")
      (check-true! (buffer-in-group? t--sw-first removed)
                   "a toggle does not change membership before close")
      (t--sw-key! "cancel")

      (check-false! (buffer-in-group? t--sw-first removed) "the named membership is removed")
      (check-true! (buffer-in-group? t--sw-first kept) "the other membership remains")
      (check-true! (buffer-known? t--sw-first) "the buffer remains alive"))
    (t--sw-done!)))

(deftest 'remove-asks-for-a-membership-without-a-current-group
  "a multiply grouped buffer chooses one membership when the frame has no context"
  (lambda ()
    (t--sw-setup!)
    (let ((removed (group-record-create! "zzsw-null-remove"))
          (kept (group-record-create! "zzsw-null-kept")))
      (buffer-add-group! t--sw-first removed)
      (buffer-add-group! t--sw-first kept)
      (switch-to-buffer! t--sw-first)
      (set-frame-local! 'current-group #f)
      (run-command "group-remove")
      (check-equal! (plist-get (minibuffer-state) 'prompt)
                    "Toggle group removal (C-g applies): "
                    "the command asks which membership to remove")
      (t--sw-type! "zzsw-null-remove")
      (t--sw-key! "confirm")
      (check-true! (minibuffer-state) "the picker remains active")
      (check-true! (buffer-in-group? t--sw-first removed)
                   "the selection remains pending until close")
      (t--sw-key! "cancel")
      (check-false! (buffer-in-group? t--sw-first removed)
                    "the selected membership is removed")
      (check-true! (buffer-in-group? t--sw-first kept)
                   "the other membership remains"))
    (t--sw-done!)))

(deftest 'remove-picker-can-clear-a-pending-removal
  "selecting the same membership again keeps it when C-g applies the changes"
  (lambda ()
    (t--sw-setup!)
    (let ((first (group-record-create! "zzsw-toggle-first"))
          (second (group-record-create! "zzsw-toggle-second")))
      (buffer-add-group! t--sw-first first)
      (buffer-add-group! t--sw-first second)
      (switch-to-buffer! t--sw-first)
      (run-command "group-remove")
      (t--sw-type! "zzsw-toggle-first")
      (t--sw-key! "confirm")
      (check-true! (buffer-in-group? t--sw-first first)
                   "the first selection is only pending")
      (t--sw-type! "zzsw-toggle-first")
      (t--sw-key! "confirm")
      (t--sw-key! "cancel")
      (check-false! (minibuffer-state) "C-g exits the picker")
      (check-true! (buffer-in-group? t--sw-first first)
                   "the second selection clears the pending removal"))
    (t--sw-done!)))

(deftest 'group-remove-opens-the-staged-picker-for-one-membership
  "the compatibility command never removes the only membership immediately"
  (lambda ()
    (t--sw-setup!)
    (let ((only (group-record-create! "zzsw-only-remove")))
      (buffer-add-group! t--sw-first only)
      (switch-to-buffer! t--sw-first)
      (run-command "group-remove")
      (check-equal! (plist-get (minibuffer-state) 'prompt)
                    "Toggle group removal (C-g applies): "
                    "the selector opens for one membership")
      (check-true! (buffer-in-group? t--sw-first only)
                   "opening the selector changes nothing")
      (t--sw-type! "zzsw-only-remove")
      (t--sw-key! "confirm")
      (check-true! (buffer-in-group? t--sw-first only)
                   "selecting the membership only stages removal")
      (t--sw-key! "cancel")
      (check-false! (buffer-in-group? t--sw-first only)
                    "C-g applies the staged removal"))
    (t--sw-done!)))

(deftest 'membership-commands-include-the-explicit-buffer-family
  "add, move, and remove apply to the document and its attached scratch buffer"
  (lambda ()
    (t--sw-setup!)
    (let ((source (group-record-create! "zzsw-family-source"))
          (added (group-record-create! "zzsw-family-added"))
          (moved (group-record-create! "zzsw-family-moved")))
      (buffer-set-local! t--sw-first 'scratch-buffer t--sw-second)
      (buffer-set-local! t--sw-second 'scratch-owner t--sw-first)
      (buffer-add-group! t--sw-first source)
      (buffer-add-group! t--sw-second source)
      (switch-to-buffer! t--sw-first)

      (buffer-add-family-to-group! t--sw-first added)
      (check-true! (buffer-in-group? t--sw-first added) "the document is added")
      (check-true! (buffer-in-group? t--sw-second added) "the scratch buffer is added")

      (buffer-move-family-to-group! t--sw-first moved)
      (check-false! (buffer-in-group? t--sw-first source) "the document leaves the source")
      (check-false! (buffer-in-group? t--sw-second source) "the scratch buffer leaves the source")
      (check-false! (buffer-in-group? t--sw-first added) "the document leaves another group")
      (check-false! (buffer-in-group? t--sw-second added) "the scratch buffer leaves another group")
      (check-true! (buffer-in-group? t--sw-first moved) "the document reaches the destination")
      (check-true! (buffer-in-group? t--sw-second moved) "the scratch buffer reaches the destination")

      (set-frame-local! 'current-group moved)
      (run-command "group-remove")
      (t--sw-type! "zzsw-family-moved")
      (t--sw-key! "confirm")
      (check-true! (buffer-in-group? t--sw-first moved)
                   "remove stays pending for the document")
      (check-true! (buffer-in-group? t--sw-second moved)
                   "remove stays pending for the companion")
      (t--sw-key! "cancel")
      (check-false! (buffer-in-group? t--sw-first moved) "remove changes the document")
      (check-false! (buffer-in-group? t--sw-second moved) "remove changes the scratch buffer"))
    (t--sw-done!)))

(deftest 'buffer-family-ignores-a-missing-companion
  "a stale companion name does not block the live owner"
  (lambda ()
    (t--sw-setup!)
    (buffer-set-local! t--sw-first 'scratch-buffer "*zzsw-missing-companion*")
    (check-equal! (buffer-family t--sw-first) (list t--sw-first)
                  "only the live owner remains eligible")
    (let ((destination (group-record-create! "zzsw-missing-family")))
      (buffer-move-family-to-group! t--sw-first destination)
      (check-true! (buffer-in-group? t--sw-first destination)
                   "the owner still moves"))
    (t--sw-done!)))

(deftest 'buffer-family-ignores-an-incompatible-companion
  "a transient companion does not join a work group"
  (lambda ()
    (t--sw-setup!)
    (buffer-set-local! t--sw-first 'scratch-buffer t--sw-second)
    (buffer-set-local! t--sw-second 'scratch-owner t--sw-first)
    (buffer-set-local! t--sw-second 'transient #t)
    (check-equal! (buffer-family t--sw-first) (list t--sw-first)
                  "the transient companion is ineligible")
    (let ((destination (group-record-create! "zzsw-incompatible-family")))
      (buffer-add-family-to-group! t--sw-first destination)
      (check-true! (buffer-in-group? t--sw-first destination)
                   "the eligible owner joins")
      (check-false! (buffer-in-group? t--sw-second destination)
                    "the transient companion stays out"))
    (t--sw-done!)))

(deftest 'buffer-select-toggles-the-active-buffer
  "the active buffer becomes selected without opening a selector"
  (lambda ()
    (t--sw-setup!)
    (check-false! (buffer-local t--sw-first 'buffer-selected)
                  "the current buffer starts unselected")
    (run-command "buffer-select")
    (check-true! (buffer-local t--sw-first 'buffer-selected)
                 "the active buffer is selected")
    (run-command "buffer-unselect")
    (check-false! (buffer-local t--sw-first 'buffer-selected)
                  "the active buffer is deselected")
    (run-command "buffer-select")
    (buffer-set-local! t--sw-second 'buffer-selected #t)
    (run-command "buffer-unselect-all")
    (check-false! (buffer-local t--sw-first 'buffer-selected)
                  "unselect all clears the active buffer")
    (check-false! (buffer-local t--sw-second 'buffer-selected)
                  "unselect all clears other buffers")
    (t--sw-done!)))

;;; --- the switch list -------------------------------------------------------------

(define (t--sw-three-groups!)
  (let ((current (group-record-create! "zzsw-current"))
        (foreign (group-record-create! "zzsw-foreign")))
    (buffer-add-group! t--sw-first current)
    (buffer-add-group! t--sw-second current)
    (buffer-add-group! t--sw-third foreign)
    (set-frame-local! 'current-group current)
    (switch-to-buffer! t--sw-second)
    (switch-to-buffer! t--sw-third)
    (switch-to-buffer! t--sw-first)
    (list current foreign)))

(deftest 'the-switcher-lists-the-current-group-before-other-buffers
  "members come first and foreign buffers remain reachable"
  (lambda ()
    (t--sw-setup!)
    (let ((ids (t--sw-three-groups!)))
      (t--sw-open-switcher!)
      (let ((labels (t--sw-labels)))
        (check-true! (member t--sw-second labels) "the member is reachable")
        (check-true! (member t--sw-third labels) "the stranger is reachable")
        (check-true! (< (t--sw-at t--sw-second) (t--sw-at t--sw-third))
                     "the member is listed before the stranger"))

      (t--sw-type! t--sw-second)
      (t--sw-key! "confirm")
      (check-equal! (current-buffer) t--sw-second "it switched")
      (check-equal! (frame-local 'current-group) (car ids) "and the context held"))
    (t--sw-done!)))

(deftest 'a-broadened-switcher-lists-every-buffer-under-two-headings
  "C-u lists the group's own first, then the rest"
  (lambda ()
    (t--sw-setup!)
    (t--sw-three-groups!)
    (t--sw-open-all!)
    (let ((labels (t--sw-labels)))
      (check-true! (member "in this group" labels) "the first heading")
      (check-true! (member "other buffers" labels) "the second")
      (check-true! (member t--sw-second labels) "a member is listed")
      (check-false! (member t--sw-first labels) "and the buffer we are in is not"))
    (check-true! (< (t--sw-at "in this group") (t--sw-at t--sw-second))
                 "the heading comes before its member")
    (check-true! (< (t--sw-at t--sw-second) (t--sw-at "other buffers"))
                 "and the member before the next heading")

    ;; the panel renders a WINDOW of rows, so filter to the stranger
    (t--sw-type! t--sw-third)
    (check-true! (member t--sw-third (t--sw-labels)) "the stranger is reachable")
    (check-true! (< (t--sw-at "other buffers") (t--sw-at t--sw-third))
                 "under the other-buffers heading")
    (t--sw-done!)))

(deftest 'a-heading-takes-no-selection-and-no-count
  "no number of steps lands on one"
  (lambda ()
    (t--sw-setup!)
    (t--sw-three-groups!)
    (t--sw-open-all!)
    (check-equal! (t--sw-selected) t--sw-second "the first selection is a real buffer")

    (t--sw-key! "next-candidate")
    (check-true! (t--sw-selected) "the next row is a row")
    (check-false! (member (t--sw-selected) '("in this group" "other buffers"))
                  "and not a heading")

    (let loop ((n 8))
      (when (> n 0) (t--sw-key! "next-candidate") (loop (- n 1))))
    (check-false! (member (t--sw-selected) '("in this group" "other buffers"))
                  "nor after eight more steps")
    (t--sw-done!)))

(deftest 'a-heading-drops-when-the-filter-empties-its-section
  "a heading with nothing under it is not a row"
  (lambda ()
    (t--sw-setup!)
    (t--sw-three-groups!)
    (t--sw-open-all!)
    ;; the third buffer lives only in the foreign group, so filtering to it
    ;; leaves the group's own section empty
    (t--sw-type! t--sw-third)
    (let ((labels (t--sw-labels)))
      (check-true! (member t--sw-third labels) "the stranger is there")
      (check-false! (member "in this group" labels) "its empty heading is gone")
      (check-false! (member t--sw-second labels) "and so is the member"))
    (t--sw-done!)))

;;; --- the three ways to answer ----------------------------------------------------

(deftest 'context-follows-the-buffer-into-its-group
  "C-RET: and the buffer is on screen even though the saved layout never showed it"
  (lambda ()
    (t--sw-setup!)
    (let ((current (group-record-create! "zzsw-current"))
          (foreign (group-record-create! "zzsw-foreign")))
      (buffer-add-group! t--sw-first current)
      (buffer-add-group! t--sw-second foreign)
      (buffer-add-group! t--sw-third foreign)
      ;; the foreign group remembers a layout that does NOT show the third
      (set-frame-local! 'current-group foreign)
      (delete-other-windows!)
      (switch-to-buffer! t--sw-second)
      (group-layout-save! foreign)
      (set-frame-local! 'current-group current)
      (delete-other-windows!)
      (switch-to-buffer! t--sw-first)

      (t--sw-open-all!)
      (t--sw-type! t--sw-third)
      (t--sw-key! "confirm-context")

      (check-equal! (frame-local 'current-group) foreign "the context followed")
      (check-equal! (current-buffer) t--sw-third "and the buffer is on screen")
      (check-false! (buffer-in-group? t--sw-third current) "it did not join this group"))
    (t--sw-done!)))

(deftest 'context-confirm-asks-which-membership-to-enter
  "C-RET on a multiply grouped buffer does not guess its destination"
  (lambda ()
    (t--sw-setup!)
    (let ((here (group-record-create! "zzsw-here"))
          (first (group-record-create! "zzsw-first-choice"))
          (second (group-record-create! "zzsw-second-choice")))
      (buffer-add-group! t--sw-first here)
      (buffer-add-group! t--sw-second first)
      (buffer-add-group! t--sw-second second)
      (switch-to-buffer! t--sw-first)

      (t--sw-open-all!)
      (t--sw-type! t--sw-second)
      (t--sw-key! "confirm-context")
      (check-true! (member "zzsw-first-choice" (t--sw-labels)) "the first membership is offered")
      (check-true! (member "zzsw-second-choice" (t--sw-labels)) "the second membership is offered")
      (t--sw-type! "zzsw-second-choice")
      (t--sw-key! "confirm")

      (check-equal! (frame-group) second "the chosen membership was entered")
      (check-equal! (current-buffer) t--sw-second "the candidate has focus"))
    (t--sw-done!)))

(deftest 'confirm-follows-the-picked-buffers-group-without-moving-membership
  "RET changes the frame standing but does not change membership"
  (lambda ()
    (t--sw-setup!)
    (let ((ids (t--sw-three-groups!)))
      (t--sw-open-all!)
      (t--sw-type! t--sw-third)
      (t--sw-key! "confirm")

      (check-equal! (current-buffer) t--sw-third "the window moved")
      (check-equal! (frame-local 'current-group) (cadr ids) "the frame followed it")
      (check-false! (buffer-in-group? t--sw-third (car ids)) "and no membership changed"))
    (t--sw-done!)))

(deftest 'switching-to-an-ungrouped-buffer-clears-the-frame-group
  "a broadened buffer switch leaves group isolation when the target is ungrouped"
  (lambda ()
    (t--sw-setup!)
    (let ((here (group-record-create! "zzsw-current")))
      (buffer-add-group! t--sw-first here)
      (buffer-add-group! t--sw-second here)
      (set-frame-local! 'current-group here)
      (switch-to-buffer! t--sw-first)

      (t--sw-open-all!)
      (t--sw-type! t--sw-third)
      (t--sw-key! "confirm")

      (check-equal! (current-buffer) t--sw-third "the ungrouped buffer is current")
      (check-false! (frame-local 'current-group) "the frame left group isolation"))
    (t--sw-done!)))

(deftest 'switching-context-restores-the-saved-layout
  "the group you go to looks the way you left it"
  (lambda ()
    (t--sw-setup!)
    (let ((left (group-record-create! "zzsw-left"))
          (right (group-record-create! "zzsw-right")))
      (buffer-add-group! t--sw-first left)
      (buffer-add-group! t--sw-second right)
      (set-frame-local! 'current-group right)
      (switch-to-buffer! t--sw-second)
      (group-layout-save! right)
      (set-frame-local! 'current-group left)
      (switch-to-buffer! t--sw-first)

      (run-command "group-switch")
      (t--sw-type! "zzsw-right")
      (t--sw-key! "confirm")

      (check-equal! (current-buffer) t--sw-second "the saved layout came back")
      (check-equal! (frame-local 'current-group) right "the context moved")
      (check-equal! (frame-local 'previous-group) left "and remembers where from")
      (check-equal! (buffer-group t--sw-first) left "the other buffer kept its group"))
    (t--sw-done!)))

(deftest 'switching-context-removes-foreign-panes-from-a-saved-layout
  "a stale layout cannot reintroduce work that no longer belongs to the group"
  (lambda ()
    (t--sw-setup!)
    (let ((docs (group-record-create! "zzsw-docs"))
          (foreign (group-record-create! "zzsw-foreign")))
      (buffer-add-group! t--sw-first docs)
      (buffer-add-group! t--sw-second docs)
      (buffer-add-group! t--sw-third docs)

      (switch-to-buffer! t--sw-first)
      (split-window! 'h 0.34)
      (other-window!)
      (switch-to-buffer! t--sw-second)
      (split-window! 'h 0.5)
      (other-window!)
      (switch-to-buffer! t--sw-third)
      (group-layout-save! docs)

      ;; The pane was valid when DOCS saved it. It became foreign later.
      (buffer-remove-group! t--sw-third docs)
      (buffer-add-group! t--sw-third foreign)

      (delete-other-windows!)
      (switch-to-buffer! t--sw-third)
      (switch-to-group! docs)

      (check-false! (member t--sw-third (map cadr (window-list)))
                    "the foreign pane was removed")
      (check-false! (member t--sw-third (window-tree-buffers (group-layout docs)))
                    "the healed snapshot no longer remembers it")
      (for-each
        (lambda (window)
          (check-true! (buffer-in-group? (cadr window) docs)
                       "every restored pane belongs to DOCS"))
        (window-list))
      (check-equal! (frame-group) docs "the restored frame remains homogeneous"))
    (t--sw-done!)))

(deftest 'group-switch-uses-mru-when-the-visible-frame-is-homogeneous
  "a frame already inside one group offers the other groups by recency"
  (lambda ()
    (t--sw-setup!)
    (let ((here (group-record-create! "zzsw-here"))
          (older (group-record-create! "zzsw-older"))
          (recent (group-record-create! "zzsw-recent")))
      (buffer-add-group! t--sw-first here)
      (buffer-add-group! t--sw-second here)
      (set-frame-local! 'current-group here)
      (delete-other-windows!)
      (switch-to-buffer! t--sw-first)
      (split-window! 'h 0.5)
      (other-window!)
      (switch-to-buffer! t--sw-second)
      (mru-note-group! older)
      (mru-note-group! recent)
      (mru-note-group! here)

      (check-true! (group-visible-homogeneous? here) "the shared predicate sees one group")
      (run-command "group-switch")
      (check-equal! (t--sw-selected) "zzsw-recent" "the most recent other group leads")
      (check-true! (< (t--sw-at "zzsw-recent") (t--sw-at "zzsw-older"))
                   "the other groups keep MRU order")
      (check-false! (member "zzsw-here" (t--sw-labels))
                    "the current group is not a destination"))
    (t--sw-done!)))

(deftest 'group-switch-puts-the-current-buffers-groups-first-in-a-mixed-frame
  "a foreign selected buffer makes its groups immediate destinations"
  (lambda ()
    (t--sw-setup!)
    (let ((here (group-record-create! "zzsw-here"))
          (target (group-record-create! "zzsw-target"))
          (recent (group-record-create! "zzsw-recent")))
      (buffer-add-group! t--sw-first here)
      (buffer-add-group! t--sw-second target)
      (set-frame-local! 'current-group here)
      (delete-other-windows!)
      (switch-to-buffer! t--sw-first)
      (split-window! 'h 0.5)
      (other-window!)
      (switch-to-buffer! t--sw-second)
      (mru-note-group! target)
      (mru-note-group! recent)
      (mru-note-group! here)

      (check-false! (group-visible-homogeneous? here) "the shared predicate sees the detour")
      (run-command "group-switch")
      (check-equal! (t--sw-selected) "zzsw-target" "the selected buffer's group leads")
      (check-true! (< (t--sw-at "zzsw-target") (t--sw-at "zzsw-recent"))
                   "the buffer's group outranks a newer unrelated group"))
    (t--sw-done!)))

(deftest 'current-group-is-derived-from-every-visible-work-buffer
  "homogeneous windows establish a context and a foreign window clears it"
  (lambda ()
    (t--sw-setup!)
    (let ((here (group-record-create! "zzsw-here"))
          (foreign (group-record-create! "zzsw-foreign")))
      (buffer-add-group! t--sw-first here)
      (buffer-add-group! t--sw-second here)
      (buffer-add-group! t--sw-third foreign)
      (switch-to-buffer! t--sw-first)
      (check-equal! (frame-group) here "one grouped window establishes its group")

      (split-window! 'h 0.5)
      (other-window!)
      (switch-to-buffer! t--sw-second)
      (check-equal! (frame-group) here "two members keep the shared group")

      (switch-to-buffer! t--sw-third)
      (check-false! (frame-group) "a foreign visible buffer makes the frame mixed")

      (delete-window!)
      (check-equal! (frame-group) here "removing the foreign window restores homogeneity"))
    (t--sw-done!)))

(deftest 'current-group-keeps-a-common-membership-across-shared-work
  "the previous common group wins when every visible buffer shares several groups"
  (lambda ()
    (t--sw-setup!)
    (let ((first (group-record-create! "zzsw-common-first"))
          (second (group-record-create! "zzsw-common-second")))
      (for-each
        (lambda (buf)
          (buffer-add-group! buf first)
          (buffer-add-group! buf second))
        (list t--sw-first t--sw-second))
      (switch-to-buffer! t--sw-first)
      (set-frame-local! 'current-group second)
      (split-window! 'h 0.5)
      (other-window!)
      (switch-to-buffer! t--sw-second)
      (check-equal! (frame-group) second "the existing common group remains current"))
    (t--sw-done!)))

(deftest 'transient-buffers-do-not-change-current-group
  "a transient interface pane does not participate in homogeneity"
  (lambda ()
    (t--sw-setup!)
    (let ((here (group-record-create! "zzsw-here")))
      (buffer-add-group! t--sw-first here)
      (buffer-set-local! t--sw-second 'transient #t)
      (switch-to-buffer! t--sw-first)
      (split-window! 'h 0.5)
      (other-window!)
      (switch-to-buffer! t--sw-second)
      (check-equal! (frame-group) here "the transient pane is ignored"))
    (t--sw-done!)))

(deftest 'context-confirm-on-an-ungrouped-buffer-starts-a-group
  "C-RET turns a new entrant into an explicit context"
  (lambda ()
    (t--sw-setup!)
    (let ((here (group-record-create! "zzsw-here")))
      (buffer-add-group! t--sw-first here)
      (switch-to-buffer! t--sw-first)
      (t--sw-open-all!)
      (t--sw-type! t--sw-third)
      (t--sw-key! "confirm-context")
      (t--sw-type! "zzsw-started")
      (t--sw-key! "confirm")

      (let ((started (group-resolve-id "zzsw-started")))
        (check-true! started "a group was created")
        (check-true! (buffer-in-group? t--sw-third started) "the picked buffer joined it")
        (check-equal! (frame-group) started "the new context was entered")
        (check-equal! (current-buffer) t--sw-third "the picked buffer has focus")))
    (t--sw-done!)))

(deftest 'switch-to-group-previews-the-group-under-the-highlight
  "moving the highlight shows the group's most recent member"
  (lambda ()
    (t--sw-setup!)
    (let ((here (group-record-create! "zzsw-peek-here"))
          (there (group-record-create! "zzsw-peek-there")))
      (buffer-add-group! t--sw-first here)
      (buffer-add-group! t--sw-second there)
      (buffer-add-group! t--sw-third there)
      (set-frame-local! 'current-group here)
      (switch-to-buffer! t--sw-third)
      (switch-to-buffer! t--sw-second)
      (switch-to-buffer! t--sw-first)
      (mru-note-group! there)
      (mru-note-group! here)

      (run-command "group-switch")
      (t--sw-type! "zzsw-peek-there")
      ;; the look waits for the highlight to rest
      (check-true!
        (wait-until (lambda () (equal? (cadr (car (window-list))) t--sw-second)) 1000 10)
        "the window shows the group's leading member")
      (check-equal! (car (buffer-list-mru)) t--sw-first
                    "and the preview moved no history")

      (t--sw-key! "cancel")
      (check-equal! (cadr (car (window-list))) t--sw-first
                    "cancelling puts the buffer you came from back"))
    (t--sw-done!)))

(deftest 'switch-to-group-enters-the-group-it-previewed
  "the peek is a look; RET is the switch, and it saves the layout you had"
  (lambda ()
    (t--sw-setup!)
    (let ((here (group-record-create! "zzsw-enter-here"))
          (there (group-record-create! "zzsw-enter-there")))
      (buffer-add-group! t--sw-first here)
      (buffer-add-group! t--sw-second there)
      (set-frame-local! 'current-group here)
      (switch-to-buffer! t--sw-second)
      (switch-to-buffer! t--sw-first)

      (run-command "group-switch")
      (t--sw-type! "zzsw-enter-there")
      (t--sw-key! "confirm")

      (check-equal! (frame-group) there "the previewed group was entered")
      (check-equal! (current-buffer) t--sw-second "its member has focus")
      (check-equal! (window-tree-buffers (group-layout here)) (list t--sw-first)
                    "the group you left kept the arrangement you worked in"))
    (t--sw-done!)))

(deftest 'switch-to-group-can-move-the-current-buffer-into-a-new-context
  "the explicit action replaces memberships with the new group"
  (lambda ()
    (t--sw-setup!)
    (let ((source (group-record-create! "zzsw-source"))
          (kept (group-record-create! "zzsw-kept")))
      (buffer-add-group! t--sw-first source)
      (buffer-add-group! t--sw-first kept)
      (switch-to-buffer! t--sw-first)
      (set-frame-local! 'current-group source)
      (run-command "group-switch")
      (t--sw-type! "Move this buffer into a new group")
      (t--sw-key! "confirm")
      (t--sw-type! "zzsw-moved")
      (t--sw-key! "confirm")

      (let ((moved (group-resolve-id "zzsw-moved")))
        (check-true! (buffer-in-group? t--sw-first moved) "the destination was added")
        (check-false! (buffer-in-group? t--sw-first source) "the visible source was removed")
        (check-false! (buffer-in-group? t--sw-first kept) "the old membership is removed")
        (check-equal! (frame-group) moved "the new group was entered")))
    (t--sw-done!)))

(deftest 'killing-a-visible-group-buffer-never-shows-a-foreign-buffer
  "a grouped frame replaces a killed member from that group only"
  (lambda ()
    (t--sw-setup!)
    (let ((here (group-record-create! "zzsw-here"))
          (foreign (group-record-create! "zzsw-foreign")))
      (buffer-add-group! t--sw-first here)
      (buffer-add-group! t--sw-second here)
      (buffer-add-group! t--sw-third foreign)
      (set-frame-local! 'current-group here)
      (switch-to-buffer! t--sw-third)
      (switch-to-buffer! t--sw-first)
      (split-window! 'h 0.5)
      (switch-to-buffer! t--sw-second)

      (buffer-kill! t--sw-second)

      (check-false! (member t--sw-third (map cadr (window-list)))
                    "the foreign MRU buffer stayed hidden")
      (for-each
        (lambda (row)
          (check-true! (buffer-in-group? (cadr row) here)
                       "every visible replacement belongs to the current group"))
        (window-list)))
    (t--sw-done!)))

(deftest 'a-pinned-empty-group-lands-on-its-chat-after-the-final-kill
  "the group chat is the total fallback when no live member remains"
  (lambda ()
    (t--sw-setup!)
    (let ((here (group-record-create! "zzsw-empty-pinned")))
      (buffer-add-group! t--sw-first here)
      (set-frame-local! 'current-group here)
      (set-frame-local! 'pinned-group here)

      (buffer-kill! t--sw-first)

      (let ((fallback (current-buffer)))
        (check-equal! fallback (group-chat here)
                      "the empty pinned group lands on its chat")
        (check-true! (chat-buffer? fallback)
                     "the fallback is a live chat buffer")
        (check-equal! (chat-group-id fallback) here
                      "the fallback belongs to the pinned group")
        (set-frame-local! 'pinned-group #f)
        (set-frame-local! 'current-group #f)
        (buffer-kill! fallback)))
    (t--sw-done!)))

(deftest 'group-pin-keeps-context-without-adopting-foreign-work
  "a pin survives display and kill changes while foreign membership stays unchanged"
  (lambda ()
    (t--sw-setup!)
    (let ((here (group-record-create! "zzsw-pin-here"))
          (foreign (group-record-create! "zzsw-pin-foreign")))
      (buffer-add-group! t--sw-first here)
      (buffer-add-group! t--sw-second here)
      (buffer-add-group! t--sw-third foreign)
      (switch-to-buffer! t--sw-first)
      (set-frame-local! 'current-group here)
      (run-command "group-pin")

      (switch-to-buffer! t--sw-third)
      (check-equal! (group-pinned) here "the frame keeps the pin")
      (check-equal! (frame-group) here "foreign display does not move current-group")
      (check-false! (buffer-in-group? t--sw-third here)
                    "the foreign buffer does not join the pinned group")
      (check-false! (group-visible-homogeneous? here)
                    "the foreign layout is not saved as homogeneous")

      (buffer-kill! t--sw-third)
      (check-equal! (frame-group) here "the kill keeps the pinned context")
      (check-true! (buffer-in-group? (current-buffer) here)
                   "the replacement comes from the pinned group"))
    (t--sw-done!)))

(deftest 'group-pin-toggle-releases-and-explicit-switch-moves-the-pin
  "the command releases a pin, and a deliberate group switch retargets it"
  (lambda ()
    (t--sw-setup!)
    (let ((first (group-record-create! "zzsw-pin-first"))
          (second (group-record-create! "zzsw-pin-second")))
      (buffer-add-group! t--sw-first first)
      (buffer-add-group! t--sw-second second)
      (switch-to-buffer! t--sw-first)
      (set-frame-local! 'current-group first)
      (run-command "group-pin")
      (switch-to-group! second)
      (check-equal! (group-pinned) second "an explicit switch moves the pin")

      (switch-to-buffer! t--sw-first)
      (check-equal! (frame-group) second "the moved pin still holds")
      (run-command "group-pin")
      (check-false! (group-pinned) "the second command releases the pin")
      (check-equal! (frame-group) first "release derives context from visible work"))
    (t--sw-done!)))

;;; --- leaving a group by a foreign pane ------------------------------------------

(deftest 'a-foreign-pane-saves-the-layout-it-leaves-and-the-switch-back-restores-it
  "showing an ungrouped buffer in a pane saves the group's layout as it is; a switch away and back finds it"
  (lambda ()
    (t--sw-setup!)
    (let ((home (group-record-create! "zzsw-seal-home"))
          (away (group-record-create! "zzsw-seal-away")))
      (buffer-add-group! t--sw-first home)
      (buffer-add-group! t--sw-second home)
      (buffer-add-group! t--sw-third away)
      (switch-to-buffer! t--sw-first)
      (split-window! 'h 0.5)
      (other-window!)
      (switch-to-buffer! t--sw-second)
      (group-current-recalculate!)
      (check-equal! (frame-group) home "two panes in one group put the frame in it")
      ;; a third pane shows a buffer in no group: the frame leaves the group
      (split-window! 'v 0.5)
      (other-window!)
      (let ((foreign (test-buffer! "zz-sw-seal-foreign" "")))
        ;; a work buffer in no group: creation joined the destination, so
        ;; take it out; a transient pane would say nothing
        (buffer-set-local! foreign 'transient #f)
        (for-each (lambda (id) (buffer-remove-group! foreign id))
                  (buffer-group-ids foreign))
        (switch-to-buffer! foreign)
        (group-current-recalculate!)
        (check-false! (frame-group) "the foreign pane takes the frame out of the group")
        (let ((tree (window-tree)))
          (check-equal! (group-layout home) tree "the layout was saved as it stood, foreign pane included")
          (check-equal! (frame-local 'previous-group) home "and the group left is remembered")
          ;; away and back: the arrangement returns
          (switch-to-group! away)
          (check-equal! (length (window-list)) 1 "the other group shows its own one pane")
          (switch-to-group! home)
          (check-equal! (length (window-list)) 3 "coming back restores the three panes")
          ;; sealed: the pane that showed the foreign buffer is a blank
          ;; pane now, the group's scratch, and the foreign buffer is out
          (check-false! (window-showing foreign) "the foreign buffer is not shown")
          (check-true! (let loop ((ws (window-list)))
                         (cond ((null? ws) #f)
                               ((string-prefix? "*scratch:" (cadr (car ws))) #t)
                               (else (loop (cdr ws)))))
                       "its pane shows the group's scratch"))
        (buffer-kill! foreign)
        (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
                  (group-buffers-as home 'scratch))))
    (t--sw-done!)))
