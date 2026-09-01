;;; chat-unstick-test.scm --- a chat can show a turn that no runtime runs.
;;;
;;; The turn flag is a conversation local, so it survives a restart. When
;;; the turn-end event is lost — a reload mid-turn, a crashed handler —
;;; the flag stays up forever: the dead-runtime recovery does not fire,
;;; because the runtime is alive, and no later event clears it. The chat
;;; then shows a hung tool call, and RET looks broken. chat-drop-stale-turn!
;;; lands what the lost turn-end would have landed, and M-x chat-unstick
;;; is the manual door.

(domain! 'testing)
(effects! '(read))

(define t--us-buf "*zz-unstick*")

;; a block in the transcript shape: (start end kind id title body status pos)
(define (t--us-tool-block status)
  (list 0 10 "tool" "t1" "a title" #f status 0))

(effects! '(write))

(define (t--us-chat! turn-active?)
  (test-buffer! t--us-buf "")
  (buffer-set-local! t--us-buf 'agent-saved-mark 1)
  (buffer-set-local! t--us-buf 'chat-turn-active turn-active?)
  (buffer-set-local! t--us-buf 'chat-activity "tool · eval")
  (buffer-set-local! t--us-buf 'agent-blocks (list (t--us-tool-block "running")))
  t--us-buf)

(deftest 'drop-stale-turn-lands-the-lost-turn-end
  "the flag clears, the activity row goes, the tool card fails"
  (lambda ()
    (let ((buf (t--us-chat! #t)))
      (chat-drop-stale-turn! buf)
      (check-false! (buffer-local buf 'chat-turn-active) "the turn flag is down")
      (check-false! (buffer-local buf 'chat-activity) "the activity row is gone")
      (check-equal! (nth 6 (car (buffer-local buf 'agent-blocks))) "failed"
                    "the running tool card is finalized")
      (buffer-kill! buf))))

(deftest 'a-chat-without-a-runtime-is-not-the-stale-case
  "the dead-runtime path keeps its own recovery; stale? says #f"
  (lambda ()
    (let ((buf (t--us-chat! #t)))
      (check-false! (chat-turn-stale? buf)
                    "no live runtime means not stale — recovery re-attaches instead")
      (buffer-kill! buf))))

(deftest 'chat-unstick-clears-a-hung-turn
  "the command is the manual door for the same repair"
  (lambda ()
    (let ((buf (t--us-chat! #t)))
      (with-current-buffer buf (lambda () (run-command "chat-unstick")))
      (check-false! (buffer-local buf 'chat-turn-active) "the turn flag is down")
      (check-false! (buffer-local buf 'chat-activity) "the activity row is gone")
      (buffer-kill! buf))))

(deftest 'chat-unstick-leaves-a-chat-with-no-turn-alone
  "nothing to clear: the command only reports"
  (lambda ()
    (let ((buf (t--us-chat! #f)))
      (with-current-buffer buf (lambda () (run-command "chat-unstick")))
      (check-false! (buffer-local buf 'chat-turn-active) "still no turn")
      (check-equal! (nth 6 (car (buffer-local buf 'agent-blocks))) "running"
                    "the tool card is untouched")
      (buffer-kill! buf))))

;; the prose-from clamp in agent-flush-prose! needs a live agent for
;; agent-mark, so it is verified against the daemon, not here.

(deftest 'a-live-slug-owned-by-another-buffer-is-not-my-runtime
  "chat-live-runtime? asks the runtime which buffer it serves"
  (lambda ()
    ;; no live runtime carries this slug, so liveness is plainly #f; the
    ;; ownership check itself needs a live agent and is verified against
    ;; the daemon. This pins the harmless half: a dead slug is never live.
    (let ((buf (t--us-chat! #f)))
      (buffer-set-local! buf 'agent-slug "zz-us-fake")
      (check-false! (chat-live-runtime? buf) "a dead slug is not a live runtime")
      (buffer-kill! buf))))

(deftest 'the-runtime-slug-is-the-chats-durable-id
  "same chat, same slug, across calls; two chats never share one; git-ref safe"
  (lambda ()
    (test-buffer! "*zz-us-a*" "")
    (test-buffer! "*zz-us-b*" "")
    (let ((sa (chat-runtime-slug "*zz-us-a*"))
          (sb (chat-runtime-slug "*zz-us-b*")))
      (check-equal! (chat-runtime-slug "*zz-us-a*") sa "the slug is stable")
      (check-false! (equal? sa sb) "two chats never share a slug")
      (check-false! (string-contains? sa ":") "no colon: agent/<slug> is a legal ref")
      (buffer-kill! "*zz-us-a*")
      (buffer-kill! "*zz-us-b*"))))
