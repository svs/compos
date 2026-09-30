;;; group-switch-test.scm --- the switcher, by the commands it runs.
;;;
;;; The switcher's prompt form (ibuffer-prompt) reads the same
;;; rows as the modal. Typing is (minibuffer-change! TEXT), and every
;;; key it answers to is a command: minibuffer-confirm for RET,
;;; minibuffer-confirm-context for C-RET, minibuffer-collect for
;;; C-c C-o, minibuffer-next-candidate for C-n. Nothing here presses a
;;; key.

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
  (when (float-open?) (float-close!))
  (for-each
    (lambda (b)
      (test-buffer! b "")
      (buffer-set-local! b 'buffer-selected #f)
      (buffer-set-local! b 'scratch-buffer #f)
      (buffer-set-local! b 'scratch-owner #f)
      (buffer-set-local! b 'scratch-from #f)
      (buffer-set-local! b 'special #f))
    (list t--sw-first t--sw-second t--sw-third))
  (set! *group-records* '())
  (set! *group-mru* '())
  (set! *group-next-id* 0)
  ;; these tests read a free frame; the default target has its own
  (layout-target-free!)
  (set-frame-local! 'current-group #f)
  (set-frame-local! 'previous-group #f)
  (set-frame-local! 'pinned-group #f)
  (delete-other-windows!)
  (switch-to-buffer! t--sw-first)
  ;; An id is "grp:SECOND:N", and N starts at 0 here, so a group of this
  ;; test can wear the id of a group of the last test. A scratch or a chat
  ;; that test left, and a membership the three buffers still hold,
  ;; would then pass for this test's own. Take them away.
  (for-each (lambda (b)
              (when (or (string-prefix? "*scratch:zzsw" b) (string-prefix? "*chat:zzsw" b))
                (buffer-kill! b)))
            (buffer-list))
  ;; The record table is deliberately empty here. buffer-group-ids only
  ;; returns resolving IDs, so removing through that accessor leaves stale
  ;; raw IDs behind. Reused per-second IDs then make a later fixture a member.
  (for-each (lambda (b)
              (buffer-set-local! b 'group-ids '())
              (buffer-set-local! b 'group #f)
              (buffer-set-local! b 'group-inherited #f)
              (buffer-set-local! b 'companion-of #f))
            (list t--sw-first t--sw-second t--sw-third)))

(define (t--sw-done!)
  (when (minibuffer-state) (minibuffer-cancel!))
  (layout-target-set! #f)
  (set-frame-local! 'current-group #f)
  (set-frame-local! 'previous-group #f)
  (set-frame-local! 'pinned-group #f)
  (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
            (list t--sw-first t--sw-second t--sw-third))
  (set! *group-records* '())
  (set! *group-next-id* 0)
  (delete-other-windows!))

;; show BUF in the selected window whatever its group: the mechanism a
;; layout uses. A test that puts a foreign buffer in a pane on purpose
;; calls this; a switch would float the buffer in the popup.
(define (t--sw-show-here! buf) (switch-to-buffer-here! buf))

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

(define (t--sw-open-switcher!) (run-command "ibuffer-prompt"))
(define (t--sw-open-all!) (run-command "ibuffer-prompt"))

;; every heading the rows can carry; none of them is a choice
(define t--sw-headings
  '("in this group" "other groups" "groups" "ungrouped" "zzsw-foreign" "recent"))

(deftest 'ibuffer-prompt-opens-the-candidate-prompt
  "C-x b opens the prompt under the switcher's name"
  (lambda ()
    (t--sw-setup!)
    (t--sw-open-switcher!)
    (check-true! (minibuffer-state) "the prompt opened")
    (check-true! (string-prefix? "Switch to" (plist-get (minibuffer-state) 'prompt))
                 "the buffer switcher owns the prompt")
    (t--sw-done!)))

(deftest 'the-switcher-pool-follows-the-invoking-window-history
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
        (let ((pool (filter (lambda (b) (member b (list t--sw-second t--sw-third noise)))
                            (map car (switch-sectioned-rows t--sw-first #f window)))))
          (check-equal! (car pool) t--sw-third "the last buffer in this window leads")
          (check-equal! (cadr pool) t--sw-second "the older buffer follows it")
          (check-equal! (caddr pool) noise "the other window's buffer comes last")))
      (buffer-kill! noise))
    (t--sw-done!)))

(deftest 'the-switcher-lists-the-buffer-you-are-on-but-never-leads-with-it
  "you came to see the whole group; RET on an empty input still goes elsewhere"
  (lambda ()
    (t--sw-setup!)
    (switch-to-buffer! t--sw-second)
    (switch-to-buffer! t--sw-first)
    (let* ((window (active-window))
           (rows (switch-buffer-only-rows
                   (switch-sectioned-rows t--sw-first #f window)))
           (buffers (filter (lambda (e) (not (switch-separator? #f e))) rows)))
      (check-true! (and (member t--sw-first (map car buffers)) #t)
                   "the buffer you are on is a candidate")
      (check-equal! (car (car (reverse buffers))) t--sw-first
                    "and it comes last: it never leads")
      (check-equal! (switch-first-choice rows t--sw-first) t--sw-second
                    "so the empty-input default is the buffer you were on before"))
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

(deftest 'new-from-a-selection-takes-the-buffers-and-the-layout
  "group-new on marked buffers takes the arrangement, and the buffers with it"
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
        (check-false! (buffer-in-group? t--sw-first old) "the old membership is left behind")
        (check-equal! (buffer-group-ids t--sw-first) (list id) "the new one is the only one")
        (check-true! (buffer-in-group? t--sw-second id) "the other selected buffer joins")
        (check-equal! (frame-local 'current-group) id "the frame stands in it")
        (check-equal! (window-tree-buffers (group-layout id)) (window-tree-buffers (window-tree))
                      "and it remembers this layout")
        (check-false! (buffer-local t--sw-first 'buffer-selected)
                      "the mark that chose the buffer is spent")
        (check-false! (buffer-local t--sw-second 'buffer-selected)
                      "and so is the other one")))
    (t--sw-done!)))

(deftest 'a-spent-selection-does-not-found-the-next-group
  "new founds a place to work: the mark is spent, so the next new is empty"
  (lambda ()
    (t--sw-setup!)
    (buffer-set-local! t--sw-first 'buffer-selected #t)
    (run-command "group-new")
    (t--sw-type! "zzsw-seeded")
    (t--sw-key! "confirm")

    (run-command "group-new")
    (t--sw-type! "zzsw-after")
    (t--sw-key! "confirm")

    (let ((seeded (group-resolve-id "zzsw-seeded"))
          (after (group-resolve-id "zzsw-after")))
      (check-true! (buffer-in-group? t--sw-first seeded) "the seed founded the first group")
      (check-false! (buffer-in-group? t--sw-first after)
                    "and the buffer you were in did not follow into the second")
      (check-equal! (filter group-work-buffer? (group-buffers after)) '()
                    "the second group starts empty"))
    (buffer-set-local! t--sw-first 'buffer-selected #f)
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
    (buffer-set-local! t--sw-first 'special #t)
    (run-command "group-new")
    (t--sw-type! "zzsw-empty-context")
    (t--sw-key! "confirm")
    (buffer-set-local! t--sw-first 'special #f)
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
    (t--sw-show-here! t--sw-first)
    (buffer-set-local! t--sw-first 'buffer-selected #t)
    (run-command "group-new")
    (t--sw-type! "zzsw-active-one")
    (t--sw-key! "confirm")
    (t--sw-show-here! t--sw-second)
    (buffer-set-local! t--sw-second 'buffer-selected #t)
    (run-command "group-new")
    (t--sw-type! "zzsw-active-two")
    (t--sw-key! "confirm")
    ;; an empty group: group-new seeds nothing from a transient buffer
    (buffer-set-local! t--sw-second 'special #t)
    (run-command "group-new")
    (t--sw-type! "zzsw-active-empty")
    (t--sw-key! "confirm")
    (buffer-set-local! t--sw-second 'special #f)
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
  (t--sw-show-here! t--sw-second)
  (buffer-set-local! t--sw-second 'buffer-selected #t)
  (run-command "group-new")
  (t--sw-type! two-name)
  (t--sw-key! "confirm")
  (t--sw-show-here! t--sw-first)
  (buffer-set-local! t--sw-first 'buffer-selected #t)
  (run-command "group-new")
  (t--sw-type! one-name)
  (t--sw-key! "confirm")
  (split-window! 'v)
  (t--sw-show-here! t--sw-third)
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

;;; --- the window of a killed buffer stays in its group ----------------------------

(define (t--sw-kill-frame! name)
  ;; one group, two windows: first on the left, second on the right,
  ;; the frame standing in the group
  (let ((id (group-record-create! name)))
    (buffer-add-group! t--sw-first id)
    (buffer-add-group! t--sw-second id)
    (set-frame-local! 'current-group id)
    (delete-other-windows!)
    (switch-to-buffer! t--sw-first)
    (split-window! 'h 0.5)
    (other-window!)
    (switch-to-buffer! t--sw-second)
    id))

(deftest 'a-killed-buffers-window-shows-the-member-it-showed-before
  "the window stays and refills from its own past, most recent member first"
  (lambda ()
    (t--sw-setup!)
    (let* ((id (t--sw-kill-frame! "zzsw-kill-member"))
           (win (active-window)))
      (buffer-add-group! t--sw-third id)
      (switch-to-buffer! t--sw-third)
      (switch-to-buffer! t--sw-second)
      (check-equal! (car (window-prev-buffers win)) t--sw-third "the window showed third before")
      (buffer-kill! t--sw-second)
      (check-equal! (length (window-list)) 2 "the window stays")
      (check-true! (window-exists? win) "the same window")
      (check-equal! (window-buffer win) t--sw-third "and shows the member it showed before")
      (check-equal! (active-window) win "the selection stays in it")
      (let ((chat (group-chat id)))
        (when (buffer-known? chat) (buffer-kill! chat))))
    (t--sw-done!)))

(deftest 'a-killed-buffers-window-shows-the-groups-last-chat
  "the window's past leads with the member the other window shows, so the group's chat takes the place"
  (lambda ()
    (t--sw-setup!)
    (let* ((id (t--sw-kill-frame! "zzsw-kill-chat"))
           (chat (group-chat id))
           (win (active-window)))
      (check-equal! (window-buffer win) t--sw-second "the window shows the victim")
      (check-equal! (car (window-prev-buffers win)) t--sw-first
                    "its past leads with first, which the left window shows")
      (buffer-kill! t--sw-second)
      (check-equal! (length (window-list)) 2 "the window stays")
      (check-true! (window-exists? win) "the same window")
      (check-equal! (window-buffer win) chat "and shows the group's chat")
      (check-equal! (active-window) win "the selection stays in it")
      (when (buffer-known? chat) (buffer-kill! chat)))
    (t--sw-done!)))

(deftest 'a-killed-buffers-window-shows-the-group-chat-without-a-member
  "no member left: the group's chat takes the place, never a scratch or a foreign buffer"
  (lambda ()
    (t--sw-setup!)
    (let ((foreign "zz-sw-foreign"))
      (test-buffer! foreign "")
      (let* ((id (t--sw-kill-frame! "zzsw-kill-scratch"))
             (win (active-window)))
        (buffer-kill! t--sw-second)
        (check-equal! (length (window-list)) 2 "the window stays")
        (let ((shown (window-buffer win)))
          (check-false! (group-scratch-buffer? shown) "not a scratch")
          (check-true! (and (chat-buffer? shown) (equal? (chat-group-id shown) id))
                       "but the group's chat")
          (check-false! (equal? shown foreign) "not the foreign buffer")
          (when (buffer-known? shown) (buffer-kill! shown))))
      (buffer-kill! foreign))
    (t--sw-done!)))

(deftest 'a-killed-buffer-in-a-dying-group-closes-its-window
  "a group with no chat and no scratch left gives the window up"
  (lambda ()
    (t--sw-setup!)
    (let* ((id (t--sw-kill-frame! "zzsw-kill-dying"))
           (win (active-window)))
      (set! *group-dying* id)
      (buffer-kill! t--sw-second)
      (set! *group-dying* #f)
      (check-equal! (length (window-list)) 1 "the window closed")
      (check-false! (window-exists? win) "that window")
      (check-equal! (current-buffer) t--sw-first "the other window remains"))
    (t--sw-done!)))

(deftest 'a-killed-group-revives-with-the-members-that-still-exist
  "revive makes the record again; a member whose buffer and file are gone is missing"
  (lambda ()
    (t--sw-setup!)
    (set! *group-graveyard* '())
    (t--sw-two-groups! "zzsw-rev-one" "zzsw-rev-two")
    (let ((two (group-resolve-id "zzsw-rev-two")))
      ;; a member belongs to ONE group, so no member is spared by living
      ;; somewhere else too: the record, its color, and every member that
      ;; still exists as a buffer or a file are what a revival brings back
      (let ((color (group-record-color (group-record-by-id two))))
        (run-command "group-kill")
        (check-false! (group-resolve-id "zzsw-rev-two") "the group is gone")
        (check-equal! (car (car *group-graveyard*)) "zzsw-rev-two" "and lies in the graveyard")
        (check-true! (group-revive! "zzsw-rev-two") "revive answers the new id")
        (let ((again (group-resolve-id "zzsw-rev-two")))
          (check-true! again "the record is back")
          (check-equal! (group-record-color (group-record-by-id again)) color
                        "with its color")
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

      (t--sw-show-here! t--sw-third)
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

(deftest 'add-moves-the-buffer-family-to-the-destination
  "a buffer holds one group, so add puts the family there and leaves the source"
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

      (check-false! (buffer-in-group? t--sw-first source) "the source membership is left")
      (check-equal! (buffer-group-ids t--sw-first) (list destination)
                    "the destination is the only membership")
      (check-equal! (frame-group) destination
                    "the visible buffer takes the frame with it")
      (check-equal! (current-buffer) t--sw-first "the command does not change windows"))
    (t--sw-done!)))

(deftest 'add-can-create-a-destination-by-name
  "a typed destination creates one group and puts the current buffer in it"
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
        (check-equal! (buffer-group-ids t--sw-first) (list created)
                      "the buffer joins it, and only it")
        (check-false! (buffer-in-group? t--sw-first source) "the source is left")
        (check-equal! (frame-group) created
                      "the visible buffer takes the frame with it")))
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
        ;; The home buffer (first) is a row too; this test marks only the
        ;; two other buffer rows.
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
  "move needs one destination, leaves the buffer in only that group, and enters it"
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
      (check-equal! (frame-group) destination
                    "move enters the destination group")
      (check-true! (buffer-known? t--sw-first) "move keeps the buffer alive"))
    (t--sw-done!)))

(deftest 'move-never-asks-for-a-source-group
  "the buffer's own group is not a question; only the destination is"
  (lambda ()
    (t--sw-setup!)
    (let ((first (group-record-create! "zzsw-first-source"))
          (second (group-record-create! "zzsw-second-source"))
          (destination (group-record-create! "zzsw-destination")))
      (buffer-add-group! t--sw-first second)
      (switch-to-buffer! t--sw-first)
      (set-frame-local! 'current-group #f)
      (run-command "group-move")

      (check-equal! (plist-get (minibuffer-state) 'prompt) "Move buffer to group: "
                    "the first prompt asks for the destination")
      (t--sw-type! "zzsw-destination")
      (t--sw-key! "confirm")

      (check-false! (buffer-in-group? t--sw-first first) "a group it never joined stays empty")
      (check-false! (buffer-in-group? t--sw-first second) "the old group is removed")
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

(deftest 'a-move-into-the-group-on-screen-keeps-the-layout
  "the group adopts the panes as they stand: a move changes membership alone"
  (lambda ()
    (t--sw-setup!)
    (let ((home (group-record-create! "zzsw-layout-home")))
      (buffer-add-group! t--sw-first home)
      (buffer-add-group! t--sw-second home)
      (switch-to-group! home)
      (delete-other-windows!)
      (t--sw-show-here! t--sw-first)
      (split-window! 'h 0.5)
      (other-window!)
      (t--sw-show-here! t--sw-second)
      (let ((older (window-tree)))
        ;; the person makes a third column and works in it, on a buffer no
        ;; group owns
        (split-window! 'h 0.5)
        (other-window!)
        (t--sw-show-here! t--sw-third)
        ;; the group remembers the two panes it had before the third column.
        ;; A move must not answer from that memory: the screen is newer.
        (group-layout-set! home older (layout-target))
        (let ((before (window-tree))
              (panes (length (window-list))))
          (winner--pre-command!)
          (run-command "group-move")
          (t--sw-type! "zzsw-layout-home")
          (t--sw-key! "confirm")
          ;; the move completes: the change is recorded
          (winner--post-command!)

          (check-true! (buffer-in-group? t--sw-third home)
                       "the moved buffer joins the group")
          (check-equal! (length (window-list)) panes
                        "the move keeps the number of panes")
          (check-equal! (window-tree) before
                        "the move keeps the arrangement the person made")
          (for-each
            (lambda (buf)
              (check-true! (member buf (layout-visible-buffers))
                           (string-append buf " left the screen")))
            (list t--sw-first t--sw-second t--sw-third))
          (check-equal! (frame-group) home "the frame stands in the group")
          (check-equal! (window-tree-buffers (group-layout home)) (window-tree-buffers before)
                        "and the group remembers the arrangement it adopted"))))
    (t--sw-done!)))

(deftest 'the-group-scratch-moves-and-removes-as-its-own-buffer
  "the group's shared scratch moves and removes like any work buffer"
  (lambda ()
    (t--sw-setup!)
    (let ((source (group-record-create! "zzsw-scratch-home"))
          (other (group-record-create! "zzsw-scratch-other"))
          (destination (group-record-create! "zzsw-scratch-away")))
      (buffer-add-group-as! t--sw-second source 'scratch)
      (buffer-add-group-as! t--sw-second other 'scratch)
      (switch-to-buffer! t--sw-second)
      (run-command "group-move")
      (t--sw-type! "zzsw-scratch-away")
      (t--sw-key! "confirm")
      (check-true! (buffer-in-group? t--sw-second destination)
                   "the scratch reaches the destination")
      (check-false! (buffer-in-group? t--sw-second source)
                    "the scratch leaves its first group")
      (check-false! (buffer-in-group? t--sw-second other)
                    "the scratch leaves its second group")
      (run-command "remove-group-from-buffer")
      (t--sw-type! "zzsw-scratch-away")
      (t--sw-key! "confirm")
      (t--sw-key! "cancel")
      (check-false! (buffer-in-group? t--sw-second destination)
                    "remove drops the chosen membership")
      (check-equal! (buffer-group-ids t--sw-second) '()
                    "the scratch keeps no membership"))
    (t--sw-done!)))

(deftest 'a-chat-moves-to-another-group
  "a chat leaves its group like any member, and it travels alone"
  (lambda ()
    (t--sw-setup!)
    (let* ((source (group-record-create! "zzsw-chat-home"))
           (destination (group-record-create! "zzsw-chat-away"))
           (chat (group-chat source))
           (id-before (chat-stable-id! chat)))
      (buffer-add-group! t--sw-first source)
      (switch-to-buffer! chat)
      (run-command "group-move")
      (t--sw-type! "zzsw-chat-away")
      (t--sw-key! "confirm")
      (let ((moved chat))
        (check-true! (buffer-known? moved)
                     "the chat keeps its name through the move")
        (check-equal! (buffer-local moved 'chat-id) id-before
                      "it is the same chat buffer, not a new one")
        (check-equal! (chat-group-id moved) destination
                      "the chat belongs to the destination")
        (check-true! (buffer-in-group? t--sw-first source)
                     "the source keeps its work buffer")
        (check-false! (buffer-in-group? t--sw-first destination)
                      "no member travelled with the chat")
        (when (buffer-known? moved) (buffer-kill! moved))))
    (t--sw-done!)))

(deftest 'a-chat-removes-its-own-group
  "remove on a chat drops its membership and touches no member"
  (lambda ()
    (t--sw-setup!)
    (let* ((source (group-record-create! "zzsw-chat-drop"))
           (chat (group-chat source)))
      (buffer-add-group! t--sw-first source)
      (switch-to-buffer! chat)
      (run-command "remove-group-from-buffer")
      (t--sw-type! "zzsw-chat-drop")
      (t--sw-key! "confirm")
      (t--sw-key! "cancel")
      (check-false! (chat-group-id chat) "the chat holds no group")
      (check-true! (buffer-in-group? t--sw-first source)
                   "the group keeps its work buffer")
      (when (buffer-known? chat) (buffer-kill! chat)))
    (t--sw-done!)))

(deftest 'move-includes-the-explicit-transient-work-buffer
  "moving a Dired-like listing moves the listing itself"
  (lambda ()
    (t--sw-setup!)
    (let ((source (group-record-create! "zzsw-transient-source"))
          (destination (group-record-create! "zzsw-transient-destination")))
      ;; Dired listings are transient for current-group derivation, but the
      ;; listing itself is still the explicit buffer the move command names.
      (buffer-set-local! t--sw-first 'special #t)
      (buffer-add-group! t--sw-first source)
      (switch-to-buffer! t--sw-first)
      (run-command "group-move")
      (t--sw-type! "zzsw-transient-destination")
      (t--sw-key! "confirm")
      (check-false! (buffer-in-group? t--sw-first source)
                    "the listing leaves the source")
      (check-true! (buffer-in-group? t--sw-first destination)
                   "the listing reaches the destination"))
    (t--sw-done!)))

(deftest 'a-lone-move-leaves-the-group-scratch-behind
  "moving one member does not drag the group's shared scratch along"
  (lambda ()
    (t--sw-setup!)
    (let ((source (group-record-create! "zzsw-keeps-scratch"))
          (destination (group-record-create! "zzsw-gains-doc")))
      (buffer-add-group! t--sw-first source)
      (buffer-add-group-as! t--sw-second source 'scratch)
      (switch-to-buffer! t--sw-first)
      (run-command "group-move")
      (t--sw-type! "zzsw-gains-doc")
      (t--sw-key! "confirm")
      (check-true! (buffer-in-group? t--sw-first destination)
                   "the document reaches the destination")
      (check-false! (buffer-in-group? t--sw-second destination)
                    "the group scratch stays out of the destination")
      (check-true! (buffer-in-group? t--sw-second source)
                   "the group scratch keeps its home group"))
    (t--sw-done!)))

(deftest 'a-failed-move-keeps-the-existing-membership
  "move changes no membership when it cannot resolve the destination"
  (lambda ()
    (t--sw-setup!)
    (let ((home (group-record-create! "zzsw-first")))
      (buffer-add-group! t--sw-first home)
      (buffer-move-family-to-group! t--sw-first "grp:missing")
      (check-equal! (buffer-group-ids t--sw-first) (list home)
                    "the failed move keeps the membership"))
    (t--sw-done!)))

(deftest 'remove-drops-the-membership-and-keeps-the-buffer
  "remove changes the membership without killing work"
  (lambda ()
    (t--sw-setup!)
    (let ((removed (group-record-create! "zzsw-removed")))
      (buffer-add-group! t--sw-first removed)
      (switch-to-buffer! t--sw-first)
      (set-frame-local! 'current-group removed)
      (run-command "remove-group-from-buffer")

      (check-equal! (plist-get (minibuffer-state) 'prompt)
                    "Toggle group removal (C-g applies): "
                    "the membership opens the picker")
      (t--sw-type! "zzsw-removed")
      (t--sw-key! "confirm")
      (check-true! (minibuffer-state) "the picker stays open after a toggle")
      (check-true! (buffer-in-group? t--sw-first removed)
                   "a toggle does not change membership before close")
      (t--sw-key! "cancel")

      (check-false! (buffer-in-group? t--sw-first removed) "the named membership is removed")
      (check-equal! (buffer-group-ids t--sw-first) '() "the buffer is left in no group")
      (check-true! (buffer-known? t--sw-first) "the buffer remains alive"))
    (t--sw-done!)))

(deftest 'remove-asks-for-a-membership-without-a-current-group
  "the buffer's own group answers, even when the frame stands in none"
  (lambda ()
    (t--sw-setup!)
    (let ((removed (group-record-create! "zzsw-null-remove")))
      (buffer-add-group! t--sw-first removed)
      (switch-to-buffer! t--sw-first)
      (set-frame-local! 'current-group #f)
      (run-command "remove-group-from-buffer")
      (check-equal! (plist-get (minibuffer-state) 'prompt)
                    "Toggle group removal (C-g applies): "
                    "the command asks before it removes")
      (t--sw-type! "zzsw-null-remove")
      (t--sw-key! "confirm")
      (check-true! (minibuffer-state) "the picker remains active")
      (check-true! (buffer-in-group? t--sw-first removed)
                   "the selection remains pending until close")
      (t--sw-key! "cancel")
      (check-false! (buffer-in-group? t--sw-first removed)
                    "the selected membership is removed"))
    (t--sw-done!)))

(deftest 'remove-picker-can-clear-a-pending-removal
  "selecting the same membership again keeps it when C-g applies the changes"
  (lambda ()
    (t--sw-setup!)
    (let ((first (group-record-create! "zzsw-toggle-first")))
      (buffer-add-group! t--sw-first first)
      (switch-to-buffer! t--sw-first)
      (run-command "remove-group-from-buffer")
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

(deftest 'remove-group-from-buffer-opens-the-staged-picker-for-one-membership
  "the compatibility command never removes the only membership immediately"
  (lambda ()
    (t--sw-setup!)
    (let ((only (group-record-create! "zzsw-only-remove")))
      (buffer-add-group! t--sw-first only)
      (switch-to-buffer! t--sw-first)
      (run-command "remove-group-from-buffer")
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
      ;; the move sweeps the source group's panes, so the window no
      ;; longer shows the moved document; stand on it again
      (switch-to-buffer! t--sw-first)
      (check-false! (buffer-in-group? t--sw-first source) "the document leaves the source")
      (check-false! (buffer-in-group? t--sw-second source) "the scratch buffer leaves the source")
      (check-false! (buffer-in-group? t--sw-first added) "the document leaves another group")
      (check-false! (buffer-in-group? t--sw-second added) "the scratch buffer leaves another group")
      (check-true! (buffer-in-group? t--sw-first moved) "the document reaches the destination")
      (check-true! (buffer-in-group? t--sw-second moved) "the scratch buffer reaches the destination")

      (set-frame-local! 'current-group moved)
      (run-command "remove-group-from-buffer")
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
    (buffer-set-local! t--sw-second 'special #t)
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
    ;; the hops build the recency order: a switch to another group's
    ;; buffer would float it, so the panes take them as a mechanism would
    (t--sw-show-here! t--sw-second)
    (t--sw-show-here! t--sw-third)
    (t--sw-show-here! t--sw-first)
    (set-frame-local! 'current-group current)
    (list current foreign)))

(deftest 'the-buffer-prompt-lists-the-pool-flat-with-the-buffer-you-are-on-last
  "ibuffer-prompt is the plain list: the window's history first, then the rest, the buffer you are on last, and no heading"
  (lambda ()
    (t--sw-setup!)
    (t--sw-three-groups!)
    (t--sw-open-all!)
    (let ((labels (t--sw-labels)))
      (check-true! (member t--sw-second labels) "a member is listed")
      (check-true! (member t--sw-third labels) "so is the stranger")
      (check-true! (member t--sw-first labels) "and so is the buffer we are in")
      (check-equal! (filter (lambda (h) (member h labels)) t--sw-headings) '()
                    "no heading is a candidate"))
    (check-equal! (filter (lambda (l) (member l (list t--sw-first t--sw-second t--sw-third)))
                          (t--sw-labels))
                  (list t--sw-third t--sw-second t--sw-first)
                  "the window's history, most recent first, and the buffer we are in last")

    ;; typing narrows to the stranger, whatever its group
    (t--sw-type! t--sw-third)
    (check-true! (member t--sw-third (t--sw-labels)) "the stranger is reachable")
    (check-false! (member t--sw-second (t--sw-labels)) "and the rest are gone")
    (t--sw-done!)))

(deftest 'the-selection-starts-on-the-first-row-and-never-lands-on-a-heading
  "the selection starts on the most recent buffer of the window's history, and no number of steps lands on a heading"
  (lambda ()
    (t--sw-setup!)
    (t--sw-three-groups!)
    (t--sw-open-all!)
    (check-equal! (t--sw-selected) t--sw-third "the first selection is the most recent other buffer")

    (t--sw-key! "next-candidate")
    (check-true! (t--sw-selected) "the next row is a row")
    (check-false! (member (t--sw-selected) t--sw-headings)
                  "and not a heading")

    (let loop ((n 8))
      (when (> n 0) (t--sw-key! "next-candidate") (loop (- n 1))))
    (check-false! (member (t--sw-selected) t--sw-headings)
                  "nor after eight more steps")
    (t--sw-done!)))

;;; --- the modal reads the same rows ---------------------------------------------

(define (t--sw-modal-at label)
  (let loop ((es (map car (list-entries "*switch*"))) (i 0))
    (cond ((null? es) -1)
          ((equal? (car es) label) i)
          (else (loop (cdr es) (+ i 1))))))

(deftest 'the-modal-switcher-sections-by-group-name-with-this-group-first
  "switch-to-buffer in the editor: every section wears its group's name, this group leads, and a heading is never the row at point"
  (lambda ()
    (t--sw-setup!)
    (when (buffer-known? "*switch*") (buffer-kill! "*switch*"))
    (t--sw-three-groups!)
    (run-command "switch-to-buffer")
    (check-equal! (current-buffer) "*switch*" "the modal opened")
    (let ((names (map car (list-entries "*switch*"))))
      (check-true! (and (member "zzsw-current" names) #t) "the first heading is this group's name")
      (check-false! (member "in this group" names) "and not a phrase")
      (check-true! (and (member "zzsw-foreign" names) #t) "the stranger's group is the second")
      (check-true! (and (member t--sw-first names) #t) "the buffer we came from is a row too")
      (check-true! (< (t--sw-modal-at "zzsw-current") (t--sw-modal-at t--sw-second))
                   "the heading comes before its member")
      (check-true! (< (t--sw-modal-at t--sw-second) (t--sw-modal-at "zzsw-foreign"))
                   "and the member before the next heading")
      (check-true! (< (t--sw-modal-at "zzsw-foreign") (t--sw-modal-at t--sw-third))
                   "the stranger sits under its group"))
    (let ((row (list-current "*switch*")))
      (check-equal! (and row (car row)) t--sw-second "point rests on the first real row"))
    ;; narrowing to the stranger empties this group's section: its heading goes
    (list-set-query! "*switch*" t--sw-third)
    (let ((names (map car (list-keep "*switch*" (list-entries "*switch*")))))
      (check-true! (and (member t--sw-third names) #t) "the stranger survives the filter")
      (check-false! (member "zzsw-current" names) "the empty heading is gone"))
    (run-command "switch-quit")
    (when (buffer-known? "*switch*") (buffer-kill! "*switch*"))
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

(deftest 'context-confirm-enters-the-buffers-one-group
  "C-RET has nothing to guess: the buffer names one group and the frame enters it"
  (lambda ()
    (t--sw-setup!)
    (let ((here (group-record-create! "zzsw-here"))
          (there (group-record-create! "zzsw-second-choice")))
      (buffer-add-group! t--sw-first here)
      (buffer-add-group! t--sw-second there)
      (switch-to-buffer! t--sw-first)

      (t--sw-open-all!)
      (t--sw-type! t--sw-second)
      (t--sw-key! "confirm-context")

      (check-false! (minibuffer-state) "no prompt stands between C-RET and the group")
      (check-equal! (frame-group) there "the buffer's group was entered")
      (check-equal! (current-buffer) t--sw-second "the candidate has focus"))
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

(deftest 'switching-context-hides-a-foreign-pane-and-the-snapshot-keeps-its-name
  "a stale layout cannot reintroduce work that left the group; the snapshot still names it, so the layout returns whole once the buffer is a member again"
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
      ;; only a restore that reproduced the saved tree writes it back: a
      ;; sanitized one dropped a pane, and saving that would erase the
      ;; arrangement instead of hiding it (switch-to-group!)
      (check-true! (and (member t--sw-third (window-tree-buffers (group-layout docs))) #t)
                   "the snapshot still names the pane it hid")
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
      (group-mru-note! older)
      (group-mru-note! recent)
      (group-mru-note! here)

      (check-true! (group-visible-homogeneous? here) "the shared predicate sees one group")
      (define *t-sw-new-label* (car (group-switch-new-action)))
      (run-command "group-switch")
      (check-equal! (t--sw-selected) "zzsw-recent" "the recent destination leads")
      (check-equal! (t--sw-at *t-sw-new-label*) -1 "creation is a command, not a row")
      (check-true! (< (t--sw-at "zzsw-recent") (t--sw-at "zzsw-older"))
                   "the other groups keep MRU order")
      (check-true! (and (member "zzsw-here" (t--sw-labels)) #t)
                   "the group you stand in is a row too: the list shows them all")
      (check-equal! (t--sw-at "zzsw-here") 2 "current group stays last"))
    (t--sw-done!)))

(deftest 'group-mru-outranks-the-shared-history-ring
  "groups keep their own recency cache, so buffer churn cannot evict them"
  (lambda ()
    (t--sw-setup!)
    (let ((older (group-record-create! "zzsw-cache-older"))
          (recent (group-record-create! "zzsw-cache-recent")))
      (group-mru-note! older)
      (group-mru-note! recent)
      (check-equal! (take (group-mru-ids) 2) (list recent older)
                    "the cache holds group ids alone, newest first")
      ;; the shared ring still reads (recent older). Only the cache says
      ;; otherwise, and the cache is what the switcher must follow.
      (set! *group-mru* (list older recent))
      (check-equal! (filter (lambda (id) (member id (list older recent)))
                            (group-ids-mru-all))
                    (list older recent)
                    "group-ids-mru-all follows the cache, not the ring")
      (group-record-delete! older)
      (check-false! (and (member older (group-mru-ids)) #t)
                    "a deleted group leaves the cache"))
    (t--sw-done!)))

(deftest 'group-switch-preserves-mru-in-a-mixed-frame
  "current buffer context leads, then other groups by recency"
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
      (t--sw-show-here! t--sw-second)
      (group-mru-note! target)
      (group-mru-note! recent)
      (group-mru-note! here)

      (check-false! (group-visible-homogeneous? here) "the shared predicate sees the detour")
      (define *t-sw-new-label* (car (group-switch-new-action)))
      (run-command "group-switch")
      (check-equal! (t--sw-selected) "zzsw-target" "the selected buffer supplies the current context")
      (check-equal! (t--sw-at *t-sw-new-label*) -1 "creation is a command, not a row")
      (check-true! (< (t--sw-at "zzsw-here") (t--sw-at "zzsw-recent"))
                   "the remaining groups keep MRU order"))
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

      (t--sw-show-here! t--sw-third)
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

(deftest 'special-buffers-do-not-change-current-group
  "a special interface pane does not participate in homogeneity"
  (lambda ()
    (t--sw-setup!)
    (let ((here (group-record-create! "zzsw-here")))
      (buffer-add-group! t--sw-first here)
      (buffer-set-local! t--sw-second 'special #t)
      (switch-to-buffer! t--sw-first)
      (split-window! 'h 0.5)
      (other-window!)
      (switch-to-buffer! t--sw-second)
      (check-equal! (frame-group) here "the transient pane is ignored"))
    (t--sw-done!)))

(deftest 'switch-to-group-previews-the-whole-group-under-the-highlight
  "moving the highlight draws the group entire, not one buffer of it"
  (lambda ()
    (t--sw-setup!)
    (let ((style group-switch-style)
          (here (group-record-create! "zzsw-peek-here"))
          (there (group-record-create! "zzsw-peek-there")))
      ;; the default shape: a modal is a panel with the frame around it,
      ;; so it previews in the frame like every other shape
      (set! group-switch-style "modal")
      (buffer-add-group! t--sw-first here)
      (buffer-add-group! t--sw-second there)
      (buffer-add-group! t--sw-third there)
      (t--sw-show-here! t--sw-third)
      (t--sw-show-here! t--sw-second)
      (t--sw-show-here! t--sw-first)
      (set-frame-local! 'current-group here)
      (group-mru-note! there)
      (group-mru-note! here)

      (run-command "group-switch")
      (t--sw-type! "zzsw-peek-there")
      ;; the look waits for the highlight to rest
      (check-true!
        (wait-until (lambda ()
                      (let ((shown (map cadr (window-list))))
                        (and (member t--sw-second shown)
                             (member t--sw-third shown)
                             #t)))
                    1000 10)
        "every member is on screen, not the group's leading buffer alone")
      (check-equal! (car (buffer-list-mru)) t--sw-first
                    "and the preview moved no history")

      (t--sw-key! "cancel")
      (check-equal! (map cadr (window-list)) (list t--sw-first)
                    "cancelling puts the whole arrangement you came from back")
      (set! group-switch-style style))
    (t--sw-done!)))

(deftest 'a-previewed-group-shows-the-layout-it-saved
  "a group with a layout is previewed in that layout, and the look moves no history"
  (lambda ()
    (t--sw-setup!)
    (let ((style group-switch-style)
          (here (group-record-create! "zzsw-look-here"))
          (there (group-record-create! "zzsw-look-there")))
      (set! group-switch-style "popup")
      (buffer-add-group! t--sw-first here)
      (buffer-add-group! t--sw-second there)
      (buffer-add-group! t--sw-third there)
      ;; the layout the group saves when you work in it: its two members,
      ;; one above the other
      (delete-other-windows!)
      (t--sw-show-here! t--sw-second)
      (split-window! 'v 0.5)
      (other-window!)
      (t--sw-show-here! t--sw-third)
      (group-layout-save! there)
      ;; and the frame you look from: one window, your own buffer
      (delete-other-windows!)
      (t--sw-show-here! t--sw-first)
      (set-frame-local! 'current-group here)

      (let ((history (car (buffer-list-mru))))
        (run-command "group-switch")
        (t--sw-type! "zzsw-look-there")
        (check-true!
          (wait-until (lambda () (equal? (map cadr (window-list))
                                        (list t--sw-second t--sw-third)))
                      1000 10)
          "the preview is the group's own saved layout, pane for pane")
        (check-equal! (car (buffer-list-mru)) history
                      "and the look moved no history")

        (t--sw-key! "cancel")
        (check-equal! (map cadr (window-list)) (list t--sw-first)
                      "cancelling puts back the frame you came from"))
      (set! group-switch-style style))
    (t--sw-done!)))

(deftest 'a-previewed-group-drops-panes-it-no-longer-holds
  "a saved layout naming a foreign buffer previews the group, not the stale pane"
  (lambda ()
    (t--sw-setup!)
    (let ((style group-switch-style)
          (here (group-record-create! "zzsw-stale-here"))
          (there (group-record-create! "zzsw-stale-there")))
      (set! group-switch-style "popup")
      (buffer-add-group! t--sw-first here)
      (buffer-add-group! t--sw-second there)
      ;; the layout `there` saved: one pane its own, one pane a buffer that
      ;; was never a member. A switch sanitizes that pane away, so the look
      ;; must too, or it shows buffers the group does not hold
      (delete-other-windows!)
      (t--sw-show-here! t--sw-second)
      (split-window! 'v 0.5)
      (other-window!)
      (t--sw-show-here! t--sw-third)
      (group-layout-save! there)
      (delete-other-windows!)
      (t--sw-show-here! t--sw-first)
      (set-frame-local! 'current-group here)

      (run-command "group-switch")
      (t--sw-type! "zzsw-stale-there")
      ;; the look draws the saved tree and sanitizes it, in that order, so
      ;; both halves are one state to wait for: waiting on either alone
      ;; passes on a frame that has not finished drawing
      (check-true!
        (wait-until (lambda ()
                      (let ((shown (map cadr (window-list))))
                        (and (member t--sw-second shown)
                             (not (member t--sw-third shown)))))
                    1000 10)
        "the look shows the group's member, not the pane it no longer holds")

      (t--sw-key! "cancel")
      (check-equal! (map cadr (window-list)) (list t--sw-first)
                    "cancelling puts back the frame you came from")
      (set! group-switch-style style))
    (t--sw-done!)))

(deftest 'a-zero-peek-keeps-the-frame-still
  "group-switch-peek-ms 0 highlights groups without drawing a frame"
  (lambda ()
    (t--sw-setup!)
    (let ((style group-switch-style)
          (ms group-switch-peek-ms)
          (here (group-record-create! "zzsw-still-here"))
          (there (group-record-create! "zzsw-still-there")))
      (set! group-switch-style "popup")
      (set! group-switch-peek-ms 0)
      (buffer-add-group! t--sw-first here)
      (buffer-add-group! t--sw-second there)
      (delete-other-windows!)
      (t--sw-show-here! t--sw-second)
      (group-layout-save! there)
      (delete-other-windows!)
      (t--sw-show-here! t--sw-first)
      (set-frame-local! 'current-group here)

      (run-command "group-switch")
      (t--sw-type! "zzsw-still-there")
      ;; waiting for a change that must not come: longer than any look
      ;; would have taken to draw
      (check-true!
        (not (wait-until (lambda () (not (equal? (map cadr (window-list))
                                                 (list t--sw-first))))
                         300 20))
        "the frame you came from is still the frame you see")

      (t--sw-key! "cancel")
      (check-equal! (map cadr (window-list)) (list t--sw-first)
                    "and closing it moves nothing either")
      (set! group-switch-peek-ms ms)
      (set! group-switch-style style))
    (t--sw-done!)))

(deftest 'a-look-writes-no-layout
  "walking the switcher leaves every group's saved layout exactly as it was"
  (lambda ()
    (t--sw-setup!)
    (let ((style group-switch-style)
          (here (group-record-create! "zzsw-nowrite-here"))
          (there (group-record-create! "zzsw-nowrite-there")))
      (set! group-switch-style "popup")
      (buffer-add-group! t--sw-first here)
      (buffer-add-group! t--sw-second there)
      (buffer-add-group! t--sw-third there)
      ;; `there` holds a two-pane arrangement of its own members
      (delete-other-windows!)
      (t--sw-show-here! t--sw-second)
      (split-window! 'v 0.5)
      (other-window!)
      (t--sw-show-here! t--sw-third)
      (group-layout-save! there)
      ;; and `here` holds one pane, its own member
      (delete-other-windows!)
      (t--sw-show-here! t--sw-first)
      (set-frame-local! 'current-group here)
      (group-layout-save! here)

      (let ((here-was (window-tree-buffers (group-layout here)))
            (there-was (window-tree-buffers (group-layout there))))
        (run-command "group-switch")
        (t--sw-type! "zzsw-nowrite-there")
        (check-true!
          (wait-until (lambda () (equal? (map cadr (window-list))
                                        (list t--sw-second t--sw-third)))
                      1000 10)
          "the look drew the other group")
        ;; whatever the editor notices about its windows while a look is on
        ;; screen, it is looking at a look and must write nothing
        (group-current-recalculate!)
        (check-equal! (frame-group) here
                      "a look does not move the group you stand in")
        (t--sw-key! "cancel")

        (check-equal! (window-tree-buffers (group-layout here)) here-was
                      "the group you stand in kept its layout")
        (check-equal! (window-tree-buffers (group-layout there)) there-was
                      "and the group you looked at kept its own"))
      (set! group-switch-style style))
    (t--sw-done!)))

(deftest 'a-group-card-says-what-it-holds-and-no-members
  "the card's facts say the count and the shape, and name no member"
  (lambda ()
    (t--sw-setup!)
    (let ((g (group-record-create! "zzsw-facts")))
      (for-each (lambda (b) (buffer-add-group! b g))
                (list t--sw-first t--sw-second t--sw-third))
      (let* ((row (group-switch-candidate g))
             (facts (nth 5 row))
             (said (map (lambda (f) (car (cdr f))) facts))
             (members (map buffer-modeline-name (group-buffers-mru g))))
        (check-equal! (nth 2 row) "container" "the row is a container card")
        (check-equal! (car (car facts)) "holds" "the facts lead with what it holds")
        (check-true! (and (member "3 buffers" said) #t) "and says how many")
        (check-true! (and (member "opens" (map car facts)) #t)
                     "and the shape the group opens in")
        (check-equal! (filter (lambda (m) (member m said)) members) '()
                      "no member of the group is a fact")))
    (t--sw-done!)))

(deftest 'switch-to-group-enters-the-group-it-previewed
  "the peek is a look; RET is the switch, and it saves the layout you had"
  (lambda ()
    (t--sw-setup!)
    (let ((here (group-record-create! "zzsw-enter-here"))
          (there (group-record-create! "zzsw-enter-there")))
      (buffer-add-group! t--sw-first here)
      (buffer-add-group! t--sw-second there)
      (t--sw-show-here! t--sw-second)
      (t--sw-show-here! t--sw-first)
      (set-frame-local! 'current-group here)

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
    (let ((source (group-record-create! "zzsw-source")))
      (buffer-add-group! t--sw-first source)
      (switch-to-buffer! t--sw-first)
      (set-frame-local! 'current-group source)
      (run-command "group-switch")
      (run-command "group-switch-new")
      (t--sw-type! "zzsw-moved")
      (t--sw-key! "confirm")

      (let ((moved (group-resolve-id "zzsw-moved")))
        (check-true! (buffer-in-group? t--sw-first moved) "the destination was added")
        (check-false! (buffer-in-group? t--sw-first source) "the visible source was removed")
        (check-equal! (buffer-group-ids t--sw-first) (list moved) "and it is the only group")
        (check-equal! (frame-group) moved "the new group was entered")))
    (t--sw-done!)))

(deftest 'killing-a-visible-group-buffer-never-shows-a-foreign-buffer
  "a grouped frame replaces a killed member from that group only"
  (lambda ()
    (t--sw-setup!)
    (let ((here (group-record-create! "zzsw-here"))
          (foreign (group-record-create! "zzsw-foreign")))
      ;; the panes are laid out before any group exists: a switch in a
      ;; group makes the buffer join it, and third must stay foreign
      (switch-to-buffer! t--sw-first)
      (split-window! 'h 0.5)
      (switch-to-buffer! t--sw-third)
      (switch-to-buffer! t--sw-second)
      (buffer-add-group! t--sw-first here)
      (buffer-add-group! t--sw-second here)
      (buffer-add-group! t--sw-third foreign)
      (set-frame-local! 'current-group here)

      (buffer-kill! t--sw-second)

      (check-false! (member t--sw-third (map cadr (window-list)))
                    "the foreign MRU buffer stayed hidden")
      (for-each
        (lambda (row)
          (check-true! (buffer-in-group? (cadr row) here)
                       "every visible replacement belongs to the current group"))
        (window-list)))
    (t--sw-done!)))

(deftest 'a-frame-without-a-group-refills-a-killed-member-from-its-group
  "a frame that lost its group never takes the killed pane's foreign history"
  (lambda ()
    (t--sw-setup!)
    (let ((here (group-record-create! "zzsw-lost-here"))
          (foreign (group-record-create! "zzsw-lost-foreign")))
      (switch-to-buffer! t--sw-first)
      (split-window! 'h 0.5)
      (switch-to-buffer! t--sw-third)
      (switch-to-buffer! t--sw-second)
      (buffer-add-group! t--sw-first here)
      (buffer-add-group! t--sw-second here)
      (buffer-add-group! t--sw-third foreign)
      (set-frame-local! 'current-group #f)

      (buffer-kill! t--sw-second)

      (check-false! (member t--sw-third (map cadr (window-list)))
                    "the pane's foreign history stayed hidden")
      (for-each
        (lambda (row)
          (check-true! (group-kill-keeper? (cadr row) here)
                       "every pane shows the killed buffer's group"))
        (window-list)))
    (t--sw-done!)))

(deftest 'a-new-group-fills-the-default-three-columns
  "a group with no saved layout opens its members in the default columns"
  (lambda ()
    (t--sw-setup!)
    (set-frame-local! 'layout-freed #f)
    (let ((id (group-record-create! "zzsw-cols")))
      (for-each (lambda (b) (buffer-add-group! b id))
                (list t--sw-first t--sw-second t--sw-third))
      (switch-to-group! id)
      (check-equal! (layout-target) 'columns "the frame takes the default target")
      (check-equal! (length (window-list)) 3 "one pane for each member")
      (for-each
        (lambda (row)
          (check-false! (string-prefix? "*scratch" (cadr row)) "no pane is a scratch"))
        (window-list)))
    (t--sw-done!)))

(deftest 'a-freed-frame-stays-free-in-a-new-group
  "C-x l free is the person's choice: a group entry does not undo it"
  (lambda ()
    (t--sw-setup!)
    (let ((id (group-record-create! "zzsw-free")))
      (buffer-add-group! t--sw-first id)
      (buffer-add-group! t--sw-second id)
      (switch-to-group! id)
      (check-false! (layout-target) "the frame stays free"))
    (t--sw-done!)))

(deftest 'a-new-pane-leaves-a-consolidated-windows-members-alone
  "a layout that needs a window fills it from buffers no pane holds"
  (lambda ()
    (t--sw-setup!)
    (let ((id (group-record-create! "zzsw-held")))
      (for-each (lambda (b) (buffer-add-group! b id))
                (list t--sw-first t--sw-second t--sw-third))
      (buffer-set-local! t--sw-first 'mode-name "text-mode")
      (buffer-set-local! t--sw-second 'mode-name "text-mode")
      (buffer-set-local! t--sw-third 'mode-name "fundamental-mode")
      (delete-other-windows!)
      (switch-to-buffer-here! t--sw-first)
      (set-frame-local! 'current-group id)
      (let ((win (active-window)))
        (set-window-prev-buffers! win (list t--sw-second))
        (window-mode-preference! win "text-mode")
        (tile-visible-windows! 'columns)
        (check-false! (window-showing t--sw-second) "the held member stays in its pane")
        (check-true! (window-showing t--sw-third) "the new pane takes other work")
        (check-true! (member t--sw-second (window-prev-buffers win))
                     "and the pane keeps it in its history")
        (window-mode-preference! win #f)))
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
        (buffer-set-local! foreign 'special #f)
        (for-each (lambda (id) (buffer-remove-group! foreign id))
                  (buffer-group-ids foreign))
        ;; a switch would float it in the popup (the tests below); a pane
        ;; that shows it is the case here, and only a window action shows
        ;; a foreign buffer in a pane
        ;; one command: the change is recorded as it completes
        (winner--pre-command!)
        (t--sw-show-here! foreign)
        (winner--post-command!)
        (check-false! (frame-group) "the foreign pane takes the frame out of the group")
        (let ((tree (window-tree)))
          (check-equal! (group-layout home) tree "the layout was saved as it stood, foreign pane included")
          (check-equal! (frame-local 'previous-group) home "and the group left is remembered")
          ;; away and back: the arrangement returns
          (switch-to-group! away)
          (check-equal! (length (window-list)) 1 "the other group shows its own one pane")
          (switch-to-group! home)
          ;; sealed: the pane that showed the foreign buffer has no member
          ;; to show, so it goes; no scratch stands in for it
          (check-equal! (length (window-list)) 2 "coming back restores the group's two panes")
          (check-false! (window-showing foreign) "the foreign buffer is not shown")
          (check-false! (let loop ((ws (window-list)))
                          (cond ((null? ws) #f)
                                ((string-prefix? "*scratch:" (cadr (car ws))) #t)
                                (else (loop (cdr ws)))))
                        "no pane shows a scratch"))
        (buffer-kill! foreign)
        (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
                  (group-buffers-as home 'scratch))))
    (t--sw-done!)))

;;; --- a switch to a foreign buffer floats it in the popup --------------------------

;; the frame in HOME with two panes; a foreign buffer that no group holds
(define (t--sw-sealed-frame!)
  (let ((home (group-record-create! "zzsw-float-home")))
    (buffer-add-group! t--sw-first home)
    (buffer-add-group! t--sw-second home)
    (switch-to-buffer! t--sw-first)
    (split-window! 'h 0.5)
    (other-window!)
    (switch-to-buffer! t--sw-second)
    (group-current-recalculate!)
    (let ((foreign (test-buffer! "zz-sw-float-foreign" "")))
      (buffer-set-local! foreign 'special #f)
      (for-each (lambda (id) (buffer-remove-group! foreign id))
                (buffer-group-ids foreign))
      (list home foreign))))

(define (t--sw-sealed-done! foreign)
  (when (float-open?) (float-close!))
  (when (buffer-known? foreign) (buffer-kill! foreign)))

(deftest 'a-foreign-buffer-is-a-display-of-category-foreign
  "a buffer outside the group is a foreign display, and nothing floats"
  (lambda ()
    (t--sw-setup!)
    (let* ((pair (t--sw-sealed-frame!)) (foreign (cadr pair)))
      (check-false! (equal? (car (display-buffer-actions-for foreign)) 'popup)
                    "a foreign buffer takes the window chain")
      (check-true! (group-foreign-buffer? foreign) "the predicate names it")
      (check-false! (group-foreign-buffer? t--sw-first) "and not a member")
      (t--sw-sealed-done! foreign))
    (t--sw-done!)))

(deftest 'a-switch-to-a-buffer-of-another-group-enters-that-group
  "the ruling of 2026-09-19: a foreign buffer switches the group; nothing floats"
  (lambda ()
    (t--sw-setup!)
    (let* ((pair (t--sw-sealed-frame!)) (home (car pair)) (foreign (cadr pair))
           (away (group-record-create! "zzsw-float-away")))
      (buffer-add-group! foreign away)
      (switch-to-buffer! foreign)
      (check-false! (float-open?) "nothing floats")
      (check-equal! (current-buffer) foreign "the buffer is selected: a switch is a visit")
      (check-equal! (frame-group) away "the frame entered the buffer's group")
      (check-false! (member foreign (window-tree-buffers (group-layout home)))
                    "and the group it left keeps no foreign pane")
      (t--sw-sealed-done! foreign)
      (group-record-delete! away))
    (t--sw-done!)))

(deftest 'a-switch-to-an-ungrouped-buffer-joins-it-to-the-group
  "the ruling of 2026-09-22: a buffer opens in the current group, and the frame keeps it"
  (lambda ()
    (t--sw-setup!)
    (let* ((pair (t--sw-sealed-frame!)) (home (car pair)) (foreign (cadr pair))
           (win (active-window)))
      (switch-to-buffer! foreign)
      (check-false! (float-open?) "nothing floats")
      (check-true! (and (window-showing foreign) #t) "a pane shows it")
      (check-true! (buffer-in-group? foreign home) "it joined the group it opened in")
      (check-equal! (frame-group) home "so the frame keeps its group")
      (t--sw-sealed-done! foreign))
    (t--sw-done!)))

(deftest 'a-switch-to-a-buffer-of-another-group-brings-it-here
  "the ruling of 2026-09-22: the buffer comes to you; the frame never follows it home"
  (lambda ()
    (t--sw-setup!)
    (let* ((pair (t--sw-sealed-frame!)) (home (car pair)) (foreign (cadr pair))
           (away (group-record-create! "zzsw-elsewhere"))
           (panes (length (window-list))))
      (buffer-add-group! foreign away)
      (check-true! (group-foreign-buffer? foreign) "it starts in another group")
      (switch-to-buffer! foreign)
      (check-equal! (frame-group) home "the frame stands where it stood")
      (check-equal! (length (window-list)) panes "and no other group's layout replaced the panes")
      (check-true! (buffer-in-group? foreign home) "the buffer joined this group")
      (check-false! (buffer-in-group? foreign away) "and left the one it came from")
      (t--sw-sealed-done! foreign))
    (t--sw-done!)))
(deftest 'a-switch-to-a-visible-member-selects-the-window-that-shows-it
  "a member already on screen is not shown twice: the switch selects its window and the selected window keeps its buffer"
  (lambda ()
    (t--sw-setup!)
    (let* ((pair (t--sw-sealed-frame!)) (foreign (cadr pair))
           (win (active-window)))
      (switch-to-buffer! t--sw-first)
      (check-false! (float-open?) "no popup")
      (check-equal! (current-buffer) t--sw-first "the member is current")
      (check-equal! (active-window) (window-showing t--sw-first) "in the window that already showed it")
      (check-equal! (window-buffer win) t--sw-second "the window we left keeps its buffer")
      (t--sw-sealed-done! foreign))
    (t--sw-done!)))

(deftest 'a-pinned-frame-shows-a-foreign-buffer-in-the-selected-window
  "a pin keeps the group through window changes, so the switch takes the pane as before"
  (lambda ()
    (t--sw-setup!)
    (let* ((pair (t--sw-sealed-frame!)) (home (car pair)) (foreign (cadr pair))
           (win (active-window)))
      (set-frame-local! 'pinned-group home)
      (switch-to-buffer! foreign)
      (check-false! (float-open?) "no popup")
      (check-equal! (window-buffer win) foreign "the pane shows the foreign buffer")
      (check-equal! (frame-group) home "and the pin holds the group")
      (set-frame-local! 'pinned-group #f)
      (t--sw-sealed-done! foreign))
    (t--sw-done!)))

;; --- workspaces: a group belongs to one frame ------------------------------

(deftest 'a-group-belongs-to-the-frame-that-founds-it
  "the frame that makes a group keeps it, so the group is that workspace's own"
  (lambda ()
    (t--sw-setup!)
    (let ((id (group-record-create! "zz-sw-own")))
      (check-equal! (group-frame-owner id) (selected-frame) "the founding frame owns it")
      (check-true! (group-here? id) "so it is a group of this workspace")
      (check-false! (group-elsewhere-frame id) "and it is nowhere else")
      (check-true! (member id (group-ids-mru)) "this frame lists it"))
    (t--sw-done!)))

(deftest 'another-frames-group-stays-out-of-this-frames-lists
  "a workspace shows its own groups only, and reaches the rest through one marked row"
  (lambda ()
    (t--sw-setup!)
    (let* ((id (group-record-create! "zz-sw-away"))
           (home (selected-frame))
           ;; a new frame becomes the selected one: come back to this
           ;; workspace before asking what it shows
           (other (make-frame!))
           (back (select-frame! home)))
      (check-equal! (selected-frame) home "the test is back in its own frame")
      (group-frame-own! id other)
      (check-equal! (group-elsewhere-frame id) other "the other frame keeps it")
      (check-false! (group-here? id) "it is not a group of this workspace")
      (check-false! (member id (group-ids-mru)) "so this frame does not list it")
      (check-true! (member id (group-ids-mru-all)) "the whole-editor list still has it")
      (check-false! (member id (active-groups)) "and it is not active here")
      (let* ((rows (group-switch-prompt-rows))
             (away (filter (lambda (c) (equal? (cadr c) "in another window"))
                           (car rows))))
        (check-equal! (map car away) (list "zz-sw-away")
                      "the switcher offers it once, marked, under its own name"))
      (delete-frame! other)
      (check-true! (group-here? id) "a frame that goes leaves the group free"))
    (t--sw-done!)))

(deftest 'a-group-no-frame-owns-is-adopted-by-the-frame-that-enters-it
  "nothing is stranded by a closed window: the next workspace to enter takes it"
  (lambda ()
    (t--sw-setup!)
    (let* ((id (group-record-create! "zz-sw-orphan"))
           (home (selected-frame))
           (gone (make-frame!))
           (back (select-frame! home)))
      (group-frame-own! id gone)
      (delete-frame! gone)
      (check-true! (group-unowned? id) "the group belongs to no live frame")
      (switch-to-group! id)
      (check-equal! (group-frame-owner id) (selected-frame) "entering it adopts it")
      (check-true! (member id (group-ids-mru)) "and this frame lists it now"))
    ;; the entry made the group's chat; a later test must not find it
    (for-each (lambda (b) (when (string-prefix? "*chat:zz-sw-orphan" b) (buffer-kill! b)))
              (buffer-list))
    (t--sw-done!)))

(deftest 'every-completed-window-change-saves-the-groups-layout
  "the owner's ruling: a group's layout is saved on each change; an arrival records nothing"
  (lambda ()
    (t--sw-setup!)
    (let ((home (group-record-create! "zzsw-each-home"))
          (away (group-record-create! "zzsw-each-away")))
      (buffer-add-group! t--sw-first home)
      (buffer-add-group! t--sw-second home)
      (buffer-add-group! t--sw-third away)
      (switch-to-group! home)
      (delete-other-windows!)
      (t--sw-show-here! t--sw-first)
      (winner--settle-screen!)
      (winner--pre-command!)
      (split-window! 'h 0.5)
      (other-window!)
      (t--sw-show-here! t--sw-second)
      (winner--post-command!)
      (check-equal! (window-tree-buffers (group-layout home)) (list t--sw-first t--sw-second)
                    "the split is saved when the command completes")
      (let ((away-layout (group-layout away)))
        (winner--pre-command!)
        (switch-to-group! away)
        (winner--post-command!)
        (check-equal! (group-layout away) away-layout "the arrival writes nothing")
        (check-equal! (window-tree-buffers (group-layout home)) (list t--sw-first t--sw-second)
                      "and the group left keeps its last change")))
    (t--sw-done!)))
