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
      (buffer-set-local! b 'buffer-selected #f))
    (list t--sw-first t--sw-second t--sw-third))
  (set! *group-records* '())
  (set! *group-next-id* 0)
  (set-frame-local! 'current-group #f)
  (set-frame-local! 'previous-group #f)
  (delete-other-windows!)
  (switch-to-buffer! t--sw-first))

(define (t--sw-done!)
  (when (minibuffer-state) (minibuffer-cancel!))
  (set-frame-local! 'current-group #f)
  (set-frame-local! 'previous-group #f)
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

;;; --- founding a group -----------------------------------------------------------

(deftest 'new-from-visible-preserves-old-memberships-and-the-layout
  "the new group takes what is on screen and leaves what was already true"
  (lambda ()
    (t--sw-setup!)
    (let ((old (group-record-create! "zzsw-old")))
      (buffer-add-group! t--sw-first old)
      (delete-other-windows!)
      (switch-to-buffer! t--sw-first)
      (split-window! 'h 0.5)
      (other-window!)
      (switch-to-buffer! t--sw-second)
      (run-command "group-new-from-visible")

      (t--sw-type! "zzsw-visible")
      (t--sw-key! "confirm")

      (let ((id (group-resolve-id "zzsw-visible")))
        (check-true! (buffer-in-group? t--sw-first old) "the old membership is kept")
        (check-true! (buffer-in-group? t--sw-first id) "and the new one added")
        (check-true! (buffer-in-group? t--sw-second id) "the other visible buffer joins")
        (check-equal! (frame-local 'current-group) id "the frame stands in it")
        (check-equal! (group-layout id) (window-tree) "and it remembers this layout")))
    (t--sw-done!)))

(deftest 'cancelled-group-creation-changes-no-group-state
  "C-g out of the prompt and nothing happened"
  (lambda ()
    (t--sw-setup!)
    (let ((before (window-tree)))
      (run-command "group-new-from-buffer")
      (t--sw-key! "cancel")
      (check-equal! (group-ids) '() "no group was founded")
      (check-false! (frame-local 'current-group) "the frame stands in none")
      (check-equal! (buffer-group-ids t--sw-first) '() "the buffer joined none")
      (check-equal! (window-tree) before "and the windows did not move"))
    (t--sw-done!)))

(deftest 'new-buffers-use-the-derived-current-group
  "buffer-new joins a homogeneous context and stays ungrouped in a mixed one"
  (lambda ()
    (t--sw-setup!)
    (let ((here (group-record-create! "zzsw-here"))
          (grouped "zz-sw-new-grouped")
          (ungrouped "zz-sw-new-ungrouped"))
      (buffer-add-group! t--sw-first here)
      (switch-to-buffer! t--sw-first)
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

      (buffer-kill! grouped)
      (buffer-kill! ungrouped))
    (t--sw-done!)))

;;; --- pull, push, pop -------------------------------------------------------------

(deftest 'pull-adds-to-the-current-group-without-switching-context
  "the buffer comes here; we do not go there"
  (lambda ()
    (t--sw-setup!)
    (let ((here (group-record-create! "zzsw-here"))
          (there (group-record-create! "zzsw-there")))
      (buffer-add-group! t--sw-first here)
      (buffer-add-group! t--sw-second there)
      (set-frame-local! 'current-group here)
      (switch-to-buffer! t--sw-first)
      (run-command "group-pull-buffer")

      ;; narrow first: the prompt offers every live work buffer, and the
      ;; suite shares one editor, so the full list holds whatever the
      ;; other files left open. Typing the name is how a person finds it.
      (t--sw-type! t--sw-second)
      (check-true! (member t--sw-second (t--sw-labels)) "the other buffer is offered")
      (t--sw-key! "confirm")

      (check-true! (buffer-in-group? t--sw-second here) "it joined this group")
      (check-true! (buffer-in-group? t--sw-second there) "and kept its own")
      (check-equal! (frame-local 'current-group) here "the context did not move")
      (check-equal! (current-buffer) t--sw-first "nor the window"))
    (t--sw-done!)))

(deftest 'push-adds-an-existing-destination-without-leaving-the-source
  "the buffer goes there; we stay here"
  (lambda ()
    (t--sw-setup!)
    (let ((source (group-record-create! "zzsw-source"))
          (destination (group-record-create! "zzsw-destination")))
      (buffer-add-group! t--sw-first source)
      (set-frame-local! 'current-group source)
      (switch-to-buffer! t--sw-first)
      (run-command "group-push-buffer")

      (let ((labels (t--sw-labels)))
        (check-true! (member "New group" labels) "a new group is offered")
        (check-true! (member "zzsw-destination" labels) "and the existing one"))

      (t--sw-type! "zzsw-destination")
      (t--sw-key! "confirm")

      (check-true! (buffer-in-group? t--sw-first source) "it keeps the source group")
      (check-true! (buffer-in-group? t--sw-first destination) "and joins the destination")
      (check-equal! (frame-local 'current-group) source "the context stays")
      (check-equal! (current-buffer) t--sw-first "and the window"))
    (t--sw-done!)))

(deftest 'push-can-create-a-destination-without-entering-it
  "two prompts: which group, then what to call it"
  (lambda ()
    (t--sw-setup!)
    (let ((source (group-record-create! "zzsw-source")))
      (buffer-add-group! t--sw-first source)
      (set-frame-local! 'current-group source)
      (switch-to-buffer! t--sw-first)
      (run-command "group-push-buffer")

      (t--sw-type! "New group")
      (t--sw-key! "confirm")
      (t--sw-type! "zzsw-created")
      (t--sw-key! "confirm")

      (let ((created (group-resolve-id "zzsw-created")))
        (check-true! created "the group was created")
        (check-true! (buffer-in-group? t--sw-first created) "and the buffer joined it")
        (check-equal! (frame-local 'current-group) source "without entering it")))
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

(deftest 'push-visible-adds-all-visible-buffers
  "visible work buffers join the destination and keep their old memberships"
  (lambda ()
    (t--sw-setup!)
    (let ((source (group-record-create! "zzsw-source"))
          (destination (group-record-create! "zzsw-destination")))
      (buffer-add-group! t--sw-first source)
      (buffer-add-group! t--sw-second source)
      (set-frame-local! 'current-group source)
      (split-window! 'h 0.5)
      (other-window!)
      (switch-to-buffer! t--sw-second)
      (run-command "group-push-visible")
      (t--sw-type! "zzsw-destination")
      (t--sw-key! "confirm")
      (check-true! (buffer-in-group? t--sw-first source) "first keeps source")
      (check-true! (buffer-in-group? t--sw-second source) "second keeps source")
      (check-true! (buffer-in-group? t--sw-first destination) "first joins destination")
      (check-true! (buffer-in-group? t--sw-second destination) "second joins destination"))
    (t--sw-done!)))

(deftest 'push-visible-prefers-selected-visible-buffers
  "one selected visible buffer limits the push to that buffer"
  (lambda ()
    (t--sw-setup!)
    (let ((source (group-record-create! "zzsw-source"))
          (destination (group-record-create! "zzsw-destination")))
      (buffer-add-group! t--sw-first source)
      (buffer-add-group! t--sw-second source)
      (set-frame-local! 'current-group source)
      (split-window! 'h 0.5)
      (other-window!)
      (switch-to-buffer! t--sw-second)
      (switch-to-buffer! t--sw-first)
      (run-command "buffer-select")
      (run-command "group-push-visible")
      (t--sw-type! "zzsw-destination")
      (t--sw-key! "confirm")
      (check-true! (buffer-in-group? t--sw-first destination) "selected buffer joins")
      (check-false! (buffer-in-group? t--sw-second destination) "unselected buffer stays"))
    (t--sw-done!)))

(deftest 'push-visible-confirms-before-joining-a-nonempty-group
  "a nonempty destination lists its buffers and still joins after yes"
  (lambda ()
    (t--sw-setup!)
    (let ((source (group-record-create! "zzsw-source"))
          (destination (group-record-create! "zzsw-destination")))
      (buffer-add-group! t--sw-first source)
      (buffer-add-group! t--sw-second destination)
      (set-frame-local! 'current-group source)
      (switch-to-buffer! t--sw-first)
      (run-command "buffer-select")
      (run-command "group-push-visible")
      (t--sw-type! "zzsw-destination")
      (t--sw-key! "confirm")
      (check-true! (minibuffer-state) "the nonempty target asks for confirmation")
      (t--sw-type! "y")
      (check-true! (buffer-in-group? t--sw-first destination)
                   "yes completes the push"))
    (t--sw-done!)))

(deftest 'push-selected-founds-a-typed-destination
  "an unknown destination name creates a group from the push prompt"
  (lambda ()
    (t--sw-setup!)
    (let ((source (group-record-create! "zzsw-source")))
      (buffer-add-group! t--sw-first source)
      (set-frame-local! 'current-group source)
      (switch-to-buffer! t--sw-first)
      (run-command "buffer-select")
      (run-command "group-push-selected")
      (t--sw-type! "zzsw-typed-destination")
      (t--sw-key! "confirm")
      (let ((destination (group-resolve-id "zzsw-typed-destination")))
        (check-true! destination "the unknown destination was created")
        (check-true! (buffer-in-group? t--sw-first destination)
                     "the selected buffer joined it")))
    (t--sw-done!)))

(deftest 'push-selected-falls-back-to-the-current-buffer
  "with no selection, the current work buffer joins the destination"
  (lambda ()
    (t--sw-setup!)
    (let ((source (group-record-create! "zzsw-source")))
      (buffer-add-group! t--sw-first source)
      (set-frame-local! 'current-group source)
      (switch-to-buffer! t--sw-first)
      (run-command "group-push-selected")
      (t--sw-type! "zzsw-current-destination")
      (t--sw-key! "confirm")
      (let ((destination (group-resolve-id "zzsw-current-destination")))
        (check-true! destination "the destination was created")
        (check-true! (buffer-in-group? t--sw-first destination)
                     "the current buffer joined it")
        (check-false! (buffer-in-group? t--sw-second destination)
                      "another buffer did not join")))
    (t--sw-done!)))

(deftest 'push-selected-prefers-an-explicit-selection
  "an explicit selection excludes the unselected current buffer"
  (lambda ()
    (t--sw-setup!)
    (split-window! 'h 0.5)
    (other-window!)
    (switch-to-buffer! t--sw-second)
    (run-command "buffer-select")
    (other-window!)
    (run-command "group-push-selected")
    (t--sw-type! "zzsw-selected-destination")
    (t--sw-key! "confirm")
    (let ((destination (group-resolve-id "zzsw-selected-destination")))
      (check-true! (buffer-in-group? t--sw-second destination)
                   "the selected buffer joined")
      (check-false! (buffer-in-group? t--sw-first destination)
                    "the current buffer stayed out"))
    (t--sw-done!)))

(deftest 'move-visible-removes-the-current-group
  "visible work buffers leave the current group after joining the destination"
  (lambda ()
    (t--sw-setup!)
    (let ((source (group-record-create! "zzsw-source"))
          (destination (group-record-create! "zzsw-destination")))
      (buffer-add-group! t--sw-first source)
      (buffer-add-group! t--sw-second source)
      (set-frame-local! 'current-group source)
      (split-window! 'h 0.5)
      (other-window!)
      (switch-to-buffer! t--sw-second)
      (run-command "group-move-visible")
      (t--sw-type! "zzsw-destination")
      (t--sw-key! "confirm")
      (check-false! (buffer-in-group? t--sw-first source) "first leaves source")
      (check-false! (buffer-in-group? t--sw-second source) "second leaves source")
      (check-true! (buffer-in-group? t--sw-first destination) "first joins destination")
      (check-true! (buffer-in-group? t--sw-second destination) "second joins destination"))
    (t--sw-done!)))

(deftest 'pop-removes-only-the-current-group-and-replaces-a-visible-buffer
  "the buffer leaves this group, keeps the others, and the window finds another"
  (lambda ()
    (t--sw-setup!)
    (let ((here (group-record-create! "zzsw-here"))
          (shared (group-record-create! "zzsw-shared")))
      (buffer-add-group! t--sw-first here)
      (buffer-add-group! t--sw-first shared)
      (buffer-add-group! t--sw-second here)
      (set-frame-local! 'current-group here)
      (switch-to-buffer! t--sw-first)
      (run-command "group-pop")

      (check-false! (buffer-in-group? t--sw-first here) "it left this group")
      (check-true! (buffer-in-group? t--sw-first shared) "and kept the other")
      (check-equal! (frame-local 'current-group) here "the context did not move")
      (check-equal! (current-buffer) t--sw-second "another member took the window")
      (check-true! (buffer-exists? t--sw-first) "and the buffer still exists"))
    (t--sw-done!)))

;;; --- the switch list -------------------------------------------------------------

(define (t--sw-three-groups!)
  (let ((current (group-record-create! "zzsw-current"))
        (foreign (group-record-create! "zzsw-foreign")))
    (buffer-add-group! t--sw-first current)
    (buffer-add-group! t--sw-second current)
    (buffer-add-group! t--sw-third foreign)
    (set-frame-local! 'current-group current)
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

(deftest 'adopt-pulls-the-buffer-into-the-current-group
  "S-RET: the buffer comes here, the context does not move to meet it"
  (lambda ()
    (t--sw-setup!)
    (let* ((ids (t--sw-three-groups!))
           (current (car ids))
           (foreign (cadr ids)))
      (t--sw-open-all!)
      (t--sw-type! t--sw-third)
      (t--sw-key! "confirm-adopt")

      (check-equal! (current-buffer) t--sw-third "we are in it")
      (check-equal! (frame-local 'current-group) current "the context did not move")
      (check-true! (buffer-in-group? t--sw-third current) "it joined this group")
      (check-true! (buffer-in-group? t--sw-third foreign) "and kept the one it had"))
    (t--sw-done!)))

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

(deftest 'switch-to-group-can-pop-the-current-buffer-into-a-new-context
  "the explicit action adds the destination and removes only the current group"
  (lambda ()
    (t--sw-setup!)
    (let ((source (group-record-create! "zzsw-source"))
          (kept (group-record-create! "zzsw-kept")))
      (buffer-add-group! t--sw-first source)
      (buffer-add-group! t--sw-first kept)
      (switch-to-buffer! t--sw-first)
      (set-frame-local! 'current-group source)
      (run-command "switch-to-group")
      (t--sw-type! "Move this buffer into a new group")
      (t--sw-key! "confirm")
      (t--sw-type! "zzsw-popped")
      (t--sw-key! "confirm")

      (let ((popped (group-resolve-id "zzsw-popped")))
        (check-true! (buffer-in-group? t--sw-first popped) "the destination was added")
        (check-false! (buffer-in-group? t--sw-first source) "the visible source was removed")
        (check-true! (buffer-in-group? t--sw-first kept) "an unrelated membership remains")
        (check-equal! (frame-group) popped "the new group was entered")))
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
