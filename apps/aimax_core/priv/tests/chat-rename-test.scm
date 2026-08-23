;;; chat-rename-test.scm --- a chat names itself from its own content.
;;;
;;; After the first turn, then every third turn, a small model reads the
;;; recent turns and the buffer takes that name. The rename keeps the
;;; buffer's process, so nothing in it moves.
;;;
;;; Two tests stay in ExUnit. One starts an agent and reads the buffer ref
;;; the session holds. One presses C-c s.

(domain! 'testing)
(effects! '(write))

(define (t--rn-kill! &rest names)
  (for-each (lambda (n) (when (buffer-known? n) (buffer-kill! n))) names))

;;; --- the cadence --------------------------------------------------------------

(deftest 'a-chat-renames-on-the-first-turn-then-every-third
  "the cadence is the whole cost control: one small call, rarely"
  (lambda ()
    (for-each
      (lambda (row)
        (check-equal! (chat-rename-turn? (car row)) (cadr row)
                      (string-append "turn " (number->string (car row)))))
      '((0 #f) (1 #t) (2 #f) (3 #f) (4 #t) (5 #f) (6 #f) (7 #t) (10 #t)))))

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

;;; --- the name -----------------------------------------------------------------

(deftest 'a-title-becomes-a-buffer-name
  "one line, no asterisks, no paths"
  (lambda ()
    (check-equal! (chat-rename-clean "  fix the preset merge \n")
                  "fix the preset merge" "trimmed")
    (check-equal! (chat-rename-clean "\"the *preset* merge/order\"")
                  "the preset merge order" "no quotes, asterisks or slashes")
    (check-equal! (chat-rename-clean "a\nb") "a b" "one line")))

(deftest 'two-chats-about-one-subject-get-numbered
  "the second one is not refused, it is numbered"
  (lambda ()
    (test-buffer! "*zztaken subject*" "")
    (check-equal! (chat-rename-unique "*me*" "zztaken subject")
                  "*zztaken subject 2*" "the taken name is numbered")
    (check-equal! (chat-rename-unique "*me*" "zzfree subject")
                  "*zzfree subject*" "a free name is taken as it is")
    (t--rn-kill! "*zztaken subject*")))

(deftest 'a-chats-own-name-is-not-a-collision
  "the same title on the same buffer stays a no-op"
  (lambda ()
    (test-buffer! "*zzsame subject*" "")
    (check-equal! (chat-rename-unique "*zzsame subject*" "zzsame subject")
                  "*zzsame subject*" "its own name is free for it")
    (t--rn-kill! "*zzsame subject*")))

(deftest 'a-chat-in-a-file-keeps-the-name-of-its-file
  "a file buffer is named by its path, and nothing renames it"
  (lambda ()
    (let ((path (string-append (aimax-home) "/zz-rename.chat")))
      (write-file! path "### You\nhi\n")
      (find-file path)
      (check-false! (chat-renameable? path) "a file chat keeps its path")
      (check-false! (chat-renameable? "*zz-not-a-file*") "an absent buffer is not renameable")
      (let ((buf (test-buffer! "*zz-renameable*" "")))
        (check-true! (chat-renameable? buf) "an ordinary chat buffer is")
        (t--rn-kill! buf))
      (t--rn-kill! path)
      (delete-file! path))))

;;; --- the rename itself --------------------------------------------------------

(deftest 'the-buffer-keeps-its-process-so-everything-in-it-survives
  "text, point, locals and the undo history all come with the name"
  (lambda ()
    (let ((buf (test-buffer! "*zz-keep*" "one\ntwo\n")))
      (buffer-set-local! buf 'chat-presets '(aimax))
      (buffer-goto! buf 4)
      (buffer-insert! buf 8 "three\n")

      (check-equal! (rename-buffer! buf "*zz-named-keep*") "*zz-named-keep*" "the new name")
      (check-false! (buffer-known? buf) "the old name is gone")
      (check-equal! (buffer-text "*zz-named-keep*") "one\ntwo\nthree\n" "the text came with it")
      (check-equal! (buffer-point "*zz-named-keep*") 4 "and the point")
      (check-equal! (buffer-local "*zz-named-keep*" 'chat-presets) '(aimax) "and the locals")

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

;;; --- the call -----------------------------------------------------------------

;; llm-tools is the model seam, and it is Scheme. Save the real one FIRST:
;; saving it after the stub saves the STUB, and the restore then installs
;; the stub for every later test in the run.
(define (t--rn-with-model reply thunk)
  (let ((real llm-tools)
        (calls '()))
    (set! llm-tools
      (lambda (prompt system specs disp cb usage model)
        (set! calls (cons (list prompt model) calls))
        (cb reply)))
    (let ((out (thunk (lambda () calls))))
      (set! llm-tools real)
      out)))

(deftest 'one-call-to-the-naming-model-per-naming-turn
  "the turn is stamped, so a second pass is not a second call"
  (lambda ()
    (let ((buf (test-buffer! "*zz-call*" "")))
      (chat-record-push! buf "user" (list (list "text" "zz preset merge")) #f)
      (t--rn-with-model "zz preset merge"
        (lambda (calls)
          (chat-rename-from-content! buf)
          (check-equal! (length (calls)) 1 "one call")
          (check-equal! (cadr (car (calls))) "openai:gpt-5.6-luna" "the small model")
          (check-contains! (car (car (calls))) "Name this editor conversation" "the prompt")
          (check-contains! (car (car (calls))) "zz preset merge" "carries the turn")
          (check-true! (buffer-known? "*zz preset merge*") "the buffer took the name")

          ;; the turn is stamped, so a second pass on it is not a second call
          (chat-rename-from-content! "*zz preset merge*")
          (check-equal! (length (calls)) 1 "still one call")))
      (t--rn-kill! buf "*zz preset merge*"))))

(deftest 'chat-auto-rename-off-means-no-call-at-all
  "the setting is read before the model is reached, not after"
  (lambda ()
    (let ((buf (test-buffer! "*zz-off*" "")))
      (chat-record-push! buf "user" (list (list "text" "something")) #f)
      (customize-set! 'chat-auto-rename #f)
      (t--rn-with-model "nope"
        (lambda (calls)
          (chat-rename-from-content! buf)
          (check-equal! (length (calls)) 0 "no call")))
      (customize-set! 'chat-auto-rename #t)
      (check-true! (buffer-known? buf) "and the buffer keeps its name")
      (t--rn-kill! buf))))

(deftest 'the-naming-turn-is-part-of-the-conversation
  "a reset clears the stamp, so the chat names itself again"
  (lambda ()
    (check-true! (member 'chat-renamed-at chat-conversation-locals)
                 "the stamp is a conversation local")))
