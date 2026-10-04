;;; chat-view-test.scm --- The rich chat is a block tree that Scheme composes.
;;;
;;; chat-view-sync! maps the transcript model to 'render-blocks. These tests
;;; call it and read the tree as data; the renderer is tested in Elixir.

(domain! 'testing)
(effects! '(write))

(define (chat-view-test--buffer name)
  (let ((buf (test-buffer! name "hello\nPaint is **fast**.\n▸ run\n{\"x\":1}\ndraft")))
    (buffer-set-local! buf 'agent-blocks
      '((26 34 "tool" "t1" "Read: a.txt" "read" "done" 32 1400)
        (6 26 "prose")
        (0 6 "user" "hello")))
    (buffer-set-local! buf 'agent-saved-mark 34)
    (buffer-set-local! buf 'render-mode "blocks")
    buf))

(define (chat-view-test--children b) (or (plist-get b 'children) '()))

(deftest 'chat-view-composes-the-transcript-as-blocks
  "a rich chat's model becomes the transcript list, the prompt, and the input"
  (lambda ()
    (let ((buf (chat-view-test--buffer "*zz-chat-view*")))
      (chat-view-sync! buf)
      (let* ((tree (buffer-local buf 'render-blocks))
             (list-block (car tree))
             (rows (chat-view-test--children list-block))
             (tool (nth 2 rows))
             (details (car (chat-view-test--children tool)))
             (summary (car (chat-view-test--children details))))
        (check-equal! (length tree) 2 "the transcript and the prompt, no activity")
        (check-equal! (plist-get list-block 'isolate) #t "the transcript is an isolated list")
        (check-equal! (plist-get list-block 'follow) #t "the transcript follows its tail")
        (check-equal! (map (lambda (r) (plist-get r 'tag)) rows)
                      '("c-user" "c-agent" "c-toolcall") "oldest block first")
        (check-equal! (plist-get (nth 1 rows) 'range) '(6 26) "prose is a range of the buffer")
        (check-equal! (plist-get (nth 1 rows) 'format) "markdown" "prose draws as Markdown")
        (check-equal! (plist-get details 'open) #f "a card starts closed")
        (check-equal! (length (chat-view-test--children details)) 1
                      "a closed card draws its summary and no body")
        (check-equal! (plist-get summary 'click) "chat-card:t1" "the summary toggles its card")
        (check-equal! (buffer-local buf 'render-input) "agent-saved-mark"
                      "the input starts at the chat mark")
        (check-equal! (plist-get (car (buffer-local buf 'render-root)) 'tag) #f
                      "the root is one plist")
        (check-equal! (plist-get (buffer-local buf 'render-root) 'class) "agent-view"
                      "the root names the chat's layout"))
      (buffer-kill! buf))))

(deftest 'chat-view-keeps-older-views-when-a-block-lands
  "a pushed block adds one view and keeps every older view"
  (lambda ()
    (let ((buf (chat-view-test--buffer "*zz-chat-view-push*")))
      (chat-view-sync! buf)
      (let ((before (chat-view-test--children (car (buffer-local buf 'render-blocks)))))
        (agent-block-push! buf 34 34 "meta" '())
        (chat-view-sync! buf)
        (let ((after (chat-view-test--children (car (buffer-local buf 'render-blocks)))))
          (check-equal! (length after) 4 "the new block has a view")
          (check-equal! (reverse (cdr (reverse after))) before "the older views are the same")))
      (buffer-kill! buf))))

(deftest 'chat-view-card-click-opens-the-card
  "the block click on a card summary opens the card and drops its preview"
  (lambda ()
    (let ((buf (chat-view-test--buffer "*zz-chat-view-card*")))
      (chat-view-sync! buf)
      (check-true! (run-hook-with-args-until-success 'block-click buf "chat-card:t1")
                   "the chat handles its own click")
      (let* ((tool (nth 2 (chat-view-test--children (car (buffer-local buf 'render-blocks)))))
             (details (car (chat-view-test--children tool))))
        (check-equal! (plist-get details 'open) #t "the card is open")
        (check-equal! (length (chat-view-test--children details)) 2 "an open card draws its body")
        (check-equal! (agent-open-cards buf) '("t1") "the open set holds the card"))
      (buffer-kill! buf))))

(deftest 'chat-view-plain-view-writes-no-tree
  "a plain chat keeps no block tree"
  (lambda ()
    (let ((buf (chat-view-test--buffer "*zz-chat-view-plain*")))
      (buffer-set-local! buf 'render-mode "plain")
      (chat-view-sync! buf)
      (check-equal! (buffer-local buf 'render-blocks) #f "no tree")
      (buffer-kill! buf))))

(deftest 'chat-view-activity-follows-the-runtime
  "the activity row is a view of the runtime, not a record of the last event"
  (lambda ()
    ;; the decision, with no buffer and no runtime in it
    (check-equal! (chat-activity-shown "streaming" 'running) "streaming"
                  "a running turn says what it is doing")
    (check-equal! (chat-activity-shown "needs permission" 'needs_attention)
                  "needs permission" "waiting on the reader still shows")
    (check-equal! (chat-activity-shown "starting agent…" #f) "starting agent…"
                  "a chat with no runtime yet keeps its label")
    (check-false! (chat-activity-shown "streaming" 'idle)
                  "an idle runtime outranks the label: the turn-end was lost")
    (check-false! (chat-activity-shown "streaming" 'dead)
                  "a backend that exited is not working either")
    (check-false! (chat-activity-shown "streaming" 'api)
                  "a chat with no runtime is not working")
    (check-false! (chat-activity-shown #f 'running) "no label, no row")
    (check-false! (chat-activity-shown "tool · eval" 'running)
                  "a running tool shows as its block, not again in the row")
    (check-equal! (chat-activity-shown "thinking · reading" 'running)
                  "thinking · reading" "thinking still shows")
    ;; the same three statuses decide it in the event handler, so the two
    ;; cannot drift apart
    (check-equal! *agent-working-statuses* '(running needs_attention starting)
                  "the working statuses are the ones the row captions")
    ;; and the tree carries the decision
    (let ((buf (chat-view-test--buffer "*zz-chat-view-activity*")))
      (buffer-set-local! buf 'chat-activity "streaming")
      (chat-view-sync! buf)
      (check-true! (re-match? "ag-activity"
                              (value->string (buffer-local buf 'render-blocks)))
                   "the row is in the tree while the work runs")
      (buffer-set-local! buf 'chat-activity #f)
      (chat-view-sync! buf)
      (check-false! (re-match? "ag-activity"
                               (value->string (buffer-local buf 'render-blocks)))
                    "the turn ends and the row leaves the tree")
      (buffer-kill! buf))))

(deftest 'chat-view-labels
  "the card's duration and token labels"
  (lambda ()
    (check-equal! (chat-view-duration-label 340) "340ms" "milliseconds")
    (check-equal! (chat-view-duration-label 1400) "1.4s" "seconds, one decimal")
    (check-equal! (chat-view-duration-label 125000) "2m 05s" "minutes")
    (check-equal! (chat-view-duration-label #f) #f "no duration")
    (check-equal! (chat-view-token-label 3) #f "too small to say")
    (check-equal! (chat-view-token-label 400) "~100 tok" "tokens")
    (check-equal! (chat-view-token-label 6000) "~1.5k tok" "thousands")))

(deftest 'chat-view-reuses-views-after-an-excise
  "a change deep in the model keeps the views of the unchanged blocks"
  (lambda ()
    (let ((buf (chat-view-test--buffer "*zz-chat-view-deep*")))
      (chat-view-sync! buf)
      (buffer-set-local! buf 'agent-blocks
        '((26 34 "tool" "t1" "Read: a.txt" "read" "done" 32 1400)
          (6 20 "prose")
          (0 6 "user" "hello")))
      (chat-view-sync! buf)
      (let ((rows (chat-view-test--children (car (buffer-local buf 'render-blocks)))))
        (check-equal! (length rows) 3 "every block has a view")
        (check-equal! (plist-get (nth 1 rows) 'range) '(6 20) "the changed block is new"))
      (buffer-kill! buf))))

;; The transcript window. The test chat's blocks hold 6, 20 and 8 bytes,
;; oldest first. A budget of 15 draws only the newest block.
(define (chat-view-test--with-window bytes thunk)
  (let ((was chat-view-window-bytes))
    (set! chat-view-window-bytes bytes)
    (let ((r (thunk)))
      (set! chat-view-window-bytes was)
      r)))

(define (chat-view-test--drawn buf)
  (map (lambda (r) (plist-get r 'class))
       (chat-view-test--children (car (buffer-local buf 'render-blocks)))))

(deftest 'chat-view-draws-the-newest-blocks-within-the-budget
  "a transcript over the byte budget draws its newest blocks and a row that names the hidden count"
  (lambda ()
    (let ((buf (chat-view-test--buffer "*zz-chat-view-window*")))
      (chat-view-test--with-window 15
        (lambda ()
          (chat-view-sync! buf)
          (let ((rows (chat-view-test--children (car (buffer-local buf 'render-blocks)))))
            (check-equal! (length rows) 2 "the earlier row and the newest block")
            (check-equal! (plist-get (car rows) 'class) "ag-earlier" "the earlier row comes first")
            (check-equal! (plist-get (car (chat-view-test--children (car rows))) 'text)
                          "Show earlier blocks (2 hidden)" "the row names the hidden count")
            (check-equal! (plist-get (cadr rows) 'tag) "c-toolcall" "the newest block draws")
            (check-equal! (plist-get (car (buffer-local buf 'render-blocks)) 'index-base) 1
                          "the newest block keeps index 2, its place in the whole transcript"))))
      (buffer-kill! buf))))

(deftest 'chat-view-earlier-click-reveals-one-more-budget
  "the earlier row's click draws one more budget of earlier blocks"
  (lambda ()
    (let ((buf (chat-view-test--buffer "*zz-chat-view-earlier*")))
      (chat-view-test--with-window 15
        (lambda ()
          (chat-view-sync! buf)
          (check-true! (run-hook-with-args-until-success 'block-click buf "chat-earlier")
                       "the chat handles its own click")
          (let ((rows (chat-view-test--children (car (buffer-local buf 'render-blocks)))))
            (check-equal! (map (lambda (r) (plist-get r 'tag)) (cdr rows))
                          '("c-agent" "c-toolcall") "the prose block draws now")
            (check-equal! (plist-get (car (chat-view-test--children (car rows))) 'text)
                          "Show earlier blocks (1 hidden)" "one block stays hidden"))))
      (buffer-kill! buf))))

(deftest 'chat-view-window-zero-draws-everything
  "a budget of 0 turns the window off"
  (lambda ()
    (let ((buf (chat-view-test--buffer "*zz-chat-view-nowindow*")))
      (chat-view-test--with-window 0
        (lambda ()
          (chat-view-sync! buf)
          (check-equal! (length (chat-view-test--children (car (buffer-local buf 'render-blocks))))
                        3 "every block draws, and no earlier row")))
      (buffer-kill! buf))))

(deftest 'chat-view-reveal-passes-a-block-over-the-budget
  "a block larger than the budget still leaves each reveal one more block"
  (lambda ()
    (let ((buf (chat-view-test--buffer "*zz-chat-view-big*")))
      (chat-view-test--with-window 4
        (lambda ()
          (chat-view-sync! buf)
          (run-hook-with-args-until-success 'block-click buf "chat-earlier")
          (check-equal! (plist-get (car (chat-view-test--children
                                           (car (chat-view-test--children
                                                  (car (buffer-local buf 'render-blocks))))))
                                   'text)
                        "Show earlier blocks (1 hidden)" "the 20-byte block draws after one reveal")))
      (buffer-kill! buf))))
