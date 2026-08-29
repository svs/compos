;;; chat-name-test.scm --- a chat is named for the work it accompanies.
;;;
;;; The name is DERIVED, never invented: *chat:<group>*, and a group founded
;;; on one buffer carries that buffer's name. So the chat reads as the work
;;; beside it, and it follows that work when the name moves.
;;;
;;; A small model used to title a chat from its recent turns. That is gone.
;;; It cost a call every third turn, the title drifted away from the buffer
;;; the chat accompanies, and a stale title stranded every store that named
;;; the chat.
;;;
;;; M-x buffer-rename on a chat still sticks: a name the person typed is not
;;; the derived one, so no re-derive takes it back.
;;;
;;; The rename keeps the buffer's process, so the transcript, the point, the
;;; presets and a live agent thread all survive it.

(domain! 'testing)
(effects! '(write))

(define (t--rn-kill! &rest names)
  (for-each (lambda (n) (when (buffer-known? n) (buffer-kill! n))) names))

(define (t--rn-drop! &rest ids)
  (for-each (lambda (id) (when (group-record-by-id id) (group-record-delete! id))) ids))

;;; --- what a turn is -----------------------------------------------------------

(deftest 'a-turn-is-a-user-message-in-the-record-or-an-m-o-response
  "a record wins, because that is the surface that has one"
  (lambda ()
    (let ((buf (test-buffer! "*zz-turns*" "")))
      (check-equal! (chat-turn-count buf) 0 "an empty buffer has no turns")

      (buffer-set-local! buf 'llm-responses '((0 4) (5 9)))
      (check-equal! (chat-turn-count buf) 2 "two M-o responses are two turns")

      (chat-record-push! buf "user" (list (list "text" "hi")) #f)
      (chat-record-push! buf "assistant" (list (list "text" "ho")) #f)
      (check-equal! (chat-turn-count buf) 1 "the record answers, not the responses")
      (t--rn-kill! buf))))

;;; --- the derived name ---------------------------------------------------------

(deftest 'a-chat-is-named-for-its-group
  "the group's label is the chat's name, and a path label reads as its file"
  (lambda ()
    (let ((id (group-record-create! "zzname-plain")))
      (check-equal! (group-chat-name id) "*chat:zzname-plain*" "a plain label")
      (t--rn-drop! id))
    (let ((id (group-record-create! "/zz/deep/notes.md")))
      (check-equal! (group-chat-name id) "*chat:notes.md*"
                    "a path label reads as the file, not the path")
      (t--rn-drop! id))))

(deftest 'renaming-a-group-renames-its-chat
  "the chat is named for the group, so it follows the group"
  (lambda ()
    (let* ((id (group-record-create! "zzname-before"))
           (chat (group-chat id)))
      (check-equal! chat "*chat:zzname-before*" "the chat is born named for its group")

      (group-rename! id "zzname-after")
      (check-true! (buffer-known? "*chat:zzname-after*") "the chat took the new name")
      (check-false! (buffer-known? "*chat:zzname-before*") "and left the old one")

      (t--rn-drop! id)
      (t--rn-kill! "*chat:zzname-before*" "*chat:zzname-after*"))))

(deftest 'renaming-the-buffer-a-group-is-named-for-moves-the-group-and-the-chat
  "the reported case: the work is renamed and the chat beside it follows"
  (lambda ()
    (let* ((doc (test-buffer! "*zz-doc-before*" "text\n"))
           (id (group-record-create! "*zz-doc-before*"))
           (chat (group-chat id)))
      (check-equal! chat "*chat:*zz-doc-before**" "the chat is named for the buffer")

      (rename-buffer! doc "*zz-doc-after*")

      (check-equal! (group-name id) "*zz-doc-after*" "the group followed the buffer")
      (check-true! (buffer-known? "*chat:*zz-doc-after**") "and the chat followed the group")

      (t--rn-drop! id)
      (t--rn-kill! "*zz-doc-before*" "*zz-doc-after*"
                   "*chat:*zz-doc-before**" "*chat:*zz-doc-after**"))))

(deftest 'a-name-the-person-typed-sticks
  "a manual rename is not the derived name, so no re-derive replaces it"
  (lambda ()
    (let* ((id (group-record-create! "zzname-manual"))
           (chat (group-chat id)))
      (rename-buffer! chat "*my own name*")
      (check-equal! (group-chat-rederive! id) "*my own name*"
                    "the re-derive leaves it alone")
      (check-true! (buffer-known? "*my own name*") "the typed name is still there")
      (check-false! (buffer-known? "*chat:zzname-manual*") "and the derived one is not back")

      (t--rn-drop! id)
      (t--rn-kill! "*chat:zzname-manual*" "*my own name*"))))

(deftest 'a-chat-the-old-namer-titled-goes-back-to-its-groups-name
  "no memory of a derived name means the name predates the rule"
  (lambda ()
    (let ((id (group-record-create! "zzname-legacy"))
          (chat (test-buffer! "*fix the preset merge*" "")))
      (chat-set-group! chat id)
      (group-record-update! id 'primary-chat-id (chat-stable-id! chat))
      (check-false! (buffer-local chat 'chat-derived-name)
                    "the legacy chat carries no derived name")

      (let ((moved (group-chat-derive-all!)))
        (check-true! (member (list chat "*chat:zzname-legacy*") moved)
                     "the sweep reports the move"))
      (check-true! (buffer-known? "*chat:zzname-legacy*") "the chat took its group's name")
      (check-false! (buffer-known? chat) "and left the title behind")

      ;; and now it remembers, so a name the person types is kept
      (rename-buffer! "*chat:zzname-legacy*" "*mine*")
      (check-equal! (group-chat-rederive! id) "*mine*" "the typed name stays")

      (t--rn-drop! id)
      (t--rn-kill! chat "*chat:zzname-legacy*" "*mine*"))))

(deftest 'the-derived-name-is-an-identity-local
  "who the chat is, so it survives a reset, a restart and a save"
  (lambda ()
    (check-true! (member 'chat-derived-name chat-identity-locals)
                 "the derived name is an identity local")))

;;; --- the rename mechanism -----------------------------------------------------

(deftest 'the-buffer-keeps-its-process-so-everything-in-it-survives
  "text, point, locals and the undo history all come with the name"
  (lambda ()
    (let ((buf (test-buffer! "*zz-keep*" "one\ntwo\n")))
      (buffer-set-local! buf 'chat-presets '(compos))
      (buffer-goto! buf 4)
      (buffer-insert! buf 8 "three\n")

      (check-equal! (rename-buffer! buf "*zz-named-keep*") "*zz-named-keep*" "the new name")
      (check-false! (buffer-known? buf) "the old name is gone")
      (check-equal! (buffer-text "*zz-named-keep*") "one\ntwo\nthree\n" "the text came with it")
      (check-equal! (buffer-point "*zz-named-keep*") 4 "and the point")
      (check-equal! (buffer-local "*zz-named-keep*" 'chat-presets) '(compos) "and the locals")

      ;; the undo history came with it
      (with-current-buffer "*zz-named-keep*" (lambda () (undo!)))
      (check-equal! (buffer-text "*zz-named-keep*") "one\ntwo\n" "and the undo history")
      (t--rn-kill! "*zz-named-keep*"))))

(deftest 'a-name-that-is-taken-is-refused
  "the buffer keeps the name it has, and the other buffer is untouched"
  (lambda ()
    (let ((buf (test-buffer! "*zz-collide*" "x")))
      (test-buffer! "*zz-named-collide*" "y")
      (check-false! (rename-buffer! buf "*zz-named-collide*") "a taken name is refused")
      (check-false! (rename-buffer! buf buf) "and so is its own")
      (check-true! (buffer-known? buf) "the buffer is still there")
      (check-equal! (buffer-text "*zz-named-collide*") "y" "and the other one is untouched")
      (t--rn-kill! buf "*zz-named-collide*"))))

(deftest 'the-m-o-change-hook-moves-with-the-buffer
  "a hook keyed on the name must follow the name"
  (lambda ()
    (let ((buf (test-buffer! "*zz-hooked*" "text\n"))
          (hooks-for (lambda (n)
                       (length (filter (lambda (h) (equal? (car h) n)) *llm-mode-hooks*)))))
      (enable-minor-mode! buf "llm-mode")
      (check-equal! (hooks-for buf) 1 "the hook is registered")

      (rename-buffer! buf "*zz-named-hooked*")
      (check-equal! (hooks-for buf) 0 "nothing is left under the old name")
      (check-equal! (hooks-for "*zz-named-hooked*") 1 "and one sits under the new one")

      ;; killing the buffer does not take the hook with it
      (disable-minor-mode! "*zz-named-hooked*" "llm-mode")
      (t--rn-kill! "*zz-named-hooked*"))))
