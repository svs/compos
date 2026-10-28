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
  (panes-choose-layout! #f)
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
  ;; The record table is deliberately empty here. buffer-group only
  ;; answers a resolving id, so removing through that accessor leaves a stale
  ;; raw id behind. Reused per-second IDs then make a later fixture a member.
  (for-each (lambda (b)
              (buffer-set-local! b 'group-id #f)
              (buffer-set-local! b 'group #f)
              (buffer-set-local! b 'companion-of #f))
            (list t--sw-first t--sw-second t--sw-third)))

(define (t--sw-done!)
  (when (minibuffer-state) (minibuffer-cancel!))
  (panes-choose-layout! #f)
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
;; the All tab: the prompt reads the starting tab when it opens
(define (t--sw-open-all!)
  (let ((tab switch-buffer-initial-tab))
    (set! switch-buffer-initial-tab 'all)
    (run-command "ibuffer-prompt")
    (set! switch-buffer-initial-tab tab)))

;; every heading the rows can carry; none of them is a choice
(define t--sw-headings
  '("in this group" "other groups" "groups" "ungrouped" "zzsw-foreign" "recent"))

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

;;; --- founding a group -----------------------------------------------------------

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
      (check-equal! (buffer-group t--sw-first) #f "the buffer joined none")
      (check-equal! (window-tree) before "and the windows did not move"))
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
      (check-equal! (buffer-group ungrouped) #f "without current-group it starts ungrouped")

      (buffer-kill! direct)
      (buffer-kill! grouped)
      (buffer-kill! ungrouped))
    (t--sw-done!)))

;;; --- add, move, remove -----------------------------------------------------------

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
      (check-equal! (buffer-group t--sw-first) destination
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
        (check-equal! (buffer-group t--sw-first) created
                      "the buffer joins it, and only it")
        (check-false! (buffer-in-group? t--sw-first source) "the source is left")
        (check-equal! (frame-group) created
                      "the visible buffer takes the frame with it")))
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

(deftest 'move-puts-the-buffer-in-the-destination
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
      (check-equal! (buffer-group t--sw-first) destination
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
      (t--sw-type! "y")
      (check-false! (buffer-in-group? t--sw-second destination)
                    "remove drops the membership")
      (check-equal! (buffer-group t--sw-second) #f
                    "the scratch keeps no membership"))
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
      (check-equal! (buffer-group t--sw-first) home
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
      (check-true! (string-prefix? "Remove " (plist-get (minibuffer-state) 'prompt))
                   "the command asks")
      (t--sw-type! "y")
      (check-false! (buffer-in-group? t--sw-first removed) "the membership is removed")
      (check-equal! (buffer-group t--sw-first) #f "the buffer is left in no group")
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
      (check-true! (string-prefix? "Remove " (plist-get (minibuffer-state) 'prompt))
                   "the command asks before it removes")
      (check-true! (buffer-in-group? t--sw-first removed)
                   "asking changes nothing")
      (t--sw-type! "y")
      (check-false! (buffer-in-group? t--sw-first removed)
                    "y removes the membership"))
    (t--sw-done!)))

(deftest 'remove-answered-no-keeps-the-group
  "n closes the question and the buffer stays where it was"
  (lambda ()
    (t--sw-setup!)
    (let ((first (group-record-create! "zzsw-toggle-first")))
      (buffer-add-group! t--sw-first first)
      (switch-to-buffer! t--sw-first)
      (run-command "remove-group-from-buffer")
      (t--sw-type! "n")
      (check-false! (minibuffer-state) "n closes the question")
      (check-true! (buffer-in-group? t--sw-first first)
                   "and the buffer keeps its group"))
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
      (check-true! (buffer-in-group? t--sw-first moved)
                   "asking changes nothing for the document")
      (t--sw-type! "y")
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

(deftest 'a-zero-preview-keeps-the-frame-still
  "group-switch-preview-ms 0 highlights groups without drawing a frame"
  (lambda ()
    (t--sw-setup!)
    (let ((style group-switch-style)
          (ms group-switch-preview-ms)
          (here (group-record-create! "zzsw-still-here"))
          (there (group-record-create! "zzsw-still-there")))
      (set! group-switch-style "popup")
      (set! group-switch-preview-ms 0)
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
      (set! group-switch-preview-ms ms)
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

(deftest 'switch-to-group-can-move-the-current-buffer-into-a-new-context
  "the explicit action puts the buffer in the new group"
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
        (check-equal! (buffer-group t--sw-first) moved "and it is the only group")
        (check-equal! (frame-group) moved "the new group was entered")))
    (t--sw-done!)))

(deftest 'a-freed-frame-stays-free-in-a-new-group
  "C-x l free is the person's choice: a group entry does not undo it"
  (lambda ()
    (t--sw-setup!)
    (let ((id (group-record-create! "zzsw-free")))
      (buffer-add-group! t--sw-first id)
      (buffer-add-group! t--sw-second id)
      (switch-to-group! id)
      (check-false! (panes-current-layout) "the frame stays free"))
    (t--sw-done!)))


(deftest 'group-pin-holds-the-frame-and-the-shown-buffer-joins-it
  "a pin holds the frame's group, and a buffer shown in the pinned frame joins that group"
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
      (check-equal! (frame-group) here "showing a foreign buffer does not move the frame")
      (check-true! (buffer-in-group? t--sw-third here)
                   "the shown buffer joins the frame's group")
      (check-false! (buffer-in-group? t--sw-third foreign) "and leaves its own: one group only")
      (check-true! (group-visible-homogeneous? here) "so the shown layout is the group's")

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
      (check-true! (buffer-in-group? t--sw-first second) "a buffer shown in the pinned frame joins it")
      (run-command "group-pin")
      (check-false! (group-pinned) "the second command releases the pin")
      (check-equal! (frame-group) second "release derives context from visible work"))
    (t--sw-done!)))

;;; --- leaving a group by a foreign pane ------------------------------------------

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
      (let ((g (buffer-group foreign))) (when g (buffer-remove-group! foreign g)))
      (list home foreign))))

(define (t--sw-sealed-done! foreign)
  (when (float-open?) (float-close!))
  (when (buffer-known? foreign) (buffer-kill! foreign)))


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

(deftest 'frames-share-groups-unless-isolated
  "every frame shows every group; an isolated frame keeps its own, reached through one marked row"
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
      (check-false! (group-elsewhere-frame id) "a plain frame keeps nothing")
      (check-true! (group-here? id) "so this frame shows its group")
      (check-true! (member id (group-ids-mru)) "and lists it")
      (set-frame-local-in! other 'isolated #t)
      (check-equal! (group-elsewhere-frame id) other "the isolated frame keeps it")
      (check-false! (group-here? id) "it is not a group of this frame")
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
    (t--sw-done!)
    ;; the entry made the group's chat; a later test must not find it. The
    ;; sweep runs after the group is gone: a kill while the group lives
    ;; lets the kill repair make the chat again.
    (for-each (lambda (b) (when (string-prefix? "*chat:zz-sw-orphan" b) (buffer-kill! b)))
              (buffer-list))))


