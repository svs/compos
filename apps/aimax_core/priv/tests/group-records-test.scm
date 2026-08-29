;;; group-records-test.scm --- a group is a record with an id, not a name.
;;;
;;; The id is what a buffer holds, so a rename moves the name and touches
;;; no membership. A dangling id founds nothing. A record with no buffers
;;; is still a record.
;;;
;;; The ExUnit original wiped *group-records* in its setup. These read
;;; deltas instead: the suite also runs in a live editor, where that list
;;; is the person's own groups.
;;;
;;; Fifteen tests stay in ExUnit. Fourteen press keys through the
;;; switcher. One reads a window through Editor.

(domain! 'testing)
(effects! '(read))

(define (t--gs-count) (length (group-ids)))

(effects! '(write))

(define (t--gs-buf) (test-buffer! "*zz-gs-work*" ""))

(define (t--gs-drop! &rest ids)
  (for-each (lambda (id) (when (group-record-by-id id) (group-record-delete! id))) ids))

(define (t--gs-kill! &rest names)
  (for-each (lambda (n) (when (buffer-known? n) (buffer-kill! n))) names))

;;; --- the id -------------------------------------------------------------------

(deftest 'new-groups-get-distinct-durable-accent-colors
  "a group color belongs to the record and survives a rename"
  (lambda ()
    (let* ((left (group-record-create! "zzgs-color-left"))
           (right (group-record-create! "zzgs-color-right"))
           (color (group-record-color (group-record-by-id left)))
           (buf (t--gs-buf)))
      (check-true! (string-prefix? "#" color) "the color is a CSS hex value")
      (check-false!
        (equal? color (group-record-color (group-record-by-id right)))
        "adjacent groups get distinct accents")
      (check-equal! (list-cell-face (nth 1 (group-cells #f left)))
                    (group-color-face left)
                    "the groups board uses the group's own accent")
      (buffer-add-group! buf left)
      (let* ((face (buffer-filename-face buf))
             (candidate (car (annotate 'buffer (list buf)))))
        (check-equal! face (group-color-face left)
                      "the filename face follows the group")
        (check-equal! (nth 4 candidate) face
                      "a minibuffer candidate carries the filename face")
        (check-equal! (list-cell-face (nth 2 (ibuffer-cell-head buf))) face
                      "ibuffer uses the filename face")
        (check-equal! (list-cell-face (nth 1 (switch-cells #f candidate))) face
                      "the modal switcher uses the filename face"))
      (buffer-move-to-group! buf #f)
      (group-rename! left "zzgs-color-renamed")
      (check-equal! (group-record-color (group-record-by-id left)) color
                    "renaming keeps the accent")
      (t--gs-drop! left right))))

(deftest 'a-rename-keeps-a-stable-group-id
  "the buffer holds the id, so the name is free to move"
  (lambda ()
    (let ((buf (t--gs-buf))
          (id (group-record-create! "zzgs-stable")))
      (buffer-add-group! buf id)
      (group-rename! id "zzgs-renamed")
      (check-equal! (buffer-group buf) id "the buffer still holds the id")
      (check-equal! (group-name id) "zzgs-renamed" "and the name moved")
      (t--gs-drop! id)
      (t--gs-kill! buf))))

(deftest 'work-buffers-keep-unique-group-id-sets
  "adding twice is adding once, and removing takes exactly one"
  (lambda ()
    (let ((buf (t--gs-buf))
          (left (group-record-create! "zzgs-left"))
          (right (group-record-create! "zzgs-right")))
      (buffer-add-group! buf left)
      (buffer-add-group! buf left)
      (buffer-add-group! buf right)
      (buffer-remove-group! buf left)
      (check-false! (buffer-in-group? buf left) "the removed one is gone")
      (check-true! (buffer-in-group? buf right) "the other one stays")
      (check-equal! (length (buffer-group-ids buf)) 1 "one membership is left")
      (t--gs-drop! left right)
      (t--gs-kill! buf))))

(deftest 'a-role-belongs-to-one-buffer-group-membership
  "the same buffer can mean different things in different groups"
  (lambda ()
    (let ((buf (t--gs-buf))
          (left (group-record-create! "zzgs-role-left"))
          (right (group-record-create! "zzgs-role-right")))
      (buffer-add-group-as! buf left 'index)
      (buffer-add-group-as! buf right "reference")
      (check-equal! (buffer-group-role buf left) "index" "the symbol became a role")
      (check-equal! (buffer-group-role buf right) "reference" "the other role is independent")
      (check-equal! (group-buffer-as left 'index) buf "a role finds its buffer")
      (check-false! (group-buffer-as right 'index) "roles do not leak between groups")
      (buffer-remove-group! buf left)
      (check-false! (buffer-group-role buf left) "leaving removes the role too")
      (t--gs-drop! left right)
      (t--gs-kill! buf))))

(deftest 'legacy-names-migrate-once-to-stable-ids
  "two buffers naming one group end up in one record, not two"
  (lambda ()
    (let ((work (t--gs-buf))
          (chat "*zz-gs-chat-legacy*")
          (before (t--gs-count)))
      (test-buffer! chat "")
      (buffer-set-local! work 'group "zzgs-legacy")
      (buffer-set-local! chat 'group "zzgs-legacy")
      (with-current-buffer chat (lambda () (set-mode! "chat-mode")))
      (let ((work-id (buffer-group work))
            (chat-id (chat-group-id chat)))
        (check-equal! work-id chat-id "both name the same record")
        (check-equal! (- (t--gs-count) before) 1 "and it is one new record")
        (check-equal! (length (buffer-group-ids work)) 1 "the work buffer is a member")
        (check-equal! (length (buffer-group-ids chat)) 0 "the chat is not a member, it belongs")
        (t--gs-drop! work-id))
      (t--gs-kill! chat work))))

(deftest 'a-dangling-id-founds-no-group-and-never-becomes-a-name
  "a restart brings the locals back before the records"
  (lambda ()
    ;; The buffer names a group nobody can resolve. That id must not found
    ;; a group called after itself: the C-c g list shows names.
    (let ((work (t--gs-buf))
          (before (t--gs-count)))
      (check-false! (group-ensure-record! "grp:9999:1") "a dangling id founds nothing")
      (check-false! (buffer-add-group! work "grp:9999:1") "and joins nothing")
      (check-equal! (t--gs-count) before "no record appeared")

      (let ((id (group-ensure-record! "zzgs-a chosen name")))
        (check-true! id "a name does found a record")
        (check-equal! (- (t--gs-count) before) 1 "exactly one")
        (check-true! (member "zzgs-a chosen name" (group-names)) "and it is listed by name")
        (t--gs-drop! id))
      (t--gs-kill! work))))

(deftest 'empty-group-records-remain-durable
  "a group with no buffers is still a group, and the desktop saves it"
  (lambda ()
    (let ((id (group-record-create! "zzgs-empty")))
      (check-equal! (group-name id) "zzgs-empty" "it has a name")
      (check-equal! (length (group-buffers id)) 0 "and no buffers")
      (check-true! (assoc 'groups-v2 (desktop-globals)) "the desktop carries the records")
      (t--gs-drop! id))))

;;; --- the chats ----------------------------------------------------------------

(deftest 'a-chat-clears-a-group-id-whose-record-is-gone
  "reading it heals it, rather than handing back a dead id forever"
  (lambda ()
    (let ((first (t--gs-buf))
          (chat "*zz-gs-chat-dangling*")
          (gone (group-record-create! "zzgs-gone")))
      (test-buffer! chat "")
      (buffer-add-group! first gone)
      (buffer-set-local! chat 'group-id gone)
      (buffer-set-local! chat 'mode-name "chat-mode")
      (check-equal! (chat-group-id chat) gone "the chat names the group")

      ;; the record goes while the chat is not swept: asleep, or deleted
      ;; straight from the board
      (group-record-delete! gone)
      (check-false! (chat-group-id chat) "the dead id is not handed back")
      (check-false! (buffer-local chat 'group-id) "and it is cleared on the buffer")
      (check-equal! (buffer-group-summary chat) "ungrouped" "the summary says so")
      (t--gs-kill! chat first))))

(deftest 'a-group-can-own-many-chats-and-one-primary-chat
  "the second chat is a new buffer, and it becomes the primary one"
  (lambda ()
    (let* ((id (group-record-create! "zzgs-chat-owner"))
           (first (group-chat id))
           (second (group-chat-new! id)))
      (check-false! (equal? first second) "two chats, two buffers")
      (check-equal! (chat-group-id first) id "the first belongs to the group")
      (check-equal! (chat-group-id second) id "and so does the second")
      (check-equal! (buffer-group-role first id) "chat" "a group chat has the chat role")
      (check-equal! (group-primary-chat id) second "the newest is the primary one")
      (check-equal! (length (buffer-group-ids first)) 0 "a chat belongs, it is not a member")
      (check-equal! (length (filter chat-buffer? (group-buffers id))) 2 "the group owns both")
      (t--gs-kill! first second)
      (t--gs-drop! id))))

(deftest 'a-group-chat-is-ready-before-any-window-shows-it
  "scene layouts can use the chat immediately after group-chat creates it"
  (lambda ()
    (let* ((id (group-record-create! "zzgs-ready-chat"))
           (chat (group-chat id)))
      (check-equal! (buffer-local chat 'mode-name) "chat-mode" "the mode is set")
      (check-true! (buffer-local chat 'agent-saved-mark) "the rich input exists")
      (check-true! (> (buffer-size chat) 0) "the surface exists")
      (t--gs-kill! chat)
      (t--gs-drop! id))))

(deftest 'an-identity-only-primary-chat-heals-its-mode-and-its-name
  "a restored chat cannot remain an inert buffer or duplicate itself"
  (lambda ()
    (let* ((id (group-record-create! "zzgs-heal-chat"))
           (chat "*zz-gs-renamed-primary*")
           (want (group-chat-name id))
           (chat-id "chat:zzgs-heal"))
      (test-buffer! chat "")
      (buffer-set-local! chat 'group-id id)
      (buffer-set-local! chat 'chat-id chat-id)
      (group-record-update! id 'primary-chat-id chat-id)

      ;; the stable identity wins: the SAME buffer answers, and it takes
      ;; the name of its group rather than a second buffer appearing there
      (check-equal! (group-chat id) want "the chat takes its group's name")
      (check-equal! (buffer-local want 'chat-id) chat-id "and it is the same chat")
      (check-false! (buffer-known? chat) "the old name is gone, so there is no duplicate")

      (check-equal! (buffer-local want 'mode-name) "chat-mode" "the mode heals")
      (check-true! (buffer-local want 'agent-saved-mark) "the input heals")
      (t--gs-kill! chat want)
      (t--gs-drop! id))))

;;; --- dissolve and layout ------------------------------------------------------

(deftest 'dissolve-keeps-buffers-and-their-other-memberships
  "dissolving a group is not deleting what was in it"
  (lambda ()
    (let ((first (t--gs-buf))
          (dissolved (group-record-create! "zzgs-dissolved"))
          (kept (group-record-create! "zzgs-kept")))
      (buffer-add-group! first dissolved)
      (buffer-add-group! first kept)
      (group-dissolve! dissolved)
      (check-true! (buffer-known? first) "the buffer is still there")
      (check-equal! (buffer-group-ids first) (list kept) "and keeps its other membership")
      (check-false! (group-resolve-id dissolved) "the dissolved group is gone")
      (t--gs-drop! kept)
      (t--gs-kill! first))))

(deftest 'group-kill-reports-the-modified-survivor
  "a partial kill names the work that normal protection kept"
  (lambda ()
    (let* ((path "/tmp/aimax-zz-group-kill-partial.txt")
           (ordinary (t--gs-buf))
           (id (group-record-create! "zzgs-partial-kill"))
           (mark (string-length (buffer-text "*Messages*"))))
      (write-file! path "saved\n")
      (visit path)
      (buffer-insert! path 0 "modified ")
      (buffer-add-group! path id)
      (buffer-add-group! ordinary id)
      (group-kill! id)
      (let ((said (buffer-text "*Messages*")))
        (check-contains! (substring said mark (string-length said))
                         "Kept 1 buffer"
                         "the command reports partial completion"))
      (check-true! (buffer-known? path) "the modified file survives")
      (check-false! (buffer-known? ordinary) "the ordinary buffer is killed")
      (buffer-mark-saved! path)
      (buffer-kill! path)
      (delete-file! path))))

(deftest 'remembered-layouts-are-keyed-by-frame
  "two frames on one group remember two layouts"
  (lambda ()
    (let ((first (t--gs-buf))
          (id (group-record-create! "zzgs-layout"))
          (here (current-buffer)))
      (buffer-add-group! first id)
      (switch-to-buffer! first)
      (group-layout-save! id)
      (let ((saved (group-record-layout (group-record-by-id id))))
        (check-equal! (car saved) 'per-frame "the layout is per-frame")
        (check-equal! (car (car (cdr saved))) (selected-frame) "keyed by this frame")
        (check-equal! (group-layout id) (window-tree) "and it is what is on screen"))
      (when (buffer-known? here) (switch-to-buffer! here))
      (t--gs-drop! id)
      (t--gs-kill! first))))

;;; --- the frame context --------------------------------------------------------

;; The frame locals are the person's own current group. Put them back.
(define (t--gs-with-frame-context thunk)
  (let ((current (frame-local 'current-group))
        (previous (frame-local 'previous-group))
        (pinned (frame-local 'pinned-group))
        (winner (frame-local 'winner-pos)))
    (let ((out (thunk)))
      (set-frame-local! 'current-group current)
      (set-frame-local! 'previous-group previous)
      (set-frame-local! 'pinned-group pinned)
      (set-frame-local! 'winner-pos winner)
      out)))

(deftest 'frame-group-context-restores-stable-ids-without-runtime-locals
  "a saved context carries ids, and malformed noise does not overwrite what is there"
  (lambda ()
    (t--gs-with-frame-context
      (lambda ()
        (let ((current (group-record-create! "zzgs-frame-current"))
              (previous (group-record-create! "zzgs-frame-previous"))
              (pinned (group-record-create! "zzgs-frame-pinned")))
          (set-frame-local! 'current-group current)
          (set-frame-local! 'previous-group previous)
          (set-frame-local! 'pinned-group pinned)
          (set-frame-local! 'winner-pos 7)

          (let ((saved (group-frame-context-state)))
            (set-frame-local! 'current-group #f)
            (set-frame-local! 'previous-group #f)
            (set-frame-local! 'pinned-group #f)
            (group-frame-context-restore! saved)
            (check-equal! (frame-local 'current-group) current "the current group came back")
            (check-equal! (frame-local 'previous-group) previous "and the previous one")
            (check-equal! (frame-local 'pinned-group) pinned "and the pin came back")
            (check-equal! (frame-local 'winner-pos) 7 "and the runtime local is untouched"))

          ;; malformed entries are skipped, one by one
          (group-frame-context-restore!
            (list 'bad
                  (list (selected-frame)
                        (list (list 'current-group)
                              (list 'current-group 42)
                              (list 'previous-group previous)
                              (list 'pinned-group pinned)))))
          (check-false! (frame-local 'current-group) "a malformed pair clears rather than guesses")
          (check-equal! (frame-local 'previous-group) previous "a good pair still lands")
          (check-equal! (frame-local 'pinned-group) pinned "the valid pin still lands")
          (check-equal! (frame-local 'winner-pos) 7 "and the runtime local is still untouched")

          ;; a group whose record goes stops being the frame's context
          (let ((deleted (group-record-create! "zzgs-frame-deleted")))
            (set-frame-local! 'current-group deleted)
            (set-frame-local! 'previous-group deleted)
            (set-frame-local! 'pinned-group deleted)
            (group-record-delete! deleted)
            (check-false! (frame-local 'current-group) "the deleted id is cleared")
            (check-false! (frame-local 'previous-group) "the previous id is cleared")
            (check-false! (frame-local 'pinned-group) "the pin is cleared"))

          (t--gs-drop! current previous pinned))))))

(deftest 'invalid-group-noise-normalizes-to-quiet
  "a setting nobody defined is the quiet one, not an error"
  (lambda ()
    (let ((id (group-record-create! "zzgs-noise")))
      (group-noise-set! id "unknown")
      (check-equal! (group-noise id) "quiet" "unknown reads as quiet")
      (t--gs-drop! id))))
