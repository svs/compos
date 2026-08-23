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
  (for-each (lambda (b) (test-buffer! b "")) (list t--sw-first t--sw-second t--sw-third))
  (set! *group-records* '())
  (set! *group-next-id* 0)
  (set-frame-local! 'current-group #f)
  (set-frame-local! 'previous-group #f)
  (delete-other-windows!)
  (switch-to-buffer! t--sw-first))

(define (t--sw-done!)
  (when (minibuffer-state) (minibuffer-cancel!))
  (for-each (lambda (b) (when (buffer-known? b) (buffer-kill! b)))
            (list t--sw-first t--sw-second t--sw-third))
  (set! *group-records* '())
  (set! *group-next-id* 0)
  (set-frame-local! 'current-group #f)
  (set-frame-local! 'previous-group #f)
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

(define (t--sw-open-switcher!) (run-command "group-switch-to-buffer"))

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

      (check-true! (member t--sw-second (t--sw-labels)) "the other buffer is offered")
      (t--sw-type! t--sw-second)
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

(deftest 'the-switcher-puts-the-groups-own-members-first-and-still-switches
  "a member leads; a stranger is in the pool below"
  (lambda ()
    (t--sw-setup!)
    (let ((ids (t--sw-three-groups!)))
      (t--sw-open-switcher!)
      (check-true! (< (t--sw-at t--sw-second) (t--sw-at "other buffers"))
                   "the member sits above the other-buffers heading")

      ;; a stranger may sit below the rendered window: filter to prove it
      ;; is in the pool at all, then clear the filter again
      (t--sw-type! t--sw-third)
      (check-true! (member t--sw-third (t--sw-labels)) "the stranger is reachable")
      (t--sw-type! "")

      (t--sw-type! t--sw-second)
      (t--sw-key! "confirm")
      (check-equal! (current-buffer) t--sw-second "it switched")
      (check-equal! (frame-local 'current-group) (car ids) "and the context held"))
    (t--sw-done!)))

(deftest 'the-switcher-lists-every-buffer-under-two-headings
  "nothing is hidden: the group's own first, then the rest"
  (lambda ()
    (t--sw-setup!)
    (t--sw-three-groups!)
    (t--sw-open-switcher!)
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
    (t--sw-open-switcher!)
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
    (t--sw-open-switcher!)
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
      (t--sw-open-switcher!)
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

      (t--sw-open-switcher!)
      (t--sw-type! t--sw-third)
      (t--sw-key! "confirm-context")

      (check-equal! (frame-local 'current-group) foreign "the context followed")
      (check-equal! (current-buffer) t--sw-third "and the buffer is on screen")
      (check-false! (buffer-in-group? t--sw-third current) "it did not join this group"))
    (t--sw-done!)))

(deftest 'confirm-moves-nothing-but-the-window
  "RET: no membership changes, no context changes"
  (lambda ()
    (t--sw-setup!)
    (let ((ids (t--sw-three-groups!)))
      (t--sw-open-switcher!)
      (t--sw-type! t--sw-third)
      (t--sw-key! "confirm")

      (check-equal! (current-buffer) t--sw-third "the window moved")
      (check-equal! (frame-local 'current-group) (car ids) "the context did not")
      (check-false! (buffer-in-group? t--sw-third (car ids)) "and no membership changed"))
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
